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
    assert mobile.get("keyframe_selection", "even") == "even"
    assert mobile["orb_nfeatures"] == orb and mobile["bow_k"] == vocab
    assert mobile.get("max_akaze_features") == akaze
    assert mobile["extract_akaze"] == (profile == "quality")
    OptimizedPipeline(processing_profile=profile).build_feature_database(None, [])
    assert calls[-1]["max_keyframes"] == (None if profile == "quality" else 80)
    assert "max_akaze_features" not in calls[-1]
    assert calls[-1].get("keyframe_selection", "even") == "even"


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


@pytest.mark.parametrize("profile,capacity", [("quality", 100), ("fast", 500)])
def test_v2_prepared_frames_are_authoritative(monkeypatch, profile, capacity):
    calls = []
    monkeypatch.setattr(OptimizedPipeline, "_trimesh_to_o3d", lambda self, mesh: mesh)
    monkeypatch.setattr(feature_extraction, "build_feature_database",
                        lambda *args, **kwargs: calls.append(kwargs) or FeatureDatabase(keyframes=[]))
    OptimizedPipeline(
        processing_profile=profile, mobile_feature_limits=True,
        mobile_preparation_policy="mobile-scan-preparation-v2",
        mobile_preparation_capacity=capacity,
    ).build_feature_database(None, [dict(path=str(i)) for i in range(capacity)])
    assert calls[-1]["max_keyframes"] is None
    assert calls[-1]["keyframe_selection"] == "even"
    assert calls[-1]["mobile_feature_budget"] == profile


def test_explicit_v2_policy_cannot_accidentally_keep_legacy_selection(monkeypatch):
    calls = []
    monkeypatch.setattr(OptimizedPipeline, "_trimesh_to_o3d", lambda self, mesh: mesh)
    monkeypatch.setattr(feature_extraction, "build_feature_database",
                        lambda *args, **kwargs: calls.append(kwargs) or FeatureDatabase(keyframes=[]))
    OptimizedPipeline(mobile_preparation_policy="mobile-scan-preparation-v2").build_feature_database(None, [])
    assert calls[-1]["max_keyframes"] is None
    assert calls[-1]["keyframe_selection"] == "even"
    assert calls[-1]["mobile_feature_budget"] == "quality"


def test_v2_over_capacity_fails_before_mesh_conversion(monkeypatch):
    monkeypatch.setattr(OptimizedPipeline, "_trimesh_to_o3d",
                        lambda *_: pytest.fail("over-capacity inputs must be rejected before extraction"))
    pipeline = OptimizedPipeline(
        mobile_feature_limits=True, mobile_preparation_policy="mobile-scan-preparation-v2",
        mobile_preparation_capacity=100,
    )
    with pytest.raises(ValueError, match="coverage_budget_exceeded"):
        pipeline.build_feature_database(None, [dict(path=str(i)) for i in range(101)])


@pytest.mark.parametrize("policy,capacity", [
    ("unknown", 100), ("mobile-scan-preparation-v2", 80),
    ("mobile-scan-preparation-v2", True),
])
def test_mobile_preparation_contract_rejects_unknown_configuration(policy, capacity):
    with pytest.raises(ValueError):
        OptimizedPipeline(mobile_feature_limits=True, mobile_preparation_policy=policy,
                          mobile_preparation_capacity=capacity)


def install_budget_detectors(monkeypatch, orb_hits=None, akaze_hits=None):
    """Keep real ray projection/BoW, replacing detector and clustering cost only."""
    state = {"frame": 0, "kind": "orb", "training_rows": []}

    def detector_result(count, width):
        indices = np.arange(count)
        points = [cv2.KeyPoint(float(2 + i % 60), float(2 + (i // 60) % 60), 1,
                              response=float(i // 2)) for i in indices]
        descriptors = np.zeros((count, width), dtype=np.uint8)
        descriptors[:, 0] = indices % 256
        descriptors[:, 1] = indices // 256
        return points, descriptors

    results = {"orb": detector_result(2000, 32), "akaze": detector_result(500, 61)}

    class Detector:
        def __init__(self, kind, maximum):
            self.kind, self.maximum = kind, maximum

        def detectAndCompute(self, *_):
            state["kind"] = self.kind
            points, descriptors = results[self.kind]
            return points[:self.maximum], descriptors[:self.maximum]

    monkeypatch.setattr(cv2, "ORB_create", lambda nfeatures: Detector("orb", nfeatures))
    namespace = cv2 if hasattr(cv2, "AKAZE_create") else cv2.xfeatures2d
    monkeypatch.setattr(namespace, "AKAZE_create", lambda: Detector("akaze", 500))

    def read_image(path, *_):
        state["frame"] = int(path)
        return np.zeros((64, 64), dtype=np.uint8)

    monkeypatch.setattr(cv2, "imread", read_image)

    class Scene:
        def add_triangles(self, _):
            return 0

        def cast_rays(self, rays):
            hits_by_frame = orb_hits if state["kind"] == "orb" else akaze_hits
            count = len(rays) if hits_by_frame is None else hits_by_frame[state["frame"]]
            distances = np.full(len(rays), np.inf, dtype=np.float32)
            if count:
                distances[-count:] = 1.0
            return {"t_hit": o3d.core.Tensor(distances, dtype=o3d.core.float32)}

    monkeypatch.setattr(o3d.t.geometry, "RaycastingScene", Scene)

    class Clustering:
        def __init__(self, n_clusters, **_):
            self.n_clusters = n_clusters

        def fit(self, descriptors):
            state["training_rows"].append(len(descriptors))
            self.labels_ = np.arange(len(descriptors)) % self.n_clusters
            self.cluster_centers_ = descriptors[:self.n_clusters]

    import sklearn.cluster
    monkeypatch.setattr(sklearn.cluster, "KMeans", Clustering)
    monkeypatch.setattr(sklearn.cluster, "MiniBatchKMeans", Clustering)
    return state, results


def budget_images(count):
    return [dict(path=str(i), source_image_id=i * 3 + 7, pose=np.eye(4)) for i in range(count)]


@pytest.mark.parametrize("count,profile,orb_total,akaze_total", [
    (80, "quality", 160_000, 40_000), (81, "quality", 160_000, 40_000),
    (100, "quality", 160_000, 40_000), (500, "quality", 160_000, 40_000),
    (500, "fast", 200_000, 0),
])
def test_budget_keeps_every_eligible_frame_and_trains_on_final_features(
        monkeypatch, count, profile, orb_total, akaze_total):
    state, _ = install_budget_detectors(monkeypatch)
    images = budget_images(count)
    database = feature_extraction.build_feature_database(
        images, o3d.geometry.TriangleMesh.create_box(), bow_k=2,
        mobile_feature_budget=profile,
    )
    assert [frame.image_id for frame in database.keyframes] == [image["source_image_id"] for image in images]
    assert sum(len(frame.descriptors) for frame in database.keyframes) == orb_total
    assert sum(0 if frame.akaze_descriptors is None else len(frame.akaze_descriptors)
               for frame in database.keyframes) == akaze_total
    assert state["training_rows"] == [orb_total]
    assert database.global_descriptors.shape == (count, 2)
    assert np.all(np.isfinite(database.global_descriptors))
    assert database.selection_report["retainedKeyframeCount"] == count
    assert database.selection_report["orbFeatureCount"] == orb_total
    assert database.selection_report["akazeFeatureCount"] == akaze_total


def test_budget_is_applied_after_geometry_and_recycles_weak_view_quotas(monkeypatch):
    hits = [19, 20, 50] + [2000] * 98
    install_budget_detectors(monkeypatch, orb_hits=hits)
    images = budget_images(len(hits))
    database = feature_extraction.build_feature_database(
        images, o3d.geometry.TriangleMesh.create_box(), bow_k=2, mobile_feature_budget="quality",
    )
    frames = database.keyframes
    assert len(frames) == 100
    assert frames[0].image_id == images[1]["source_image_id"]
    assert [len(frame.descriptors) for frame in frames[:2]] == [20, 50]
    assert sum(len(frame.descriptors) for frame in frames) == 160_000
    assert max(len(frame.descriptors) for frame in frames[2:]) - min(len(frame.descriptors) for frame in frames[2:]) <= 1
    assert database.selection_report["insufficientFeatureFrameIndices"] == [images[0]["source_image_id"]]
    assert database.selection_report["insufficientFeatureFrameCount"] == 1


def test_budget_remainders_use_source_index_and_response_ties_preserve_alignment(monkeypatch):
    _, results = install_budget_detectors(monkeypatch)
    images = list(reversed(budget_images(81)))
    database = feature_extraction.build_feature_database(
        images, o3d.geometry.TriangleMesh.create_box(), bow_k=2, mobile_feature_budget="quality",
    )
    assert [frame.image_id for frame in database.keyframes] == sorted(image["source_image_id"] for image in images)
    assert [len(frame.descriptors) for frame in database.keyframes] == [1976] * 25 + [1975] * 56
    frame = database.keyframes[0]
    expected = sorted(range(2000), key=lambda i: -results["orb"][0][i].response)[:1976]
    np.testing.assert_array_equal(frame.descriptors, results["orb"][1][expected])
    assert frame.keypoints == [results["orb"][0][i].pt for i in expected]
    for point, hit in zip(frame.keypoints, frame.points_3d):
        direction = np.array([(point[0] - 32) / 51.2, -(point[1] - 32) / 51.2, -1.0])
        np.testing.assert_allclose(hit, direction / np.linalg.norm(direction), atol=1e-7)
    expected_akaze = sorted(range(500), key=lambda i: -results["akaze"][0][i].response)[:494]
    np.testing.assert_array_equal(frame.akaze_descriptors, results["akaze"][1][expected_akaze])
    assert frame.akaze_keypoints == [results["akaze"][0][i].pt for i in expected_akaze]
    for point, hit in zip(frame.akaze_keypoints, frame.akaze_points_3d):
        direction = np.array([(point[0] - 32) / 51.2, -(point[1] - 32) / 51.2, -1.0])
        np.testing.assert_allclose(hit, direction / np.linalg.norm(direction), atol=1e-7)


def test_akaze_budget_recycles_quota_from_missing_and_weak_geometry(monkeypatch):
    install_budget_detectors(monkeypatch, akaze_hits=[0, 20, 50] + [500] * 97)
    database = feature_extraction.build_feature_database(
        budget_images(100), o3d.geometry.TriangleMesh.create_box(),
        mobile_feature_budget="quality", bow_k=2,
    )
    assert len(database.keyframes) == 100
    assert database.keyframes[0].akaze_descriptors is None
    assert [len(frame.akaze_descriptors) for frame in database.keyframes[1:3]] == [20, 50]
    full_quotas = [len(frame.akaze_descriptors) for frame in database.keyframes[3:]]
    assert max(full_quotas) - min(full_quotas) <= 1
    assert sum(full_quotas) + 70 == 40_000


def test_small_v2_maps_preserve_existing_feature_arrays(monkeypatch):
    install_budget_detectors(monkeypatch)
    mesh = o3d.geometry.TriangleMesh.create_box()
    images = budget_images(3)
    legacy = feature_extraction.build_feature_database(images, mesh, max_akaze_features=500, bow_k=2)
    mobile = feature_extraction.build_feature_database(images, mesh, mobile_feature_budget="quality", bow_k=2)
    for old, new in zip(legacy.keyframes, mobile.keyframes):
        np.testing.assert_array_equal(old.descriptors, new.descriptors)
        np.testing.assert_array_equal(old.akaze_descriptors, new.akaze_descriptors)
        assert old.keypoints == new.keypoints and old.points_3d == new.points_3d
    np.testing.assert_array_equal(legacy.vocabulary, mobile.vocabulary)
    np.testing.assert_array_equal(legacy.global_descriptors, mobile.global_descriptors)


def test_unknown_mobile_budget_fails_before_detector_creation(monkeypatch):
    monkeypatch.setattr(cv2, "ORB_create", lambda **_: pytest.fail("unknown budget must be rejected first"))
    with pytest.raises(ValueError, match="Unsupported mobile feature budget"):
        feature_extraction.build_feature_database([], o3d.geometry.TriangleMesh.create_box(),
                                                   mobile_feature_budget="unlimited")


def test_v2_export_rechecks_alignment_before_writing(monkeypatch, tmp_path):
    from processing_pipeline.models import KeyframeData
    from processing_pipeline import optimized_pipeline
    database = FeatureDatabase(keyframes=[KeyframeData(
        image_id=0, keypoints=[], descriptors=np.zeros((20, 32), dtype=np.uint8),
        points_3d=[(0.0, 0.0, 0.0)] * 20, camera_pose=np.eye(4),
    )])
    monkeypatch.setattr(optimized_pipeline, "save_feature_database",
                        lambda *_: pytest.fail("invalid database must not be exported"))
    pipeline = OptimizedPipeline(mobile_feature_limits=True,
                                 mobile_preparation_policy="mobile-scan-preparation-v2")
    with pytest.raises(ValueError, match="aligned"):
        pipeline.export_asset_bundle("missing.glb", None, database, str(tmp_path / "asset"))
    assert not (tmp_path / "asset").exists()
