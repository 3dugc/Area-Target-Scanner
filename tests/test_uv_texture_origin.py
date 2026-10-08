"""Exported OBJ/GLB colors must agree with an asymmetric ARKit camera image."""
import io
import json
import struct

import numpy as np
from PIL import Image
import pytest
import trimesh

from processing_pipeline import uv_unwrap as uv


def _camera_plane(tmp_path):
    expected = np.array([[240, 20, 20], [20, 240, 20],
                         [20, 20, 240], [240, 220, 20]], dtype=np.uint8)
    pixels = np.empty((128, 128, 3), dtype=np.uint8)
    pixels[:64, :64], pixels[:64, 64:] = expected[0], expected[1]
    pixels[64:, :64], pixels[64:, 64:] = expected[2], expected[3]
    Image.fromarray(pixels).save(tmp_path / "camera.png")
    vertices = np.array([[-.5, -.5, -1], [.5, -.5, -1],
                         [.5, .5, -1], [-.5, .5, -1]], dtype=np.float32)
    uvs = np.array([[.1, .1], [.9, .1], [.9, .9], [.1, .9]], dtype=np.float32)
    faces = np.array([[0, 1, 2], [0, 2, 3]], dtype=np.uint32)
    normals = np.tile([0., 0., 1.], (4, 1)).astype(np.float32)
    calibration = dict(fx=64, fy=64, cx=64, cy=64, width=128, height=128)
    poses = {"frames": [dict(imageFile="camera.png", intrinsics=calibration,
                             transform=np.eye(4).flatten(order="F").tolist())]}
    points = np.array([[-.25, .25, -1], [.25, .25, -1],
                       [-.25, -.25, -1], [.25, -.25, -1]])
    # Independent ground truth is the camera sample at each known world point:
    # px=fx*x/-z+cx, py=fy*-y/-z+cy for the identity ARKit camera.
    camera_x = (64 * points[:, 0] / -points[:, 2] + 64).astype(int)
    camera_y = (64 * -points[:, 1] / -points[:, 2] + 64).astype(int)
    np.testing.assert_array_equal(pixels[camera_y, camera_x], expected)
    return vertices, normals, uvs, faces, calibration, poses, points, expected


def _uv_at_world_points(vertices, faces, uvs, points):
    result = []
    for point in points:
        for face in faces:
            triangle = vertices[face]
            weights = np.linalg.lstsq(np.vstack([triangle.T, np.ones(3)]),
                                      np.r_[point, 1.], rcond=None)[0]
            if weights.min() >= -1e-6 and np.linalg.norm(weights @ triangle - point) < 1e-6:
                result.append(weights @ uvs[face])
                break
        else:
            raise AssertionError("Expected world point is absent from exported geometry")
    return np.asarray(result)


def _sample_exported_glb(mesh, points):
    data = mesh.export(file_type="glb")
    offset, document, binary = 12, None, None
    while offset < len(data):
        size, kind = struct.unpack_from("<I4s", data, offset)
        chunk = data[offset + 8:offset + 8 + size]
        if kind == b"JSON":
            document = json.loads(chunk)
        elif kind == b"BIN\x00":
            binary = chunk
        offset += 8 + size

    def accessor(index):
        entry = document["accessors"][index]
        view = document["bufferViews"][entry["bufferView"]]
        dtype = {5126: "<f4", 5125: "<u4", 5123: "<u2", 5121: "u1"}[entry["componentType"]]
        columns = {"SCALAR": 1, "VEC2": 2, "VEC3": 3}[entry["type"]]
        item_size = np.dtype(dtype).itemsize
        return np.ndarray((entry["count"], columns), dtype=dtype, buffer=binary,
                          offset=entry.get("byteOffset", 0) + view.get("byteOffset", 0),
                          strides=(view.get("byteStride", columns * item_size), item_size))

    primitive = document["meshes"][0]["primitives"][0]
    vertices = accessor(primitive["attributes"]["POSITION"])
    uvs = accessor(primitive["attributes"]["TEXCOORD_0"])
    faces = accessor(primitive["indices"]).reshape((-1, 3))
    sampled_uvs = _uv_at_world_points(vertices, faces, uvs, points)
    material = document["materials"][primitive["material"]]
    texture_index = material["pbrMetallicRoughness"]["baseColorTexture"]["index"]
    image_index = document["textures"][texture_index]["source"]
    view = document["bufferViews"][document["images"][image_index]["bufferView"]]
    start = view.get("byteOffset", 0)
    image = np.asarray(Image.open(io.BytesIO(binary[start:start + view["byteLength"]])).convert("RGB"))
    # Sample glTF's stored-image origin directly, independently of OBJ sampling.
    x = np.rint(sampled_uvs[:, 0] * (image.shape[1] - 1)).astype(int)
    y = np.rint(sampled_uvs[:, 1] * (image.shape[0] - 1)).astype(int)
    return image[y, x]


@pytest.mark.parametrize("writeback", ["renderer", "pipeline"])
@pytest.mark.parametrize("format", ["obj", "glb"])
def test_exported_texture_preserves_asymmetric_camera_world_colors(tmp_path, monkeypatch, writeback, format):
    vertices, normals, uvs, faces, calibration, poses, points, expected = _camera_plane(tmp_path)
    camera_before = (tmp_path / "camera.png").read_bytes()
    uv.write_obj(str(tmp_path / "model.obj"), vertices, normals, uvs, faces)
    if writeback == "renderer":
        atlas = uv.render_texture_atlas(vertices, uvs, faces, str(tmp_path), calibration,
                                        poses, atlas_size=129)
        Image.fromarray(atlas).save(tmp_path / "atlas.png")
        uv.write_mtl(str(tmp_path / "model.mtl"), texture_filename="atlas.png")
    else:
        (tmp_path / "intrinsics.json").write_text(json.dumps(calibration))
        (tmp_path / "poses.json").write_text(json.dumps(poses))
        # UV packing is fixed to isolate image origin; rasterization and every
        # actual file/export boundary run normally, including JPEG writeback.
        monkeypatch.setattr(uv, "unwrap_with_xatlas", lambda *args, **kwargs:
                            (vertices, normals, uvs, faces, np.arange(4)))
        uv.uv_unwrap_scan(str(tmp_path), profile="quality", atlas_size=129)

    mesh = trimesh.load(tmp_path / "model.obj", force="mesh", process=False)
    exported_uvs = _uv_at_world_points(mesh.vertices, mesh.faces, mesh.visual.uv, points)
    # UV values/geometry stay unchanged; only the image row origin is corrected.
    expected_uvs = _uv_at_world_points(vertices, faces, uvs, points)
    np.testing.assert_allclose(exported_uvs, expected_uvs, atol=1e-6)
    assert (tmp_path / "camera.png").read_bytes() == camera_before
    if format == "obj":
        actual = trimesh.visual.color.uv_to_color(exported_uvs, mesh.visual.material.image)[:, :3]
    else:
        actual = _sample_exported_glb(mesh, points)
    # JPEG writeback can change a channel by a small amount, not swap quadrants.
    np.testing.assert_allclose(actual.astype(int), expected.astype(int), atol=3)
