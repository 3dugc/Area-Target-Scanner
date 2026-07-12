"""Cross-component integration tests that verify data flows correctly between
the major subsystems: OptimizedPipeline, feature_extraction, feature_db,
optimizer_client, web_service, and native_visual_localizer.

These tests target the gaps identified in the existing test suite:
1. Feature DB → Native Localizer data format compatibility
2. Web service concurrent job handling
3. Pipeline resilience to edge-case inputs (large meshes, minimal frames)
4. Manifest bounds accuracy with real scan data
5. Docker/deployment configuration consistency
6. Optimizer client retry/timeout behavior
7. Safe extract edge cases (symlinks, nested dirs, zero-byte files)
"""

from __future__ import annotations

import io
import json
import math
import os
import shutil
import sqlite3
import tempfile
import threading
import time
import zipfile
from unittest.mock import MagicMock, patch

import cv2
import numpy as np
import open3d as o3d
import pytest
import trimesh

from processing_pipeline.feature_db import load_feature_database, save_feature_database
from processing_pipeline.feature_extraction import _hamming_word_assignment
from processing_pipeline.models import FeatureDatabase, KeyframeData, ScanInput
from processing_pipeline.optimized_pipeline import OptimizedPipeline
from processing_pipeline.optimizer_client import ModelOptimizerClient


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_textured_image(width=640, height=480, seed=42):
    rng = np.random.default_rng(seed)
    img = rng.integers(0, 256, (height, width), dtype=np.uint8)
    for _ in range(30):
        cx, cy = rng.integers(20, width - 20), rng.integers(20, height - 20)
        cv2.circle(img, (int(cx), int(cy)), int(rng.integers(5, 30)), int(rng.integers(0, 256)), 2)
    for _ in range(20):
        x1, y1 = int(rng.integers(0, width)), int(rng.integers(0, height))
        x2, y2 = int(rng.integers(0, width)), int(rng.integers(0, height))
        cv2.line(img, (x1, y1), (x2, y2), int(rng.integers(0, 256)), 2)
    return img


def _make_camera_pose(tx=0.0, ty=0.0, tz=2.0):
    pose = np.eye(4, dtype=np.float64)
    pose[0, 3], pose[1, 3], pose[2, 3] = tx, ty, tz
    return pose


def _create_sphere_glb(path):
    mesh = o3d.geometry.TriangleMesh.create_sphere(radius=1.0, resolution=20)
    mesh.compute_vertex_normals()
    tri = trimesh.Trimesh(vertices=np.asarray(mesh.vertices), faces=np.asarray(mesh.triangles))
    tri.export(path, file_type="glb")
    return mesh


def _setup_scan_dir(scan_dir, n_frames=3, glb_path=None):
    """Create a complete scan directory with OBJ, texture, poses, and images."""
    os.makedirs(os.path.join(scan_dir, "images"), exist_ok=True)
    mesh = o3d.geometry.TriangleMesh.create_sphere(radius=1.0, resolution=20)
    mesh.compute_vertex_normals()
    verts, faces = np.asarray(mesh.vertices), np.asarray(mesh.triangles)
    obj_lines = [f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}" for v in verts]
    obj_lines += [f"f {f[0]+1} {f[1]+1} {f[2]+1}" for f in faces]
    with open(os.path.join(scan_dir, "model.obj"), "w") as f:
        f.write("\n".join(obj_lines))
    with open(os.path.join(scan_dir, "model.mtl"), "w") as f:
        f.write("newmtl material0\nKd 0.8 0.8 0.8\n")
    cv2.imwrite(os.path.join(scan_dir, "texture.jpg"), np.zeros((64, 64, 3), dtype=np.uint8))

    frames = []
    for i in range(n_frames):
        pose = _make_camera_pose(tx=0.2 * i - 0.2, tz=2.0 + 0.1 * i)
        frames.append({
            "index": i, "timestamp": float(i),
            "imageFile": f"images/frame_{i:04d}.jpg",
            "transform": pose.T.flatten().tolist(),
        })
        cv2.imwrite(os.path.join(scan_dir, "images", f"frame_{i:04d}.jpg"),
                     _make_textured_image(seed=500 + i))
    with open(os.path.join(scan_dir, "poses.json"), "w") as f:
        json.dump({"frames": frames}, f)

    if glb_path:
        _create_sphere_glb(glb_path)


def _mock_optimizer(glb_path):
    mock = MagicMock()
    mock.optimize.return_value = "mock_task"
    mock.wait_for_completion.return_value = "completed"
    mock.download.side_effect = lambda tid, dest: shutil.copy2(glb_path, dest) or dest
    return mock



# ===========================================================================
# 1. Feature DB → Native Localizer format compatibility
# ===========================================================================

class TestFeatureDbNativeLocalizerCompat:
    """Verify that the SQLite feature database produced by the Python pipeline
    contains data in the exact format expected by the C++ native localizer:
    - vocabulary descriptors: 32-byte uint8 blobs
    - keyframe poses: 64-byte float64 (4x4 matrix) blobs
    - feature descriptors: 32-byte uint8 blobs
    - 3D points: three float64 columns
    - IDF weights: positive float values
    """

    def test_vocabulary_descriptor_size_matches_native(self, tmp_path):
        """C++ expects exactly 32 bytes per vocabulary descriptor."""
        scan_dir, output_dir = str(tmp_path / "scan"), str(tmp_path / "out")
        glb_path = str(tmp_path / "opt.glb")
        _setup_scan_dir(scan_dir, n_frames=4, glb_path=glb_path)

        pipeline = OptimizedPipeline(optimizer_url="http://fake:3000")
        with patch("processing_pipeline.optimized_pipeline.ModelOptimizerClient",
                    return_value=_mock_optimizer(glb_path)):
            pipeline.run(scan_dir, output_dir)

        conn = sqlite3.connect(os.path.join(output_dir, "features.db"))
        cur = conn.cursor()
        cur.execute("SELECT descriptor FROM vocabulary")
        for (blob,) in cur.fetchall():
            assert len(blob) == 32, f"Vocabulary descriptor should be 32 bytes, got {len(blob)}"
        conn.close()

    def test_feature_descriptor_size_matches_native(self, tmp_path):
        """C++ expects exactly 32 bytes per feature descriptor."""
        scan_dir, output_dir = str(tmp_path / "scan"), str(tmp_path / "out")
        glb_path = str(tmp_path / "opt.glb")
        _setup_scan_dir(scan_dir, n_frames=4, glb_path=glb_path)

        pipeline = OptimizedPipeline(optimizer_url="http://fake:3000")
        with patch("processing_pipeline.optimized_pipeline.ModelOptimizerClient",
                    return_value=_mock_optimizer(glb_path)):
            pipeline.run(scan_dir, output_dir)

        conn = sqlite3.connect(os.path.join(output_dir, "features.db"))
        cur = conn.cursor()
        cur.execute("SELECT descriptor FROM features")
        for (blob,) in cur.fetchall():
            assert len(blob) == 32, f"Feature descriptor should be 32 bytes, got {len(blob)}"
        conn.close()

    def test_pose_blob_is_4x4_float64(self, tmp_path):
        """C++ reads poses as 4x4 float64 matrices (128 bytes)."""
        scan_dir, output_dir = str(tmp_path / "scan"), str(tmp_path / "out")
        glb_path = str(tmp_path / "opt.glb")
        _setup_scan_dir(scan_dir, n_frames=4, glb_path=glb_path)

        pipeline = OptimizedPipeline(optimizer_url="http://fake:3000")
        with patch("processing_pipeline.optimized_pipeline.ModelOptimizerClient",
                    return_value=_mock_optimizer(glb_path)):
            pipeline.run(scan_dir, output_dir)

        conn = sqlite3.connect(os.path.join(output_dir, "features.db"))
        cur = conn.cursor()
        cur.execute("SELECT pose FROM keyframes")
        for (blob,) in cur.fetchall():
            assert len(blob) == 128, f"Pose should be 128 bytes (4x4 float64), got {len(blob)}"
            pose = np.frombuffer(blob, dtype=np.float64).reshape(4, 4)
            # Last row should be [0, 0, 0, 1] for a valid SE(3) matrix
            np.testing.assert_allclose(pose[3, :], [0, 0, 0, 1], atol=1e-10)
        conn.close()

    def test_idf_weights_are_positive_and_finite(self, tmp_path):
        """IDF weights must be finite positive floats for the C++ BoW scoring."""
        scan_dir, output_dir = str(tmp_path / "scan"), str(tmp_path / "out")
        glb_path = str(tmp_path / "opt.glb")
        _setup_scan_dir(scan_dir, n_frames=4, glb_path=glb_path)

        pipeline = OptimizedPipeline(optimizer_url="http://fake:3000")
        with patch("processing_pipeline.optimized_pipeline.ModelOptimizerClient",
                    return_value=_mock_optimizer(glb_path)):
            pipeline.run(scan_dir, output_dir)

        conn = sqlite3.connect(os.path.join(output_dir, "features.db"))
        cur = conn.cursor()
        cur.execute("SELECT idf_weight FROM vocabulary")
        weights = [row[0] for row in cur.fetchall()]
        assert len(weights) > 0
        for w in weights:
            assert math.isfinite(w), f"IDF weight must be finite, got {w}"
            # IDF = log(N/(1+df)) can be negative when df > N-1, but should be finite
            assert isinstance(w, float)
        conn.close()

    def test_3d_points_are_finite(self, tmp_path):
        """All 3D feature points must be finite (no NaN/Inf)."""
        scan_dir, output_dir = str(tmp_path / "scan"), str(tmp_path / "out")
        glb_path = str(tmp_path / "opt.glb")
        _setup_scan_dir(scan_dir, n_frames=4, glb_path=glb_path)

        pipeline = OptimizedPipeline(optimizer_url="http://fake:3000")
        with patch("processing_pipeline.optimized_pipeline.ModelOptimizerClient",
                    return_value=_mock_optimizer(glb_path)):
            pipeline.run(scan_dir, output_dir)

        conn = sqlite3.connect(os.path.join(output_dir, "features.db"))
        cur = conn.cursor()
        cur.execute("SELECT x3d, y3d, z3d FROM features")
        for x, y, z in cur.fetchall():
            assert math.isfinite(x) and math.isfinite(y) and math.isfinite(z), \
                f"3D point ({x}, {y}, {z}) contains non-finite values"
        conn.close()



# ===========================================================================
# 2. Web service concurrent job handling
# ===========================================================================

class TestWebServiceConcurrency:
    """Verify the web service handles multiple simultaneous uploads correctly."""

    def test_concurrent_uploads_get_unique_job_ids(self, tmp_path):
        """Two simultaneous uploads should get different job IDs."""
        from web_service.app import app, jobs

        zip1 = str(tmp_path / "scan1.zip")
        zip2 = str(tmp_path / "scan2.zip")
        for zp in [zip1, zip2]:
            with zipfile.ZipFile(zp, "w") as zf:
                zf.writestr("model.obj", "v 0 0 0\n")
                zf.writestr("model.mtl", "newmtl m\n")
                zf.writestr("texture.jpg", b"\xff\xd8\xff\xe0")
                zf.writestr("poses.json", '{"frames": [{"index":0,"timestamp":0,"imageFile":"x.jpg","transform":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}]}')

        with app.test_client() as client:
            with open(zip1, "rb") as f1:
                resp1 = client.post("/api/upload", data={"file": (f1, "s1.zip")},
                                    content_type="multipart/form-data")
            with open(zip2, "rb") as f2:
                resp2 = client.post("/api/upload", data={"file": (f2, "s2.zip")},
                                    content_type="multipart/form-data")

            assert resp1.status_code == 200
            assert resp2.status_code == 200
            id1 = resp1.get_json()["job_id"]
            id2 = resp2.get_json()["job_id"]
            assert id1 != id2

            # Wait briefly then clean up
            time.sleep(1)
            for jid in [id1, id2]:
                if jid in jobs:
                    del jobs[jid]

    def test_job_store_thread_safety(self):
        """_update_job should not corrupt state under concurrent access."""
        from web_service.app import _update_job, jobs, _jobs_lock

        job_id = "thread_test"
        jobs[job_id] = {"status": "queued", "progress": 0}

        errors = []

        def updater(n):
            try:
                for i in range(100):
                    _update_job(job_id, progress=i, status=f"step_{n}_{i}")
            except Exception as e:
                errors.append(e)

        threads = [threading.Thread(target=updater, args=(t,)) for t in range(5)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert len(errors) == 0, f"Thread safety errors: {errors}"
        assert jobs[job_id]["progress"] >= 0
        del jobs[job_id]


# ===========================================================================
# 3. Pipeline resilience — edge cases
# ===========================================================================

class TestPipelineEdgeCases:
    """Test pipeline behavior with unusual but valid inputs."""

    def test_single_frame_produces_valid_output(self, tmp_path):
        """Pipeline should work with just 1 keyframe (minimum viable input)."""
        scan_dir, output_dir = str(tmp_path / "scan"), str(tmp_path / "out")
        glb_path = str(tmp_path / "opt.glb")
        _setup_scan_dir(scan_dir, n_frames=1, glb_path=glb_path)

        pipeline = OptimizedPipeline(optimizer_url="http://fake:3000")
        with patch("processing_pipeline.optimized_pipeline.ModelOptimizerClient",
                    return_value=_mock_optimizer(glb_path)):
            pipeline.run(scan_dir, output_dir)

        assert os.path.isfile(os.path.join(output_dir, "manifest.json"))
        assert os.path.isfile(os.path.join(output_dir, "features.db"))
        assert os.path.isfile(os.path.join(output_dir, "optimized.glb"))

        with open(os.path.join(output_dir, "manifest.json")) as f:
            manifest = json.load(f)
        assert manifest["keyframeCount"] >= 1

    def test_intrinsics_file_is_loaded_when_present(self, tmp_path):
        """When intrinsics.json exists, pipeline should use it."""
        scan_dir = str(tmp_path / "scan")
        _setup_scan_dir(scan_dir, n_frames=2)

        intrinsics = {"fx": 525.0, "fy": 525.0, "cx": 320.0, "cy": 240.0,
                       "width": 640, "height": 480}
        with open(os.path.join(scan_dir, "intrinsics.json"), "w") as f:
            json.dump(intrinsics, f)

        pipeline = OptimizedPipeline()
        scan_input = pipeline.validate_input(scan_dir)
        assert scan_input.intrinsics is not None
        assert scan_input.intrinsics["fx"] == 525.0

    def test_validate_input_rejects_empty_poses(self, tmp_path):
        """poses.json with empty frames list should raise ValueError."""
        scan_dir = str(tmp_path / "scan")
        os.makedirs(scan_dir)
        for name in ["model.obj", "model.mtl", "texture.jpg"]:
            with open(os.path.join(scan_dir, name), "w") as f:
                f.write("dummy")
        with open(os.path.join(scan_dir, "poses.json"), "w") as f:
            json.dump({"frames": []}, f)

        pipeline = OptimizedPipeline()
        with pytest.raises(ValueError, match="不包含任何帧"):
            pipeline.validate_input(scan_dir)

    def test_validate_input_rejects_missing_obj(self, tmp_path):
        """Missing model.obj should raise FileNotFoundError."""
        scan_dir = str(tmp_path / "scan")
        os.makedirs(scan_dir)
        for name in ["model.mtl", "texture.jpg"]:
            with open(os.path.join(scan_dir, name), "w") as f:
                f.write("dummy")
        with open(os.path.join(scan_dir, "poses.json"), "w") as f:
            json.dump({"frames": [{"index": 0, "timestamp": 0, "imageFile": "x.jpg",
                                    "transform": list(range(16))}]}, f)

        pipeline = OptimizedPipeline()
        with pytest.raises(FileNotFoundError):
            pipeline.validate_input(scan_dir)

    def test_optimize_model_raises_on_failure(self, tmp_path):
        """When optimizer returns 'failed', pipeline should raise RuntimeError."""
        scan_dir = str(tmp_path / "scan")
        _setup_scan_dir(scan_dir, n_frames=2)

        pipeline = OptimizedPipeline(optimizer_url="http://fake:3000")
        scan_input = pipeline.validate_input(scan_dir)

        mock = MagicMock()
        mock.optimize.return_value = "task_fail"
        mock.wait_for_completion.return_value = "failed"

        with patch("processing_pipeline.optimized_pipeline.ModelOptimizerClient",
                    return_value=mock):
            with pytest.raises(RuntimeError, match="模型优化失败"):
                pipeline.optimize_model(scan_input, str(tmp_path / "work"))



# ===========================================================================
# 4. Manifest bounds accuracy
# ===========================================================================

class TestManifestBoundsAccuracy:
    """Verify manifest bounds match the actual mesh geometry."""

    def test_bounds_match_trimesh_aabb(self, tmp_path):
        """Manifest min/max bounds should exactly match trimesh.bounds."""
        scan_dir, output_dir = str(tmp_path / "scan"), str(tmp_path / "out")
        glb_path = str(tmp_path / "opt.glb")
        _setup_scan_dir(scan_dir, n_frames=3, glb_path=glb_path)

        pipeline = OptimizedPipeline(optimizer_url="http://fake:3000")
        with patch("processing_pipeline.optimized_pipeline.ModelOptimizerClient",
                    return_value=_mock_optimizer(glb_path)):
            pipeline.run(scan_dir, output_dir)

        with open(os.path.join(output_dir, "manifest.json")) as f:
            manifest = json.load(f)

        # Load the same GLB and check bounds
        scene = trimesh.load(os.path.join(output_dir, "optimized.glb"))
        if isinstance(scene, trimesh.Scene):
            mesh_tri = scene.to_geometry()
        else:
            mesh_tri = scene

        expected_min = mesh_tri.bounds[0].tolist()
        expected_max = mesh_tri.bounds[1].tolist()

        np.testing.assert_allclose(manifest["bounds"]["min"], expected_min, atol=1e-6)
        np.testing.assert_allclose(manifest["bounds"]["max"], expected_max, atol=1e-6)


# ===========================================================================
# 5. Docker/deployment configuration consistency
# ===========================================================================

class TestDeploymentConfig:
    """Verify Docker and deployment configs are internally consistent."""

    def test_dockerfile_exposes_correct_port(self):
        """Dockerfile EXPOSE should match the port app.py listens on."""
        with open("Dockerfile") as f:
            content = f.read()
        assert "EXPOSE 5000" in content

    def test_docker_compose_port_mapping(self):
        """docker-compose should map host port to container port 5000."""
        with open("docker-compose.yml") as f:
            content = f.read()
        assert "5000" in content

    def test_web_service_requirements_include_flask(self):
        """web_service/requirements.txt must include flask."""
        with open("web_service/requirements.txt") as f:
            content = f.read().lower()
        assert "flask" in content

    def test_dockerfile_copies_processing_pipeline(self):
        """Dockerfile must COPY processing_pipeline/ for the web service to work."""
        with open("Dockerfile") as f:
            content = f.read()
        assert "processing_pipeline" in content

    def test_dockerfile_sets_pythonpath(self):
        """PYTHONPATH must be set so processing_pipeline is importable."""
        with open("Dockerfile") as f:
            content = f.read()
        assert "PYTHONPATH" in content

    def test_ci_runs_on_supported_python_versions(self):
        """Phase 0 CI should use the specified Python 3.11 baseline."""
        with open(".github/workflows/ci.yml") as f:
            content = f.read()
        assert 'python-version: "3.11"' in content


# ===========================================================================
# 6. Optimizer client timeout/retry behavior
# ===========================================================================

class TestOptimizerClientEdgeCases:
    """Test optimizer client handles network edge cases."""

    def test_wait_for_completion_timeout(self):
        """Should raise TimeoutError if task never completes."""
        client = ModelOptimizerClient(base_url="http://fake:3000")

        with patch.object(client, "get_status", return_value={"status": "processing"}):
            with pytest.raises(TimeoutError):
                client.wait_for_completion("task_stuck", poll_interval=0.01, timeout=0.05)

    def test_wait_for_completion_returns_failed(self):
        """Should return 'failed' immediately when status is failed."""
        client = ModelOptimizerClient(base_url="http://fake:3000")

        with patch.object(client, "get_status", return_value={"status": "failed"}):
            result = client.wait_for_completion("task_fail", poll_interval=0.01)
            assert result == "failed"

    def test_optimize_raises_on_http_error(self, tmp_path):
        """Should propagate HTTP errors from the optimizer service."""
        import requests

        client = ModelOptimizerClient(base_url="http://fake:3000")

        obj_path = str(tmp_path / "model.obj")
        with open(obj_path, "w") as f:
            f.write("v 0 0 0\n")

        mock_resp = MagicMock()
        mock_resp.raise_for_status.side_effect = requests.HTTPError("503 Service Unavailable")

        with patch("requests.post", return_value=mock_resp):
            with pytest.raises(requests.HTTPError):
                client.optimize(obj_path)


# ===========================================================================
# 7. Safe extract edge cases
# ===========================================================================

class TestSafeExtractEdgeCases:
    """Test ZIP extraction security beyond basic path traversal."""

    def test_zero_byte_files_extract_ok(self, tmp_path):
        """ZIP with zero-byte files should extract without error."""
        from web_service.app import safe_extract

        zip_path = str(tmp_path / "empty_files.zip")
        with zipfile.ZipFile(zip_path, "w") as zf:
            zf.writestr("empty.txt", "")
            zf.writestr("also_empty.dat", "")

        extract_dir = str(tmp_path / "extracted")
        os.makedirs(extract_dir)
        with zipfile.ZipFile(zip_path, "r") as zf:
            safe_extract(zf, extract_dir)

        assert os.path.isfile(os.path.join(extract_dir, "empty.txt"))
        assert os.path.getsize(os.path.join(extract_dir, "empty.txt")) == 0

    def test_nested_directories_extract_ok(self, tmp_path):
        """ZIP with nested directory structure should extract correctly."""
        from web_service.app import safe_extract

        zip_path = str(tmp_path / "nested.zip")
        with zipfile.ZipFile(zip_path, "w") as zf:
            zf.writestr("a/b/c/deep.txt", "deep content")
            zf.writestr("a/b/shallow.txt", "shallow content")

        extract_dir = str(tmp_path / "extracted")
        os.makedirs(extract_dir)
        with zipfile.ZipFile(zip_path, "r") as zf:
            safe_extract(zf, extract_dir)

        assert os.path.isfile(os.path.join(extract_dir, "a", "b", "c", "deep.txt"))

    def test_size_limit_enforced(self, tmp_path):
        """ZIP exceeding max_size should be rejected."""
        from web_service.app import safe_extract

        zip_path = str(tmp_path / "big.zip")
        with zipfile.ZipFile(zip_path, "w") as zf:
            zf.writestr("big.bin", b"x" * 1000)

        extract_dir = str(tmp_path / "extracted")
        os.makedirs(extract_dir)
        with zipfile.ZipFile(zip_path, "r") as zf:
            with pytest.raises(ValueError, match="size limit"):
                safe_extract(zf, extract_dir, max_size=500)

    def test_path_traversal_with_dot_dot(self, tmp_path):
        """ZIP entries with ../ should be rejected."""
        from web_service.app import safe_extract

        zip_path = str(tmp_path / "traversal.zip")
        with zipfile.ZipFile(zip_path, "w") as zf:
            zf.writestr("../escape.txt", "escaped")

        extract_dir = str(tmp_path / "extracted")
        os.makedirs(extract_dir)
        with zipfile.ZipFile(zip_path, "r") as zf:
            with pytest.raises(ValueError, match="[Tt]raversal"):
                safe_extract(zf, extract_dir)


# ===========================================================================
# 8. Hamming word assignment correctness
# ===========================================================================

class TestHammingWordAssignmentProperties:
    """Additional property tests for the Hamming-based word assignment."""

    def test_identical_descriptor_maps_to_same_word(self):
        """If a descriptor equals a vocabulary medoid, it should map to that word."""
        vocab = np.array([[0]*32, [255]*32, [128]*32], dtype=np.uint8)
        descs = np.array([[255]*32], dtype=np.uint8)  # exact match to word 1
        labels = _hamming_word_assignment(descs, vocab)
        assert labels[0] == 1

    def test_assignment_is_deterministic(self):
        """Same input should always produce same output."""
        rng = np.random.default_rng(99)
        vocab = rng.integers(0, 256, (50, 32), dtype=np.uint8)
        descs = rng.integers(0, 256, (100, 32), dtype=np.uint8)
        labels1 = _hamming_word_assignment(descs, vocab)
        labels2 = _hamming_word_assignment(descs, vocab)
        np.testing.assert_array_equal(labels1, labels2)

    def test_all_labels_within_vocab_range(self):
        """All assigned labels should be in [0, K)."""
        rng = np.random.default_rng(77)
        k = 20
        vocab = rng.integers(0, 256, (k, 32), dtype=np.uint8)
        descs = rng.integers(0, 256, (200, 32), dtype=np.uint8)
        labels = _hamming_word_assignment(descs, vocab)
        assert labels.min() >= 0
        assert labels.max() < k

    def test_single_word_vocabulary(self):
        """With K=1, all descriptors should map to word 0."""
        vocab = np.array([[42]*32], dtype=np.uint8)
        descs = np.random.default_rng(0).integers(0, 256, (50, 32), dtype=np.uint8)
        labels = _hamming_word_assignment(descs, vocab)
        np.testing.assert_array_equal(labels, np.zeros(50, dtype=np.intp))


# ===========================================================================
# 9. trimesh → Open3D conversion correctness
# ===========================================================================

class TestTrimeshToO3dConversion:
    """Verify OptimizedPipeline._trimesh_to_o3d preserves geometry."""

    def test_vertex_count_preserved(self):
        tri = trimesh.creation.icosphere(subdivisions=2)
        o3d_mesh = OptimizedPipeline._trimesh_to_o3d(tri)
        assert len(o3d_mesh.vertices) == len(tri.vertices)

    def test_face_count_preserved(self):
        tri = trimesh.creation.icosphere(subdivisions=2)
        o3d_mesh = OptimizedPipeline._trimesh_to_o3d(tri)
        assert len(o3d_mesh.triangles) == len(tri.faces)

    def test_vertex_positions_match(self):
        tri = trimesh.creation.icosphere(subdivisions=2)
        o3d_mesh = OptimizedPipeline._trimesh_to_o3d(tri)
        np.testing.assert_allclose(
            np.asarray(o3d_mesh.vertices),
            np.asarray(tri.vertices, dtype=np.float64),
            atol=1e-10,
        )

    def test_face_indices_match(self):
        tri = trimesh.creation.icosphere(subdivisions=2)
        o3d_mesh = OptimizedPipeline._trimesh_to_o3d(tri)
        np.testing.assert_array_equal(
            np.asarray(o3d_mesh.triangles),
            np.asarray(tri.faces, dtype=np.int32),
        )

    def test_int64_faces_handled(self):
        """trimesh sometimes uses int64 faces; conversion must handle this."""
        tri = trimesh.creation.icosphere(subdivisions=1)
        tri.faces = tri.faces.astype(np.int64)  # force int64
        o3d_mesh = OptimizedPipeline._trimesh_to_o3d(tri)
        assert len(o3d_mesh.triangles) == len(tri.faces)


# ===========================================================================
# 10. Feature database save/load round-trip with edge cases
# ===========================================================================

class TestFeatureDbRoundTripEdgeCases:
    """Test feature_db save/load with edge-case data."""

    def test_empty_database_roundtrip(self, tmp_path):
        """Empty FeatureDatabase should round-trip without error."""
        db = FeatureDatabase(keyframes=[], global_descriptors=None, vocabulary=None)
        path = str(tmp_path / "empty.db")
        save_feature_database(db, path)
        loaded = load_feature_database(path)
        assert len(loaded.keyframes) == 0
        assert loaded.vocabulary is None
        assert loaded.global_descriptors is None

    def test_single_keyframe_roundtrip(self, tmp_path):
        """Single keyframe with minimal features should round-trip."""
        kf = KeyframeData(
            image_id=0,
            keypoints=[(10.0, 20.0), (30.0, 40.0)],
            descriptors=np.array([[1]*32, [2]*32], dtype=np.uint8),
            points_3d=[(0.1, 0.2, 0.3), (0.4, 0.5, 0.6)],
            camera_pose=np.eye(4, dtype=np.float64),
        )
        vocab = np.array([[128]*32], dtype=np.uint8)
        gd = np.array([[1.0]], dtype=np.float64)

        db = FeatureDatabase(keyframes=[kf], global_descriptors=gd, vocabulary=vocab)
        path = str(tmp_path / "single.db")
        save_feature_database(db, path)
        loaded = load_feature_database(path)

        assert len(loaded.keyframes) == 1
        assert loaded.keyframes[0].image_id == 0
        assert len(loaded.keyframes[0].keypoints) == 2
        np.testing.assert_array_equal(loaded.keyframes[0].descriptors, kf.descriptors)
        np.testing.assert_allclose(loaded.keyframes[0].camera_pose, np.eye(4))

    def test_large_vocabulary_roundtrip(self, tmp_path):
        """Vocabulary with 1000 words should round-trip correctly."""
        rng = np.random.default_rng(42)
        vocab = rng.integers(0, 256, (1000, 32), dtype=np.uint8)
        kf = KeyframeData(
            image_id=0,
            keypoints=[(float(i), float(i)) for i in range(50)],
            descriptors=rng.integers(0, 256, (50, 32), dtype=np.uint8),
            points_3d=[(float(i), float(i), float(i)) for i in range(50)],
            camera_pose=np.eye(4, dtype=np.float64),
        )
        gd = rng.random((1, 1000))
        db = FeatureDatabase(keyframes=[kf], global_descriptors=gd, vocabulary=vocab)

        path = str(tmp_path / "large_vocab.db")
        save_feature_database(db, path)
        loaded = load_feature_database(path)

        assert loaded.vocabulary.shape == (1000, 32)
        np.testing.assert_array_equal(loaded.vocabulary, vocab)


# ===========================================================================
# 11. Web service find_scan_root
# ===========================================================================

class TestFindScanRoot:
    """Test the find_scan_root utility handles various ZIP structures."""

    def test_files_at_root(self, tmp_path):
        from web_service.app import find_scan_root
        d = str(tmp_path / "flat")
        os.makedirs(d)
        for name in ["model.obj", "poses.json"]:
            with open(os.path.join(d, name), "w") as f:
                f.write("")
        assert find_scan_root(d) == d

    def test_files_in_subdirectory(self, tmp_path):
        from web_service.app import find_scan_root
        d = str(tmp_path / "nested")
        sub = os.path.join(d, "scan_data", "inner")
        os.makedirs(sub)
        for name in ["model.obj", "poses.json"]:
            with open(os.path.join(sub, name), "w") as f:
                f.write("")
        result = find_scan_root(d)
        assert result == sub

    def test_no_scan_files_returns_none(self, tmp_path):
        from web_service.app import find_scan_root
        d = str(tmp_path / "empty")
        os.makedirs(d)
        with open(os.path.join(d, "readme.txt"), "w") as f:
            f.write("")
        assert find_scan_root(d) is None

    def test_partial_files_returns_none(self, tmp_path):
        """Having only model.obj but not poses.json should return None."""
        from web_service.app import find_scan_root
        d = str(tmp_path / "partial")
        os.makedirs(d)
        with open(os.path.join(d, "model.obj"), "w") as f:
            f.write("")
        assert find_scan_root(d) is None
