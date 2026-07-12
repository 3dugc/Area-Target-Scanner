"""Quick benchmark: xatlas speed with decimated mesh vs full mesh."""
import numpy as np
import trimesh
import time

# Load our scan data
glb = trimesh.load("data/other/2026_3_19.glb", force='scene')
meshes = list(glb.geometry.values())
mesh = meshes[0]  # Main mesh
print(f"Original: {len(mesh.vertices)} verts, {len(mesh.faces)} faces")

# Decimate to ~30K faces using open3d
try:
    import open3d as o3d
    o3d_mesh = o3d.geometry.TriangleMesh()
    o3d_mesh.vertices = o3d.utility.Vector3dVector(mesh.vertices)
    o3d_mesh.triangles = o3d.utility.Vector3iVector(mesh.faces)
    target = 30000
    decimated_o3d = o3d_mesh.simplify_quadric_decimation(target)
    dec_verts = np.asarray(decimated_o3d.vertices).astype(np.float32)
    dec_faces = np.asarray(decimated_o3d.triangles).astype(np.uint32)
    print(f"Decimated: {len(dec_verts)} verts, {len(dec_faces)} faces")
except ImportError:
    print("open3d not available, using original mesh")
    dec_verts = mesh.vertices.astype(np.float32)
    dec_faces = mesh.faces.astype(np.uint32)

# Try xatlas
try:
    import xatlas
    
    # Decimated mesh
    t0 = time.time()
    vmapping, indices, uvs = xatlas.parametrize(dec_verts, dec_faces)
    t1 = time.time()
    print(f"Decimated: xatlas took {t1-t0:.1f}s, {len(uvs)} UV verts")
    
    # Full mesh
    t0 = time.time()
    vmapping2, indices2, uvs2 = xatlas.parametrize(
        mesh.vertices.astype(np.float32),
        mesh.faces.astype(np.uint32)
    )
    t1 = time.time()
    print(f"Full: xatlas took {t1-t0:.1f}s, {len(uvs2)} UV verts")
except ImportError:
    print("xatlas python package not installed")
