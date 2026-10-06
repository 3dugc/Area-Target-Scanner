"""Camera projection must follow each actual image's calibration after resizing."""
import numpy as np
import pytest
from PIL import Image
from processing_pipeline.uv_unwrap import render_texture_atlas, _vectorized_assign_frames


def _pose(x=0):
    pose = np.eye(4)
    pose[0, 3] = x
    return pose.flatten(order="F").tolist()


def _intrinsics(width, height):
    return dict(fx=width / 2, fy=width / 2, cx=width / 2, cy=height / 2, width=width, height=height)


def _legacy_assign_frames(centers, normals, pose_matrices, intrinsics):
    """Frozen dense calculation, independent of production's bounded traversal."""
    camera_positions = np.asarray([pose[:3, 3] for pose in pose_matrices], dtype=np.float64)
    camera_vectors = camera_positions[None, :, :] - centers[:, None, :]
    squared_distances = np.sum(camera_vectors ** 2, axis=2)
    distances = np.sqrt(squared_distances)
    directions = camera_vectors / np.where(distances > 1e-10, distances, 1.0)[:, :, None]
    facing = np.sum(normals[:, None, :] * directions, axis=2)
    scores = np.where(facing > 0, facing / np.maximum(squared_distances, 1e-20), -1.0)
    homogeneous_centers = np.hstack([centers, np.ones((len(centers), 1), dtype=np.float64)])
    calibration_list = [intrinsics] * len(pose_matrices) if isinstance(intrinsics, dict) else intrinsics
    for index, pose in enumerate(pose_matrices):
        calibration = calibration_list[index]
        camera_points = (np.linalg.inv(pose) @ homogeneous_centers.T).T
        behind = camera_points[:, 2] >= 0
        depth = np.where(behind, 1.0, -camera_points[:, 2])
        x = calibration["fx"] * (camera_points[:, 0] / depth) + calibration["cx"]
        y = calibration["fy"] * (-camera_points[:, 1] / depth) + calibration["cy"]
        invisible = (behind | (x < 0) | (x >= calibration["width"])
                     | (y < 0) | (y >= calibration["height"]))
        scores[invisible, index] = -1.0
    assignments = np.argmax(scores, axis=1).astype(np.int32)
    assignments[scores[np.arange(len(centers)), assignments] <= 0] = -1
    return assignments


@pytest.mark.parametrize("dtype", [np.float32, np.float64])
def test_assignment_matches_frozen_reference_at_ties_bounds_and_invisible_faces(dtype):
    # Exact x/y boundaries, behind-camera and degenerate/facing-away normals.
    centers = np.array([[-.5, 0, -1], [.5, 0, -1], [0, .5, -1], [0, -.5, -1],
                        [0, 0, 1], [0, 0, -1], [0, 0, -1], [0, 0, 0],
                        [100, 0, -1]], dtype=dtype)
    normals = np.tile([0, 0, 1], (len(centers), 1)).astype(dtype)
    normals[5] = 0
    normals[6] = [0, 0, -1]
    cameras = [np.eye(4), np.eye(4), np.eye(4)]
    calibrations = [dict(fx=20, fy=20, cx=10, cy=10, width=20, height=20),
                    dict(fx=10, fy=10, cx=10, cy=10, width=40, height=20),
                    dict(fx=10, fy=10, cx=10, cy=10, width=40, height=20)]
    expected = _legacy_assign_frames(centers, normals, cameras, calibrations)
    # First frame wins equal scores; right/bottom edges are exclusive.
    np.testing.assert_array_equal(expected, [0, 1, 0, 1, -1, -1, -1, -1, -1])
    actual = _vectorized_assign_frames(centers, normals, cameras, calibrations)
    assert actual.dtype == np.int32
    np.testing.assert_array_equal(actual, expected)


def test_assignment_matches_frozen_reference_with_rotated_cameras_and_shared_intrinsics():
    random = np.random.default_rng(311)
    centers = random.uniform(-3, 3, (87, 3)).astype(np.float32)
    normals = random.normal(size=centers.shape).astype(np.float32)
    normals /= np.linalg.norm(normals, axis=1, keepdims=True)
    cameras = []
    for index in range(9):
        angle = index * .27
        pose = np.eye(4)
        pose[:3, :3] = [[np.cos(angle), 0, np.sin(angle)], [0, 1, 0],
                       [-np.sin(angle), 0, np.cos(angle)]]
        pose[:3, 3] = random.uniform(-1, 1, 3)
        cameras.append(pose)
    intrinsics = _intrinsics(81, 53)
    expected = _legacy_assign_frames(centers, normals, cameras, intrinsics)
    np.testing.assert_array_equal(_vectorized_assign_frames(centers, normals, cameras, intrinsics), expected)


@pytest.mark.parametrize("frame_count", [100, 500])
def test_hundred_and_five_hundred_distinct_views_match_dense_reference(frame_count):
    # Every camera has a distinct face, with alternating resized calibrations.
    centers = np.column_stack([np.arange(frame_count) * 4., np.zeros(frame_count),
                               -np.ones(frame_count)])
    normals = np.tile([0., 0., 1.], (frame_count, 1))
    cameras, calibrations = [], []
    for index in range(frame_count):
        pose = np.eye(4)
        pose[0, 3] = index * 4.
        cameras.append(pose)
        calibrations.append(_intrinsics(64, 48) if index % 2 else _intrinsics(32, 24))
    expected = _legacy_assign_frames(centers, normals, cameras, calibrations)
    np.testing.assert_array_equal(expected, np.arange(frame_count))
    np.testing.assert_array_equal(_vectorized_assign_frames(centers, normals, cameras, calibrations), expected)


def test_assignment_rejects_mismatched_per_frame_calibration_count():
    with pytest.raises(ValueError, match="calibration count"):
        _vectorized_assign_frames(np.array([[0., 0., -1.]]), np.array([[0., 0., 1.]]),
                                  [np.eye(4)], [])


def test_frame_assignment_uses_each_frame_intrinsics_and_bounds():
    centers = np.array([[-.5, 0, -1], [.5, 0, -1]])
    normals = np.array([[0, 0, 1], [0, 0, 1]])
    cameras = [np.eye(4), np.eye(4)]
    calibration = [dict(fx=20, fy=20, cx=10, cy=10, width=20, height=20),
                   dict(fx=10, fy=10, cx=10, cy=10, width=40, height=20)]
    np.testing.assert_array_equal(_vectorized_assign_frames(centers, normals, cameras, calibration), [0, 1])


def test_mixed_image_dimensions_use_selected_frame_calibration_for_sampling(tmp_path):
    Image.new("RGB", (64, 32), (255, 0, 0)).save(tmp_path / "left.png")
    Image.new("RGB", (32, 16), (0, 0, 255)).save(tmp_path / "right.png")
    vertices = np.array([[-2.5, -.5, -2], [-1.5, -.5, -2], [-2.5, .5, -2],
                         [1.5, -.5, -2], [2.5, -.5, -2], [1.5, .5, -2]])
    uvs = np.array([[.05, .05], [.45, .05], [.05, .95], [.55, .05], [.95, .05], [.55, .95]])
    frames = [dict(imageFile="left.png", transform=_pose(-2), intrinsics=_intrinsics(64, 32)),
              dict(imageFile="right.png", transform=_pose(2), intrinsics=_intrinsics(32, 16))]
    atlas = render_texture_atlas(vertices, uvs, np.array([[0, 1, 2], [3, 4, 5]]), str(tmp_path),
                                 _intrinsics(64, 32), {"frames": frames}, atlas_size=32)
    np.testing.assert_array_equal(atlas[4, 4], [255, 0, 0])
    np.testing.assert_array_equal(atlas[4, 22], [0, 0, 255])


def test_resize_and_scaled_intrinsics_preserve_projection_and_legacy_fallback(tmp_path):
    yy, xx = np.mgrid[:32, :64]
    pixels = np.stack([xx * 3, yy * 5, np.full_like(xx, 67)], axis=2).astype(np.uint8)
    Image.fromarray(pixels).save(tmp_path / "full.png")
    Image.fromarray(pixels[::2, ::2]).save(tmp_path / "half.png")
    vertices = np.array([[-.5, -.25, -2], [.5, -.25, -2], [0, .25, -2]])
    uvs = np.array([[0, 0], [1, 0], [.5, 1]])
    faces = np.array([[0, 1, 2]])
    shared = _intrinsics(64, 32)
    def render(name, per_frame=None):
        frame = dict(imageFile=name, transform=_pose())
        if per_frame is not None:
            frame["intrinsics"] = per_frame
        return render_texture_atlas(vertices, uvs, faces, str(tmp_path), shared,
                                    {"frames": [frame]}, atlas_size=32)
    original = render("full.png", shared)
    np.testing.assert_array_equal(render("full.png"), original)
    resized = render("half.png", _intrinsics(32, 16))
    # Nearest-neighbor 2x resize introduces at most one original pixel of rounding.
    assert np.max(np.abs(original.astype(int) - resized.astype(int))) <= 5
