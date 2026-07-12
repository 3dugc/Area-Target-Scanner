"""用真正的 xatlas 库测试我们的 mesh UV 展开质量"""
import zipfile
import os
import numpy as np
import xatlas
from collections import defaultdict

# 解压 mesh
SCAN_ZIP = "data/data1/scan_20260323_170907.zip"
TMPDIR = "/tmp/xatlas_test"
os.makedirs(TMPDIR, exist_ok=True)

with zipfile.ZipFile(SCAN_ZIP) as z:
    obj_files = [n for n in z.namelist() if n.endswith('.obj')]
    obj_name = obj_files[0]
    z.extract(obj_name, TMPDIR)
    obj_path = os.path.join(TMPDIR, obj_name)

# 解析 OBJ
verts, faces = [], []
with open(obj_path) as f:
    for line in f:
        if line.startswith("v "):
            p = line.split()
            verts.append([float(p[1]), float(p[2]), float(p[3])])
        elif line.startswith("f "):
            parts = line.split()[1:]
            fv = []
            for p in parts:
                idx = p.split("/")
                fv.append(int(idx[0]) - 1)
            faces.append(fv)

verts = np.array(verts, dtype=np.float32)
faces = np.array(faces, dtype=np.uint32)
print(f"Mesh: {len(verts)} vertices, {len(faces)} faces")

# 计算法线
def compute_normals(verts, faces):
    normals = np.zeros_like(verts)
    v0 = verts[faces[:, 0]]
    v1 = verts[faces[:, 1]]
    v2 = verts[faces[:, 2]]
    fn = np.cross(v1 - v0, v2 - v0)
    for i in range(3):
        np.add.at(normals, faces[:, i], fn)
    lengths = np.linalg.norm(normals, axis=1, keepdims=True)
    lengths[lengths < 1e-10] = 1.0
    return (normals / lengths).astype(np.float32)

normals = compute_normals(verts, faces)

def analyze_uv_continuity(verts_orig, faces_orig, vmapping, indices, uvs):
    """分析 UV 展开后的连续性"""
    # 用原始顶点 index 做 edge key
    edge_to_faces = defaultdict(list)
    for fi in range(len(indices)):
        face = indices[fi]
        for i in range(3):
            # 原始顶点 index
            ov0 = vmapping[face[i]]
            ov1 = vmapping[face[(i+1)%3]]
            key = (min(ov0, ov1), max(ov0, ov1))
            # UV vertex index
            uvi0 = face[i]
            uvi1 = face[(i+1)%3]
            edge_to_faces[key].append((fi, ov0, ov1, uvi0, uvi1))
    
    shared = 0
    total_interior = 0
    for key, face_list in edge_to_faces.items():
        if len(face_list) >= 2:
            total_interior += 1
            # 检查前两个面的 UV 是否连续
            _, ov0a, ov1a, uvi0a, uvi1a = face_list[0]
            _, ov0b, ov1b, uvi0b, uvi1b = face_list[1]
            # 构建 (orig_vert -> uv_idx) 映射
            map_a = {}
            if ov0a == key[0]: map_a[key[0]] = uvi0a; map_a[key[1]] = uvi1a
            else: map_a[key[0]] = uvi1a; map_a[key[1]] = uvi0a
            map_b = {}
            if ov0b == key[0]: map_b[key[0]] = uvi0b; map_b[key[1]] = uvi1b
            else: map_b[key[0]] = uvi1b; map_b[key[1]] = uvi0b
            # UV 连续 = 同一原始顶点映射到同一 UV 顶点
            if map_a[key[0]] == map_b[key[0]] and map_a[key[1]] == map_b[key[1]]:
                shared += 1
    
    continuity = shared / total_interior * 100 if total_interior > 0 else 0
    
    # 统计 chart 数量（UV 连通分量）
    parent = list(range(len(indices)))
    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    def union(a, b):
        a, b = find(a), find(b)
        if a != b: parent[a] = b
    
    for key, face_list in edge_to_faces.items():
        if len(face_list) >= 2:
            fi0 = face_list[0][0]
            fi1 = face_list[1][0]
            _, ov0a, ov1a, uvi0a, uvi1a = face_list[0]
            _, ov0b, ov1b, uvi0b, uvi1b = face_list[1]
            map_a = {}
            if ov0a == key[0]: map_a[key[0]] = uvi0a; map_a[key[1]] = uvi1a
            else: map_a[key[0]] = uvi1a; map_a[key[1]] = uvi0a
            map_b = {}
            if ov0b == key[0]: map_b[key[0]] = uvi0b; map_b[key[1]] = uvi1b
            else: map_b[key[0]] = uvi1b; map_b[key[1]] = uvi0b
            if map_a[key[0]] == map_b[key[0]] and map_a[key[1]] == map_b[key[1]]:
                union(fi0, fi1)
    
    islands = len(set(find(i) for i in range(len(indices))))
    
    print(f"  内部边: {total_interior}, UV连续边: {shared}, 连续率: {continuity:.1f}%")
    print(f"  UV island (chart) 数量: {islands}")
    print(f"  平均每个 chart 面数: {len(indices)/islands:.1f}")

# 测试不同 maxCost 参数
configs = [
    ("默认 maxCost=2.0, iter=1", 2.0, 1),
    ("maxCost=8.0, iter=2", 8.0, 2),
    ("maxCost=16.0, iter=4", 16.0, 4),
    ("maxCost=32.0, iter=4", 32.0, 4),
]

for label, max_cost, max_iter in configs:
    print(f"\n=== {label} ===")
    atlas = xatlas.Atlas()
    atlas.add_mesh(verts, faces, normals)
    
    co = xatlas.ChartOptions()
    co.max_cost = max_cost
    co.max_iterations = max_iter
    
    po = xatlas.PackOptions()
    po.resolution = 4096
    po.padding = 2
    po.bilinear = True
    
    atlas.generate(co, po, verbose=False)
    vmapping, indices, uvs = atlas[0]
    print(f"输出: {len(uvs)} UV vertices, {len(indices)} faces")
    analyze_uv_continuity(verts, faces, vmapping, indices, uvs)
