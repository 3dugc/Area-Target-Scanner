"""Balanced mobile feature quotas keep every geometrically eligible view."""

import importlib

import pytest
import numpy as np

from processing_pipeline.models import FeatureDatabase, KeyframeData


def _quotas():
    spec = importlib.util.find_spec("processing_pipeline.feature_budget")
    assert spec is not None, "mobile feature quota allocator is missing"
    return importlib.import_module("processing_pipeline.feature_budget").balanced_quotas


@pytest.mark.parametrize("count,expected", [(80, 2000), (100, 1600), (500, 320)])
def test_quality_orb_budget_balances_full_frames(count, expected):
    assert _quotas()([2000] * count, 160_000, 2000, minimum=20) == [expected] * count


def test_quality_akaze_budget_for_500_full_frames():
    assert _quotas()([500] * 500, 40_000, 500) == [80] * 500


def test_weak_views_keep_features_and_return_unused_quota():
    assert _quotas()([20, 50, 2000], 1500, 2000, minimum=20) == [20, 50, 1430]


def test_remainder_uses_stable_input_order():
    assert _quotas()([2000] * 81, 160_000, 2000, minimum=20) == [1976] * 25 + [1975] * 56


def test_empty_or_zero_demand_does_not_consume_budget():
    assert _quotas()([], 100, 500) == []
    assert _quotas()([0, 50, 500], 600, 500) == [0, 50, 500]


def test_minimum_reservation_must_fit_budget():
    with pytest.raises(ValueError, match="feature_budget_exceeded"):
        _quotas()([20] * 3, 59, 2000, minimum=20)


@pytest.mark.parametrize("demands,total,maximum,minimum", [
    ([1.5], 10, 500, 0), ([-1], 10, 500, 0), ([True], 10, 500, 0),
    ([20], -1, 500, 20), ([20], 10, 0, 0), ([20], 10, 500, -1),
])
def test_invalid_limits_and_demands_are_rejected(demands, total, maximum, minimum):
    with pytest.raises(ValueError):
        _quotas()(demands, total, maximum, minimum)


def _validation_database():
    frame = KeyframeData(
        image_id=7, descriptors=np.zeros((20, 32), dtype=np.uint8),
        keypoints=[(1.0, 2.0)] * 20, points_3d=[(1.0, 2.0, 3.0)] * 20,
        camera_pose=np.eye(4), akaze_descriptors=np.zeros((3, 61), dtype=np.uint8),
        akaze_keypoints=[(1.0, 2.0)] * 3, akaze_points_3d=[(1.0, 2.0, 3.0)] * 3,
    )
    return FeatureDatabase(keyframes=[frame], vocabulary=np.zeros((1, 32), dtype=np.uint8),
                           global_descriptors=np.ones((1, 1)))


def test_export_validation_reports_actual_counts():
    from processing_pipeline.feature_budget import validate_mobile_feature_database
    assert validate_mobile_feature_database(_validation_database(), "quality") == {
        "orbFeatureCount": 20, "akazeFeatureCount": 3,
        "vocabularySize": 1, "retainedKeyframeCount": 1,
    }


@pytest.mark.parametrize("field,value", [
    ("descriptors", np.zeros((20, 31), dtype=np.uint8)),
    ("descriptors", np.zeros((20, 32), dtype=np.float32)),
    ("keypoints", [(1.0, 2.0)] * 19),
    ("points_3d", [(1.0, 2.0, 3.0)] * 19),
    ("akaze_keypoints", None),
    ("akaze_points_3d", [(1.0, 2.0, 3.0)]),
    ("akaze_descriptors", np.zeros((3, 60), dtype=np.uint8)),
    ("keypoints", [(float("nan"), 2.0)] * 20),
    ("points_3d", [(1.0, 2.0, float("inf"))] * 20),
])
def test_export_validation_rejects_invalid_correspondences(field, value):
    from processing_pipeline.feature_budget import validate_mobile_feature_database
    database = _validation_database()
    setattr(database.keyframes[0], field, value)
    with pytest.raises(ValueError):
        validate_mobile_feature_database(database, "quality")


@pytest.mark.parametrize("field,value", [
    ("vocabulary", np.zeros((1001, 32), dtype=np.uint8)),
    ("vocabulary", np.zeros((1, 31), dtype=np.uint8)),
    ("global_descriptors", np.ones((2, 1))),
    ("global_descriptors", np.full((1, 1), np.nan)),
])
def test_export_validation_rejects_invalid_bow(field, value):
    from processing_pipeline.feature_budget import validate_mobile_feature_database
    database = _validation_database()
    setattr(database, field, value)
    with pytest.raises(ValueError):
        validate_mobile_feature_database(database, "quality")


def test_export_validation_enforces_native_frame_count_and_total_feature_limits():
    from dataclasses import replace
    from processing_pipeline.feature_budget import validate_mobile_feature_database
    database = _validation_database()
    database.keyframes = [replace(database.keyframes[0], image_id=i) for i in range(1001)]
    with pytest.raises(ValueError, match="1000 keyframes"):
        validate_mobile_feature_database(database, "quality")
    frame = _validation_database().keyframes[0]
    frame.descriptors = np.zeros((2000, 32), dtype=np.uint8)
    frame.keypoints = [(1.0, 2.0)] * 2000
    frame.points_3d = [(1.0, 2.0, 3.0)] * 2000
    database.keyframes = [replace(frame, image_id=i) for i in range(81)]
    database.global_descriptors = np.ones((81, 1))
    with pytest.raises(ValueError, match="total feature limit"):
        validate_mobile_feature_database(database, "quality")


def test_fast_export_rejects_akaze():
    from processing_pipeline.feature_budget import validate_mobile_feature_database
    with pytest.raises(ValueError, match="AKAZE limit"):
        validate_mobile_feature_database(_validation_database(), "fast")


def test_fixed_budget_config_cannot_raise_reader_limits():
    from dataclasses import replace
    from processing_pipeline.feature_budget import MOBILE_FEATURE_BUDGETS, resolve_mobile_feature_budget
    quality = MOBILE_FEATURE_BUDGETS["quality"]
    assert resolve_mobile_feature_budget(quality) is quality
    with pytest.raises(ValueError, match="Unsupported mobile feature budget"):
        resolve_mobile_feature_budget(replace(quality, orb_total=1_000_000))
