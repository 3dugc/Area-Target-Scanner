"""Property-based tests for the optimized pipeline.

This file accumulates all property tests for the pipeline-optimization spec.
"""

from __future__ import annotations

import json
import os
import tempfile
from unittest.mock import MagicMock, patch

import numpy as np

from hypothesis import given, settings
from hypothesis import strategies as st

from processing_pipeline.optimizer_client import ModelOptimizerClient
from processing_pipeline.optimized_pipeline import OptimizedPipeline


# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------

NON_TERMINAL_STATUSES = ["pending", "processing"]
TERMINAL_STATUSES = ["completed", "failed"]


@st.composite
def status_sequence(draw):
    """Generate a list of non-terminal statuses followed by exactly one terminal status.

    The sequence always ends with a single terminal status ("completed" or
    "failed"), preceded by zero or more non-terminal statuses drawn from
    "pending" and "processing".
    """
    non_terminal = draw(
        st.lists(
            st.sampled_from(NON_TERMINAL_STATUSES),
            min_size=0,
            max_size=20,
        )
    )
    terminal = draw(st.sampled_from(TERMINAL_STATUSES))
    return non_terminal + [terminal]


# ---------------------------------------------------------------------------
# Property 4: 轮询终止性
# ---------------------------------------------------------------------------


class TestPollingTermination:
    """Property 4: 轮询终止性

    *For any* 状态响应序列，当序列中出现 "completed" 或 "failed" 状态时，
    wait_for_completion 应立即终止轮询并返回该终止状态。

    **Validates: Requirements 2.6**
    """

    @given(seq=status_sequence())
    @settings(max_examples=100)
    @patch("processing_pipeline.optimizer_client.time.sleep")
    def test_p4_polling_terminates_on_terminal_status(
        self, mock_sleep: MagicMock, seq: list[str]
    ):
        """wait_for_completion returns the terminal status and calls
        get_status exactly len(seq) times, sleeping len(seq)-1 times.

        **Validates: Requirements 2.6**
        """
        # Build mock responses for each status in the sequence
        mock_responses = [
            MagicMock(
                status_code=200,
                json=MagicMock(return_value={"status": s}),
                raise_for_status=MagicMock(),
            )
            for s in seq
        ]

        with patch(
            "processing_pipeline.optimizer_client.requests.get",
            side_effect=mock_responses,
        ) as mock_get:
            client = ModelOptimizerClient(
                base_url="http://localhost:3000", timeout=30
            )
            result = client.wait_for_completion("test-task", poll_interval=0.0)

            # The terminal status is the last element in the sequence
            expected_terminal = seq[-1]
            assert result == expected_terminal

            # get_status called exactly once per status in the sequence
            assert mock_get.call_count == len(seq)

            # sleep called between non-terminal polls (no sleep after terminal)
            assert mock_sleep.call_count == len(seq) - 1


# ---------------------------------------------------------------------------
# Strategies for Property 1
# ---------------------------------------------------------------------------

REQUIRED_FILES = ["model.obj", "texture.jpg", "model.mtl", "poses.json"]


@st.composite
def file_subset(draw):
    """Generate a subset of the 4 required scan files to include in a temp directory."""
    return draw(
        st.sets(st.sampled_from(REQUIRED_FILES), min_size=0, max_size=4)
    )


# ---------------------------------------------------------------------------
# Property 1: 输入验证完整性
# ---------------------------------------------------------------------------


class TestInputValidationCompleteness:
    """Property 1: 输入验证完整性

    *For any* scan 目录，validate_input 成功当且仅当 model.obj、texture.jpg、
    model.mtl、poses.json 四个必需文件全部存在；成功时返回的 ScanInput 中所有
    文件路径指向存在的文件；缺少任何一个必需文件时抛出 FileNotFoundError。

    **Validates: Requirements 1.1, 1.2, 1.6**
    """

    VALID_POSES_JSON = json.dumps(
        {
            "frames": [
                {
                    "imageFile": "images/frame_0000.jpg",
                    "transform": [
                        1, 0, 0, 0,
                        0, 1, 0, 0,
                        0, 0, 1, 0,
                        0, 0, 0, 1,
                    ],
                }
            ]
        }
    )

    @given(present_files=file_subset())
    @settings(max_examples=100)
    def test_p1_validate_input_iff_all_required_files_present(
        self, present_files: set[str]
    ):
        """validate_input succeeds iff all 4 required files exist.

        When successful, every file path in the returned ScanInput points to
        an existing file.  When any required file is missing, FileNotFoundError
        is raised.

        **Validates: Requirements 1.1, 1.2, 1.6**
        """
        import tempfile

        pipeline = OptimizedPipeline()

        with tempfile.TemporaryDirectory() as scan_dir:
            # Create only the files in the drawn subset
            for fname in present_files:
                fpath = os.path.join(scan_dir, fname)
                if fname == "poses.json":
                    with open(fpath, "w") as f:
                        f.write(self.VALID_POSES_JSON)
                else:
                    with open(fpath, "w") as f:
                        f.write("dummy")

            all_present = present_files == set(REQUIRED_FILES)

            if all_present:
                result = pipeline.validate_input(scan_dir)
                # All file paths in ScanInput must point to existing files
                assert os.path.isfile(result.obj_path)
                assert os.path.isfile(result.texture_path)
                assert os.path.isfile(result.mtl_path)
            else:
                try:
                    pipeline.validate_input(scan_dir)
                    # Should not reach here
                    assert False, "Expected FileNotFoundError for missing files"
                except FileNotFoundError:
                    pass


# ---------------------------------------------------------------------------
# Strategies for Property 2
# ---------------------------------------------------------------------------

pose_float = st.floats(allow_nan=False, allow_infinity=False, min_value=-1e6, max_value=1e6)


@st.composite
def arkit_column_major_affine_transform(draw):
    """Generate a finite affine pose serialized in ARKit column-major layout."""
    matrix = np.eye(4, dtype=np.float64)
    matrix[:3, :] = np.asarray(
        draw(st.lists(pose_float, min_size=12, max_size=12)),
        dtype=np.float64,
    ).reshape((3, 4))
    return matrix.reshape(-1, order="F").tolist()


# ---------------------------------------------------------------------------
# Property 2: 位姿矩阵列主序解析
# ---------------------------------------------------------------------------


class TestPoseMatrixColumnMajor:
    """Property 2: 位姿矩阵列主序解析

    *For any* 有限仿射 4×4 矩阵，以 ARKit column-major 形式写入
    poses.json 的 transform 字段后，Pipeline 解析结果应等价于
    ``np.array(data).reshape(4, 4, order='F')``。

    **Validates: Requirements 1.3**
    """

    @given(data=arkit_column_major_affine_transform())
    @settings(max_examples=100)
    def test_p2_pose_matrix_column_major_reshape(self, data: list[float]):
        """validate_input parses the transform field using column-major order.

        **Validates: Requirements 1.3**
        """
        import numpy as np

        pipeline = OptimizedPipeline()

        with tempfile.TemporaryDirectory() as scan_dir:
            # Create required files
            for fname in ("model.obj", "texture.jpg", "model.mtl"):
                with open(os.path.join(scan_dir, fname), "w") as f:
                    f.write("dummy")

            # Create poses.json with the generated affine transform.
            poses = {
                "frames": [
                    {
                        "imageFile": "images/frame_0000.jpg",
                        "transform": data,
                    }
                ]
            }
            with open(os.path.join(scan_dir, "poses.json"), "w") as f:
                json.dump(poses, f)

            result = pipeline.validate_input(scan_dir)

            # The parsed pose should equal column-major reshape
            expected = np.array(data, dtype=np.float64).reshape(4, 4, order="F")
            np.testing.assert_array_equal(result.images[0]["pose"], expected)


# ---------------------------------------------------------------------------
# Strategies for Property 3
# ---------------------------------------------------------------------------

intrinsics_float = st.floats(min_value=1.0, max_value=1e4, allow_nan=False, allow_infinity=False)
intrinsics_int = st.integers(min_value=1, max_value=4096)


# ---------------------------------------------------------------------------
# Property 3: 相机内参可选性
# ---------------------------------------------------------------------------


class TestCameraIntrinsicsOptionality:
    """Property 3: 相机内参可选性

    *For any* 有效的 scan 目录，当 intrinsics.json 存在时 ScanInput.intrinsics
    应为非 None 的字典；当 intrinsics.json 不存在时 ScanInput.intrinsics 应为 None。

    **Validates: Requirements 1.5**
    """

    VALID_POSES_JSON = json.dumps(
        {
            "frames": [
                {
                    "imageFile": "images/frame_0000.jpg",
                    "transform": [
                        1, 0, 0, 0,
                        0, 1, 0, 0,
                        0, 0, 1, 0,
                        0, 0, 0, 1,
                    ],
                }
            ]
        }
    )

    @given(
        has_intrinsics=st.booleans(),
        fx=intrinsics_float,
        fy=intrinsics_float,
        cx=intrinsics_float,
        cy=intrinsics_float,
        width=intrinsics_int,
        height=intrinsics_int,
    )
    @settings(max_examples=100)
    def test_p3_intrinsics_present_iff_file_exists(
        self,
        has_intrinsics: bool,
        fx: float,
        fy: float,
        cx: float,
        cy: float,
        width: int,
        height: int,
    ):
        """When intrinsics.json exists, ScanInput.intrinsics is a non-None dict
        matching the file contents; when absent, ScanInput.intrinsics is None.

        **Validates: Requirements 1.5**
        """
        pipeline = OptimizedPipeline()

        with tempfile.TemporaryDirectory() as scan_dir:
            # Create the 4 required files
            for fname in ("model.obj", "texture.jpg", "model.mtl"):
                with open(os.path.join(scan_dir, fname), "w") as f:
                    f.write("dummy")

            with open(os.path.join(scan_dir, "poses.json"), "w") as f:
                f.write(self.VALID_POSES_JSON)

            # Optionally create intrinsics.json
            intrinsics_data = {
                "fx": fx,
                "fy": fy,
                "cx": cx,
                "cy": cy,
                "width": width,
                "height": height,
            }
            if has_intrinsics:
                with open(os.path.join(scan_dir, "intrinsics.json"), "w") as f:
                    json.dump(intrinsics_data, f)

            result = pipeline.validate_input(scan_dir)

            if has_intrinsics:
                assert result.intrinsics is not None
                assert isinstance(result.intrinsics, dict)
                assert result.intrinsics == intrinsics_data
            else:
                assert result.intrinsics is None


# ---------------------------------------------------------------------------
# Strategies for Property 5
# ---------------------------------------------------------------------------

mesh_count_strategy = st.integers(min_value=2, max_value=5)
box_extent = st.floats(min_value=0.1, max_value=10.0, allow_nan=False, allow_infinity=False)


# ---------------------------------------------------------------------------
# Property 5: 多 Mesh 合并
# ---------------------------------------------------------------------------


class TestMultiMeshMerge:
    """Property 5: 多 Mesh 合并

    *For any* 包含多个 mesh 的 GLB 文件（trimesh.Scene 类型），Pipeline 应将所有
    mesh 合并为单个 mesh，合并后的顶点数应等于所有子 mesh 顶点数之和。

    **Validates: Requirements 3.2**
    """

    @given(
        num_meshes=mesh_count_strategy,
        extents=st.lists(
            st.tuples(box_extent, box_extent, box_extent),
            min_size=5,
            max_size=5,
        ),
    )
    @settings(max_examples=50)
    def test_p5_multi_mesh_merge_preserves_total_vertex_count(
        self,
        num_meshes: int,
        extents: list[tuple[float, float, float]],
    ):
        """When a GLB contains multiple meshes (trimesh.Scene), merging via
        scene.to_geometry() produces a single mesh whose vertex count
        equals the sum of all sub-mesh vertex counts.

        **Validates: Requirements 3.2**
        """
        import trimesh

        # Create individual meshes with random extents
        meshes = []
        for i in range(num_meshes):
            ext = extents[i]
            box = trimesh.creation.box(extents=[ext[0], ext[1], ext[2]])
            meshes.append(box)

        expected_total_vertices = sum(len(m.vertices) for m in meshes)

        # Build a Scene from the meshes
        scene = trimesh.Scene()
        for i, m in enumerate(meshes):
            scene.add_geometry(m, node_name=f"mesh_{i}")

        # Export to GLB and reload (round-trip through file format)
        with tempfile.TemporaryDirectory() as td:
            glb_path = os.path.join(td, "multi_mesh.glb")
            scene.export(glb_path, file_type="glb")

            # Load using the same logic as build_feature_database
            loaded = trimesh.load(glb_path)
            assert isinstance(loaded, trimesh.Scene), (
                f"Expected trimesh.Scene for multi-mesh GLB, got {type(loaded).__name__}"
            )

            # Sum vertex counts from individual geometries in the loaded scene
            loaded_geoms = list(loaded.geometry.values())
            loaded_total = sum(len(g.vertices) for g in loaded_geoms)

            # Merge all meshes (same logic as pipeline)
            merged = loaded.to_geometry()

            # Merged mesh should be a single Trimesh
            assert isinstance(merged, trimesh.Trimesh), (
                f"Expected trimesh.Trimesh after merge, got {type(merged).__name__}"
            )

            # Vertex count of merged mesh equals sum of sub-mesh vertex counts
            assert len(merged.vertices) == loaded_total
            assert len(merged.vertices) == expected_total_vertices


# ---------------------------------------------------------------------------
# Strategies for Property 6
# ---------------------------------------------------------------------------

num_images_strategy = st.integers(min_value=1, max_value=3)


# ---------------------------------------------------------------------------
# Property 6: 特征数据库非空
# ---------------------------------------------------------------------------


class TestFeatureDatabaseNonEmpty:
    """Property 6: 特征数据库非空

    *For any* 有效的 GLB 文件和非空的关键帧图像列表，build_feature_database 返回的
    FeatureDatabase 应包含至少 1 个 keyframe。

    **Validates: Requirements 3.3**
    """

    @staticmethod
    def _create_checkerboard_image(
        width: int, height: int, square_size: int = 20
    ) -> np.ndarray:
        """Create a checkerboard pattern image that produces many ORB features."""
        img = np.zeros((height, width), dtype=np.uint8)
        for y in range(height):
            for x in range(width):
                if ((x // square_size) + (y // square_size)) % 2 == 0:
                    img[y, x] = 255
        # Convert to 3-channel for JPEG saving
        return np.stack([img, img, img], axis=-1)

    @given(num_images=num_images_strategy)
    @settings(max_examples=3, deadline=None)
    def test_p6_feature_database_non_empty(self, num_images: int):
        """build_feature_database returns a FeatureDatabase with >= 1 keyframe
        when given a valid GLB mesh and checkerboard images with strong features.

        **Validates: Requirements 3.3**
        """
        import cv2
        import trimesh

        pipeline = OptimizedPipeline()

        with tempfile.TemporaryDirectory() as td:
            # 1. Create a large sphere mesh at origin (good for ray-casting)
            sphere = trimesh.creation.icosphere(subdivisions=3, radius=2.0)
            glb_path = os.path.join(td, "test_mesh.glb")
            sphere.export(glb_path, file_type="glb")

            # 2. Create checkerboard images (strong ORB features)
            images = []
            width, height = 640, 480
            for i in range(num_images):
                img = self._create_checkerboard_image(width, height, square_size=20)
                img_path = os.path.join(td, f"frame_{i:04d}.jpg")
                cv2.imwrite(img_path, img)

                # Camera at (0, 0, 5) looking toward origin (along -Z)
                # Identity rotation with translation along +Z
                pose = np.eye(4, dtype=np.float64)
                pose[2, 3] = 5.0  # camera 5 units away from origin
                images.append({"path": img_path, "pose": pose})

            # 3. Set reasonable intrinsics
            intrinsics = {
                "fx": 500.0,
                "fy": 500.0,
                "cx": 320.0,
                "cy": 240.0,
                "width": 640,
                "height": 480,
            }

            # 4. Load mesh and call build_feature_database
            scene = trimesh.load(glb_path)
            if isinstance(scene, trimesh.Scene):
                mesh_tri = scene.to_geometry()
            else:
                mesh_tri = scene
            features = pipeline.build_feature_database(
                mesh_tri, images, intrinsics
            )

            # 5. Assert non-empty FeatureDatabase
            assert hasattr(features, "keyframes")
            assert len(features.keyframes) >= 1, (
                f"Expected at least 1 keyframe but got {len(features.keyframes)}"
            )


# ---------------------------------------------------------------------------
# Strategies for Property 7
# ---------------------------------------------------------------------------

num_keyframes_strategy = st.integers(min_value=0, max_value=5)


# ---------------------------------------------------------------------------
# Helper for Property 7
# ---------------------------------------------------------------------------

from processing_pipeline.models import KeyframeData, FeatureDatabase, ScanInput


def _make_feature_database(n_keyframes: int) -> FeatureDatabase:
    """Create a synthetic FeatureDatabase with *n_keyframes* keyframes."""
    keyframes = []
    for i in range(n_keyframes):
        kf = KeyframeData(
            image_id=i,
            keypoints=[(float(x), float(x)) for x in range(25)],
            descriptors=np.random.randint(0, 256, (25, 32), dtype=np.uint8),
            points_3d=[(0.0, 0.0, 0.0)] * 25,
            camera_pose=np.eye(4),
        )
        keyframes.append(kf)
    return FeatureDatabase(keyframes=keyframes)


# ---------------------------------------------------------------------------
# Property 7: 资产包文件完整性
# ---------------------------------------------------------------------------


class TestAssetBundleFileCompleteness:
    """Property 7: 资产包文件完整性

    *For any* 有效的 GLB 文件和 FeatureDatabase，export_asset_bundle 执行后
    输出目录应恰好包含 optimized.glb、features.db 和 manifest.json 三个文件。

    **Validates: Requirements 4.1**
    """

    EXPECTED_FILES = {"optimized.glb", "features.db", "manifest.json"}

    @given(n_keyframes=num_keyframes_strategy)
    @settings(max_examples=20)
    def test_p7_asset_bundle_contains_exactly_three_files(
        self, n_keyframes: int
    ):
        """export_asset_bundle produces exactly optimized.glb, features.db,
        and manifest.json in the output directory, each with size > 0.

        **Validates: Requirements 4.1**
        """
        import trimesh

        pipeline = OptimizedPipeline()

        with tempfile.TemporaryDirectory() as td:
            # 1. Create a simple GLB mesh (trimesh box)
            box = trimesh.creation.box(extents=[1.0, 1.0, 1.0])
            glb_path = os.path.join(td, "source.glb")
            box.export(glb_path, file_type="glb")

            # 2. Create a synthetic FeatureDatabase
            features = _make_feature_database(n_keyframes)

            # 3. Load mesh and export asset bundle
            scene = trimesh.load(glb_path)
            mesh_tri = scene.to_geometry() if isinstance(scene, trimesh.Scene) else scene
            output_dir = os.path.join(td, "output")
            pipeline.export_asset_bundle(glb_path, mesh_tri, features, output_dir)

            # 4. Assert output directory contains exactly the 3 expected files
            actual_files = set(os.listdir(output_dir))
            assert actual_files == self.EXPECTED_FILES, (
                f"Expected {self.EXPECTED_FILES}, got {actual_files}"
            )

            # 5. Assert each file is non-empty (size > 0)
            for fname in self.EXPECTED_FILES:
                fpath = os.path.join(output_dir, fname)
                fsize = os.path.getsize(fpath)
                assert fsize > 0, f"{fname} is empty (size=0)"


# ---------------------------------------------------------------------------
# Property 8: GLB 复制保真性
# ---------------------------------------------------------------------------


class TestGLBCopyFidelity:
    """Property 8: GLB 复制保真性

    *For any* GLB 源文件，export_asset_bundle 复制到输出目录的 optimized.glb
    应与源文件字节完全一致。

    **Validates: Requirements 4.2**
    """

    @given(
        ext_x=box_extent,
        ext_y=box_extent,
        ext_z=box_extent,
    )
    @settings(max_examples=20)
    def test_p8_glb_copy_is_byte_identical_to_source(
        self,
        ext_x: float,
        ext_y: float,
        ext_z: float,
    ):
        """The optimized.glb produced by export_asset_bundle must be
        byte-for-byte identical to the source GLB file.

        **Validates: Requirements 4.2**
        """
        import trimesh

        pipeline = OptimizedPipeline()

        with tempfile.TemporaryDirectory() as td:
            # 1. Create a GLB from a box with random extents
            box = trimesh.creation.box(extents=[ext_x, ext_y, ext_z])
            glb_path = os.path.join(td, "source.glb")
            box.export(glb_path, file_type="glb")

            # 2. Read the raw source bytes
            with open(glb_path, "rb") as f:
                source_bytes = f.read()

            # 3. Create a minimal FeatureDatabase (empty keyframes is fine)
            features = _make_feature_database(0)

            # 4. Load mesh and call export_asset_bundle
            scene = trimesh.load(glb_path)
            mesh_tri = scene.to_geometry() if isinstance(scene, trimesh.Scene) else scene
            output_dir = os.path.join(td, "output")
            pipeline.export_asset_bundle(glb_path, mesh_tri, features, output_dir)

            # 5. Read the copied GLB bytes
            copied_path = os.path.join(output_dir, "optimized.glb")
            with open(copied_path, "rb") as f:
                copied_bytes = f.read()

            # 6. Assert byte-for-byte identity
            assert source_bytes == copied_bytes, (
                f"GLB copy mismatch: source {len(source_bytes)} bytes vs "
                f"copied {len(copied_bytes)} bytes"
            )


# ---------------------------------------------------------------------------
# Strategies for Property 9
# ---------------------------------------------------------------------------

from processing_pipeline.feature_db import save_feature_database, load_feature_database

kf_count_strategy = st.integers(min_value=1, max_value=5)
feat_count_strategy = st.integers(min_value=20, max_value=50)
kp_x_strategy = st.floats(min_value=0.0, max_value=640.0, allow_nan=False, allow_infinity=False)
kp_y_strategy = st.floats(min_value=0.0, max_value=480.0, allow_nan=False, allow_infinity=False)
pt3d_coord = st.floats(min_value=-100.0, max_value=100.0, allow_nan=False, allow_infinity=False)
translation_float = st.floats(min_value=-50.0, max_value=50.0, allow_nan=False, allow_infinity=False)


@st.composite
def random_keyframe(draw, kf_id: int):
    """Generate a random KeyframeData with realistic feature data."""
    n_features = draw(feat_count_strategy)

    keypoints = [
        (draw(kp_x_strategy), draw(kp_y_strategy))
        for _ in range(n_features)
    ]

    # Use st.binary for descriptors to avoid excessive entropy consumption
    desc_bytes = draw(st.binary(min_size=n_features * 32, max_size=n_features * 32))
    descriptors = np.frombuffer(desc_bytes, dtype=np.uint8).reshape(n_features, 32).copy()

    points_3d = [
        (draw(pt3d_coord), draw(pt3d_coord), draw(pt3d_coord))
        for _ in range(n_features)
    ]

    # Camera pose: identity rotation + random translation
    camera_pose = np.eye(4, dtype=np.float64)
    camera_pose[0, 3] = draw(translation_float)
    camera_pose[1, 3] = draw(translation_float)
    camera_pose[2, 3] = draw(translation_float)

    return KeyframeData(
        image_id=kf_id,
        keypoints=keypoints,
        descriptors=descriptors,
        points_3d=points_3d,
        camera_pose=camera_pose,
    )


@st.composite
def random_feature_database(draw):
    """Generate a random FeatureDatabase with 1-5 keyframes, no vocabulary."""
    n_keyframes = draw(kf_count_strategy)
    keyframes = []
    for i in range(n_keyframes):
        kf = draw(random_keyframe(kf_id=i))
        keyframes.append(kf)
    return FeatureDatabase(keyframes=keyframes, global_descriptors=None, vocabulary=None)


# ---------------------------------------------------------------------------
# Property 9: 特征数据库序列化往返
# ---------------------------------------------------------------------------


class TestFeatureDatabaseSerializationRoundTrip:
    """Property 9: 特征数据库序列化往返

    *For any* 有效的 FeatureDatabase，序列化为 SQLite（features.db）后再反序列化
    应得到等价的 FeatureDatabase 对象。

    **Validates: Requirements 4.3**
    """

    @given(db=random_feature_database())
    @settings(max_examples=20, deadline=None)
    def test_p9_feature_database_serialization_round_trip(self, db: FeatureDatabase):
        """save_feature_database followed by load_feature_database produces
        an equivalent FeatureDatabase: same keyframe count, image_ids,
        keypoints (within tolerance), descriptors (exact), 3D points
        (within tolerance), and camera poses (within tolerance).

        **Validates: Requirements 4.3**
        """
        with tempfile.TemporaryDirectory() as td:
            db_path = os.path.join(td, "features.db")

            # Save and reload
            save_feature_database(db, db_path)
            loaded = load_feature_database(db_path)

            # Same number of keyframes
            assert len(loaded.keyframes) == len(db.keyframes), (
                f"Keyframe count mismatch: expected {len(db.keyframes)}, "
                f"got {len(loaded.keyframes)}"
            )

            # Same image_ids
            original_ids = sorted(kf.image_id for kf in db.keyframes)
            loaded_ids = sorted(kf.image_id for kf in loaded.keyframes)
            assert original_ids == loaded_ids, (
                f"Image ID mismatch: expected {original_ids}, got {loaded_ids}"
            )

            # Compare each keyframe
            orig_by_id = {kf.image_id: kf for kf in db.keyframes}
            loaded_by_id = {kf.image_id: kf for kf in loaded.keyframes}

            for kf_id in original_ids:
                orig_kf = orig_by_id[kf_id]
                load_kf = loaded_by_id[kf_id]

                # Keypoints: within tolerance
                assert len(load_kf.keypoints) == len(orig_kf.keypoints), (
                    f"Keyframe {kf_id}: keypoint count mismatch"
                )
                for j, (orig_kp, load_kp) in enumerate(
                    zip(orig_kf.keypoints, load_kf.keypoints)
                ):
                    np.testing.assert_allclose(
                        orig_kp, load_kp, atol=1e-6,
                        err_msg=f"Keyframe {kf_id}, keypoint {j} mismatch",
                    )

                # Descriptors: exact match
                np.testing.assert_array_equal(
                    load_kf.descriptors, orig_kf.descriptors,
                    err_msg=f"Keyframe {kf_id}: descriptor mismatch",
                )

                # 3D points: within tolerance
                assert len(load_kf.points_3d) == len(orig_kf.points_3d), (
                    f"Keyframe {kf_id}: 3D point count mismatch"
                )
                for j, (orig_pt, load_pt) in enumerate(
                    zip(orig_kf.points_3d, load_kf.points_3d)
                ):
                    np.testing.assert_allclose(
                        orig_pt, load_pt, atol=1e-6,
                        err_msg=f"Keyframe {kf_id}, point_3d {j} mismatch",
                    )

                # Camera poses: within tolerance
                np.testing.assert_allclose(
                    load_kf.camera_pose, orig_kf.camera_pose, atol=1e-10,
                    err_msg=f"Keyframe {kf_id}: camera pose mismatch",
                )


# ---------------------------------------------------------------------------
# Property 10: Manifest 完整性与引用一致性
# ---------------------------------------------------------------------------


class TestManifestCompletenessAndReferenceConsistency:
    """Property 10: Manifest 完整性与引用一致性

    *For any* 生成的 manifest.json，应包含 version、meshFile、featureDbFile、
    bounds、keyframeCount、featureType、format、optimizedWith、createdAt 全部字段，
    且 meshFile 和 featureDbFile 引用的文件在输出目录中存在。

    **Validates: Requirements 4.4, 4.5**
    """

    REQUIRED_MANIFEST_FIELDS = {
        "version",
        "meshFile",
        "featureDbFile",
        "bounds",
        "keyframeCount",
        "featureType",
        "format",
        "optimizedWith",
        "createdAt",
    }

    @given(
        n_keyframes=st.integers(min_value=0, max_value=5),
        ext_x=box_extent,
        ext_y=box_extent,
        ext_z=box_extent,
    )
    @settings(max_examples=20)
    def test_p10_manifest_completeness_and_reference_consistency(
        self,
        n_keyframes: int,
        ext_x: float,
        ext_y: float,
        ext_z: float,
    ):
        """The generated manifest.json contains all required fields with correct
        values, and the files referenced by meshFile and featureDbFile exist in
        the output directory.

        **Validates: Requirements 4.4, 4.5**
        """
        import trimesh

        pipeline = OptimizedPipeline()

        with tempfile.TemporaryDirectory() as td:
            # 1. Create a GLB mesh (trimesh box with random extents)
            box = trimesh.creation.box(extents=[ext_x, ext_y, ext_z])
            glb_path = os.path.join(td, "source.glb")
            box.export(glb_path, file_type="glb")

            # 2. Create a FeatureDatabase with the generated keyframes
            features = _make_feature_database(n_keyframes)

            # 3. Load mesh and call export_asset_bundle
            scene = trimesh.load(glb_path)
            mesh_tri = scene.to_geometry() if isinstance(scene, trimesh.Scene) else scene
            output_dir = os.path.join(td, "output")
            pipeline.export_asset_bundle(glb_path, mesh_tri, features, output_dir)

            # 4. Load manifest.json
            manifest_path = os.path.join(output_dir, "manifest.json")
            assert os.path.isfile(manifest_path), "manifest.json not found"
            with open(manifest_path) as f:
                manifest = json.load(f)

            # 5. Assert all required fields exist
            actual_fields = set(manifest.keys())
            missing = self.REQUIRED_MANIFEST_FIELDS - actual_fields
            assert not missing, f"Missing manifest fields: {missing}"

            # 6. Assert meshFile reference exists in output_dir
            mesh_file_path = os.path.join(output_dir, manifest["meshFile"])
            assert os.path.isfile(mesh_file_path), (
                f"meshFile '{manifest['meshFile']}' not found in output dir"
            )

            # 7. Assert featureDbFile reference exists in output_dir
            db_file_path = os.path.join(output_dir, manifest["featureDbFile"])
            assert os.path.isfile(db_file_path), (
                f"featureDbFile '{manifest['featureDbFile']}' not found in output dir"
            )

            # 8. Assert keyframeCount matches the FeatureDatabase
            assert manifest["keyframeCount"] == n_keyframes, (
                f"keyframeCount mismatch: expected {n_keyframes}, "
                f"got {manifest['keyframeCount']}"
            )

            # 9. Assert fixed field values
            assert manifest["version"] == "2.0", (
                f"Expected version '2.0', got '{manifest['version']}'"
            )
            assert manifest["featureType"] == "ORB", (
                f"Expected featureType 'ORB', got '{manifest['featureType']}'"
            )
            assert manifest["format"] == "glb", (
                f"Expected format 'glb', got '{manifest['format']}'"
            )
            assert manifest["optimizedWith"] == "3D-Model-Optimizer", (
                f"Expected optimizedWith '3D-Model-Optimizer', "
                f"got '{manifest['optimizedWith']}'"
            )


# ---------------------------------------------------------------------------
# Property 11: Manifest 包围盒准确性
# ---------------------------------------------------------------------------


class TestManifestBoundsAccuracy:
    """Property 11: Manifest 包围盒准确性

    *For any* GLB mesh，manifest.json 中 bounds.min 和 bounds.max 应与该 mesh
    顶点计算得到的轴对齐包围盒（AABB）一致。

    **Validates: Requirements 4.6**
    """

    @given(
        ext_x=box_extent,
        ext_y=box_extent,
        ext_z=box_extent,
    )
    @settings(max_examples=20)
    def test_p11_manifest_bounds_match_mesh_aabb(
        self,
        ext_x: float,
        ext_y: float,
        ext_z: float,
    ):
        """The bounds.min and bounds.max in manifest.json must match the
        axis-aligned bounding box (AABB) computed from the GLB mesh vertices.

        **Validates: Requirements 4.6**
        """
        import trimesh

        pipeline = OptimizedPipeline()

        with tempfile.TemporaryDirectory() as td:
            # 1. Create a GLB mesh (trimesh box with random extents)
            box = trimesh.creation.box(extents=[ext_x, ext_y, ext_z])
            glb_path = os.path.join(td, "source.glb")
            box.export(glb_path, file_type="glb")

            # 2. Compute expected AABB from the mesh vertices
            mesh = trimesh.load(glb_path)
            if isinstance(mesh, trimesh.Scene):
                mesh = mesh.to_geometry()
            expected_min = mesh.bounds[0].tolist()
            expected_max = mesh.bounds[1].tolist()

            # 3. Create a minimal FeatureDatabase
            features = _make_feature_database(0)

            # 4. Call export_asset_bundle with mesh object
            output_dir = os.path.join(td, "output")
            pipeline.export_asset_bundle(glb_path, mesh, features, output_dir)

            # 5. Load manifest.json
            manifest_path = os.path.join(output_dir, "manifest.json")
            assert os.path.isfile(manifest_path), "manifest.json not found"
            with open(manifest_path) as f:
                manifest = json.load(f)

            # 6. Assert bounds.min matches expected AABB min
            assert "bounds" in manifest, "manifest missing 'bounds' field"
            manifest_min = manifest["bounds"]["min"]
            manifest_max = manifest["bounds"]["max"]

            np.testing.assert_allclose(
                manifest_min,
                expected_min,
                atol=1e-5,
                err_msg="bounds.min mismatch between manifest and mesh AABB",
            )

            # 7. Assert bounds.max matches expected AABB max
            np.testing.assert_allclose(
                manifest_max,
                expected_max,
                atol=1e-5,
                err_msg="bounds.max mismatch between manifest and mesh AABB",
            )


# ---------------------------------------------------------------------------
# Property 12: 管线故障传播
# ---------------------------------------------------------------------------


class TestPipelineFaultPropagation:
    """Property 12: 管线故障传播

    *For any* 管线步骤（输入验证、模型优化、特征提取、资产打包），当该步骤抛出异常时，
    后续步骤不应被执行，异常应向上传播。

    **Validates: Requirements 5.3**
    """

    # Ordered pipeline steps as called by run()
    STEPS = [
        "validate_input",       # Step 1 → returns ScanInput
        "optimize_model",       # Step 2 → returns str (glb_path)
        "build_feature_database",  # Step 3 → returns FeatureDatabase
        "export_asset_bundle",  # Step 4 → returns None
    ]

    # Mock return values for each step (used for steps BEFORE the failing one)
    STEP_RETURNS = {
        "validate_input": ScanInput(
            obj_path="/fake/model.obj",
            texture_path="/fake/texture.jpg",
            mtl_path="/fake/model.mtl",
            images=[],
            intrinsics=None,
        ),
        "optimize_model": "/fake/optimized.glb",
        "build_feature_database": FeatureDatabase(keyframes=[]),
        "export_asset_bundle": None,
    }

    @given(failing_step_idx=st.integers(min_value=0, max_value=3))
    @settings(max_examples=20)
    def test_p12_fault_propagation_stops_subsequent_steps(
        self, failing_step_idx: int
    ):
        """When step N raises RuntimeError, steps N+1..4 are never called
        and the RuntimeError propagates to the caller.

        **Validates: Requirements 5.3**
        """
        import trimesh

        pipeline = OptimizedPipeline()

        scan_dir = "/fake/scan"
        output_dir = "/fake/output"

        # Build a patch context for every step
        patches = {}
        mocks = {}
        for i, step_name in enumerate(self.STEPS):
            p = patch.object(OptimizedPipeline, step_name)
            mock_method = p.start()
            patches[step_name] = p
            mocks[step_name] = mock_method

            if i < failing_step_idx:
                # Steps before the failing step succeed with valid mock data
                mock_method.return_value = self.STEP_RETURNS[step_name]
            elif i == failing_step_idx:
                # The failing step raises RuntimeError
                mock_method.side_effect = RuntimeError(
                    f"Simulated failure in {step_name}"
                )
            # Steps after the failing step are left as default mocks
            # (we'll assert they were NOT called)

        # When the failing step is build_feature_database or export_asset_bundle
        # (index >= 2), run() calls trimesh.load(glb_path) between optimize_model
        # and build_feature_database. We need to mock trimesh.load so it doesn't
        # fail on the fake path returned by the mocked optimize_model.
        trimesh_patch = None
        if failing_step_idx >= 2:
            mock_mesh = trimesh.creation.box(extents=[1.0, 1.0, 1.0])
            trimesh_patch = patch(
                "trimesh.load",
                return_value=mock_mesh,
            )
            trimesh_patch.start()

        try:
            # run() should propagate the RuntimeError
            import pytest
            with pytest.raises(RuntimeError, match=f"Simulated failure in {self.STEPS[failing_step_idx]}"):
                pipeline.run(scan_dir, output_dir)

            # Steps AFTER the failing step must NOT have been called
            for j in range(failing_step_idx + 1, len(self.STEPS)):
                after_step = self.STEPS[j]
                assert not mocks[after_step].called, (
                    f"Step '{after_step}' (index {j}) should not have been "
                    f"called when step '{self.STEPS[failing_step_idx]}' "
                    f"(index {failing_step_idx}) raised an exception"
                )
        finally:
            # Stop all patches
            for p in patches.values():
                p.stop()
            if trimesh_patch is not None:
                trimesh_patch.stop()
