#!/usr/bin/env python3
"""Re-generate texture atlas from camera frames + poses + mesh geometry.

Uses the existing UV layout (which is good, <0.3% overlap) and re-projects
camera images onto the texture atlas using proper pinhole camera model
matching the iOS scanner's TextureProjector logic.
"""

import json
import os
import sys
import numpy as np
from PIL import Image
from scipy.ndimage import distance_transform_edt

SCAN_DIR = "data/scan_20260317_132224/scan_20260317_132224"
OUT_DIR = "data/scan_retextured"
os.makedirs(OUT_DIR, exist_ok=True)

ATLAS_SIZE = 4096


def parse_obj(path):
    """Parse OBJ into vertices, UVs, face-vertex indices, face-UV indices."""
    verts, uvs = [], []
    faces_v, faces_vt = [], []
    with open(path) as f:
        for line in f:
            if line.startswith("v "):
                p = line.split()
                verts.append([float(p[1]), float(p[2]), float(p[3])])
            elif line.startswith("vt "):
                p = line.split()
                uvs.append([float(p[1]), float(p[2])])
            elif line.startswith("f "):
                parts = line.split()[1:]
                fv, ft = [], []
                for p in parts:
                    idx = p.split("/")
                    fv.append(int(idx[0]) - 1)
                    ft.append(int(idx[1]) - 1 if len(idx) > 1 else 0)
                faces_v.append(fv)
                faces_vt.append(ft)
    return (np.array(verts, dtype=np.float64),
            np.array(uvs, dtype=np.float64),
            np.array(faces_v, dtype=np.int32),
            np.array(faces_vt, dtype=np.int32))


def load_camera_data():
    with open(os.path.join(SCAN_DIR, "intrinsics.json")) as f:
        intr = json.load(f)
    with open(os.path.join(SCAN_DIR, "poses.json")) as f:
        poses = json.load(f)
    return intr, poses


def build_pose_matrices(poses_data):
    """Build 4x4 pose matrices (column-major as stored in poses.json)."""
    matrices = []
    for frame in poses_data["frames"]:
        # poses.json stores column-major, reshape with Fortran order
        t = np.array(frame["transform"], dtype=np.float64).reshape(4, 4, order='F')
        matrices.append(t)
    return matrices


def project_point_to_image(world_pt, pose_matrix, intr):
    """Project 3D world point to 2D image pixel coords.

    Follows the same convention as iOS TextureProjector:
    - ARKit: camera looks along -Z in camera space
    - px = fx * (X / -Z) + cx
    - py = fy * (-Y / -Z) + cy
    Returns (px, py) or None if behind camera or out of bounds.
    """
    view = np.linalg.inv(pose_matrix)
    p_cam = view @ np.array([world_pt[0], world_pt[1], world_pt[2], 1.0])

    # Camera looks along -Z, so point must have negative Z
    if p_cam[2] >= 0:
        return None

    neg_z = -p_cam[2]
    px = intr['fx'] * (p_cam[0] / neg_z) + intr['cx']
    py = intr['fy'] * (-p_cam[1] / neg_z) + intr['cy']

    if 0 <= px < intr['width'] and 0 <= py < intr['height']:
        return (px, py)
    return None


def select_best_frame_for_face(center, normal, pose_matrices, intr):
    """Select best camera frame: highest score = dot(normal, viewDir) / dist.

    Uses linear distance decay (not quadratic) to prevent near-origin frames
    from monopolizing face assignments.
    """
    best_idx, best_score = -1, 0.0
    for i, pose in enumerate(pose_matrices):
        cam_pos = pose[:3, 3]
        # Skip near-origin frames (camera hasn't moved yet)
        if np.linalg.norm(cam_pos) < 0.01:
            continue
        to_cam = cam_pos - center
        dist = np.linalg.norm(to_cam)
        if dist < 1e-10:
            continue
        view_dir = to_cam / dist
        dot = np.dot(normal, view_dir)
        if dot <= 0:  # backface
            continue
        if project_point_to_image(center, pose, intr) is None:
            continue
        score = dot / dist
        if score > best_score:
            best_score = score
            best_idx = i
    return best_idx


def compute_face_data(verts, faces_v):
    """Compute face centers and normals."""
    v0 = verts[faces_v[:, 0]]
    v1 = verts[faces_v[:, 1]]
    v2 = verts[faces_v[:, 2]]
    centers = (v0 + v1 + v2) / 3.0
    normals = np.cross(v1 - v0, v2 - v0)
    lengths = np.linalg.norm(normals, axis=1, keepdims=True)
    lengths[lengths < 1e-10] = 1.0
    normals = normals / lengths
    return centers, normals


def assign_frames(centers, normals, pose_matrices, intr):
    """Assign best camera frame to each face."""
    n = len(centers)
    assignments = np.full(n, -1, dtype=np.int32)
    for i in range(n):
        if i % 10000 == 0:
            print(f"  Assigning frame for face {i}/{n}...")
        assignments[i] = select_best_frame_for_face(
            centers[i], normals[i], pose_matrices, intr)
    assigned = np.sum(assignments >= 0)
    print(f"  Assigned: {assigned}/{n} faces ({assigned/n*100:.1f}%)")
    return assignments


def render_atlas(verts, uvs, faces_v, faces_vt, assignments,
                 pose_matrices, images, intr):
    """Render texture atlas by rasterizing UV triangles and sampling from images.

    For each face:
    1. Get the assigned camera frame
    2. Rasterize the UV triangle into atlas pixels
    3. For each atlas pixel, compute barycentric coords -> 3D world point
    4. Project world point to camera image -> sample color
    """
    print("Rendering texture atlas...")
    atlas = np.zeros((ATLAS_SIZE, ATLAS_SIZE, 3), dtype=np.float64)
    weight = np.zeros((ATLAS_SIZE, ATLAS_SIZE), dtype=np.float64)

    n_faces = len(faces_v)
    for fi in range(n_faces):
        if fi % 10000 == 0:
            print(f"  Rasterizing face {fi}/{n_faces}...")

        frame_idx = assignments[fi]
        if frame_idx < 0:
            continue

        pose = pose_matrices[frame_idx]
        img = images[frame_idx]
        img_h, img_w = img.shape[:2]

        # 3D vertices of this face
        fv = faces_v[fi]
        p0, p1, p2 = verts[fv[0]], verts[fv[1]], verts[fv[2]]

        # UV vertices of this face
        ft = faces_vt[fi]
        uv0, uv1, uv2 = uvs[ft[0]], uvs[ft[1]], uvs[ft[2]]

        # UV to atlas pixel coords
        a = uv0 * (ATLAS_SIZE - 1)
        b = uv1 * (ATLAS_SIZE - 1)
        c = uv2 * (ATLAS_SIZE - 1)

        # Bounding box in atlas
        u_min = max(0, int(np.floor(min(a[0], b[0], c[0]))))
        u_max = min(ATLAS_SIZE - 1, int(np.ceil(max(a[0], b[0], c[0]))))
        v_min = max(0, int(np.floor(min(a[1], b[1], c[1]))))
        v_max = min(ATLAS_SIZE - 1, int(np.ceil(max(a[1], b[1], c[1]))))

        if u_min > u_max or v_min > v_max:
            continue

        # Precompute barycentric denominator
        e0 = b - a
        e1 = c - a
        d00 = np.dot(e0, e0)
        d01 = np.dot(e0, e1)
        d11 = np.dot(e1, e1)
        denom = d00 * d11 - d01 * d01
        if abs(denom) < 1e-12:
            continue
        inv_denom = 1.0 / denom

        # Precompute view matrix for this frame
        view = np.linalg.inv(pose)

        for py in range(v_min, v_max + 1):
            for px in range(u_min, u_max + 1):
                pt = np.array([px, py], dtype=np.float64)
                e2 = pt - a
                d02 = np.dot(e0, e2)
                d12 = np.dot(e1, e2)
                v_bary = (d11 * d02 - d01 * d12) * inv_denom
                w_bary = (d00 * d12 - d01 * d02) * inv_denom
                u_bary = 1.0 - v_bary - w_bary

                if u_bary < -0.005 or v_bary < -0.005 or w_bary < -0.005:
                    continue

                # Interpolate 3D position
                world_pt = u_bary * p0 + v_bary * p1 + w_bary * p2

                # Project to camera image
                p_cam = view @ np.array([world_pt[0], world_pt[1], world_pt[2], 1.0])
                if p_cam[2] >= 0:
                    continue
                neg_z = -p_cam[2]
                ix = intr['fx'] * (p_cam[0] / neg_z) + intr['cx']
                iy = intr['fy'] * (-p_cam[1] / neg_z) + intr['cy']

                ixi, iyi = int(ix), int(iy)
                if 0 <= ixi < img_w and 0 <= iyi < img_h:
                    # Flip Y: UV v=0 is texture bottom, but numpy row 0 is image top
                    # So UV row py should map to image row (ATLAS_SIZE - 1 - py)
                    flipped_py = ATLAS_SIZE - 1 - py
                    atlas[flipped_py, px] += img[iyi, ixi].astype(np.float64)
                    weight[flipped_py, px] += 1.0

    # Normalize
    mask = weight > 0
    for ch in range(3):
        atlas[:, :, ch][mask] /= weight[mask]

    # Fill empty pixels with nearest neighbor
    print("  Filling empty pixels...")
    for ch in range(3):
        channel = atlas[:, :, ch]
        empty = ~mask
        if empty.any() and mask.any():
            _, indices = distance_transform_edt(empty, return_distances=True,
                                                return_indices=True)
            channel[empty] = channel[indices[0][empty], indices[1][empty]]

    filled_pct = mask.sum() / mask.size * 100
    print(f"  Filled pixels: {mask.sum():,} ({filled_pct:.1f}%)")
    return np.clip(atlas, 0, 255).astype(np.uint8)


def write_output(verts, uvs, faces_v, faces_vt, atlas_img):
    """Write OBJ + MTL + texture to output directory."""
    # Texture
    tex_path = os.path.join(OUT_DIR, "texture.jpg")
    Image.fromarray(atlas_img).save(tex_path, quality=95)
    print(f"  Texture: {tex_path}")

    # MTL
    mtl_path = os.path.join(OUT_DIR, "model.mtl")
    with open(mtl_path, 'w') as f:
        f.write("newmtl textured_material\n")
        f.write("Ka 1.0 1.0 1.0\n")
        f.write("Kd 1.0 1.0 1.0\n")
        f.write("map_Kd texture.jpg\n")

    # OBJ
    obj_path = os.path.join(OUT_DIR, "model.obj")
    with open(obj_path, 'w') as f:
        f.write("# Re-textured mesh\n")
        f.write("mtllib model.mtl\n")
        f.write("usemtl textured_material\n\n")
        for v in verts:
            f.write(f"v {v[0]} {v[1]} {v[2]}\n")
        f.write("\n")
        for vt in uvs:
            f.write(f"vt {vt[0]} {vt[1]}\n")
        f.write("\n")
        for i in range(len(faces_v)):
            fv, ft = faces_v[i], faces_vt[i]
            f.write(f"f {fv[0]+1}/{ft[0]+1} "
                    f"{fv[1]+1}/{ft[1]+1} "
                    f"{fv[2]+1}/{ft[2]+1}\n")
    print(f"  OBJ: {obj_path}")
    print(f"  MTL: {mtl_path}")


def render_preview(verts, uvs, faces_v, faces_vt, atlas_img):
    """Quick render preview of the re-textured model."""
    from PIL import ImageDraw

    W, H = 1600, 1200
    tex = atlas_img

    # Sample per-face color
    th, tw = tex.shape[:2]
    face_colors = np.zeros((len(faces_vt), 3), dtype=np.uint8)
    for i in range(len(faces_vt)):
        tri_uv = uvs[faces_vt[i]]
        cu, cv = tri_uv.mean(axis=0)
        px = int(np.clip(cu, 0, 0.999) * tw)
        py = int(np.clip(1.0 - cv, 0, 0.999) * th)
        face_colors[i] = tex[py, px]

    # Face normals for lighting
    v0 = verts[faces_v[:, 0]]
    v1 = verts[faces_v[:, 1]]
    v2 = verts[faces_v[:, 2]]
    normals = np.cross(v1 - v0, v2 - v0)
    lengths = np.linalg.norm(normals, axis=1, keepdims=True)
    lengths[lengths < 1e-10] = 1
    normals = normals / lengths

    light = np.array([0.3, 0.8, 0.5])
    light = light / np.linalg.norm(light)
    shade = np.clip(0.3 + 0.7 * np.abs(normals @ light), 0, 1)

    center = (verts.min(axis=0) + verts.max(axis=0)) / 2
    extent = (verts.max(axis=0) - verts.min(axis=0)).max()
    dist = extent * 1.2

    views = [
        (center + np.array([dist*0.8, dist*0.4, dist*0.6]), "3/4 View"),
        (center + np.array([0, dist*0.3, dist]), "Front"),
        (center + np.array([dist, dist*0.3, 0]), "Right"),
    ]

    result_images = []
    for eye, title in views:
        eye = eye.astype(np.float64)
        fwd = center - eye
        fwd = fwd / np.linalg.norm(fwd)
        up = np.array([0, 1, 0], dtype=np.float64)
        right = np.cross(fwd, up)
        right = right / np.linalg.norm(right)
        up2 = np.cross(right, fwd)

        v_c = verts - eye
        x = v_c @ right
        y = v_c @ up2
        z = v_c @ fwd

        fov_f = 1.0 / np.tan(np.radians(30))
        aspect = W / H
        z_safe = np.where(z > 0.01, z, 0.01)
        sx = ((fov_f / aspect * x / z_safe + 1) * 0.5 * W).astype(np.float32)
        sy = ((1 - fov_f * y / z_safe) * 0.5 * H).astype(np.float32)

        face_z = z[faces_v].mean(axis=1)
        order = np.argsort(-face_z)

        img = Image.new('RGB', (W, H), (30, 30, 35))
        draw = ImageDraw.Draw(img)

        for fi in order:
            if face_z[fi] < 0.01:
                continue
            fv = faces_v[fi]
            pts = [(float(sx[fv[j]]), float(sy[fv[j]])) for j in range(3)]
            xs = [p[0] for p in pts]
            ys = [p[1] for p in pts]
            if max(xs) < 0 or min(xs) > W or max(ys) < 0 or min(ys) > H:
                continue
            s = shade[fi]
            c = face_colors[fi]
            r = int(np.clip(c[0] * s, 0, 255))
            g = int(np.clip(c[1] * s, 0, 255))
            b = int(np.clip(c[2] * s, 0, 255))
            draw.polygon(pts, fill=(r, g, b))

        result_images.append((img, title))

    # Compose
    canvas = Image.new('RGB', (W * 3, H), (20, 20, 25))
    for i, (img, title) in enumerate(result_images):
        canvas.paste(img, (i * W, 0))
    out = os.path.join(OUT_DIR, "preview.png")
    canvas.save(out)
    print(f"  Preview: {out}")


def main():
    print("=" * 60)
    print("RE-TEXTURING MESH FROM CAMERA FRAMES")
    print("=" * 60)

    # 1. Load mesh
    print("\n[1/6] Loading mesh...")
    obj_path = os.path.join(SCAN_DIR, "model.obj")
    verts, uvs, faces_v, faces_vt = parse_obj(obj_path)
    print(f"  {len(verts)} verts, {len(uvs)} UVs, {len(faces_v)} faces")

    # 2. Load camera data
    print("\n[2/6] Loading camera data...")
    intr, poses_data = load_camera_data()
    pose_matrices = build_pose_matrices(poses_data)
    print(f"  {len(pose_matrices)} frames, {intr['width']}x{intr['height']}")

    # 3. Load images
    print("\n[3/6] Loading images...")
    images = []
    for frame in poses_data["frames"]:
        img_path = os.path.join(SCAN_DIR, frame["imageFile"])
        img = np.array(Image.open(img_path).convert("RGB"))
        images.append(img)
    print(f"  Loaded {len(images)} images")

    # 4. Assign best frame per face
    print("\n[4/6] Assigning camera frames to faces...")
    centers, normals = compute_face_data(verts, faces_v)
    assignments = assign_frames(centers, normals, pose_matrices, intr)

    # 5. Render atlas
    print("\n[5/6] Rendering texture atlas...")
    atlas_img = render_atlas(verts, uvs, faces_v, faces_vt, assignments,
                             pose_matrices, images, intr)

    # 6. Write output
    print("\n[6/6] Writing output...")
    write_output(verts, uvs, faces_v, faces_vt, atlas_img)

    # Preview
    print("\nRendering preview...")
    render_preview(verts, uvs, faces_v, faces_vt, atlas_img)

    print("\n" + "=" * 60)
    print(f"Done! Output in: {OUT_DIR}/")
    print("  model.obj + model.mtl + texture.jpg")
    print("  preview.png (3 viewpoints)")
    print("=" * 60)


if __name__ == "__main__":
    main()
