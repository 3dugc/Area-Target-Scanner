"""Camera projection must follow each actual image's calibration after resizing."""
import numpy as np
from PIL import Image
from processing_pipeline.uv_unwrap import render_texture_atlas, _vectorized_assign_frames


def _pose(x=0):
    pose = np.eye(4)
    pose[0, 3] = x
    return pose.flatten(order="F").tolist()


def _intrinsics(width, height):
    return dict(fx=width / 2, fy=width / 2, cx=width / 2, cy=height / 2, width=width, height=height)


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
