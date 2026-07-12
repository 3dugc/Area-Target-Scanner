"""
Integration tests for the native visual localizer library (libvisual_localizer.dylib).
Tests the C API via ctypes to verify correctness without Unity.
"""
import ctypes
import os
import numpy as np
import cv2
import pytest

# --- Load the native library ---
DYLIB_PATH = os.path.join(
    os.path.dirname(__file__), "..",
    "native_visual_localizer", "build", "libvisual_localizer.dylib"
)

if not os.path.exists(DYLIB_PATH):
    pytest.skip("libvisual_localizer.dylib not built", allow_module_level=True)

lib = ctypes.CDLL(DYLIB_PATH)


# --- C struct and function signatures ---
class VLResult(ctypes.Structure):
    _fields_ = [
        ("state", ctypes.c_int),
        ("pose", ctypes.c_float * 16),
        ("confidence", ctypes.c_float),
        ("matched_features", ctypes.c_int),
    ]

lib.vl_create.restype = ctypes.c_void_p
lib.vl_create.argtypes = []

lib.vl_destroy.restype = None
lib.vl_destroy.argtypes = [ctypes.c_void_p]

lib.vl_add_vocabulary_word.restype = ctypes.c_int
lib.vl_add_vocabulary_word.argtypes = [
    ctypes.c_void_p, ctypes.c_int,
    ctypes.POINTER(ctypes.c_float), ctypes.c_int, ctypes.c_float
]

lib.vl_add_keyframe.restype = ctypes.c_int
lib.vl_add_keyframe.argtypes = [
    ctypes.c_void_p, ctypes.c_int,
    ctypes.POINTER(ctypes.c_float),
    ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int,
    ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float)
]

lib.vl_build_index.restype = ctypes.c_int
lib.vl_build_index.argtypes = [ctypes.c_void_p]

lib.vl_process_frame.restype = VLResult
lib.vl_process_frame.argtypes = [
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int, ctypes.c_int,
    ctypes.c_float, ctypes.c_float, ctypes.c_float, ctypes.c_float,
    ctypes.c_int, ctypes.POINTER(ctypes.c_float)
]

lib.vl_reset.restype = None
lib.vl_reset.argtypes = [ctypes.c_void_p]


# =====================================================================
# Test 1: Handle lifecycle — create/destroy without crash
# =====================================================================
class TestHandleLifecycle:
    def test_create_returns_non_null(self):
        handle = lib.vl_create()
        assert handle is not None and handle != 0
        lib.vl_destroy(handle)

    def test_destroy_null_is_safe(self):
        """vl_destroy(NULL) should be a no-op, not crash."""
        lib.vl_destroy(None)

    def test_multiple_create_destroy(self):
        """Multiple handles can coexist."""
        h1 = lib.vl_create()
        h2 = lib.vl_create()
        assert h1 != h2
        lib.vl_destroy(h1)
        lib.vl_destroy(h2)


# =====================================================================
# Test 2: NULL handle safety — all API functions handle NULL gracefully
# =====================================================================
class TestNullHandleSafety:
    def test_add_vocabulary_word_null(self):
        desc = (ctypes.c_float * 32)(*([0.0] * 32))
        ret = lib.vl_add_vocabulary_word(None, 0, desc, 32, 1.0)
        assert ret == 0

    def test_add_keyframe_null(self):
        pose = (ctypes.c_float * 16)(*([0.0] * 16))
        desc = (ctypes.c_ubyte * 32)(*([0] * 32))
        pts3d = (ctypes.c_float * 3)(*([0.0] * 3))
        pts2d = (ctypes.c_float * 2)(*([0.0] * 2))
        ret = lib.vl_add_keyframe(None, 0, pose, desc, 1, pts3d, pts2d)
        assert ret == 0

    def test_build_index_null(self):
        ret = lib.vl_build_index(None)
        assert ret == 0

    def test_process_frame_null(self):
        img = (ctypes.c_ubyte * 100)(*([128] * 100))
        result = lib.vl_process_frame(None, img, 10, 10, 500, 500, 5, 5, 0, None)
        assert result.state == 2  # LOST

    def test_reset_null(self):
        """vl_reset(NULL) should not crash."""
        lib.vl_reset(None)


# =====================================================================
# Test 3: LOST state consistency
# =====================================================================
class TestLostStateConsistency:
    def test_empty_image_returns_lost(self):
        handle = lib.vl_create()
        lib.vl_build_index(handle)
        # 1x1 black image — not enough features
        img = (ctypes.c_ubyte * 1)(0)
        result = lib.vl_process_frame(handle, img, 1, 1, 500, 500, 0.5, 0.5, 0, None)
        assert result.state == 2  # LOST
        assert result.confidence == 0.0
        assert result.matched_features == 0
        # Pose should be identity
        pose = list(result.pose)
        assert pose[0] == pytest.approx(1.0)
        assert pose[5] == pytest.approx(1.0)
        assert pose[10] == pytest.approx(1.0)
        assert pose[15] == pytest.approx(1.0)
        lib.vl_destroy(handle)

    def test_small_featureless_image_returns_lost(self):
        handle = lib.vl_create()
        lib.vl_build_index(handle)
        # 64x64 uniform gray — no features to extract
        img_data = bytes([128] * 64 * 64)
        img = (ctypes.c_ubyte * len(img_data))(*img_data)
        result = lib.vl_process_frame(handle, img, 64, 64, 500, 500, 32, 32, 0, None)
        assert result.state == 2  # LOST
        assert result.confidence == 0.0
        lib.vl_destroy(handle)


# =====================================================================
# Test 4: Data loading — vocabulary and keyframes
# =====================================================================
class TestDataLoading:
    def test_add_vocabulary_word_succeeds(self):
        handle = lib.vl_create()
        desc = (ctypes.c_float * 32)(*([1.0] * 32))
        ret = lib.vl_add_vocabulary_word(handle, 0, desc, 32, 1.5)
        assert ret == 1
        lib.vl_destroy(handle)

    def test_add_keyframe_succeeds(self):
        handle = lib.vl_create()
        pose = (ctypes.c_float * 16)(*[
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 5,
            0, 0, 0, 1
        ])
        desc = (ctypes.c_ubyte * 32)(*([42] * 32))
        pts3d = (ctypes.c_float * 3)(1.0, 2.0, 3.0)
        pts2d = (ctypes.c_float * 2)(100.0, 200.0)
        ret = lib.vl_add_keyframe(handle, 0, pose, desc, 1, pts3d, pts2d)
        assert ret == 1
        lib.vl_destroy(handle)

    def test_build_index_succeeds(self):
        handle = lib.vl_create()
        ret = lib.vl_build_index(handle)
        assert ret == 1
        lib.vl_destroy(handle)


# =====================================================================
# Test 5: VLResult struct layout — matches expected C layout
# =====================================================================
class TestVLResultLayout:
    def test_struct_size(self):
        """VLResult should be: int(4) + float[16](64) + float(4) + int(4) = 76 bytes."""
        assert ctypes.sizeof(VLResult) == 76

    def test_field_offsets(self):
        assert VLResult.state.offset == 0
        assert VLResult.pose.offset == 4
        assert VLResult.confidence.offset == 68
        assert VLResult.matched_features.offset == 72


# =====================================================================
# Test 6: End-to-end with synthetic data — ORB features on textured image
# =====================================================================
class TestEndToEnd:
    def _create_textured_image(self, width=640, height=480):
        """Create a grayscale image with enough texture for ORB to find features."""
        np.random.seed(42)
        img = np.random.randint(0, 256, (height, width), dtype=np.uint8)
        # Add some structure
        for i in range(0, height, 40):
            img[i:i+2, :] = 255
        for j in range(0, width, 40):
            img[:, j:j+2] = 0
        return img

    def _extract_orb_features(self, img, n_features=1000):
        """Extract ORB features using Python OpenCV (same params as native)."""
        orb = cv2.ORB_create(nfeatures=n_features)
        kps, descs = orb.detectAndCompute(img, None)
        return kps, descs

    def test_process_frame_with_loaded_keyframe(self):
        """
        Load a keyframe extracted from a synthetic image, then process
        the same image. Should get TRACKING or at least not crash.
        """
        handle = lib.vl_create()

        # Create textured image and extract features
        img = self._create_textured_image()
        kps, descs = self._extract_orb_features(img)

        if descs is None or len(kps) < 20:
            lib.vl_destroy(handle)
            pytest.skip("Not enough ORB features extracted")

        n_features = len(kps)

        # Add a dummy vocabulary (single word)
        vocab_desc = (ctypes.c_float * 32)(*([128.0] * 32))
        lib.vl_add_vocabulary_word(handle, 0, vocab_desc, 32, 1.0)

        # Prepare keyframe data
        pose_data = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 5,
            0, 0, 0, 1
        ]
        pose = (ctypes.c_float * 16)(*pose_data)

        # Flatten descriptors (each 32 bytes)
        flat_desc = descs.flatten().tobytes()
        desc_arr = (ctypes.c_ubyte * len(flat_desc))(*flat_desc)

        # 3D points — place them in front of camera
        pts3d_list = []
        for kp in kps:
            pts3d_list.extend([kp.pt[0] / 100.0, kp.pt[1] / 100.0, 5.0])
        pts3d = (ctypes.c_float * len(pts3d_list))(*pts3d_list)

        # 2D points
        pts2d_list = []
        for kp in kps:
            pts2d_list.extend([kp.pt[0], kp.pt[1]])
        pts2d = (ctypes.c_float * len(pts2d_list))(*pts2d_list)

        lib.vl_add_keyframe(handle, 0, pose, desc_arr, n_features, pts3d, pts2d)
        lib.vl_build_index(handle)

        # Process the same image
        img_flat = img.flatten().tobytes()
        img_arr = (ctypes.c_ubyte * len(img_flat))(*img_flat)

        fx, fy = 500.0, 500.0
        cx, cy = 320.0, 240.0

        result = lib.vl_process_frame(
            handle, img_arr, 640, 480,
            fx, fy, cx, cy,
            0, None
        )

        # The result should be valid (either TRACKING or LOST, but not crash)
        assert result.state in [0, 1, 2]
        assert 0.0 <= result.confidence <= 1.0
        assert result.matched_features >= 0

        # If TRACKING, verify pose validity
        if result.state == 1:
            pose_arr = list(result.pose)
            # Last row should be [0, 0, 0, 1]
            assert pose_arr[12] == pytest.approx(0.0, abs=0.01)
            assert pose_arr[13] == pytest.approx(0.0, abs=0.01)
            assert pose_arr[14] == pytest.approx(0.0, abs=0.01)
            assert pose_arr[15] == pytest.approx(1.0, abs=0.01)
            # Confidence should be > 0
            assert result.confidence > 0.0
            # Matched features >= 20 (MinInlierCount)
            assert result.matched_features >= 20

        lib.vl_destroy(handle)

    def test_process_frame_no_keyframes_returns_lost(self):
        """With no keyframes loaded, should always return LOST."""
        handle = lib.vl_create()
        lib.vl_build_index(handle)

        img = self._create_textured_image()
        img_flat = img.flatten().tobytes()
        img_arr = (ctypes.c_ubyte * len(img_flat))(*img_flat)

        result = lib.vl_process_frame(
            handle, img_arr, 640, 480,
            500, 500, 320, 240,
            0, None
        )
        assert result.state == 2  # LOST
        lib.vl_destroy(handle)

    def test_reset_clears_state(self):
        """After reset, behavior should be same as fresh handle."""
        handle = lib.vl_create()
        lib.vl_build_index(handle)
        lib.vl_reset(handle)

        img = self._create_textured_image(64, 64)
        img_flat = img.flatten().tobytes()
        img_arr = (ctypes.c_ubyte * len(img_flat))(*img_flat)

        result = lib.vl_process_frame(
            handle, img_arr, 64, 64,
            500, 500, 32, 32,
            0, None
        )
        assert result.state == 2  # LOST (no keyframes)
        lib.vl_destroy(handle)
