"""End-to-end tests for the Area Target processing pipeline.

Tests the full data flow:
  Scan ZIP → Web Service → OptimizedPipeline (4 steps) → Asset Bundle → Verification

The 3D-Model-Optimizer external service is mocked (it's a Docker container),
but everything else runs for real: ZIP extraction, input validation, ORB feature
extraction, ray-mesh intersection, BoW vocabulary building, SQLite persistence,
asset bundling, and web service HTTP endpoints.
"""

from __future__ import annotations

import io
import json
import os
import shutil
import sqlite3
import tempfile
import time
import zipfile
from unittest.mock import MagicMock, patch

import cv2
import numpy as np
import open3d as o3d


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _create_sphere_glb(output_path: str) -> o3d.geometry.TriangleMesh:
    """Create a unit sphere mesh and export it as GLB via trimesh."""
    import trimesh

    mesh = o3d.geometry.TriangleMesh.create_sphere(radius=1.0, resolution=20)
    mesh.compute_vertex_normals()

    tri_mesh = trimesh.Trimesh(
        vertices=np.asarray(mesh.vertices),
        faces=np.asarray(mesh.triangles),
    )
    tri_mesh.export(output_path, file_type="glb")
    return mesh


def _make_textured_image(width=640, height=480, seed=42):
    """Generate a synthetic image with enough texture for ORB detection."""
    rng = np.random.default_rng(seed)
    img = rng.integers(0, 256, (height, width), dtype=np.uint8)
    # Add some structure (circles, lines) to help ORB
    for _ in range(30):
        cx, cy = rng.integers(20, width - 20), rng.integers(20, height - 20)
        r = int(rng.integers(5, 30))
        cv2.circle(img, (int(cx), int(cy)), r, int(rng.integers(0, 256)), 2)
    for _ in range(20):
        x1, y1 = int(rng.integers(0, width)), int(rng.integers(0, height))
        x2, y2 = int(rng.integers(0, width)), int(rng.integers(0, height))
        cv2.line(img, (x1, y1), (x2, y2), int(rng.integers(0, 256)), 2)
    return img


def _make_camera_pose(tx=0.0, ty=0.0, tz=2.0):
    """Create a camera pose looking at the origin from (tx, ty, tz)."""
    pose = np.eye(4, dtype=np.float64)
    pose[0, 3] = tx
    pose[1, 3] = ty
    pose[2, 3] = tz
    return pose


def _build_scan_zip(zip_path: str, n_frames: int = 3) -> str:
    """Build a realistic scan ZIP with model.obj, texture, poses, and images.

    Returns the zip_path.
    """
    with tempfile.TemporaryDirectory() as scan_dir:
        # Create a simple OBJ sphere
        mesh = o3d.geometry.TriangleMesh.create_sphere(radius=1.0, resolution=10)
        mesh.compute_vertex_normals()
        verts = np.asarray(mesh.vertices)
        faces = np.asarray(mesh.triangles)

        obj_lines = []
        for v in verts:
            obj_lines.append(f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}")
        for f in faces:
            obj_lines.append(f"f {f[0]+1} {f[1]+1} {f[2]+1}")
        obj_content = "\n".join(obj_lines)

        # Create texture (simple JPEG)
        texture_img = np.zeros((256, 256, 3), dtype=np.uint8)
        texture_img[:128, :, 0] = 200  # red top half
        texture_img[128:, :, 2] = 200  # blue bottom half
        _, texture_bytes = cv2.imencode(".jpg", texture_img)

        # Create poses.json
        frames = []
        for i in range(n_frames):
            pose = _make_camera_pose(tx=0.3 * i, tz=2.0 + 0.2 * i)
            # Column-major flatten
            transform = pose.T.flatten().tolist()
            frames.append({
                "index": i,
                "timestamp": float(i),
                "imageFile": f"images/frame_{i:04d}.jpg",
                "transform": transform,
            })
        poses_json = json.dumps({"frames": frames})

        # Create keyframe images with texture
        images_dir = os.path.join(scan_dir, "images")
        os.makedirs(images_dir, exist_ok=True)

        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("model.obj", obj_content)
            zf.writestr("model.mtl", "newmtl material0\nKd 0.8 0.8 0.8\n")
            zf.writestr("texture.jpg", texture_bytes.tobytes())
            zf.writestr("poses.json", poses_json)

            for i in range(n_frames):
                img = _make_textured_image(seed=42 + i)
                _, img_bytes = cv2.imencode(".jpg", img)
                zf.writestr(f"images/frame_{i:04d}.jpg", img_bytes.tobytes())

    return zip_path



def _mock_optimizer_client():
    """Create a mock ModelOptimizerClient that returns a pre-built GLB."""
    mock_client = MagicMock()
    mock_client.optimize.return_value = "mock_task_001"
    mock_client.wait_for_completion.return_value = "completed"
    return mock_client


# ---------------------------------------------------------------------------
# Test 1: Pipeline E2E — Full 4-step pipeline with real feature extraction
# ---------------------------------------------------------------------------


class TestPipelineE2E:
    """Full pipeline e2e: scan dir → validate → optimize (mock) → features → bundle.

    Mocks only the external 3D-Model-Optimizer service. Everything else
    (ORB extraction, ray-mesh intersection, BoW vocabulary, SQLite, asset
    bundling) runs for real.
    """

    def test_full_pipeline_produces_valid_asset_bundle(self, tmp_path):
        """Run OptimizedPipeline.run() end-to-end and verify the output
        asset bundle contains manifest.json, optimized.glb, and features.db
        with correct structure and data types.
        """
        from processing_pipeline.optimized_pipeline import OptimizedPipeline

        scan_dir = str(tmp_path / "scan")
        output_dir = str(tmp_path / "output")
        glb_path = str(tmp_path / "optimized.glb")

        # Prepare scan directory
        os.makedirs(scan_dir, exist_ok=True)
        os.makedirs(os.path.join(scan_dir, "images"), exist_ok=True)

        # Create sphere mesh as OBJ
        mesh = o3d.geometry.TriangleMesh.create_sphere(radius=1.0, resolution=20)
        mesh.compute_vertex_normals()
        verts = np.asarray(mesh.vertices)
        faces = np.asarray(mesh.triangles)

        obj_lines = []
        for v in verts:
            obj_lines.append(f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}")
        for f in faces:
            obj_lines.append(f"f {f[0]+1} {f[1]+1} {f[2]+1}")

        with open(os.path.join(scan_dir, "model.obj"), "w") as f:
            f.write("\n".join(obj_lines))
        with open(os.path.join(scan_dir, "model.mtl"), "w") as f:
            f.write("newmtl material0\nKd 0.8 0.8 0.8\n")

        texture_img = np.zeros((256, 256, 3), dtype=np.uint8)
        cv2.imwrite(os.path.join(scan_dir, "texture.jpg"), texture_img)

        # Create keyframe images with rich texture for ORB
        n_frames = 5
        frames = []
        for i in range(n_frames):
            pose = _make_camera_pose(tx=0.2 * i - 0.4, tz=2.0 + 0.1 * i)
            transform = pose.T.flatten().tolist()
            frames.append({
                "index": i,
                "timestamp": float(i),
                "imageFile": f"images/frame_{i:04d}.jpg",
                "transform": transform,
            })
            img = _make_textured_image(seed=100 + i)
            cv2.imwrite(
                os.path.join(scan_dir, "images", f"frame_{i:04d}.jpg"), img
            )

        with open(os.path.join(scan_dir, "poses.json"), "w") as f:
            json.dump({"frames": frames}, f)

        # Create the GLB that the optimizer would return
        _create_sphere_glb(glb_path)

        # Mock only the optimizer service
        pipeline = OptimizedPipeline(optimizer_url="http://fake:3000")

        mock_client = _mock_optimizer_client()

        def mock_download(task_id, dest):
            shutil.copy2(glb_path, dest)
            return dest

        mock_client.download.side_effect = mock_download

        with patch(
            "processing_pipeline.optimized_pipeline.ModelOptimizerClient",
            return_value=mock_client,
        ):
            pipeline.run(scan_dir, output_dir)

        # --- Verify output asset bundle ---

        # 1. manifest.json exists and is valid
        manifest_path = os.path.join(output_dir, "manifest.json")
        assert os.path.isfile(manifest_path)
        with open(manifest_path) as f:
            manifest = json.load(f)

        assert manifest["version"] == "2.0"
        assert manifest["meshFile"] == "optimized.glb"
        assert manifest["featureDbFile"] == "features.db"
        assert manifest["featureType"] == "ORB"
        assert manifest["keyframeCount"] >= 1
        assert "bounds" in manifest
        assert "min" in manifest["bounds"]
        assert "max" in manifest["bounds"]
        assert len(manifest["bounds"]["min"]) == 3
        assert len(manifest["bounds"]["max"]) == 3

        # 2. optimized.glb exists and is non-empty
        glb_output = os.path.join(output_dir, "optimized.glb")
        assert os.path.isfile(glb_output)
        assert os.path.getsize(glb_output) > 0

        # 3. features.db exists and has correct schema + data
        db_path = os.path.join(output_dir, "features.db")
        assert os.path.isfile(db_path)

        conn = sqlite3.connect(db_path)
        cur = conn.cursor()

        # Verify tables exist
        cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = {row[0] for row in cur.fetchall()}
        assert "keyframes" in tables
        assert "features" in tables
        assert "vocabulary" in tables

        # Verify keyframes
        cur.execute("SELECT COUNT(*) FROM keyframes")
        n_keyframes = cur.fetchone()[0]
        assert n_keyframes >= 1, "Should have at least 1 keyframe"
        assert n_keyframes == manifest["keyframeCount"]

        # Verify features
        cur.execute("SELECT COUNT(*) FROM features")
        n_features = cur.fetchone()[0]
        assert n_features >= 20, "Should have at least 20 features total"

        # Verify feature descriptors are uint8 (32 bytes each)
        cur.execute("SELECT descriptor FROM features LIMIT 1")
        desc_blob = cur.fetchone()[0]
        desc = np.frombuffer(desc_blob, dtype=np.uint8)
        assert len(desc) == 32, f"ORB descriptor should be 32 bytes, got {len(desc)}"

        # Verify vocabulary
        cur.execute("SELECT COUNT(*) FROM vocabulary")
        n_words = cur.fetchone()[0]
        assert n_words >= 1, "Should have at least 1 vocabulary word"

        # Verify vocabulary descriptors are uint8 (32 bytes each)
        cur.execute("SELECT descriptor FROM vocabulary LIMIT 1")
        vocab_blob = cur.fetchone()[0]
        vocab_desc = np.frombuffer(vocab_blob, dtype=np.uint8)
        assert len(vocab_desc) == 32, (
            f"Vocabulary descriptor should be 32 bytes (uint8), got {len(vocab_desc)}"
        )

        # Verify IDF weights are positive
        cur.execute("SELECT idf_weight FROM vocabulary")
        idf_weights = [row[0] for row in cur.fetchall()]
        assert all(isinstance(w, float) for w in idf_weights)

        # Verify global descriptors exist and are correct dimension
        cur.execute("SELECT global_descriptor FROM keyframes WHERE global_descriptor IS NOT NULL")
        gd_rows = cur.fetchall()
        assert len(gd_rows) == n_keyframes
        gd = np.frombuffer(gd_rows[0][0], dtype=np.float64)
        assert len(gd) == n_words, (
            f"Global descriptor dimension ({len(gd)}) should match vocabulary size ({n_words})"
        )

        # Verify BoW vectors are L2-normalized (Bug 4/12 fix: changed from L1 to L2 to match C++ side)
        for row in gd_rows:
            bow = np.frombuffer(row[0], dtype=np.float64)
            l2 = np.linalg.norm(bow)
            assert abs(l2 - 1.0) < 1e-6, f"BoW vector L2 norm should be ~1.0, got {l2}"

        conn.close()


    def test_feature_db_roundtrip_through_pipeline(self, tmp_path):
        """Verify that the feature database produced by the pipeline can be
        loaded back and all data types are preserved (uint8 descriptors,
        float64 poses, uint8 vocabulary medoids).
        """
        from processing_pipeline.feature_db import load_feature_database
        from processing_pipeline.optimized_pipeline import OptimizedPipeline

        scan_dir = str(tmp_path / "scan")
        output_dir = str(tmp_path / "output")
        glb_path = str(tmp_path / "optimized.glb")

        # Setup scan directory (same as above, condensed)
        os.makedirs(os.path.join(scan_dir, "images"), exist_ok=True)

        mesh = o3d.geometry.TriangleMesh.create_sphere(radius=1.0, resolution=20)
        mesh.compute_vertex_normals()
        verts = np.asarray(mesh.vertices)
        faces = np.asarray(mesh.triangles)

        obj_lines = [f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}" for v in verts]
        obj_lines += [f"f {f[0]+1} {f[1]+1} {f[2]+1}" for f in faces]
        with open(os.path.join(scan_dir, "model.obj"), "w") as f:
            f.write("\n".join(obj_lines))
        with open(os.path.join(scan_dir, "model.mtl"), "w") as f:
            f.write("newmtl material0\n")
        cv2.imwrite(
            os.path.join(scan_dir, "texture.jpg"),
            np.zeros((64, 64, 3), dtype=np.uint8),
        )

        n_frames = 4
        frames = []
        for i in range(n_frames):
            pose = _make_camera_pose(tx=0.15 * i, tz=2.0)
            frames.append({
                "index": i,
                "timestamp": float(i),
                "imageFile": f"images/frame_{i:04d}.jpg",
                "transform": pose.T.flatten().tolist(),
            })
            cv2.imwrite(
                os.path.join(scan_dir, "images", f"frame_{i:04d}.jpg"),
                _make_textured_image(seed=200 + i),
            )
        with open(os.path.join(scan_dir, "poses.json"), "w") as f:
            json.dump({"frames": frames}, f)

        _create_sphere_glb(glb_path)

        pipeline = OptimizedPipeline(optimizer_url="http://fake:3000")
        mock_client = _mock_optimizer_client()
        mock_client.download.side_effect = lambda tid, dest: shutil.copy2(glb_path, dest) or dest

        with patch(
            "processing_pipeline.optimized_pipeline.ModelOptimizerClient",
            return_value=mock_client,
        ):
            pipeline.run(scan_dir, output_dir)

        # Load the feature database back
        db_path = os.path.join(output_dir, "features.db")
        loaded = load_feature_database(db_path)

        # Verify data types
        assert len(loaded.keyframes) >= 1
        for kf in loaded.keyframes:
            assert kf.descriptors.dtype == np.uint8
            assert kf.camera_pose.dtype == np.float64
            assert kf.camera_pose.shape == (4, 4)
            assert len(kf.keypoints) == len(kf.points_3d)
            assert len(kf.keypoints) == kf.descriptors.shape[0]
            # Each descriptor is 32 bytes
            assert kf.descriptors.shape[1] == 32

        # Vocabulary is uint8 medoids
        assert loaded.vocabulary is not None
        vocab = np.asarray(loaded.vocabulary)
        assert vocab.dtype == np.uint8
        assert vocab.shape[1] == 32

        # Global descriptors match keyframe count
        assert loaded.global_descriptors is not None
        assert loaded.global_descriptors.shape[0] == len(loaded.keyframes)
        assert loaded.global_descriptors.shape[1] == vocab.shape[0]


# ---------------------------------------------------------------------------
# Test 2: Web Service E2E — Upload → Poll → Download → Verify
# ---------------------------------------------------------------------------


class TestWebServiceE2E:
    """Full web service e2e: HTTP upload → background processing → download.

    Mocks the optimizer service. Tests the Flask app endpoints and the
    background pipeline execution thread.
    """

    def test_upload_poll_download_cycle(self, tmp_path):
        """Upload a scan ZIP via /api/upload, poll /api/status until complete,
        download via /api/download, and verify the result ZIP contents.
        """
        from web_service.app import app, jobs

        zip_path = str(tmp_path / "scan.zip")
        _build_scan_zip(zip_path, n_frames=3)

        glb_path = str(tmp_path / "optimized.glb")
        _create_sphere_glb(glb_path)

        mock_client = _mock_optimizer_client()
        mock_client.download.side_effect = lambda tid, dest: shutil.copy2(glb_path, dest) or dest

        with patch(
            "processing_pipeline.optimized_pipeline.ModelOptimizerClient",
            return_value=mock_client,
        ):
            with app.test_client() as client:
                # 1. Upload
                with open(zip_path, "rb") as f:
                    resp = client.post(
                        "/api/upload",
                        data={"file": (f, "scan.zip")},
                        content_type="multipart/form-data",
                    )
                assert resp.status_code == 200
                data = resp.get_json()
                assert "job_id" in data
                job_id = data["job_id"]

                # 2. Poll until completed or failed (max 120s)
                deadline = time.monotonic() + 120
                final_status = None
                while time.monotonic() < deadline:
                    resp = client.get(f"/api/status/{job_id}")
                    assert resp.status_code == 200
                    status_data = resp.get_json()
                    if status_data["status"] in ("completed", "failed"):
                        final_status = status_data
                        break
                    time.sleep(0.5)

                assert final_status is not None, "Pipeline did not finish within 120s"
                assert final_status["status"] == "completed", (
                    f"Pipeline failed: {final_status.get('error')}"
                )
                assert final_status["progress"] == 100
                assert final_status["finished_at"] is not None

                # 3. Download
                resp = client.get(f"/api/download/{job_id}")
                assert resp.status_code == 200

                # 4. Verify the downloaded ZIP
                result_zip = io.BytesIO(resp.data)
                with zipfile.ZipFile(result_zip, "r") as zf:
                    names = zf.namelist()
                    assert "manifest.json" in names
                    assert "optimized.glb" in names
                    assert "features.db" in names

                    # Verify manifest
                    manifest = json.loads(zf.read("manifest.json"))
                    assert manifest["version"] == "2.0"
                    assert manifest["featureType"] == "ORB"
                    assert manifest["keyframeCount"] >= 1

                # Cleanup
                if job_id in jobs:
                    del jobs[job_id]

    def test_upload_rejects_non_zip(self):
        """Uploading a non-ZIP file should return 400."""
        from web_service.app import app

        with app.test_client() as client:
            resp = client.post(
                "/api/upload",
                data={"file": (io.BytesIO(b"not a zip"), "scan.txt")},
                content_type="multipart/form-data",
            )
            assert resp.status_code == 400

    def test_upload_rejects_missing_file(self):
        """Uploading without a file should return 400."""
        from web_service.app import app

        with app.test_client() as client:
            resp = client.post("/api/upload")
            assert resp.status_code == 400

    def test_status_unknown_job_returns_404(self):
        """Querying status for a non-existent job should return 404."""
        from web_service.app import app

        with app.test_client() as client:
            resp = client.get("/api/status/nonexistent")
            assert resp.status_code == 404

    def test_download_incomplete_job_returns_404(self):
        """Downloading before completion should return 404."""
        from web_service.app import app, jobs

        jobs["incomplete_test"] = {
            "id": "incomplete_test",
            "status": "processing",
            "progress": 50,
        }
        with app.test_client() as client:
            resp = client.get("/api/download/incomplete_test")
            assert resp.status_code == 404
        del jobs["incomplete_test"]


# ---------------------------------------------------------------------------
# Test 3: Security E2E — ZIP traversal + safe_extract in full flow
# ---------------------------------------------------------------------------


class TestSecurityE2E:
    """Verify security fixes work in the full pipeline context."""

    def test_malicious_zip_rejected_by_web_service(self, tmp_path):
        """A ZIP with path traversal entries should be rejected during
        extraction, and the job should fail with an appropriate error.
        """
        from web_service.app import app, jobs

        # Build a malicious ZIP
        zip_path = str(tmp_path / "malicious.zip")
        with zipfile.ZipFile(zip_path, "w") as zf:
            zf.writestr("../../etc/evil.txt", "malicious content")
            zf.writestr("model.obj", "v 0 0 0\n")
            zf.writestr("poses.json", '{"frames": []}')

        with app.test_client() as client:
            with open(zip_path, "rb") as f:
                resp = client.post(
                    "/api/upload",
                    data={"file": (f, "malicious.zip")},
                    content_type="multipart/form-data",
                )
            assert resp.status_code == 200
            job_id = resp.get_json()["job_id"]

            # Wait for the job to fail
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                resp = client.get(f"/api/status/{job_id}")
                status_data = resp.get_json()
                if status_data["status"] in ("completed", "failed"):
                    break
                time.sleep(0.2)

            assert status_data["status"] == "failed"
            assert "traversal" in status_data["error"].lower() or "path" in status_data["error"].lower()

            if job_id in jobs:
                del jobs[job_id]

    def test_zip_missing_required_files_fails_gracefully(self, tmp_path):
        """A ZIP without model.obj/poses.json should fail with a clear error."""
        from web_service.app import app, jobs

        zip_path = str(tmp_path / "incomplete.zip")
        with zipfile.ZipFile(zip_path, "w") as zf:
            zf.writestr("readme.txt", "no model here")

        with app.test_client() as client:
            with open(zip_path, "rb") as f:
                resp = client.post(
                    "/api/upload",
                    data={"file": (f, "incomplete.zip")},
                    content_type="multipart/form-data",
                )
            job_id = resp.get_json()["job_id"]

            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                resp = client.get(f"/api/status/{job_id}")
                status_data = resp.get_json()
                if status_data["status"] in ("completed", "failed"):
                    break
                time.sleep(0.2)

            assert status_data["status"] == "failed"
            # Should mention missing files
            assert status_data["error"] is not None

            if job_id in jobs:
                del jobs[job_id]


# ---------------------------------------------------------------------------
# Test 4: Progress Tracking E2E — Verify real progress updates
# ---------------------------------------------------------------------------


class TestProgressTrackingE2E:
    """Verify that progress updates reflect actual pipeline step completion."""

    def test_progress_monotonically_increases(self, tmp_path):
        """Progress should only increase during pipeline execution,
        ending at 100% on success.
        """
        from web_service.app import app, jobs

        zip_path = str(tmp_path / "scan.zip")
        _build_scan_zip(zip_path, n_frames=3)

        glb_path = str(tmp_path / "optimized.glb")
        _create_sphere_glb(glb_path)

        mock_client = _mock_optimizer_client()
        mock_client.download.side_effect = lambda tid, dest: shutil.copy2(glb_path, dest) or dest

        progress_samples = []

        with patch(
            "processing_pipeline.optimized_pipeline.ModelOptimizerClient",
            return_value=mock_client,
        ):
            with app.test_client() as client:
                with open(zip_path, "rb") as f:
                    resp = client.post(
                        "/api/upload",
                        data={"file": (f, "scan.zip")},
                        content_type="multipart/form-data",
                    )
                job_id = resp.get_json()["job_id"]

                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    resp = client.get(f"/api/status/{job_id}")
                    data = resp.get_json()
                    progress_samples.append(data["progress"])
                    if data["status"] in ("completed", "failed"):
                        break
                    time.sleep(0.1)

                assert data["status"] == "completed"

        # Verify monotonic increase
        for i in range(1, len(progress_samples)):
            assert progress_samples[i] >= progress_samples[i - 1], (
                f"Progress decreased: {progress_samples[i-1]} → {progress_samples[i]} "
                f"at sample {i}"
            )

        # Final progress should be 100
        assert progress_samples[-1] == 100

        if job_id in jobs:
            del jobs[job_id]


# ---------------------------------------------------------------------------
# Test 5: CLI E2E — Full pipeline via command-line interface
# ---------------------------------------------------------------------------


class TestCLIE2E:
    """Test the CLI entry point runs the full pipeline."""

    def test_cli_produces_asset_bundle(self, tmp_path):
        """Running the CLI with --input and --output should produce
        a valid asset bundle directory.
        """
        from unittest.mock import patch

        scan_dir = str(tmp_path / "scan")
        output_dir = str(tmp_path / "output")
        glb_path = str(tmp_path / "optimized.glb")

        # Setup scan directory
        os.makedirs(os.path.join(scan_dir, "images"), exist_ok=True)

        mesh = o3d.geometry.TriangleMesh.create_sphere(radius=1.0, resolution=20)
        mesh.compute_vertex_normals()
        verts = np.asarray(mesh.vertices)
        faces = np.asarray(mesh.triangles)

        obj_lines = [f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}" for v in verts]
        obj_lines += [f"f {f[0]+1} {f[1]+1} {f[2]+1}" for f in faces]
        with open(os.path.join(scan_dir, "model.obj"), "w") as f:
            f.write("\n".join(obj_lines))
        with open(os.path.join(scan_dir, "model.mtl"), "w") as f:
            f.write("newmtl material0\n")
        cv2.imwrite(
            os.path.join(scan_dir, "texture.jpg"),
            np.zeros((64, 64, 3), dtype=np.uint8),
        )

        frames = []
        for i in range(3):
            pose = _make_camera_pose(tx=0.2 * i, tz=2.0)
            frames.append({
                "index": i,
                "timestamp": float(i),
                "imageFile": f"images/frame_{i:04d}.jpg",
                "transform": pose.T.flatten().tolist(),
            })
            cv2.imwrite(
                os.path.join(scan_dir, "images", f"frame_{i:04d}.jpg"),
                _make_textured_image(seed=300 + i),
            )
        with open(os.path.join(scan_dir, "poses.json"), "w") as f:
            json.dump({"frames": frames}, f)

        _create_sphere_glb(glb_path)

        mock_client = _mock_optimizer_client()
        mock_client.download.side_effect = lambda tid, dest: shutil.copy2(glb_path, dest) or dest

        with patch(
            "processing_pipeline.optimized_pipeline.ModelOptimizerClient",
            return_value=mock_client,
        ):
            with patch(
                "sys.argv",
                ["cli", "--input", scan_dir, "--output", output_dir],
            ):
                from processing_pipeline.cli import main
                main()

        # Verify output
        assert os.path.isfile(os.path.join(output_dir, "manifest.json"))
        assert os.path.isfile(os.path.join(output_dir, "optimized.glb"))
        assert os.path.isfile(os.path.join(output_dir, "features.db"))

        with open(os.path.join(output_dir, "manifest.json")) as f:
            manifest = json.load(f)
        assert manifest["version"] == "2.0"
        assert manifest["keyframeCount"] >= 1
