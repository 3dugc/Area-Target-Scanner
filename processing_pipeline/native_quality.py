"""FFI for the canonical C++ quality kernel; no Python quality algorithm.

Device runtimes include this kernel in their full shared core. The server builds
the same source module without the unrelated OpenCV/SQLite runtime dependencies.
Production containers prebuild it; local tools cache a source-keyed build.
"""
import ctypes as C
import fcntl
from functools import lru_cache
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile


class Frame(C.Structure):
    _fields_ = [("struct_size", C.c_uint32), ("api_version", C.c_uint32),
                *[(name, C.c_uint64) for name in ("frame_id", "capture_timestamp_ns", "map_generation",
                                                "capture_clock_epoch", "camera_id")],
                ("data", C.c_void_p), ("byte_length", C.c_uint64), ("row_stride", C.c_uint64),
                ("width", C.c_uint32), ("height", C.c_uint32), ("pixel_format", C.c_uint32),
                *[(name, C.c_float) for name in ("fx", "fy", "cx", "cy")]]


class GrayQuality(C.Structure):
    _fields_ = [*[(name, C.c_uint32) for name in ("struct_size", "api_version", "policy_version",
                                               "accepted", "rejection_reason")],
                *[(name, C.c_float) for name in ("laplacian_variance", "gray_standard_deviation",
                                              "mean_intensity", "saturated_fraction")],
                ("sample_count", C.c_uint64)]


class KeyframeCandidate(C.Structure):
    _fields_ = [*[(name, C.c_uint32) for name in ("struct_size", "api_version", "source_ordinal", "pose_valid")],
                ("laplacian_variance", C.c_float), ("quality_accepted", C.c_uint32),
                ("camera_to_world", C.c_float * 16)]


@lru_cache(maxsize=1)
def quality_library():
    explicit = os.environ.get("AREA_TARGET_QUALITY_LIBRARY")
    if explicit:
        path = Path(explicit)
    else:
        root = Path(__file__).resolve().parents[1]
        sources = [root / "native_visual_localizer/src/gray_quality.cpp",
                   root / "native_visual_localizer/src/frame_contract.cpp",
                   root / "native_visual_localizer/src/keyframe_selection.cpp"]
        inputs = [*sources, root / "native_visual_localizer/src/frame_contract.h",
                  root / "native_visual_localizer/src/rigid_math.h",
                  root / "native_visual_localizer/include/area_target_runtime.h"]
        key = hashlib.sha256(b"".join(p.read_bytes() for p in inputs)).hexdigest()[:24]
        cache = root / "build/native-quality" / key
        cache.mkdir(parents=True, exist_ok=True)
        path = cache / ("quality.dylib" if sys.platform == "darwin" else "quality.so")
        with (cache / "build.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if not path.is_file():
                with tempfile.TemporaryDirectory(dir=cache) as temporary:
                    output = Path(temporary) / path.name
                    command = [os.environ.get("CXX", "c++"), "-std=c++17", "-O2", "-shared", "-fPIC",
                               "-fvisibility=hidden", "-I", str(root / "native_visual_localizer/include"),
                               "-I", str(root / "native_visual_localizer/src"),
                               *map(str, sources), "-o", str(output)]
                    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                    (cache / "build.log").write_text(result.stdout)
                    if result.returncode:
                        raise RuntimeError("Shared C++ quality build failed: " + str(cache / "build.log"))
                    os.replace(output, path)
    library = C.CDLL(str(path))
    library.atc_assess_gray_quality.argtypes = [C.POINTER(Frame), C.POINTER(GrayQuality)]
    library.atc_assess_gray_quality.restype = C.c_int32
    library.atc_select_keyframes_v2.argtypes = [C.POINTER(KeyframeCandidate), C.c_uint32, C.c_uint32,
                                              C.c_uint32, C.POINTER(C.c_uint32), C.c_uint32,
                                              C.POINTER(C.c_uint32)]
    library.atc_select_keyframes_v2.restype = C.c_int32
    return library


def assess_gray(gray):
    import numpy as np
    if gray is None or gray.ndim != 2 or gray.dtype != np.uint8 or min(gray.shape) < 3:
        return None
    pixels = np.ascontiguousarray(gray)
    height, width = pixels.shape
    frame = Frame(struct_size=C.sizeof(Frame), api_version=2, data=pixels.ctypes.data,
                  byte_length=pixels.nbytes, row_stride=width, width=width, height=height,
                  pixel_format=1, fx=1, fy=1, cx=width / 2, cy=height / 2)
    quality = GrayQuality(struct_size=C.sizeof(GrayQuality), api_version=2, policy_version=1)
    status = quality_library().atc_assess_gray_quality(C.byref(frame), C.byref(quality))
    return quality if status == 0 else None


def select_ordinals(images, qualities, max_keyframes):
    """Marshal original ordinals and camera poses; all selection policy is C++."""
    import numpy as np
    count = len(images)
    candidates = (KeyframeCandidate * count)()
    for index, (info, quality) in enumerate(zip(images, qualities)):
        item = candidates[index]
        item.struct_size, item.api_version, item.source_ordinal = C.sizeof(KeyframeCandidate), 2, index
        item.laplacian_variance = quality.sharpness
        item.quality_accepted = int(quality.reason is None)
        try:
            pose = np.asarray(info.get("pose"), dtype=np.float32)
            if pose.shape == (4, 4):
                item.pose_valid = 1
                item.camera_to_world[:] = pose.reshape(-1)
        except (ValueError, TypeError, OverflowError):
            pass
    capacity = count if max_keyframes is None else min(count, max_keyframes)
    output = (C.c_uint32 * capacity)()
    selected_count = C.c_uint32()
    status = quality_library().atc_select_keyframes_v2(candidates, count, count, max_keyframes or 0,
                                                      output, capacity, C.byref(selected_count))
    if status != 0:
        raise ValueError(f"Shared C++ keyframe selection rejected input (status {status})")
    return list(output[:selected_count.value])
