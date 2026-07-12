"""Unit tests for buildFeatureDatabase() — ORB extraction and ray-mesh intersection.

Validates Requirements 8.1, 8.2, 8.3.
"""

from __future__ import annotations

import os
import tempfile

import cv2
import numpy as np
import open3d as o3d
import pytest

from processing_pipeline.models import (
    FeatureDatabase,
    KeyframeData,
    ProcessedCloud,
)
from processing_pipeline.feature_extraction import build_feature_database


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_sphere_cloud(n_points: int = 5000, radius: float = 1.0) -> ProcessedCloud:
    """Create a ProcessedCloud of points on a sphere with outward normals."""
    rng = np.random.default_rng(42)
    raw = rng.standard_normal((n_points, 3))
    norms = np.linalg.norm(raw, axis=1, keepdims=True)
    norms = np.clip(norms, 1e-10, None)
    points = (raw / norms) * radius
    normals = raw / norms
    colors = np.zeros((n_points, 3))
    return ProcessedCloud(
        points=points, normals=normals, colors=colors, point_count=n_points
    )


def _build_sphere_mesh() -> o3d.geometry.TriangleMesh:
    """Build a sphere mesh via lazy cache (avoids Poisson segfault at import time)."""
    from tests.conftest import get_sphere_mesh
    return get_sphere_mesh(n_points=5000, radius=1.0)


def _make_textured_image(
    width: int = 640, height: int = 480, seed: int = 42
) -> np.ndarray:
    """Generate a synthetic image with enough texture for ORB detection."""
    rng = np.random.RandomState(seed)
    img = rng.randint(0, 256, (height, width), dtype=np.uint8)
    # Add strong corners / edges to guarantee ORB detections
    for _ in range(80):
        cx = rng.randint(20, width - 20)
        cy = rng.randint(20, height - 20)
        r = rng.randint(5, 20)
        cv2.circle(img, (cx, cy), r, int(rng.randint(0, 256)), -1)
        cv2.rectangle(
            img,
            (cx - r, cy - r),
            (cx + r, cy + r),
            int(rng.randint(0, 256)),
            2,
        )
    return img


def _save_image(img: np.ndarray, directory: str, name: str) -> str:
    path = os.path.join(directory, name)
    cv2.imwrite(path, img)
    return path


def _make_camera_pose(
    tx: float = 0.0, ty: float = 0.0, tz: float = 3.0
) -> np.ndarray:
    """Camera-to-world pose looking at the origin from +Z."""
    pose = np.eye(4, dtype=np.float64)
    pose[0, 3] = tx
    pose[1, 3] = ty
    pose[2, 3] = tz
    return pose


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestBuildFeatureDatabaseBasic:
    """Basic functionality tests for buildFeatureDatabase()."""

    def setup_method(self):
        import copy
        self.mesh = copy.deepcopy(_build_sphere_mesh())
        self.tmpdir = tempfile.mkdtemp()

    def _make_images(self, count: int = 3) -> list:
        images = []
        for i in range(count):
            img = _make_textured_image(seed=42 + i)
            path = _save_image(img, self.tmpdir, f"frame_{i:04d}.png")
            pose = _make_camera_pose(tx=0.2 * i, tz=3.0)
            images.append({"path": path, "pose": pose})
        return images

    def test_returns_feature_database(self):
        images = self._make_images(2)
        db = build_feature_database(images, self.mesh)
        assert isinstance(db, FeatureDatabase)

    def test_keyframes_have_correct_structure(self):
        images = self._make_images(2)
        db = build_feature_database(images, self.mesh)
        for kf in db.keyframes:
            assert isinstance(kf, KeyframeData)
            assert len(kf.keypoints) == len(kf.points_3d)
            assert kf.descriptors.shape[0] == len(kf.keypoints)
            assert kf.descriptors.shape[1] == 32  # ORB descriptor size
            assert kf.descriptors.dtype == np.uint8

    def test_keyframes_have_at_least_20_features(self):
        """Requirement 8.3: keyframes with < 20 valid features are skipped."""
        images = self._make_images(3)
        db = build_feature_database(images, self.mesh)
        for kf in db.keyframes:
            assert len(kf.keypoints) >= 20

    def test_3d_points_near_mesh_surface(self):
        """Requirement 8.2: 3D points come from ray-mesh intersection."""
        images = self._make_images(2)
        db = build_feature_database(images, self.mesh)
        bbox = self.mesh.get_axis_aligned_bounding_box()
        min_b = np.asarray(bbox.min_bound) - 0.5  # tolerance for Poisson mesh
        max_b = np.asarray(bbox.max_bound) + 0.5
        for kf in db.keyframes:
            for pt in kf.points_3d:
                p = np.array(pt)
                assert np.all(p >= min_b) and np.all(p <= max_b), (
                    f"3D point {p} outside mesh bounding box"
                )

    def test_camera_pose_stored(self):
        images = self._make_images(1)
        db = build_feature_database(images, self.mesh)
        if db.keyframes:
            kf = db.keyframes[0]
            np.testing.assert_array_almost_equal(
                kf.camera_pose, images[0]["pose"]
            )

    def test_vocabulary_is_uint8_medoids(self):
        """Requirement 8.4: vocabulary is a uint8 medoid array."""
        images = self._make_images(2)
        db = build_feature_database(images, self.mesh)
        if db.keyframes:
            assert isinstance(db.vocabulary, np.ndarray)
            assert db.vocabulary.dtype == np.uint8
            assert db.vocabulary.ndim == 2
            assert db.vocabulary.shape[1] == 32  # ORB descriptor size
        else:
            assert db.vocabulary is None

    def test_global_descriptors_shape(self):
        """Requirement 8.5: global_descriptors has shape (n_keyframes, K)."""
        images = self._make_images(2)
        db = build_feature_database(images, self.mesh)
        if db.keyframes:
            assert db.global_descriptors is not None
            assert db.global_descriptors.shape[0] == len(db.keyframes)
            k = len(db.vocabulary)  # number of vocabulary words
            assert db.global_descriptors.shape[1] == k
        else:
            assert db.global_descriptors is None

    def test_bow_vectors_l2_normalized(self):
        """Requirement 8.5: BoW vectors are L2-normalized (norm ≈ 1.0)."""
        images = self._make_images(2)
        db = build_feature_database(images, self.mesh)
        if db.keyframes and db.global_descriptors is not None:
            for i in range(db.global_descriptors.shape[0]):
                l2 = np.linalg.norm(db.global_descriptors[i])
                np.testing.assert_almost_equal(l2, 1.0, decimal=6)

    def test_bow_vectors_finite(self):
        """BoW vectors should contain only finite values (TF-IDF may be negative)."""
        images = self._make_images(2)
        db = build_feature_database(images, self.mesh)
        if db.keyframes and db.global_descriptors is not None:
            assert np.all(np.isfinite(db.global_descriptors))


class TestBuildFeatureDatabaseEdgeCases:
    """Edge case tests for buildFeatureDatabase()."""

    def setup_method(self):
        import copy
        self.mesh = copy.deepcopy(_build_sphere_mesh())
        self.tmpdir = tempfile.mkdtemp()

    def test_empty_images_list(self):
        db = build_feature_database([], self.mesh)
        assert isinstance(db, FeatureDatabase)
        assert len(db.keyframes) == 0
        assert db.vocabulary is None
        assert db.global_descriptors is None

    def test_unreadable_image_skipped(self):
        """Images that can't be read should be skipped gracefully.

        After Bug 6 fix, build_feature_database raises ValueError when all
        images are skipped (no keyframes with >= 20 features).
        """
        images = [{"path": "/nonexistent/image.png", "pose": np.eye(4)}]
        with pytest.raises(ValueError, match="Feature database is empty"):
            build_feature_database(images, self.mesh)

    def test_blank_image_few_features(self):
        """A blank (uniform) image produces few/no ORB features and is skipped.

        After Bug 6 fix, build_feature_database raises ValueError when all
        images produce insufficient features.
        """
        blank = np.full((480, 640), 128, dtype=np.uint8)
        path = _save_image(blank, self.tmpdir, "blank.png")
        images = [{"path": path, "pose": _make_camera_pose()}]
        with pytest.raises(ValueError, match="Feature database is empty"):
            build_feature_database(images, self.mesh)

    def test_camera_far_away_no_hits(self):
        """Camera very far from mesh — rays miss → keyframe skipped.

        After Bug 6 fix, build_feature_database raises ValueError when all
        images produce insufficient features.
        """
        img = _make_textured_image()
        path = _save_image(img, self.tmpdir, "far.png")
        # Camera at z=1000 looking at origin — the sphere is radius ~1
        pose = _make_camera_pose(tz=1000.0)
        images = [{"path": path, "pose": pose}]
        with pytest.raises(ValueError, match="Feature database is empty"):
            build_feature_database(images, self.mesh)


class TestBuildFeatureDatabaseAKAZE:
    """Tests for AKAZE feature extraction in build_feature_database().

    Validates Requirement 3.2: AKAZE extraction via extract_akaze parameter.
    """

    def setup_method(self):
        import copy
        self.mesh = copy.deepcopy(_build_sphere_mesh())
        self.tmpdir = tempfile.mkdtemp()

    def _make_images(self, count: int = 3) -> list:
        images = []
        for i in range(count):
            img = _make_textured_image(seed=42 + i)
            path = _save_image(img, self.tmpdir, f"frame_{i:04d}.png")
            pose = _make_camera_pose(tx=0.2 * i, tz=3.0)
            images.append({"path": path, "pose": pose})
        return images

    def test_akaze_fields_populated_when_enabled(self):
        """extract_akaze=True should populate akaze_* fields on keyframes."""
        images = self._make_images(2)
        db = build_feature_database(images, self.mesh, extract_akaze=True)
        has_akaze = False
        for kf in db.keyframes:
            if kf.akaze_descriptors is not None:
                has_akaze = True
                assert kf.akaze_keypoints is not None
                assert kf.akaze_points_3d is not None
                assert len(kf.akaze_keypoints) == len(kf.akaze_points_3d)
                assert kf.akaze_descriptors.shape[0] == len(kf.akaze_keypoints)
                assert kf.akaze_descriptors.dtype == np.uint8
        assert has_akaze, "At least one keyframe should have AKAZE features"

    def test_akaze_fields_none_when_disabled(self):
        """extract_akaze=False should leave akaze_* fields as None."""
        images = self._make_images(2)
        db = build_feature_database(images, self.mesh, extract_akaze=False)
        for kf in db.keyframes:
            assert kf.akaze_descriptors is None
            assert kf.akaze_keypoints is None
            assert kf.akaze_points_3d is None

    def test_akaze_3d_points_near_mesh_surface(self):
        """AKAZE 3D points should come from ray-mesh intersection (near mesh)."""
        images = self._make_images(2)
        db = build_feature_database(images, self.mesh, extract_akaze=True)
        bbox = self.mesh.get_axis_aligned_bounding_box()
        min_b = np.asarray(bbox.min_bound) - 0.5
        max_b = np.asarray(bbox.max_bound) + 0.5
        for kf in db.keyframes:
            if kf.akaze_points_3d is not None:
                for pt in kf.akaze_points_3d:
                    p = np.array(pt)
                    assert np.all(p >= min_b) and np.all(p <= max_b), (
                        f"AKAZE 3D point {p} outside mesh bounding box"
                    )

    def test_akaze_default_is_enabled(self):
        """Default value of extract_akaze should be True."""
        images = self._make_images(1)
        db = build_feature_database(images, self.mesh)
        # With default params, AKAZE should be extracted
        has_akaze = any(kf.akaze_descriptors is not None for kf in db.keyframes)
        assert has_akaze, "Default extract_akaze=True should produce AKAZE features"

    def test_orb_fields_unaffected_by_akaze(self):
        """AKAZE extraction should not affect ORB fields."""
        images = self._make_images(2)
        db_with = build_feature_database(images, self.mesh, extract_akaze=True)
        db_without = build_feature_database(images, self.mesh, extract_akaze=False)
        assert len(db_with.keyframes) == len(db_without.keyframes)
        for kf_a, kf_b in zip(db_with.keyframes, db_without.keyframes):
            assert kf_a.image_id == kf_b.image_id
            assert len(kf_a.keypoints) == len(kf_b.keypoints)
            np.testing.assert_array_equal(kf_a.descriptors, kf_b.descriptors)


class TestBuildFeatureDatabaseORB:
    """Tests specifically for ORB feature extraction (Requirement 8.1)."""

    def setup_method(self):
        import copy
        self.mesh = copy.deepcopy(_build_sphere_mesh())
        self.tmpdir = tempfile.mkdtemp()

    def test_orb_max_features_2000(self):
        """Requirement 8.1: ORB uses nfeatures=2000."""
        rng = np.random.RandomState(99)
        img = rng.randint(0, 256, (480, 640), dtype=np.uint8)
        for _ in range(200):
            cx = rng.randint(10, 630)
            cy = rng.randint(10, 470)
            cv2.circle(
                img, (cx, cy), rng.randint(3, 15),
                int(rng.randint(0, 256)), -1,
            )
        path = _save_image(img, self.tmpdir, "textured.png")
        pose = _make_camera_pose(tz=3.0)
        images = [{"path": path, "pose": pose}]
        db = build_feature_database(images, self.mesh)
        for kf in db.keyframes:
            assert len(kf.keypoints) <= 2000
