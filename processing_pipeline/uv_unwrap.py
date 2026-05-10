"""UV unwrapping module using xatlas for server-side processing.

Takes an OBJ mesh with per-triangle UV (from iPad fast stub) and re-unwraps
it with proper chart segmentation and packing, then re-projects texture from
camera frames.
"""

import json
import logging
import os
import shutil
import struct
import subprocess
import tempfile
import threading

import numpy as np
import xatlas
from PIL import Image
from scipy.ndimage import distance_transform_edt

logger = logging.getLogger(__name__)

FAST_ATLAS_SIZE = int(os.environ.get("UV_FAST_ATLAS_SIZE", "2048"))
QUALITY_ATLAS_SIZE = int(os.environ.get("UV_QUALITY_ATLAS_SIZE", "4096"))
ATLAS_SIZE = QUALITY_ATLAS_SIZE
UV_XATLAS_NATIVE = os.environ.get("UV_XATLAS_NATIVE", "1") == "1"
UV_XATLAS_HELPER_PATH = os.environ.get("UV_XATLAS_HELPER_PATH", "/app/bin/xatlas_helper")
UV_FAST_TARGET_FACES = int(os.environ.get("UV_FAST_TARGET_FACES", "50000"))
UV_FAST_DECIMATE_THRESHOLD_FACES = int(os.environ.get("UV_FAST_DECIMATE_THRESHOLD_FACES", "60000"))
UV_ALLOW_QUALITY_DEGRADE = os.environ.get("UV_ALLOW_QUALITY_DEGRADE", "0") == "1"

_HELPER_INPUT_MAGIC = b"XATLASIN"
_HELPER_OUTPUT_MAGIC = b"XATLASOU"
_HELPER_PROTOCOL_VERSION = 1


def _atlas_size_for_profile(profile, atlas_size=None):
    if atlas_size is not None:
        return int(atlas_size)
    env_override = os.environ.get("UV_ATLAS_SIZE")
    if env_override:
        return int(env_override)
    return FAST_ATLAS_SIZE if profile == "fast" else QUALITY_ATLAS_SIZE


def _xatlas_options_for_profile(profile):
    if profile == "fast":
        return {"max_iterations": 1, "brute_force": False}
    return {"max_iterations": 4, "brute_force": False}


def _should_decimate_for_profile(profile, face_count):
    if face_count <= UV_FAST_DECIMATE_THRESHOLD_FACES:
        return False
    return profile == "fast" or UV_ALLOW_QUALITY_DEGRADE


def _emit_progress(on_progress, message, progress=None):
    if on_progress is None:
        return
    try:
        on_progress(message, progress)
    except TypeError:
        on_progress(message)


def parse_obj(path):
    """Parse OBJ file into vertices, normals, UVs, and face indices."""
    vertices, normals, uvs = [], [], []
    faces_v, faces_vt = [], []
    with open(path) as f:
        for line in f:
            if line.startswith("v "):
                p = line.split()
                vertices.append([float(p[1]), float(p[2]), float(p[3])])
            elif line.startswith("vn "):
                p = line.split()
                normals.append([float(p[1]), float(p[2]), float(p[3])])
            elif line.startswith("vt "):
                p = line.split()
                uvs.append([float(p[1]), float(p[2])])
            elif line.startswith("f "):
                parts = line.split()[1:]
                fv, ft = [], []
                for p in parts:
                    idx = p.split("/")
                    fv.append(int(idx[0]) - 1)
                    ft.append(int(idx[1]) - 1 if len(idx) > 1 and idx[1] else 0)
                faces_v.append(fv)
                faces_vt.append(ft)
    return (
        np.array(vertices, dtype=np.float32),
        np.array(normals, dtype=np.float32) if normals else np.zeros((len(vertices), 3), dtype=np.float32),
        np.array(uvs, dtype=np.float32) if uvs else None,
        np.array(faces_v, dtype=np.uint32),
        np.array(faces_vt, dtype=np.int32) if faces_vt else None,
    )


def _helper_arrays(vertices, normals, faces):
    vertices = np.ascontiguousarray(vertices, dtype=np.float32)
    faces = np.ascontiguousarray(faces, dtype=np.uint32)
    if normals is None or len(normals) != len(vertices):
        normals = np.zeros((len(vertices), 3), dtype=np.float32)
    normals = np.ascontiguousarray(normals, dtype=np.float32)
    return vertices, normals, faces


def _write_xatlas_helper_input(
    path,
    vertices,
    normals,
    faces,
    atlas_size,
    max_iterations,
    brute_force=False,
    block_align=False,
):
    """Write the small binary protocol consumed by native/xatlas_helper."""
    vertices, normals, faces = _helper_arrays(vertices, normals, faces)
    flags = (1 if brute_force else 0) | (2 if block_align else 0)
    with open(path, "wb") as f:
        f.write(_HELPER_INPUT_MAGIC)
        f.write(
            struct.pack(
                "<6I",
                _HELPER_PROTOCOL_VERSION,
                len(vertices),
                len(faces),
                int(atlas_size),
                int(max_iterations),
                flags,
            )
        )
        vertices.astype("<f4", copy=False).tofile(f)
        normals.astype("<f4", copy=False).tofile(f)
        faces.astype("<u4", copy=False).tofile(f)


def _read_xatlas_helper_output(path, vertices, normals):
    vertices, normals, _ = _helper_arrays(vertices, normals, np.zeros((0, 3), dtype=np.uint32))
    with open(path, "rb") as f:
        magic = f.read(len(_HELPER_OUTPUT_MAGIC))
        if magic != _HELPER_OUTPUT_MAGIC:
            raise RuntimeError("native xatlas output has invalid magic")
        header_bytes = f.read(struct.calcsize("<6I"))
        if len(header_bytes) != struct.calcsize("<6I"):
            raise RuntimeError("native xatlas output header is truncated")
        version, vertex_count, index_count, width, height, chart_count = struct.unpack(
            "<6I", header_bytes
        )
        if version != _HELPER_PROTOCOL_VERSION:
            raise RuntimeError(f"unsupported native xatlas output version: {version}")

        vmapping = np.fromfile(f, dtype="<u4", count=vertex_count).astype(np.uint32, copy=False)
        indices = np.fromfile(f, dtype="<u4", count=index_count).astype(np.uint32, copy=False)
        uvs = np.fromfile(f, dtype="<f4", count=vertex_count * 2).astype(np.float32, copy=False)

    if len(vmapping) != vertex_count or len(indices) != index_count or len(uvs) != vertex_count * 2:
        raise RuntimeError("native xatlas output mesh is truncated")
    if index_count % 3 != 0:
        raise RuntimeError(f"native xatlas output index count is not triangular: {index_count}")
    if len(vmapping) and int(vmapping.max()) >= len(vertices):
        raise RuntimeError("native xatlas output references a missing source vertex")

    new_faces = np.ascontiguousarray(indices.reshape((-1, 3)), dtype=np.uint32)
    new_uvs = np.ascontiguousarray(uvs.reshape((-1, 2)), dtype=np.float32)
    new_verts = np.ascontiguousarray(vertices[vmapping], dtype=np.float32)
    new_normals = np.ascontiguousarray(normals[vmapping], dtype=np.float32) if len(normals) else None
    meta = {
        "atlas_width": width,
        "atlas_height": height,
        "chart_count": chart_count,
        "native_xatlas": True,
    }
    return new_verts, new_normals, new_uvs, new_faces, vmapping, meta


def _native_helper_available(helper_path=UV_XATLAS_HELPER_PATH, use_native=UV_XATLAS_NATIVE):
    return bool(use_native and helper_path and os.path.isfile(helper_path) and os.access(helper_path, os.X_OK))


def _native_progress_value(category, raw_progress):
    progress = max(0.0, min(float(raw_progress), 100.0)) / 100.0
    ranges = {
        "AddMesh": (9.0, 10.0),
        "ComputeCharts": (10.0, 14.0),
        "PackCharts": (14.0, 15.5),
        "BuildOutputMeshes": (15.5, 16.0),
    }
    start, end = ranges.get(category, (10.0, 16.0))
    return start + (end - start) * progress


def _unwrap_with_native_xatlas(
    vertices,
    normals,
    faces,
    atlas_size=ATLAS_SIZE,
    max_iterations=1,
    brute_force=False,
    on_progress=None,
    helper_path=UV_XATLAS_HELPER_PATH,
):
    """Run the repo-built xatlas helper and stream real progress callbacks."""
    logger.info(
        "Running native xatlas helper: %d verts, %d faces, atlas=%d, max_iterations=%d",
        len(vertices),
        len(faces),
        atlas_size,
        max_iterations,
    )
    with tempfile.TemporaryDirectory(prefix="xatlas_native_") as tmp_dir:
        input_path = os.path.join(tmp_dir, "mesh.bin")
        output_path = os.path.join(tmp_dir, "unwrap.bin")
        _write_xatlas_helper_input(
            input_path,
            vertices,
            normals,
            faces,
            atlas_size,
            max_iterations,
            brute_force=brute_force,
        )

        proc = subprocess.Popen(
            [helper_path, input_path, output_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        done_event = None
        assert proc.stdout is not None
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                logger.debug("native xatlas helper stdout: %s", line)
                continue
            if event.get("type") == "progress":
                category = event.get("category", "xatlas")
                raw_progress = event.get("progress", 0)
                mapped = _native_progress_value(category, raw_progress)
                _emit_progress(
                    on_progress,
                    f"0/4 UV 纹理展开 ({category} {int(raw_progress)}%)",
                    mapped,
                )
            elif event.get("type") == "done":
                done_event = event

        stderr = proc.stderr.read() if proc.stderr else ""
        exit_code = proc.wait()
        if exit_code != 0:
            tail = stderr.strip()[-1200:] if stderr else "no stderr"
            raise RuntimeError(f"native xatlas helper failed with exit code {exit_code}: {tail}")
        if stderr.strip():
            logger.warning("native xatlas helper stderr: %s", stderr.strip()[-1200:])
        if done_event is None:
            logger.warning("native xatlas helper completed without a done event")
        if not os.path.isfile(output_path):
            raise RuntimeError("native xatlas helper completed but did not write output")

        return _read_xatlas_helper_output(output_path, vertices, normals)


def _unwrap_with_python_xatlas(
    vertices,
    normals,
    faces,
    atlas_size=ATLAS_SIZE,
    max_iterations=4,
    brute_force=False,
    on_progress=None,
):
    """Fallback path using the Python xatlas wheel with synthetic heartbeat progress."""
    logger.info("Running Python xatlas UV unwrap: %d verts, %d faces", len(vertices), len(faces))
    result = {}
    error = {}

    def run_generate():
        try:
            atlas = xatlas.Atlas()
            atlas.add_mesh(vertices, faces, normals)

            chart_opts = xatlas.ChartOptions()
            chart_opts.max_iterations = max_iterations
            chart_opts.normal_deviation_weight = 2.0
            chart_opts.normal_seam_weight = 4.0

            pack_opts = xatlas.PackOptions()
            pack_opts.resolution = atlas_size
            pack_opts.padding = 2
            pack_opts.bilinear = True
            pack_opts.bruteForce = brute_force
            pack_opts.create_image = True

            atlas.generate(chart_opts, pack_opts, verbose=False)
            vmapping, indices, new_uvs = atlas[0]
            indices = np.asarray(indices, dtype=np.uint32)
            if indices.ndim == 1:
                indices = indices.reshape((-1, 3))
            result["value"] = (
                vertices[vmapping],
                normals[vmapping] if len(normals) > 0 else None,
                new_uvs,
                indices,
                vmapping,
                {
                    "atlas_width": getattr(atlas, "width", atlas_size),
                    "atlas_height": getattr(atlas, "height", atlas_size),
                    "chart_count": getattr(atlas, "chart_count", None),
                    "native_xatlas": False,
                },
            )
        except Exception as exc:  # pragma: no cover - re-raised in parent thread
            error["value"] = exc

    thread = threading.Thread(target=run_generate, name="python-xatlas-generate", daemon=True)
    thread.start()
    heartbeat = 0
    while thread.is_alive():
        synthetic_progress = min(15.0, 12.0 + heartbeat * 0.35)
        _emit_progress(
            on_progress,
            "0/4 UV 纹理展开 (Python xatlas 处理中)",
            synthetic_progress,
        )
        heartbeat += 1
        thread.join(timeout=2.0)
    if error:
        raise error["value"]

    new_verts, new_normals, new_uvs, indices, vmapping, meta = result["value"]
    logger.info(
        "Python xatlas result: %s charts, %sx%s atlas",
        meta.get("chart_count"),
        meta.get("atlas_width"),
        meta.get("atlas_height"),
    )
    return new_verts, new_normals, new_uvs, indices, vmapping, meta


def unwrap_with_xatlas(
    vertices,
    normals,
    faces,
    atlas_size=ATLAS_SIZE,
    profile="quality",
    max_iterations=None,
    brute_force=None,
    on_progress=None,
    helper_path=UV_XATLAS_HELPER_PATH,
    use_native=UV_XATLAS_NATIVE,
):
    """Re-unwrap mesh using native xatlas progress when available, with wheel fallback."""
    options = _xatlas_options_for_profile(profile)
    if max_iterations is None:
        max_iterations = options["max_iterations"]
    if brute_force is None:
        brute_force = options["brute_force"]

    vertices, normals, faces = _helper_arrays(vertices, normals, faces)
    if _native_helper_available(helper_path=helper_path, use_native=use_native):
        return _unwrap_with_native_xatlas(
            vertices,
            normals,
            faces,
            atlas_size=atlas_size,
            max_iterations=max_iterations,
            brute_force=brute_force,
            on_progress=on_progress,
            helper_path=helper_path,
        )

    logger.info("Native xatlas helper unavailable; falling back to Python xatlas wheel")
    return _unwrap_with_python_xatlas(
        vertices,
        normals,
        faces,
        atlas_size=atlas_size,
        max_iterations=max_iterations,
        brute_force=brute_force,
        on_progress=on_progress,
    )


def _decimate_mesh(vertices, normals, faces, target_faces, on_progress=None):
    """Simplify large fast-profile meshes before UV unwrap to cap xatlas cost."""
    if len(faces) <= target_faces:
        return vertices, normals, faces
    try:
        import open3d as o3d
    except Exception as exc:
        logger.warning("Open3D unavailable for UV fast decimation: %s", exc)
        return vertices, normals, faces

    _emit_progress(
        on_progress,
        f"0/4 UV 纹理展开 (简化网格 {len(faces)}->{target_faces})",
        8.5,
    )
    mesh = o3d.geometry.TriangleMesh()
    mesh.vertices = o3d.utility.Vector3dVector(np.asarray(vertices, dtype=np.float64))
    mesh.triangles = o3d.utility.Vector3iVector(np.asarray(faces, dtype=np.int32))
    if normals is not None and len(normals) == len(vertices):
        mesh.vertex_normals = o3d.utility.Vector3dVector(np.asarray(normals, dtype=np.float64))
    else:
        mesh.compute_vertex_normals()

    try:
        mesh.remove_duplicated_vertices()
        mesh.remove_duplicated_triangles()
        mesh.remove_degenerate_triangles()
        mesh.remove_non_manifold_edges()
        simplified = mesh.simplify_quadric_decimation(target_number_of_triangles=int(target_faces))
        simplified.remove_degenerate_triangles()
        simplified.remove_unreferenced_vertices()
        simplified.compute_vertex_normals()
    except Exception as exc:
        logger.warning("UV fast decimation failed; using original mesh: %s", exc)
        return vertices, normals, faces

    dec_vertices = np.asarray(simplified.vertices, dtype=np.float32)
    dec_faces = np.asarray(simplified.triangles, dtype=np.uint32)
    dec_normals = np.asarray(simplified.vertex_normals, dtype=np.float32)
    if len(dec_vertices) == 0 or len(dec_faces) == 0:
        logger.warning("UV fast decimation produced empty mesh; using original mesh")
        return vertices, normals, faces
    logger.info("UV fast decimation: %d faces -> %d faces", len(faces), len(dec_faces))
    return dec_vertices, dec_normals, dec_faces


def _vectorized_assign_frames(centers, normals, pose_matrices, intr):
    """Vectorized best-frame assignment for all faces at once.

    For each face, find the camera with highest score = dot(normal, viewDir) / dist^2,
    where the face center must project into the image bounds.

    Returns:
        assignments: (N,) int array, -1 if no valid frame found
    """
    n_faces = len(centers)
    n_frames = len(pose_matrices)

    # Camera positions: (n_frames, 3)
    cam_positions = np.array([p[:3, 3] for p in pose_matrices], dtype=np.float64)

    # Precompute view matrices for projection check
    view_matrices = np.array([np.linalg.inv(p) for p in pose_matrices], dtype=np.float64)

    fx, fy, cx, cy = intr['fx'], intr['fy'], intr['cx'], intr['cy']
    img_w, img_h = intr['width'], intr['height']

    # to_cam: (n_faces, n_frames, 3)
    to_cam = cam_positions[np.newaxis, :, :] - centers[:, np.newaxis, :]

    # dist: (n_faces, n_frames)
    dist_sq = np.sum(to_cam ** 2, axis=2)
    dist = np.sqrt(dist_sq)
    dist_safe = np.where(dist > 1e-10, dist, 1.0)

    # view_dir: (n_faces, n_frames, 3)
    view_dir = to_cam / dist_safe[:, :, np.newaxis]

    # dot product with face normals: (n_faces, n_frames)
    dot = np.sum(normals[:, np.newaxis, :] * view_dir, axis=2)

    # score = dot / dist^2, only where dot > 0
    score = np.where(dot > 0, dot / np.maximum(dist_sq, 1e-20), -1.0)

    # Projection check: transform centers to camera space for each frame
    # centers_h: (n_faces, 4) homogeneous
    centers_h = np.hstack([centers, np.ones((n_faces, 1), dtype=np.float64)])

    # For each frame, project all centers
    for i in range(n_frames):
        # p_cam: (n_faces, 4)
        p_cam = (view_matrices[i] @ centers_h.T).T
        # Must have negative Z (camera looks along -Z)
        behind = p_cam[:, 2] >= 0
        neg_z = np.where(behind, 1.0, -p_cam[:, 2])
        px = fx * (p_cam[:, 0] / neg_z) + cx
        py = fy * (-p_cam[:, 1] / neg_z) + cy
        out_of_bounds = behind | (px < 0) | (px >= img_w) | (py < 0) | (py >= img_h)
        score[out_of_bounds, i] = -1.0

    # Best frame per face
    assignments = np.argmax(score, axis=1).astype(np.int32)
    # Mark faces with no valid frame
    best_scores = score[np.arange(n_faces), assignments]
    assignments[best_scores <= 0] = -1

    return assignments


def render_texture_atlas(
    new_verts,
    new_uvs,
    new_faces,
    scan_dir,
    intr,
    poses_data,
    on_progress=None,
    atlas_size=ATLAS_SIZE,
):
    """Render texture atlas with vectorized frame assignment and per-face rasterization."""
    import time
    frames = poses_data["frames"]
    n_frames = len(frames)
    logger.info("Rendering texture atlas from %d camera frames (vectorized)...", n_frames)
    _emit_progress(on_progress, f"0/4 UV 纹理展开 (准备 {n_frames} 个相机帧)", 18)

    # Precompute pose and view matrices
    pose_matrices = []
    view_matrices = []
    for frame in frames:
        t = np.array(frame["transform"], dtype=np.float64).reshape(4, 4, order='F')
        pose_matrices.append(t)
        view_matrices.append(np.linalg.inv(t))

    image_cache = {}

    def get_image(frame_idx):
        if frame_idx not in image_cache:
            img_path = os.path.join(scan_dir, frames[frame_idx]["imageFile"])
            image_cache[frame_idx] = np.array(
                Image.open(img_path).convert("RGB"),
                dtype=np.float32,
            )
        return image_cache[frame_idx]

    fx, fy, cx, cy = intr['fx'], intr['fy'], intr['cx'], intr['cy']

    # Step 1: Batch compute face centers and normals
    t0 = time.time()
    v0 = new_verts[new_faces[:, 0]].astype(np.float32)
    v1 = new_verts[new_faces[:, 1]].astype(np.float32)
    v2 = new_verts[new_faces[:, 2]].astype(np.float32)
    centers = (v0 + v1 + v2) / 3.0
    edge1 = v1 - v0
    edge2 = v2 - v0
    cross = np.cross(edge1, edge2)
    cross_len = np.linalg.norm(cross, axis=1, keepdims=True)
    valid_faces = (cross_len.ravel() > 1e-10)
    normals = np.zeros_like(cross)
    normals[valid_faces] = cross[valid_faces] / cross_len[valid_faces]
    logger.info("  Computed %d face normals in %.1fs", valid_faces.sum(), time.time() - t0)

    # Step 2: Vectorized frame assignment
    t1 = time.time()
    _emit_progress(on_progress, "0/4 UV 纹理展开 (分配纹理帧)", 19)
    assignments = _vectorized_assign_frames(centers, normals, pose_matrices, intr)
    assigned_count = (assignments >= 0).sum()
    logger.info("  Assigned %d/%d faces in %.1fs", assigned_count, len(new_faces), time.time() - t1)

    # Step 3: Per-face rasterization with vectorized pixel processing
    t2 = time.time()
    atlas = np.zeros((atlas_size, atlas_size, 3), dtype=np.float32)
    atlas_weight = np.zeros((atlas_size, atlas_size), dtype=np.float32)

    total = len(new_faces)
    for fi in range(total):
        if fi % 20000 == 0:
            logger.info("  Rasterizing face %d/%d...", fi, total)
            raster_progress = 20 + min(7, int(7 * fi / max(total, 1)))
            _emit_progress(
                on_progress,
                f"0/4 UV 纹理展开 (纹理投影 {fi}/{total})",
                raster_progress,
            )

        if assignments[fi] < 0 or not valid_faces[fi]:
            continue

        frame_idx = assignments[fi]
        view = view_matrices[frame_idx]
        img = get_image(frame_idx)
        h, w = img.shape[:2]

        face = new_faces[fi]
        uv0, uv1, uv2 = new_uvs[face[0]], new_uvs[face[1]], new_uvs[face[2]]
        px_uvs = np.array([uv0, uv1, uv2], dtype=np.float32) * (atlas_size - 1)

        u_min = max(0, int(np.floor(px_uvs[:, 0].min())))
        u_max = min(atlas_size - 1, int(np.ceil(px_uvs[:, 0].max())))
        v_min = max(0, int(np.floor(px_uvs[:, 1].min())))
        v_max = min(atlas_size - 1, int(np.ceil(px_uvs[:, 1].max())))

        if u_min >= u_max or v_min >= v_max:
            continue

        # Vectorized barycentric for all pixels in bounding box
        a, b, c = px_uvs[0], px_uvs[1], px_uvs[2]
        v0b, v1b = c - a, b - a
        dot00 = np.dot(v0b, v0b)
        dot01 = np.dot(v0b, v1b)
        dot11 = np.dot(v1b, v1b)
        denom = dot00 * dot11 - dot01 * dot01
        if abs(denom) < 1e-10:
            continue
        inv_denom = 1.0 / denom

        # Create pixel grid
        px_range = np.arange(u_min, u_max + 1, dtype=np.float32)
        py_range = np.arange(v_min, v_max + 1, dtype=np.float32)
        grid_x, grid_y = np.meshgrid(px_range, py_range)
        # (n_pixels, 2)
        pts_x = grid_x.ravel()
        pts_y = grid_y.ravel()

        v2b_x = pts_x - a[0]
        v2b_y = pts_y - a[1]
        dot02 = v0b[0] * v2b_x + v0b[1] * v2b_y
        dot12 = v1b[0] * v2b_x + v1b[1] * v2b_y
        u_bary = (dot11 * dot02 - dot01 * dot12) * inv_denom
        v_bary = (dot00 * dot12 - dot01 * dot02) * inv_denom

        # Filter pixels inside triangle
        inside = (u_bary >= -0.01) & (v_bary >= -0.01) & ((u_bary + v_bary) <= 1.01)
        if not inside.any():
            continue

        u_b = u_bary[inside]
        v_b = v_bary[inside]
        w0 = 1.0 - u_b - v_b
        w1 = v_b
        w2 = u_b

        # 3D world points: (n_inside, 3)
        fv0, fv1, fv2 = v0[fi], v1[fi], v2[fi]
        world_pts = w0[:, np.newaxis] * fv0 + w1[:, np.newaxis] * fv1 + w2[:, np.newaxis] * fv2

        # Project to camera: vectorized
        ones = np.ones((len(world_pts), 1), dtype=world_pts.dtype)
        world_h = np.hstack([world_pts, ones])  # (n, 4)
        p_cam = (view @ world_h.T).T  # (n, 4)

        visible = p_cam[:, 2] < 0
        if not visible.any():
            continue

        neg_z = -p_cam[visible, 2]
        ix = (fx * (p_cam[visible, 0] / neg_z) + cx).astype(np.int32)
        iy = (fy * (-p_cam[visible, 1] / neg_z) + cy).astype(np.int32)

        in_bounds = (ix >= 0) & (ix < w) & (iy >= 0) & (iy < h)
        if not in_bounds.any():
            continue

        # Atlas pixel coords for valid pixels
        atlas_px = pts_x[inside][visible][in_bounds].astype(np.int32)
        atlas_py = pts_y[inside][visible][in_bounds].astype(np.int32)
        sample_ix = ix[in_bounds]
        sample_iy = iy[in_bounds]

        # Sample from image and accumulate
        colors = img[sample_iy, sample_ix]  # (n_valid, 3)
        # Use np.add.at for safe accumulation (handles duplicate indices)
        np.add.at(atlas, (atlas_py, atlas_px), colors)
        np.add.at(atlas_weight, (atlas_py, atlas_px), 1.0)

    logger.info("  Rasterized in %.1fs", time.time() - t2)

    # Normalize
    _emit_progress(on_progress, "0/4 UV 纹理展开 (填充纹理空洞)", 27)
    mask = atlas_weight > 0
    for ch in range(3):
        atlas[:, :, ch][mask] /= atlas_weight[mask]

    # Fill empty pixels with nearest neighbor
    for ch in range(3):
        channel = atlas[:, :, ch]
        empty = ~mask
        if empty.any() and mask.any():
            _, indices = distance_transform_edt(empty, return_distances=True, return_indices=True)
            channel[empty] = channel[indices[0][empty], indices[1][empty]]

    filled_pct = mask.sum() / mask.size * 100
    logger.info("Atlas rendered: %.1f%% pixels filled (total %.1fs)", filled_pct, time.time() - t0)
    return np.clip(atlas, 0, 255).astype(np.uint8)


def write_obj(path, vertices, normals, uvs, faces, mtl_name="model.mtl"):
    """Write OBJ file with vertices, normals, UVs, and faces."""
    with open(path, 'w') as f:
        f.write("# UV-unwrapped mesh (xatlas)\n")
        f.write(f"mtllib {mtl_name}\n")
        f.write("usemtl textured_material\n\n")
        for v in vertices:
            f.write(f"v {v[0]} {v[1]} {v[2]}\n")
        f.write("\n")
        for vt in uvs:
            f.write(f"vt {vt[0]} {vt[1]}\n")
        f.write("\n")
        if normals is not None and len(normals) > 0:
            for vn in normals:
                f.write(f"vn {vn[0]} {vn[1]} {vn[2]}\n")
            f.write("\n")
        for face in faces:
            i0, i1, i2 = face[0] + 1, face[1] + 1, face[2] + 1
            if normals is not None and len(normals) > 0:
                f.write(f"f {i0}/{i0}/{i0} {i1}/{i1}/{i1} {i2}/{i2}/{i2}\n")
            else:
                f.write(f"f {i0}/{i0} {i1}/{i1} {i2}/{i2}\n")


def write_mtl(path, texture_filename="texture.jpg"):
    """Write MTL material file."""
    with open(path, 'w') as f:
        f.write("newmtl textured_material\n")
        f.write("Ka 1.0 1.0 1.0\n")
        f.write("Kd 1.0 1.0 1.0\n")
        f.write(f"map_Kd {texture_filename}\n")


def uv_unwrap_scan(scan_dir, profile="quality", on_progress=None, atlas_size=None):
    """Run full UV unwrap pipeline on a scan directory.

    Reads model.obj, runs xatlas UV unwrap, re-projects texture from camera
    frames, and overwrites model.obj + texture.jpg + model.mtl in place.

    Args:
        scan_dir: Path to extracted scan directory containing model.obj,
                  texture.jpg, poses.json, intrinsics.json, images/

    Returns:
        dict with stats: chart_count, vertex_count, face_count
    """
    obj_path = os.path.join(scan_dir, "model.obj")
    poses_path = os.path.join(scan_dir, "poses.json")
    intrinsics_path = os.path.join(scan_dir, "intrinsics.json")
    atlas_size = _atlas_size_for_profile(profile, atlas_size=atlas_size)

    # Validate required files
    for p in [obj_path, poses_path, intrinsics_path]:
        if not os.path.isfile(p):
            raise FileNotFoundError(f"UV unwrap requires: {p}")

    # 1. Parse OBJ
    logger.info(
        "UV unwrap: loading mesh from %s (profile=%s, atlas=%d)",
        obj_path,
        profile,
        atlas_size,
    )
    _emit_progress(on_progress, "0/4 UV 纹理展开 (解析 OBJ)", 8)
    vertices, normals, old_uvs, faces_v, faces_vt = parse_obj(obj_path)
    logger.info("  %d vertices, %d faces", len(vertices), len(faces_v))
    input_vertex_count = len(vertices)
    input_face_count = len(faces_v)

    decimated = False
    if _should_decimate_for_profile(profile, len(faces_v)):
        before_faces = len(faces_v)
        vertices, normals, faces_v = _decimate_mesh(
            vertices,
            normals,
            faces_v,
            target_faces=UV_FAST_TARGET_FACES,
            on_progress=on_progress,
        )
        decimated = len(faces_v) < before_faces

    # 2. Run xatlas
    options = _xatlas_options_for_profile(profile)
    _emit_progress(on_progress, "0/4 UV 纹理展开 (xatlas 展开)", 10)
    unwrap_result = unwrap_with_xatlas(
        vertices,
        normals,
        faces_v,
        atlas_size=atlas_size,
        profile=profile,
        max_iterations=options["max_iterations"],
        brute_force=options["brute_force"],
        on_progress=on_progress,
    )
    if len(unwrap_result) == 5:
        new_verts, new_normals, new_uvs, new_faces, vmapping = unwrap_result
        unwrap_meta = {"native_xatlas": False}
    else:
        new_verts, new_normals, new_uvs, new_faces, vmapping, unwrap_meta = unwrap_result

    # 3. Load camera data
    _emit_progress(on_progress, "0/4 UV 纹理展开 (加载相机数据)", 16)
    with open(intrinsics_path) as f:
        intr = json.load(f)
    with open(poses_path) as f:
        poses_data = json.load(f)

    # 4. Render texture atlas
    atlas_img = render_texture_atlas(
        new_verts,
        new_uvs,
        new_faces,
        scan_dir,
        intr,
        poses_data,
        on_progress=on_progress,
        atlas_size=atlas_size,
    )

    # 5. Backup originals and write new files
    _emit_progress(on_progress, "0/4 UV 纹理展开 (写回模型和纹理)", 28)
    backup_dir = os.path.join(scan_dir, "_backup_pre_unwrap")
    os.makedirs(backup_dir, exist_ok=True)
    for fname in ["model.obj", "texture.jpg", "model.mtl"]:
        src = os.path.join(scan_dir, fname)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(backup_dir, fname))

    # Write new OBJ
    write_obj(obj_path, new_verts, new_normals, new_uvs, new_faces)
    logger.info("  Written: %s (%d verts, %d faces)", obj_path, len(new_verts), len(new_faces))

    # Write new texture
    tex_path = os.path.join(scan_dir, "texture.jpg")
    Image.fromarray(atlas_img).save(tex_path, quality=95)
    logger.info("  Written: %s (%dx%d)", tex_path, atlas_img.shape[1], atlas_img.shape[0])

    # Write new MTL
    mtl_path = os.path.join(scan_dir, "model.mtl")
    write_mtl(mtl_path)

    stats = {
        "vertex_count": len(new_verts),
        "face_count": len(new_faces),
        "atlas_size": atlas_size,
        "input_vertex_count": input_vertex_count,
        "input_face_count": input_face_count,
        "xatlas_face_count": len(faces_v),
        "decimated": decimated,
        "native_xatlas": bool(unwrap_meta.get("native_xatlas")),
        "xatlas_max_iterations": options["max_iterations"],
    }
    if unwrap_meta.get("chart_count") is not None:
        stats["chart_count"] = unwrap_meta["chart_count"]
    logger.info("UV unwrap complete: %s", stats)
    _emit_progress(on_progress, "0/4 UV 纹理展开完成", 30)
    return stats
