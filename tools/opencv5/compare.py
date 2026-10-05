#!/usr/bin/env python3
"""Run each OpenCV version in its own Python process on one frozen NPZ suite.

Example (prepare exactly once with OpenCV 4):
  python4 compare.py prepare --inputs inputs.npz
  python4 compare.py run --inputs inputs.npz --output 4.json --features-output 4.npz
  python5 compare.py run --inputs inputs.npz --output 5.json --features-output 5.npz \
      --reference-features 4.npz
  python4 compare.py compare --old 4.json --new 5.json --output comparison.json

Add --native-library PATH to each run to exercise that process's sole native
localizer through the existing C ABI. No OpenCV 4 and 5 native libraries may be
loaded into the same process. The feature artifacts contain uint8 descriptors.
"""

import argparse
import ctypes as ct
import hashlib
import json
import os
from pathlib import Path
import platform
import sys
import time

# These apply to independently loaded OpenCV/BLAS runtimes before import/CDLL.
for _variable in ("OPENCV_FOR_THREADS_NUM", "OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS",
                  "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ[_variable] = "1"
os.environ["OPENCV_OPENCL_RUNTIME"] = "disabled"

import numpy as np


CASES = ("identity", "lighting", "affine", "blur", "blank", "unrelated")
SEED = 20261005
ORB_PARAMETERS = dict(nfeatures=3000, scaleFactor=1.2, nlevels=8,
                      edgeThreshold=31, firstLevel=0, WTA_K=2,
                      scoreType=0, patchSize=31, fastThreshold=20)
LIMITATIONS = [
    "Synthetic images and geometry do not establish field recognition rate or robustness.",
    "CPU timings are observations of these builds. Compiler flags, CPU dispatch and "
    "packaging are not fully controlled; timing percentages cannot be attributed "
    "causally to the OpenCV version.",
    "Native version/dependency identity must be checked externally (for example otool); "
    "the public C ABI does not expose a runtime version or thread-count getter.",
]


def timing_stats(seconds):
    values = np.asarray(seconds, dtype=float) * 1000
    if not len(values):
        raise ValueError("At least one measured repeat is required")
    return {"median_ms": float(np.median(values)),
            "p95_ms": float(np.percentile(values, 95)), "samples": len(values)}


def pose_error(actual, expected):
    actual, expected = np.asarray(actual), np.asarray(expected)
    relative = actual[:3, :3] @ expected[:3, :3].T
    cosine = np.clip((np.trace(relative) - 1) / 2, -1, 1)
    return {"rotation_deg": float(np.degrees(np.arccos(cosine))),
            "translation": float(np.linalg.norm(actual[:3, 3] - expected[:3, 3]))}


def match_metrics(query_xy, train_xy, matches, homography, threshold=3.0):
    result = {"ratio_matches": len(matches), "geometric_inliers": None,
              "precision": None, "median_error_px": None, "p95_error_px": None}
    if homography is None:
        return result
    if not matches:
        result.update(geometric_inliers=0, precision=0.0)
        return result
    query_ids, train_ids = np.asarray(matches, dtype=float)[:, :2].astype(int).T
    train = np.asarray(train_xy)[train_ids]
    homogeneous = np.column_stack([train, np.ones(len(train))]) @ homography.T
    predicted = homogeneous[:, :2] / homogeneous[:, 2:3]
    errors = np.linalg.norm(np.asarray(query_xy)[query_ids] - predicted, axis=1)
    count = int(np.count_nonzero(errors <= threshold))
    result.update(geometric_inliers=count, precision=count / len(matches),
                  median_error_px=float(np.median(errors)),
                  p95_error_px=float(np.percentile(errors, 95)))
    return result


def validate_comparable(first, second):
    for field in ("input_sha256", "numpy_version", "settings"):
        if field not in first or field not in second or first[field] != second[field]:
            raise ValueError("Refusing comparison: " + field + " differs or is absent")


def _sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _json_array(value):
    return np.array(json.dumps(value, sort_keys=True))


def _metadata(archive):
    return json.loads(str(archive["metadata"]))


def _settings(warmup, repeats):
    return {"seed": SEED, "threads": 1, "opencv_setNumThreads_argument": 0, "opencl": False,
            "warmup": warmup, "repeats": repeats,
            "clahe": {"clipLimit": 2.0, "tileGridSize": [8, 8]},
            "orb": ORB_PARAMETERS,
            "akaze": {"descriptor_type": "MLDB", "descriptor_size": 0,
                      "descriptor_channels": 3, "threshold": .001,
                      "nOctaves": 4, "nOctaveLayers": 4, "diffusivity": "PM_G2"},
            "matching": {"norm": "HAMMING", "ratio": .75,
                         "bidirectional_ratio_check": True, "geometric_threshold_px": 3},
            "pnp": {"iterationsCount": 200, "reprojectionError": 3.0,
                    "confidence": .999, "flags": "ITERATIVE", "refine_inliers": True}}


def prepare_inputs(path):
    """Freeze every pixel/correspondence under OpenCV 4, without overwriting."""
    import cv2

    path = Path(path)
    if path.exists():
        raise FileExistsError("Inputs already exist; reuse this NPZ for both versions: " + str(path))
    if cv2.__version__.split(".")[0] != "4":
        raise ValueError("prepare must run exactly once in the OpenCV 4 environment")
    cv2.setNumThreads(0)  # Disable parallel_for; GCD's getter otherwise reports CPU count.
    cv2.ocl.setUseOpenCL(False)
    rng = np.random.default_rng(SEED)
    height, width = 480, 640
    base = rng.integers(0, 256, (height, width), dtype=np.uint8)
    for _ in range(160):
        x, y = rng.integers(25, width - 25), rng.integers(25, height - 25)
        cv2.circle(base, (int(x), int(y)), int(rng.integers(3, 18)),
                   int(rng.integers(0, 256)), -1)
    affine = cv2.getRotationMatrix2D((width / 2, height / 2), 4, .97)
    affine[:, 2] += [7, -5]
    homography = np.vstack([affine, [0, 0, 1]])
    arrays = {"image_base": base, "image_identity": base.copy(),
              "image_lighting": np.clip(base.astype(float) * .65 + 35, 0, 255).astype(np.uint8),
              "image_affine": cv2.warpAffine(base, affine, (width, height)),
              "image_blur": cv2.GaussianBlur(base, (5, 5), 1.2),
              "image_blank": np.full_like(base, 127),
              "image_unrelated": rng.integers(0, 256, base.shape, dtype=np.uint8),
              "homography_affine": homography}
    camera = np.array([[500., 0, 320], [0, 510., 240], [0, 0, 1]])
    points = rng.uniform([-1.3, -.9, 2.5], [1.3, .9, 5.5], (250, 3))
    rvec, tvec = np.array([.08, -.05, .03]), np.array([.15, -.12, .25])
    clean, _ = cv2.projectPoints(points, rvec, tvec, camera, None)
    clean = clean.reshape(-1, 2)
    noise = clean + rng.normal(0, .4, clean.shape)
    outliers = noise.copy()
    mask = np.zeros(len(points), dtype=bool)
    mask[rng.choice(len(points), 50, replace=False)] = True
    outliers[mask] = rng.uniform([0, 0], [width, height], (50, 2))
    pose = np.eye(4)
    pose[:3, :3] = cv2.Rodrigues(rvec)[0]
    pose[:3, 3] = tvec
    arrays.update(camera=camera, pnp_points3d=points,
                  pnp_clean=clean, pnp_noise=noise, pnp_outliers=outliers,
                  pnp_outlier_mask=mask, pnp_expected_pose=pose,
                  metadata=_json_array({"format": 1, "seed": SEED,
                                        "producer_opencv": cv2.__version__,
                                        "producer_numpy": np.__version__, "cases": CASES}))
    path.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation prevents a second producer from silently replacing inputs.
    with path.open("xb") as stream:
        np.savez_compressed(stream, **arrays)
    return {"input_sha256": _sha256(path), "path": str(path.resolve())}


def _measure(function, warmup, repeats):
    for _ in range(warmup):
        function()
    samples = []
    for _ in range(repeats):
        start = time.perf_counter()
        result = function()
        samples.append(time.perf_counter() - start)
    return result, timing_stats(samples)


def _extractor(cv2, algorithm):
    if algorithm == "orb":
        return cv2.ORB_create(**ORB_PARAMETERS)
    namespace = cv2 if hasattr(cv2, "AKAZE_create") else getattr(cv2, "xfeatures2d", None)
    if namespace is None or not hasattr(namespace, "AKAZE_create"):
        raise ValueError("AKAZE requires OpenCV 5 contrib (cv2.xfeatures2d.AKAZE_create); "
                         "the core-only opencv-python 5 package cannot run this comparison")
    return namespace.AKAZE_create(descriptor_type=namespace.AKAZE_DESCRIPTOR_MLDB,
                                 descriptor_size=0, descriptor_channels=3, threshold=.001,
                                 nOctaves=4, nOctaveLayers=4, diffusivity=namespace.KAZE_DIFF_PM_G2)


def _extract(cv2, detector, image):
    enhanced = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8)).apply(image)
    keypoints, descriptors = detector.detectAndCompute(enhanced, None)
    xy = np.array([keypoint.pt for keypoint in keypoints], dtype=np.float32).reshape(-1, 2)
    if descriptors is None:
        descriptors = np.empty((0, detector.descriptorSize()), dtype=np.uint8)
    if descriptors.dtype != np.uint8:
        raise TypeError("ORB/AKAZE C ABI descriptors must be uint8")
    return xy, np.ascontiguousarray(descriptors)


def _matches(cv2, query, train):
    if len(query) < 2 or len(train) < 2:
        return []
    matcher = cv2.BFMatcher(cv2.NORM_HAMMING)
    forward = matcher.knnMatch(query, train, k=2)
    reverse = matcher.knnMatch(train, query, k=2)
    backward = {pair[0].queryIdx: pair[0].trainIdx for pair in reverse
                if len(pair) == 2 and pair[0].distance < .75 * pair[1].distance}
    return [(pair[0].queryIdx, pair[0].trainIdx, float(pair[0].distance)) for pair in forward
            if len(pair) == 2 and pair[0].distance < .75 * pair[1].distance
            and backward.get(pair[0].trainIdx) == pair[0].queryIdx]


def _pnp(cv2, inputs, case):
    cv2.setRNGSeed(SEED)
    points, pixels, camera = inputs["pnp_points3d"], inputs["pnp_" + case], inputs["camera"]
    success, rotation, translation, inliers = cv2.solvePnPRansac(
        points, pixels, camera, None, iterationsCount=200, reprojectionError=3.,
        confidence=.999, flags=cv2.SOLVEPNP_ITERATIVE)
    if not success or inliers is None:
        return {"success": False, "inliers": 0, "pose_error": None}
    ids = inliers.ravel()
    refined, rotation, translation = cv2.solvePnP(
        points[ids], pixels[ids], camera, None, rotation, translation,
        useExtrinsicGuess=True, flags=cv2.SOLVEPNP_ITERATIVE)
    pose = np.eye(4)
    pose[:3, :3], pose[:3, 3] = cv2.Rodrigues(rotation)[0], translation.ravel()
    projected = cv2.projectPoints(points[ids], rotation, translation, camera, None)[0].reshape(-1, 2)
    errors = np.linalg.norm(projected - pixels[ids], axis=1)
    return {"success": bool(success), "refined": bool(refined), "inliers": len(ids),
            "pose_error": pose_error(pose, inputs["pnp_expected_pose"]),
            "median_reprojection_error_px": float(np.median(errors)),
            "p95_reprojection_error_px": float(np.percentile(errors, 95)),
            "outliers_accepted": int(np.count_nonzero(inputs["pnp_outlier_mask"][ids])) if case == "outliers" else 0}


class _VLResult(ct.Structure):
    _fields_ = [("state", ct.c_int), ("pose", ct.c_float * 16),
                ("confidence", ct.c_float), ("matched_features", ct.c_int)]


class _VLDebugInfo(ct.Structure):
    _fields_ = [("orb_keypoints", ct.c_int), ("candidate_keyframes", ct.c_int),
                ("best_kf_id", ct.c_int), ("best_raw_matches", ct.c_int),
                ("best_good_matches", ct.c_int), ("best_inliers", ct.c_int),
                ("best_bow_sim", ct.c_float), ("best_inlier_ratio", ct.c_float),
                ("akaze_triggered", ct.c_int), ("akaze_keypoints", ct.c_int),
                ("akaze_best_inliers", ct.c_int), ("consistency_rejected", ct.c_int)]


def _native_library(path):
    if ct.sizeof(_VLResult) != 76 or ct.sizeof(_VLDebugInfo) != 48:
        raise RuntimeError("Unexpected C ABI struct layout")
    library = ct.CDLL(str(Path(path).resolve()))
    handle, byte, floating = ct.c_void_p, ct.POINTER(ct.c_ubyte), ct.POINTER(ct.c_float)
    signatures = {
        "vl_create": (handle, []), "vl_destroy": (None, [handle]),
        "vl_reset": (None, [handle]), "vl_build_index": (ct.c_int, [handle]),
        "vl_add_vocabulary_word": (ct.c_int, [handle, ct.c_int, byte, ct.c_int, ct.c_float]),
        "vl_add_keyframe": (ct.c_int, [handle, ct.c_int, floating, byte, ct.c_int, floating, floating]),
        "vl_add_keyframe_akaze": (ct.c_int, [handle, ct.c_int, byte, ct.c_int, ct.c_int, floating, floating]),
        "vl_get_debug_info": (None, [handle, ct.POINTER(_VLDebugInfo)]),
        "vl_process_frame_out": (None, [handle, byte, ct.c_int, ct.c_int,
                                         ct.c_float, ct.c_float, ct.c_float, ct.c_float,
                                         ct.c_int, floating, ct.POINTER(_VLResult)]),
    }
    for name, (restype, argtypes) in signatures.items():
        function = getattr(library, name)
        function.restype, function.argtypes = restype, argtypes
    return library


def _pointer(array, ctype):
    return array.ctypes.data_as(ct.POINTER(ctype))


def _native_case(library, inputs, features, algorithm, warmup, repeats):
    """Backproject real detected pixels with varied AR -Z depths for known pose."""
    xy, descriptors = features[algorithm + "_xy"], features[algorithm + "_descriptors"]
    count = min(len(xy), 800)
    if count < 100:
        raise ValueError("Native synthetic contract needs at least 100 database features")
    xy, descriptors = np.ascontiguousarray(xy[:count], dtype=np.float32), np.ascontiguousarray(descriptors[:count])
    if descriptors.dtype != np.uint8:
        raise TypeError("Native descriptors must be uint8")
    camera = inputs["camera"]
    fx, fy, cx, cy = camera[0, 0], camera[1, 1], camera[0, 2], camera[1, 2]
    depths = np.random.default_rng(SEED + 1).uniform(2, 5, count)
    expected = np.eye(4)
    expected[:3, 3] = [.15, -.23, .34]
    points = np.column_stack([depths * (xy[:, 0] - cx) / fx,
                              -depths * (xy[:, 1] - cy) / fy, -depths])
    points = np.ascontiguousarray(points - expected[:3, 3], dtype=np.float32)
    database_pose = np.eye(4, dtype=np.float32)
    handle = library.vl_create()
    if not handle:
        raise RuntimeError("vl_create failed")
    try:
        word = np.zeros(32, dtype=np.uint8)
        if not library.vl_add_vocabulary_word(handle, 0, _pointer(word, ct.c_ubyte), 32, 1.):
            raise RuntimeError("Vocabulary load failed")
        # An ambiguous ORB database intentionally forces real AKAZE fallback.
        orb = descriptors if algorithm == "orb" else np.zeros((count, 32), dtype=np.uint8)
        if not library.vl_add_keyframe(handle, 7, _pointer(database_pose, ct.c_float),
                                      _pointer(orb, ct.c_ubyte), count,
                                      _pointer(points, ct.c_float), _pointer(xy, ct.c_float)):
            raise RuntimeError("ORB keyframe load failed")
        if algorithm == "akaze" and not library.vl_add_keyframe_akaze(
                handle, 7, _pointer(descriptors, ct.c_ubyte), count, descriptors.shape[1],
                _pointer(points, ct.c_float), _pointer(xy, ct.c_float)):
            raise RuntimeError("AKAZE keyframe load failed")
        if not library.vl_build_index(handle):
            raise RuntimeError("Native index build failed")

        def process(image):
            library.vl_reset(handle)
            result, debug = _VLResult(), _VLDebugInfo()
            library.vl_process_frame_out(handle, _pointer(image, ct.c_ubyte),
                                         image.shape[1], image.shape[0], fx, fy, cx, cy,
                                         0, None, ct.byref(result))
            library.vl_get_debug_info(handle, ct.byref(debug))
            pose = np.array(result.pose, dtype=float).reshape(4, 4)
            return {"state": {0: "INITIALIZING", 1: "TRACKING", 2: "LOST"}.get(result.state, "INVALID"),
                    "confidence": float(result.confidence), "matched_features": result.matched_features,
                    "pose": pose.tolist(), "pose_error": pose_error(pose, expected),
                    "debug": {name: getattr(debug, name) for name, _ in debug._fields_}}

        known, timing = _measure(lambda: process(inputs["image_base"]), warmup, repeats)
        known["timing"] = timing
        blank, blank_timing = _measure(lambda: process(inputs["image_blank"]), warmup, repeats)
        blank["timing"] = blank_timing
        passed = (known["state"] == "TRACKING"
                  and known["pose_error"]["rotation_deg"] < 1
                  and known["pose_error"]["translation"] < .05
                  and blank["state"] == "LOST" and blank["confidence"] == 0
                  and blank["matched_features"] == 0
                  and np.allclose(blank["pose"], np.eye(4), atol=0))
        if algorithm == "akaze":
            passed = passed and known["debug"]["akaze_triggered"] == 1 and known["debug"]["akaze_best_inliers"] >= 15
        return {"contract_passed": bool(passed), "database_features": count,
                "database_pose": database_pose.tolist(), "known_pose": known, "blank": blank}
    finally:
        library.vl_destroy(handle)


def run_suite(inputs_path, features_path, warmup=3, repeats=15,
              reference_features=None, native_library=None):
    import cv2

    if warmup < 0 or repeats < 1:
        raise ValueError("warmup must be nonnegative and repeats must be positive")
    if Path(inputs_path).resolve() == Path(features_path).resolve():
        raise ValueError("Feature output cannot overwrite fixed inputs")
    cv2.setNumThreads(0)
    cv2.ocl.setUseOpenCL(False)
    cv2.setRNGSeed(SEED)
    with np.load(inputs_path, allow_pickle=False) as archive:
        inputs = dict(archive)
    settings = _settings(warmup, repeats)
    identity = {"input_sha256": _sha256(inputs_path), "numpy_version": np.__version__,
                "settings": settings, "opencv_version": cv2.__version__}
    metadata = _metadata(inputs)
    if metadata["seed"] != SEED or metadata["producer_opencv"].split(".")[0] != "4":
        raise ValueError("The frozen suite must be prepared by OpenCV 4 with the fixed seed")
    if metadata["producer_numpy"] != np.__version__:
        raise ValueError("numpy_version differs from the fixed input producer")
    report = {**identity, "format": 1, "input_producer": metadata,
              "runtime": {"python": sys.version, "python_executable": sys.executable,
                          "opencv_version": cv2.__version__, "opencv_module": cv2.__file__,
                          "akaze_namespace": "cv2" if hasattr(cv2, "AKAZE_create") else "cv2.xfeatures2d",
                          "numpy_version": np.__version__, "opencv_threads": cv2.getNumThreads(),
                          "opencv_setNumThreads_argument": 0,
                          "opencl": cv2.ocl.useOpenCL(), "platform": platform.platform(),
                          "opencv_build_information": cv2.getBuildInformation()},
              "extraction": {}, "matching": {}, "pnp": {}, "limitations": LIMITATIONS}
    feature_arrays, queries = {"metadata": _json_array(identity)}, {}
    for algorithm in ("orb", "akaze"):
        detector = _extractor(cv2, algorithm)
        base, _ = _measure(lambda: _extract(cv2, detector, inputs["image_base"]), warmup, repeats)
        feature_arrays[algorithm + "_xy"], feature_arrays[algorithm + "_descriptors"] = base
        queries[algorithm], report["extraction"][algorithm] = {}, {}
        for case in CASES:
            extracted, timing = _measure(lambda: _extract(cv2, detector, inputs["image_" + case]), warmup, repeats)
            queries[algorithm][case] = extracted
            report["extraction"][algorithm][case] = {"keypoints": len(extracted[0]),
                                                    "descriptor_bytes": extracted[1].shape[1], "timing": timing}
    producers = {"self": feature_arrays}
    if reference_features:
        if Path(reference_features).resolve() == Path(features_path).resolve():
            raise ValueError("Feature output cannot overwrite the reference producer")
        with np.load(reference_features, allow_pickle=False) as archive:
            reference = dict(archive)
        validate_comparable(identity, _metadata(reference))
        producers["reference"] = reference
        report["reference_producer"] = _metadata(reference)
    for producer, features in producers.items():
        report["matching"][producer] = {}
        for algorithm in ("orb", "akaze"):
            train_xy, train_desc = features[algorithm + "_xy"], features[algorithm + "_descriptors"]
            report["matching"][producer][algorithm] = {}
            for case in CASES:
                query_xy, query_desc = queries[algorithm][case]
                matches, timing = _measure(lambda: _matches(cv2, query_desc, train_desc), warmup, repeats)
                homography = inputs["homography_affine"] if case == "affine" else np.eye(3)
                if case in ("blank", "unrelated"):
                    homography = None
                metrics = match_metrics(query_xy, train_xy, matches, homography)
                report["matching"][producer][algorithm][case] = {**metrics, "timing": timing}
    for case in ("clean", "noise", "outliers"):
        result, timing = _measure(lambda: _pnp(cv2, inputs, case), warmup, repeats)
        report["pnp"][case] = {**result, "timing": timing}
    if native_library:
        library = _native_library(native_library)
        report["native_library"] = {"path": str(Path(native_library).resolve()), "sha256": _sha256(native_library),
                                    "threads_requested_via_environment": 1}
        report["native"] = {producer: {algorithm: _native_case(library, inputs, features, algorithm, warmup, repeats)
                                      for algorithm in ("orb", "akaze")}
                            for producer, features in producers.items()}
        report["native_contract_passed"] = all(result["contract_passed"]
                                                for cases in report["native"].values() for result in cases.values())
    else:
        report["native_contract_passed"] = None
    Path(features_path).parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(features_path, **feature_arrays)
    return report


def compare_reports(old, new):
    validate_comparable(old, new)
    if old["opencv_version"].split(".")[0] != "4" or new["opencv_version"].split(".")[0] != "5":
        raise ValueError("Comparison requires an OpenCV 4 old run and an OpenCV 5 new run")
    if "reference_producer" not in new:
        raise ValueError("New run must include --reference-features for producer 4 -> query 5")
    validate_comparable(old, new["reference_producer"])
    if old["opencv_version"] != new["reference_producer"]["opencv_version"]:
        raise ValueError("reference_producer OpenCV version differs from old report")
    timings = []
    for section in ("extraction", "pnp"):
        def walk(first, second, path):
            if isinstance(first, dict) and "median_ms" in first:
                a, b = first["median_ms"], second["median_ms"]
                timings.append({"metric": path, "old_median_ms": a, "new_median_ms": b,
                                "old_p95_ms": first["p95_ms"], "new_p95_ms": second["p95_ms"],
                                "observed_change_percent": ((b / a - 1) * 100) if a else None})
            elif isinstance(first, dict):
                for key in first.keys() & second.keys():
                    walk(first[key], second[key], path + "." + key)
        walk(old[section], new[section], section)
    return {"format": 1, "input_sha256": old["input_sha256"],
            "old_opencv": old["opencv_version"], "new_opencv": new["opencv_version"],
            "numpy_version": old["numpy_version"], "settings": old["settings"],
            "matching": {"4_to_4": old["matching"]["self"],
                         "4_to_5": new["matching"]["reference"], "5_to_5": new["matching"]["self"]},
            "pnp": {"old": old["pnp"], "new": new["pnp"]},
            "native": {"old": old.get("native"), "new": new.get("native")},
            "native_contract_passed": {"old": old.get("native_contract_passed"),
                                       "new": new.get("native_contract_passed")},
            "observed_timings": sorted(timings, key=lambda item: item["metric"]), "limitations": LIMITATIONS}


def _write_json(path, report):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("prepare", help="Freeze inputs exactly once using OpenCV 4")
    prepare.add_argument("--inputs", required=True)
    run = commands.add_parser("run", help="Execute in one isolated OpenCV environment")
    for name in ("inputs", "output", "features-output"):
        run.add_argument("--" + name, required=True)
    run.add_argument("--reference-features")
    run.add_argument("--native-library")
    run.add_argument("--warmup", type=int, default=3)
    run.add_argument("--repeats", type=int, default=15)
    compare = commands.add_parser("compare", help="Validate comparable identities and combine reports")
    for name in ("old", "new", "output"):
        compare.add_argument("--" + name, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            print(json.dumps(prepare_inputs(args.inputs), sort_keys=True))
            return 0
        if args.command == "run":
            report = run_suite(args.inputs, args.features_output, args.warmup, args.repeats,
                               args.reference_features, args.native_library)
        else:
            report = compare_reports(json.loads(Path(args.old).read_text()), json.loads(Path(args.new).read_text()))
        _write_json(args.output, report)
        print(json.dumps({"output": str(Path(args.output).resolve()),
                          "native_contract_passed": report["native_contract_passed"]}, sort_keys=True))
        # Preserve diagnostic JSON and fail explicitly if a real native positive/negative contract fails.
        contracts = report["native_contract_passed"]
        return 1 if contracts is False or (isinstance(contracts, dict) and False in contracts.values()) else 0
    except (ValueError, FileExistsError, OSError) as error:
        parser.exit(2, str(error) + "\n")


if __name__ == "__main__":
    sys.exit(main())
