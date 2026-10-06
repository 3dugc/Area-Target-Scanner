"""Behavior checks for the independent OpenCV comparison runner."""

import importlib.util
import os
from pathlib import Path

import numpy as np
import pytest


@pytest.fixture(scope="module")
def runner():
    def load():
        path = Path(__file__).resolve().parents[1] / "tools/opencv5/compare.py"
        assert path.exists(), "The OpenCV comparison runner has not been implemented"
        spec = importlib.util.spec_from_file_location("opencv_comparison", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    return load


def test_timing_reports_median_and_p95_in_milliseconds(runner):
    runner = runner()
    result = runner.timing_stats([0.001, 0.002, 0.003, 0.004, 0.005])
    assert result == {"median_ms": 3.0, "p95_ms": 4.8, "samples": 5}


def test_pose_error_uses_relative_rotation_and_translation(runner):
    runner = runner()
    expected = np.eye(4)
    actual = np.array([[0, -1, 0, 3], [1, 0, 0, 4], [0, 0, 1, 0], [0, 0, 0, 1]])
    result = runner.pose_error(actual, expected)
    assert result["rotation_deg"] == pytest.approx(90)
    assert result["translation"] == pytest.approx(5)


def test_known_homography_counts_geometric_matches_and_errors(runner):
    runner = runner()
    train = np.array([[10, 20], [30, 40], [50, 60]], dtype=float)
    query = np.array([[13, 25], [33, 45], [70, 80]], dtype=float)
    homography = np.array([[1, 0, 3], [0, 1, 5], [0, 0, 1]], dtype=float)
    matches = [(0, 0, 0.0), (1, 1, 2.0), (2, 2, 9.0)]
    result = runner.match_metrics(query, train, matches, homography, threshold=3)
    assert result["ratio_matches"] == 3
    assert result["geometric_inliers"] == 2
    assert result["precision"] == pytest.approx(2 / 3)
    assert result["median_error_px"] == 0


def test_unrelated_images_do_not_claim_geometric_inliers(runner):
    runner = runner()
    result = runner.match_metrics(np.zeros((1, 2)), np.zeros((1, 2)), [(0, 0, 1)], None)
    assert result["ratio_matches"] == 1
    assert result["geometric_inliers"] is None
    assert result["precision"] is None


def test_real_akaze_factory_uses_binary_descriptors(runner):
    runner = runner()
    import cv2

    detector = runner._extractor(cv2, "akaze")
    assert detector.descriptorSize() == 61
    assert detector.descriptorType() == cv2.CV_8U


@pytest.mark.parametrize("field", ["input_sha256", "numpy_version", "settings"])
def test_comparison_rejects_mismatched_input_or_execution_identity(runner, field):
    runner = runner()
    first = {"input_sha256": "fixed", "numpy_version": "2.4.6", "settings": {"threads": 1}}
    second = {**first, field: "different"}
    with pytest.raises(ValueError, match=field):
        runner.validate_comparable(first, second)


def test_comparison_rejects_same_major_reports_instead_of_labeling_them_4_to_5(runner):
    runner = runner()
    identity = {"input_sha256": "fixed", "numpy_version": np.__version__, "settings": {}}
    first = {**identity, "opencv_version": "4.13.0", "extraction": {}, "pnp": {},
             "matching": {"self": {}}}
    second = {**first, "reference_producer": {**identity, "opencv_version": "4.13.0"},
              "matching": {"self": {}, "reference": {}}}
    with pytest.raises(ValueError, match="OpenCV 4.*OpenCV 5"):
        runner.compare_reports(first, second)


def test_comparison_includes_both_producers_and_preserves_native_failure(runner):
    runner = runner()
    identity = {"input_sha256": "fixed", "numpy_version": np.__version__, "settings": {}}
    first = {**identity, "opencv_version": "4.13.0", "extraction": {}, "pnp": {},
             "matching": {"self": {"old": 1}}, "native_contract_passed": False}
    second = {**identity, "opencv_version": "5.0.0", "extraction": {}, "pnp": {},
              "reference_producer": {**identity, "opencv_version": "4.13.0"},
              "matching": {"self": {"new": 2}, "reference": {"old_to_new": 3}},
              "native_contract_passed": True}
    report = runner.compare_reports(first, second)
    assert report["matching"] == {"4_to_4": {"old": 1}, "4_to_5": {"old_to_new": 3}, "5_to_5": {"new": 2}}
    assert report["native_contract_passed"] == {"old": False, "new": True}


def test_prepare_once_has_all_cases_and_non_coplanar_pnp(runner, tmp_path):
    runner = runner()
    import cv2

    if not cv2.__version__.startswith("4."):
        pytest.skip("Input producer must be OpenCV 4")
    path = tmp_path / "inputs.npz"
    runner.prepare_inputs(path)
    with np.load(path, allow_pickle=False) as inputs:
        assert all(inputs["image_" + name].dtype == np.uint8 for name in runner.CASES)
        assert np.array_equal(inputs["image_identity"], inputs["image_base"])
        assert np.ptp(inputs["pnp_points3d"][:, 2]) > 1
        assert np.count_nonzero(inputs["pnp_outlier_mask"]) > 0
    with pytest.raises(FileExistsError):
        runner.prepare_inputs(path)


def test_real_run_extracts_uint8_features_matches_and_recovers_noisy_pose(runner, tmp_path):
    runner = runner()
    import cv2

    if not cv2.__version__.startswith("4."):
        pytest.skip("Input producer must be OpenCV 4")
    inputs, features = tmp_path / "inputs.npz", tmp_path / "features.npz"
    runner.prepare_inputs(inputs)
    report = runner.run_suite(inputs, features, warmup=0, repeats=1)
    assert report["runtime"]["opencv_threads"] == 1
    assert report["runtime"]["numpy_version"] == np.__version__
    for algorithm in ["orb", "akaze"]:
        identity = report["matching"]["self"][algorithm]["identity"]
        assert identity["geometric_inliers"] > 50
        assert identity["median_error_px"] < 0.001
    for case in ["clean", "noise", "outliers"]:
        result = report["pnp"][case]
        assert result["success"]
        assert result["pose_error"]["rotation_deg"] < 1
        assert result["pose_error"]["translation"] < 0.05
    with np.load(features, allow_pickle=False) as saved:
        assert saved["orb_descriptors"].dtype == np.uint8
        assert saved["akaze_descriptors"].dtype == np.uint8


def test_native_requires_tracking_for_known_pose_and_lost_for_blank(runner, tmp_path):
    library = os.environ.get("OPENCV_COMPARISON_NATIVE_LIBRARY")
    if not library:
        pytest.skip("Set OPENCV_COMPARISON_NATIVE_LIBRARY for the real C ABI contract check")
    runner = runner()
    import cv2

    if not cv2.__version__.startswith("4."):
        pytest.skip("Input producer must be OpenCV 4")
    inputs, features = tmp_path / "inputs.npz", tmp_path / "features.npz"
    runner.prepare_inputs(inputs)
    report = runner.run_suite(inputs, features, warmup=0, repeats=1, native_library=library)
    for algorithm in ["orb", "akaze"]:
        result = report["native"]["self"][algorithm]
        assert result["known_pose"]["state"] == "TRACKING"
        assert result["known_pose"]["pose_error"]["rotation_deg"] < 1
        assert result["known_pose"]["pose_error"]["translation"] < 0.05
        assert result["blank"]["state"] == "LOST"
