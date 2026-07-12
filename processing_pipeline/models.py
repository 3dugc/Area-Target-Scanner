"""Core data models for the processing pipeline."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, List, Optional

import numpy as np
from numpy.typing import NDArray


@dataclass
class ProcessedCloud:
    """Preprocessed point cloud with normals and colors.

    Attributes:
        points: (N, 3) array of 3D point coordinates.
        normals: (N, 3) array of unit normal vectors.
        colors: (N, 3) array of RGB values in [0, 1].
        point_count: Number of points in the cloud.
    """

    points: NDArray[np.float64]
    normals: NDArray[np.float64]
    colors: NDArray[np.float64]
    point_count: int


@dataclass
class CameraPose:
    """Camera pose for a captured frame.

    Attributes:
        timestamp: Capture timestamp in seconds.
        transform: 4x4 camera-to-world transformation matrix.
        image_filename: Filename of the corresponding RGB image.
    """

    timestamp: float
    transform: NDArray[np.float64]  # (4, 4)
    image_filename: str


@dataclass
class CameraIntrinsics:
    """Camera intrinsic parameters.

    Attributes:
        fx: Focal length in x (pixels).
        fy: Focal length in y (pixels).
        cx: Principal point x (pixels).
        cy: Principal point y (pixels).
        width: Image width in pixels.
        height: Image height in pixels.
    """

    fx: float
    fy: float
    cx: float
    cy: float
    width: int
    height: int


@dataclass
class FramePose:
    """Single frame pose from poses.json.

    Attributes:
        index: Frame index.
        timestamp: Capture timestamp in seconds.
        image_file: Relative path to the image file (e.g. "images/frame_0000.jpg").
        transform: 16-element array storing a 4x4 matrix in column-major order.
    """

    index: int
    timestamp: float
    image_file: str
    transform: NDArray[np.float64]  # (16,) column-major


@dataclass
class KeyframeData:
    """Feature data for a single keyframe.

    Attributes:
        image_id: Unique keyframe identifier.
        keypoints: List of 2D keypoint tuples (x, y).
        descriptors: (M, 32) array of ORB descriptors (uint8).
        points_3d: List of 3D points corresponding to each keypoint.
        camera_pose: 4x4 camera-to-world transformation matrix.
        akaze_descriptors: (M, 61) AKAZE 描述子 (uint8)，可选。
        akaze_keypoints: AKAZE 2D 关键点列表 (x, y)，可选。
        akaze_points_3d: AKAZE 对应的 3D 点列表 (x, y, z)，可选。
    """

    image_id: int
    keypoints: List[tuple[float, float]]
    descriptors: NDArray[np.uint8]
    points_3d: List[tuple[float, float, float]]
    camera_pose: NDArray[np.float64]  # (4, 4)
    akaze_descriptors: Optional[NDArray[np.uint8]] = None
    akaze_keypoints: Optional[List[tuple[float, float]]] = None
    akaze_points_3d: Optional[List[tuple[float, float, float]]] = None


@dataclass
class FeatureDatabase:
    """Visual feature database for AR localization.

    Attributes:
        keyframes: List of keyframe feature data.
        global_descriptors: (K, D) array of global BoW descriptors per keyframe.
        vocabulary: Trained Bag-of-Words vocabulary (k-means cluster centers).
    """

    keyframes: List[KeyframeData] = field(default_factory=list)
    global_descriptors: Optional[NDArray[np.float64]] = None
    vocabulary: Optional[Any] = None  # sklearn KMeans or similar


@dataclass
class TexturedMesh:
    """Mesh with associated texture and material files.

    Attributes:
        mesh: Open3D TriangleMesh object.
        texture_file: Path to the texture atlas PNG file.
        material_file: Path to the MTL material file.
        quality_score: Texture quality score in [0, 1]. None if not evaluated.
    """

    mesh: Any  # open3d.geometry.TriangleMesh
    texture_file: str
    material_file: str
    quality_score: Optional[float] = None


@dataclass
class BoundingBox:
    """Axis-aligned bounding box.

    Attributes:
        min_point: (3,) array for the minimum corner.
        max_point: (3,) array for the maximum corner.
    """

    min_point: NDArray[np.float64]  # (3,)
    max_point: NDArray[np.float64]  # (3,)


@dataclass
class AssetManifest:
    """Manifest describing an Area Target asset bundle.

    Attributes:
        version: Asset format version string.
        name: Human-readable asset name.
        mesh_file: Filename of the OBJ mesh.
        texture_file: Filename of the texture atlas PNG.
        feature_db_file: Filename of the SQLite feature database.
        bounds: Scene bounding box.
        keyframe_count: Number of keyframes in the feature database.
        feature_type: Feature descriptor type (e.g. "ORB").
        created_at: ISO 8601 creation timestamp.
    """

    version: str
    name: str
    mesh_file: str
    texture_file: str
    feature_db_file: str
    bounds: BoundingBox
    keyframe_count: int
    feature_type: str
    created_at: str

@dataclass
class ScanInput:
    """Validated scan input data from an iOS scan ZIP.

    Contains paths to the textured model files (model.obj + texture.jpg + model.mtl),
    a list of image frames with their 4x4 pose matrices, and optional camera intrinsics.

    Attributes:
        obj_path: Path to the OBJ mesh file.
        texture_path: Path to the texture image file.
        mtl_path: Path to the MTL material file.
        images: List of dicts, each with "path" (str) and "pose" (np.ndarray shape (4,4)).
        intrinsics: Camera intrinsic parameters dict, or None if not available.
    """

    obj_path: str
    texture_path: str
    mtl_path: str
    images: List[dict]  # [{"path": str, "pose": NDArray (4,4)}]
    intrinsics: Optional[dict]

