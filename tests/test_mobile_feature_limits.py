"""Explicit mobile producers stay within the real native reader's feature budget."""
import cv2
import numpy as np
import open3d as o3d
import pytest
from processing_pipeline import feature_extraction
from processing_pipeline.models import FeatureDatabase
from processing_pipeline.optimized_pipeline import OptimizedPipeline


@pytest.mark.parametrize("profile,orb,vocab,akaze", [("quality", 2000, 1000, 500), ("fast", 1000, 500, None)])
def test_mobile_profile_limits_are_explicit_and_do_not_mutate_legacy(monkeypatch, profile, orb, vocab, akaze):
    calls = []
    monkeypatch.setattr(OptimizedPipeline, "_trimesh_to_o3d", lambda self, mesh: mesh)
    monkeypatch.setattr(feature_extraction, "build_feature_database",
                        lambda *args, **kwargs: calls.append(kwargs) or FeatureDatabase(keyframes=[]))
    OptimizedPipeline(processing_profile=profile, mobile_feature_limits=True).build_feature_database(None, [])
    mobile = calls[-1]
    assert mobile["max_keyframes"] == 80
    assert mobile["orb_nfeatures"] == orb and mobile["bow_k"] == vocab
    assert mobile.get("max_akaze_features") == akaze
    assert mobile["extract_akaze"] == (profile == "quality")
    OptimizedPipeline(processing_profile=profile).build_feature_database(None, [])
    assert calls[-1]["max_keyframes"] == (None if profile == "quality" else 80)
    assert "max_akaze_features" not in calls[-1]


def _fake_detectors(monkeypatch):
    def detection(count, width):
        points = [cv2.KeyPoint(float(16 + i % 25), float(16 + (i // 25) % 25), 1,
                              response=float(i)) for i in range(count)]
        descriptors = np.repeat((np.arange(count) % 251).astype(np.uint8)[:, None], width, axis=1)
        return points, descriptors
    orb_points, orb_desc = detection(2103, 32)
    akaze_points, akaze_desc = detection(1700, 61)
    class Detector:
        def __init__(self, points, descriptors): self.result = points, descriptors
        def detectAndCompute(self, *_): return self.result
    monkeypatch.setattr(cv2, "ORB_create", lambda **_: Detector(orb_points, orb_desc))
    akaze_namespace = cv2 if hasattr(cv2, "AKAZE_create") else cv2.xfeatures2d
    monkeypatch.setattr(akaze_namespace, "AKAZE_create", lambda: Detector(akaze_points, akaze_desc))
    monkeypatch.setattr(cv2, "imread", lambda *_: np.zeros((64, 64), dtype=np.uint8))
    class Scene:
        def add_triangles(self, _): return 0
        def cast_rays(self, rays):
            return {"t_hit": o3d.core.Tensor(np.ones(len(rays)), dtype=o3d.core.float32)}
    monkeypatch.setattr(o3d.t.geometry, "RaycastingScene", Scene)
    return akaze_points, akaze_desc


def test_worst_case_mobile_quality_outputs_at_most_200k_aligned_features(monkeypatch):
    points, descriptors = _fake_detectors(monkeypatch)
    mesh = o3d.geometry.TriangleMesh.create_box()
    images = [dict(path=str(i), pose=np.eye(4)) for i in range(81)]
    database = feature_extraction.build_feature_database(
        images, mesh, max_keyframes=80, orb_nfeatures=2000, max_akaze_features=500,
        bow_k=1, use_minibatch_kmeans=True, kmeans_n_init=1, kmeans_max_iter=1)
    assert len(database.keyframes) == 80
    assert database.keyframes[0].image_id == 0 and database.keyframes[-1].image_id == 80
    assert sum(len(frame.descriptors) + len(frame.akaze_descriptors) for frame in database.keyframes) == 200_000
    for frame in database.keyframes:
        assert len(frame.descriptors) == len(frame.keypoints) == len(frame.points_3d) == 2000
        assert len(frame.akaze_descriptors) == len(frame.akaze_keypoints) == len(frame.akaze_points_3d) == 500
        assert frame.akaze_keypoints[0] == points[-1].pt
        np.testing.assert_array_equal(frame.akaze_descriptors[0], descriptors[-1])


def test_legacy_akaze_extraction_remains_uncapped(monkeypatch):
    _fake_detectors(monkeypatch)
    database = feature_extraction.build_feature_database(
        [dict(path="frame", pose=np.eye(4))], o3d.geometry.TriangleMesh.create_box(), bow_k=1,
        use_minibatch_kmeans=True, kmeans_n_init=1, kmeans_max_iter=1)
    assert len(database.keyframes[0].akaze_descriptors) == 1700
