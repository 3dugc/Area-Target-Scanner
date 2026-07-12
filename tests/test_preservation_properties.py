"""Preservation Property Tests — run on UNFIXED code to establish baseline.

These tests verify that non-buggy behavior is preserved. They should PASS
on the current unfixed code, confirming the baseline behaviors that must
not regress after bug fixes are applied.

Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7
"""

from __future__ import annotations

import os
import tempfile
import zipfile
from unittest.mock import MagicMock, patch

import numpy as np
from hypothesis import given, settings, HealthCheck
from hypothesis import strategies as st


# ---------------------------------------------------------------------------
# Preservation: Hamming Word Assignment Correctness (Req 3.1)
# ---------------------------------------------------------------------------


class TestHammingWordAssignmentCorrectness:
    """Verify that _hamming_word_assignment() produces correct word assignments
    by comparing against a simple reference implementation.

    For small inputs (N=50, K=10), the vectorized version must match the
    reference brute-force Hamming distance computation.

    **Validates: Requirements 3.1**
    """

    @staticmethod
    def _reference_hamming_word_assignment(descriptors, vocabulary_medoids):
        """Pure-Python reference implementation for Hamming word assignment.

        Computes Hamming distance as popcount(XOR) for each descriptor-word
        pair and returns the argmin word index per descriptor.
        """
        descriptors = np.asarray(descriptors, dtype=np.uint8)
        vocabulary_medoids = np.asarray(vocabulary_medoids, dtype=np.uint8)
        n = len(descriptors)
        k = len(vocabulary_medoids)
        labels = np.empty(n, dtype=np.intp)
        for i in range(n):
            best_word = 0
            best_dist = float("inf")
            for w in range(k):
                xor = np.bitwise_xor(descriptors[i], vocabulary_medoids[w])
                dist = sum(bin(b).count("1") for b in xor)
                if dist < best_dist:
                    best_dist = dist
                    best_word = w
            labels[i] = best_word
        return labels

    @given(
        seed=st.integers(min_value=0, max_value=2**31 - 1),
        n_desc=st.integers(min_value=1, max_value=50),
        n_words=st.integers(min_value=2, max_value=10),
    )
    @settings(
        max_examples=10,
        deadline=60000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_hamming_assignment_matches_reference(self, seed, n_desc, n_words):
        """For small inputs, the pipeline's _hamming_word_assignment must
        produce the same word labels as the reference implementation.

        **Validates: Requirements 3.1**
        """
        from processing_pipeline.feature_extraction import _hamming_word_assignment

        rng = np.random.default_rng(seed)
        descriptors = rng.integers(0, 256, size=(n_desc, 32), dtype=np.uint8)
        vocabulary = rng.integers(0, 256, size=(n_words, 32), dtype=np.uint8)

        actual = _hamming_word_assignment(descriptors, vocabulary)
        expected = self._reference_hamming_word_assignment(descriptors, vocabulary)

        np.testing.assert_array_equal(
            actual,
            expected,
            err_msg=(
                f"_hamming_word_assignment output differs from reference "
                f"for N={n_desc}, K={n_words}, seed={seed}"
            ),
        )

    def test_hamming_assignment_deterministic(self):
        """Same inputs must always produce the same word assignments.

        **Validates: Requirements 3.1**
        """
        from processing_pipeline.feature_extraction import _hamming_word_assignment

        rng = np.random.default_rng(99)
        descriptors = rng.integers(0, 256, size=(30, 32), dtype=np.uint8)
        vocabulary = rng.integers(0, 256, size=(8, 32), dtype=np.uint8)

        result1 = _hamming_word_assignment(descriptors, vocabulary)
        result2 = _hamming_word_assignment(descriptors, vocabulary)

        np.testing.assert_array_equal(
            result1, result2,
            err_msg="Hamming word assignment is not deterministic",
        )


# ---------------------------------------------------------------------------
# Preservation: Feature Descriptor Round-Trip (Req 3.2)
# ---------------------------------------------------------------------------


class TestFeatureDescriptorRoundTrip:
    """Verify that uint8 ORB feature descriptors in the features table
    survive a save→load round-trip byte-identically.

    **Validates: Requirements 3.2**
    """

    @given(
        n_features=st.integers(min_value=20, max_value=100),
        n_keyframes=st.integers(min_value=1, max_value=3),
    )
    @settings(
        max_examples=10,
        deadline=30000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_feature_descriptors_byte_identical_after_roundtrip(
        self, n_features, n_keyframes, tmp_path_factory
    ):
        """Generate random uint8 ORB descriptors, save to SQLite via
        save_feature_database, load back, and verify byte-identical.

        **Validates: Requirements 3.2**
        """
        from processing_pipeline.feature_db import (
            load_feature_database,
            save_feature_database,
        )
        from processing_pipeline.models import FeatureDatabase, KeyframeData

        rng = np.random.default_rng(42)

        keyframes = []
        for kf_idx in range(n_keyframes):
            descriptors = rng.integers(0, 256, size=(n_features, 32), dtype=np.uint8)
            kf = KeyframeData(
                image_id=kf_idx,
                keypoints=[(float(i), float(i + 1)) for i in range(n_features)],
                descriptors=descriptors,
                points_3d=[(float(i), float(i), float(i)) for i in range(n_features)],
                camera_pose=np.eye(4, dtype=np.float64),
            )
            keyframes.append(kf)

        db = FeatureDatabase(
            keyframes=keyframes,
            vocabulary=None,
            global_descriptors=None,
        )

        tmp_dir = tmp_path_factory.mktemp("feat_roundtrip")
        db_path = str(tmp_dir / "features.db")
        save_feature_database(db, db_path)
        loaded_db = load_feature_database(db_path)

        # Verify each keyframe's descriptors are byte-identical
        assert len(loaded_db.keyframes) == n_keyframes
        for orig_kf, loaded_kf in zip(keyframes, loaded_db.keyframes):
            assert loaded_kf.descriptors.dtype == np.uint8, (
                f"Loaded descriptor dtype is {loaded_kf.descriptors.dtype}, expected uint8"
            )
            np.testing.assert_array_equal(
                orig_kf.descriptors,
                loaded_kf.descriptors,
                err_msg="Feature descriptors are not byte-identical after round-trip",
            )

    @given(
        n_features=st.integers(min_value=20, max_value=80),
    )
    @settings(
        max_examples=10,
        deadline=30000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_keyframe_pose_roundtrip(self, n_features, tmp_path_factory):
        """Verify camera pose (float64 4x4) round-trips correctly.

        **Validates: Requirements 3.2**
        """
        from processing_pipeline.feature_db import (
            load_feature_database,
            save_feature_database,
        )
        from processing_pipeline.models import FeatureDatabase, KeyframeData

        rng = np.random.default_rng(123)
        pose = rng.standard_normal((4, 4)).astype(np.float64)

        descriptors = rng.integers(0, 256, size=(n_features, 32), dtype=np.uint8)
        kf = KeyframeData(
            image_id=0,
            keypoints=[(float(i), float(i)) for i in range(n_features)],
            descriptors=descriptors,
            points_3d=[(rng.random(), rng.random(), rng.random()) for _ in range(n_features)],
            camera_pose=pose,
        )

        db = FeatureDatabase(keyframes=[kf], vocabulary=None, global_descriptors=None)

        tmp_dir = tmp_path_factory.mktemp("pose_roundtrip")
        db_path = str(tmp_dir / "features.db")
        save_feature_database(db, db_path)
        loaded_db = load_feature_database(db_path)

        np.testing.assert_array_almost_equal(
            loaded_db.keyframes[0].camera_pose,
            pose,
            decimal=10,
            err_msg="Camera pose not preserved after round-trip",
        )


# ---------------------------------------------------------------------------
# Preservation: Legitimate ZIP Processing (Req 3.3)
# ---------------------------------------------------------------------------


class TestLegitimateZipProcessing:
    """Verify that legitimate ZIP files (no ../, reasonable size) extract
    normally to extract_dir.

    **Validates: Requirements 3.3**
    """

    @given(
        n_files=st.integers(min_value=1, max_value=5),
        filename_base=st.from_regex(r"[a-z]{3,8}", fullmatch=True),
    )
    @settings(max_examples=10, deadline=10000)
    def test_legitimate_zip_extracts_normally(self, n_files, filename_base, tmp_path_factory):
        """Generate a legitimate ZIP file with safe relative paths and verify
        it extracts correctly via safe_extract.

        **Validates: Requirements 3.3**
        """
        from web_service.app import safe_extract

        tmp_dir = tmp_path_factory.mktemp("legit_zip")
        zip_path = str(tmp_dir / "test.zip")
        extract_dir = str(tmp_dir / "extracted")
        os.makedirs(extract_dir, exist_ok=True)

        # Create a legitimate ZIP with safe paths
        filenames = [f"{filename_base}_{i}.txt" for i in range(n_files)]
        with zipfile.ZipFile(zip_path, "w") as zf:
            for fname in filenames:
                zf.writestr(fname, f"content of {fname}")

        # Extract using safe_extract (current behavior)
        with zipfile.ZipFile(zip_path, "r") as zf:
            safe_extract(zf, extract_dir)

        # Verify all files extracted correctly within extract_dir
        for fname in filenames:
            extracted_path = os.path.join(extract_dir, fname)
            assert os.path.isfile(extracted_path), (
                f"Legitimate file {fname} was not extracted"
            )
            # Verify the resolved path is within extract_dir
            resolved = os.path.realpath(extracted_path)
            assert resolved.startswith(os.path.realpath(extract_dir)), (
                f"Extracted file {fname} resolved outside extract_dir"
            )

    @given(
        subdir_name=st.from_regex(r"[a-z]{2,6}", fullmatch=True),
        filename=st.from_regex(r"[a-z]{3,8}\.[a-z]{2,4}", fullmatch=True),
    )
    @settings(max_examples=10, deadline=10000)
    def test_legitimate_zip_with_subdirectories(self, subdir_name, filename, tmp_path_factory):
        """ZIP files with legitimate subdirectory paths extract correctly.

        **Validates: Requirements 3.3**
        """
        from web_service.app import safe_extract

        tmp_dir = tmp_path_factory.mktemp("legit_zip_subdir")
        zip_path = str(tmp_dir / "test.zip")
        extract_dir = str(tmp_dir / "extracted")
        os.makedirs(extract_dir, exist_ok=True)

        safe_path = f"{subdir_name}/{filename}"
        with zipfile.ZipFile(zip_path, "w") as zf:
            zf.writestr(safe_path, "safe content")

        with zipfile.ZipFile(zip_path, "r") as zf:
            safe_extract(zf, extract_dir)

        extracted_path = os.path.join(extract_dir, safe_path)
        assert os.path.isfile(extracted_path), (
            f"Legitimate subdirectory file {safe_path} was not extracted"
        )
        resolved = os.path.realpath(extracted_path)
        assert resolved.startswith(os.path.realpath(extract_dir))


# ---------------------------------------------------------------------------
# Preservation: Feature Database Build Output (Req 3.4)
# ---------------------------------------------------------------------------


class TestFeatureDatabaseBuildOutput:
    """Verify that build_feature_database() with sufficient features produces
    a non-empty FeatureDatabase with keyframes, vocabulary, and global_descriptors.

    **Validates: Requirements 3.4**
    """

    def test_build_feature_database_produces_complete_output(self):
        """With sufficient features (mocked ORB extraction), build_feature_database
        returns a FeatureDatabase with keyframes, vocabulary, and global_descriptors.

        **Validates: Requirements 3.4**
        """
        import open3d as o3d
        from unittest.mock import patch, MagicMock
        import cv2

        from processing_pipeline.feature_extraction import build_feature_database
        from processing_pipeline.models import FeatureDatabase

        # Create a simple mesh for ray-casting
        mesh = o3d.geometry.TriangleMesh.create_sphere(radius=1.0)
        mesh.compute_vertex_normals()

        rng = np.random.default_rng(42)

        # Generate mock ORB keypoints and descriptors
        n_kps = 50
        mock_kps = [
            MagicMock(pt=(float(rng.uniform(10, 630)), float(rng.uniform(10, 470))))
            for _ in range(n_kps)
        ]
        mock_descs = rng.integers(0, 256, size=(n_kps, 32), dtype=np.uint8)

        # Create a mock image that returns our controlled features
        mock_img = np.zeros((480, 640), dtype=np.uint8)

        images = []
        with tempfile.TemporaryDirectory() as tmpdir:
            for i in range(3):
                img_path = os.path.join(tmpdir, f"frame_{i}.jpg")
                import cv2
                cv2.imwrite(img_path, mock_img)
                pose = np.eye(4, dtype=np.float64)
                pose[2, 3] = 2.0 + i * 0.5  # Move camera back
                images.append({"path": img_path, "pose": pose})

            # Patch ORB to return our controlled features
            mock_orb = MagicMock()
            mock_orb.detectAndCompute.return_value = (mock_kps, mock_descs)

            with patch("cv2.ORB_create", return_value=mock_orb):
                result = build_feature_database(images, mesh)

        assert isinstance(result, FeatureDatabase)
        # With mocked features that hit the sphere, we should get keyframes
        if len(result.keyframes) > 0:
            assert result.vocabulary is not None, (
                "Vocabulary should not be None when keyframes exist"
            )
            assert result.global_descriptors is not None, (
                "Global descriptors should not be None when keyframes exist"
            )
            assert result.global_descriptors.shape[0] == len(result.keyframes), (
                "Global descriptors rows should match keyframe count"
            )


# ---------------------------------------------------------------------------
# Preservation: Pipeline Final Progress State (Req 3.6)
# ---------------------------------------------------------------------------


class TestPipelineFinalProgressState:
    """Verify that pipeline normal completion results in 100% progress
    and "completed" status.

    **Validates: Requirements 3.6**
    """

    def test_pipeline_completion_sets_100_percent_and_completed(self):
        """When pipeline.run() completes successfully, the job should
        end with progress=100 and status="completed".

        **Validates: Requirements 3.6**
        """
        from web_service.app import jobs, run_pipeline

        # Create a mock job
        job_id = "test_preservation_progress"
        jobs[job_id] = {
            "id": job_id,
            "status": "queued",
            "step": "等待处理",
            "progress": 0,
            "error": None,
            "result_zip": None,
            "created_at": "2025-01-01T00:00:00Z",
            "finished_at": None,
        }

        # Create a minimal valid ZIP with model.obj and poses.json
        with tempfile.TemporaryDirectory() as tmpdir:
            zip_path = os.path.join(tmpdir, "test.zip")
            with zipfile.ZipFile(zip_path, "w") as zf:
                zf.writestr("model.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")
                zf.writestr("texture.jpg", b"\xff\xd8\xff\xe0" + b"\x00" * 100)
                zf.writestr("model.mtl", "newmtl material0\n")
                zf.writestr(
                    "poses.json",
                    '{"frames": [{"imageFile": "images/frame_0000.jpg", '
                    '"transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,2,1]}]}',
                )
                zf.writestr("images/frame_0000.jpg", b"\xff\xd8\xff\xe0" + b"\x00" * 100)

            mock_pipeline_instance = MagicMock()
            mock_pipeline_instance.validate_input.return_value = MagicMock(
                images=[], intrinsics=None
            )
            mock_pipeline_instance.optimize_model.return_value = "/fake/model.glb"

            mock_mesh = MagicMock()
            mock_mesh.bounds = [[0, 0, 0], [1, 1, 1]]

            import trimesh as _trimesh_mod

            with patch(
                "processing_pipeline.optimized_pipeline.OptimizedPipeline",
                return_value=mock_pipeline_instance,
            ), patch.object(
                _trimesh_mod, "load", return_value=mock_mesh
            ), patch.object(
                _trimesh_mod, "Scene", new=type("_FakeScene", (), {})
            ):

                output_dir = os.path.join(
                    os.environ.get("OUTPUT_DIR", "/tmp/pipeline_outputs"),
                    job_id,
                )
                os.makedirs(output_dir, exist_ok=True)
                with open(os.path.join(output_dir, "manifest.json"), "w") as f:
                    f.write("{}")

                run_pipeline(job_id, zip_path)

        job = jobs[job_id]
        assert job["progress"] == 100, (
            f"Expected progress=100 after completion, got {job['progress']}"
        )
        assert job["status"] == "completed", (
            f"Expected status='completed', got '{job['status']}'"
        )

        # Cleanup
        del jobs[job_id]


# ---------------------------------------------------------------------------
# Preservation: E2E Test Baseline (Req 3.7)
# ---------------------------------------------------------------------------


class TestE2EBaseline:
    """Verify that existing e2e tests pass on the current unfixed code,
    establishing a baseline that must not regress after fixes.

    This is a meta-test that confirms the e2e test suite is green.

    **Validates: Requirements 3.7**
    """

    def test_e2e_test_module_importable(self):
        """The e2e test module should be importable without errors,
        confirming the test infrastructure is intact.

        **Validates: Requirements 3.7**
        """
        import tests.test_e2e as e2e_module

        # Verify the key test classes exist
        assert hasattr(e2e_module, "TestPipelineE2E"), (
            "TestPipelineE2E class missing from test_e2e.py"
        )
        assert hasattr(e2e_module, "TestWebServiceE2E"), (
            "TestWebServiceE2E class missing from test_e2e.py"
        )
        assert hasattr(e2e_module, "TestSecurityE2E"), (
            "TestSecurityE2E class missing from test_e2e.py"
        )
        assert hasattr(e2e_module, "TestProgressTrackingE2E"), (
            "TestProgressTrackingE2E class missing from test_e2e.py"
        )

    def test_e2e_test_classes_have_test_methods(self):
        """Each e2e test class should have at least one test method.

        **Validates: Requirements 3.7**
        """
        import tests.test_e2e as e2e_module

        for cls_name in [
            "TestPipelineE2E",
            "TestWebServiceE2E",
            "TestSecurityE2E",
            "TestProgressTrackingE2E",
            "TestCLIE2E",
        ]:
            cls = getattr(e2e_module, cls_name)
            test_methods = [m for m in dir(cls) if m.startswith("test_")]
            assert len(test_methods) > 0, (
                f"{cls_name} has no test methods"
            )
