"""验证顶点焊接后 xatlas 的 UV 展开质量"""
import zipfile, os, numpy as np, xatlas
from collections import defaultdict
from scipy.spatial import cKDTree

TMPDIR = '/tmp/xatlas_test'
obj_path = os.path.join(TMPDIR, 'scan_20260323_170907/model.obj')

# 解析 OBJ
verts, faces = [], []
with open(obj_path) as f:
    for line in f:
        if line.startswith("v "):
            p = line.split()
            verts.append([float(p[1]), float(p[2]), float(p[3])])
        elif line.startswith("f "):
            parts = line.split()[1:]
            fv = [int(p.split("/")[0]) - 1 for p in parts]
            faces.append(fv)

verts = np.array(verts, dtype=np.float32)
faces = np.array(faces, dtype=np.uint32)
print(f"原始 mesh: {len(verts)} 顶点, {len(faces)} 面")

# 顶点焊接：合并位置相同的顶点
print("\n焊接顶点中...")
tree = cKDTree(verts)
eps = 1e-5  # 焊接阈值 0.01mm

# 用 union-find 合并 colocal 顶点
parent = list(range(len(verts)))
def find(x):
    while parent[x] != x:
        parent[x] = parent[parent[x]]
        x = parent[x]
    return x
def union(a, b):
    a, b = find(a), find(b)
    if a != b:
        parent[a] = b

pairs = tree.query_pairs(r=eps)
print(f"  找到 {len(pairs)} 对 colocal 顶点")
for a, b in pairs:
    union(a, b)

# 建立新的顶点映射
root_to_new = {}
old_to_new = np.zeros(len(verts), dtype=np.uint32)
new_verts = []
for i in range(len(verts)):
    root = find(i)
    if root not in root_to_new:
        root_to_new[root] = len(new_verts)
        new_verts.append(verts[root])
    old_to_new[i] = root_to_new[root]

new_verts = np.array(new_verts, dtype=np.float32)
new_faces = old_to_new[faces]

# 去除退化面
valid = (new_faces[:, 0] != new_faces[:, 1]) & \
        (new_faces[:, 1] != new_faces[:, 2]) & \
        (new_faces[:, 0] != new_faces[:, 2])
new_faces = new_faces[valid]

print(f"焊接后: {len(new_verts)} 顶点, {len(new_faces)} 面")
print(f"  顶点减少: {len(verts)} -> {len(new_verts)} ({(1-len(new_verts)/len(verts))*100:.1f}%)")
print(f"  退化面移除: {np.sum(~valid)}")

# 验证拓扑
vert_usage = np.zeros(len(new_verts), dtype=int)
for face in new_faces:
    for vi in face:
        vert_usage[vi] += 1
shared_verts = np.sum(vert_usage >= 2)
print(f"  共享顶点 (>=2面): {shared_verts} ({shared_verts/len(new_verts)*100:.1f}%)")

edge_count = defaultdict(int)
for face in new_faces:
    for i in range(3):
        v0, v1 = sorted([face[i], face[(i+1)%3]])
        edge_count[(v0, v1)] += 1
shared_edges = sum(1 for c in edge_count.values() if c >= 2)
total_edges = len(edge_count)
print(f"  共享边: {shared_edges}/{total_edges} ({shared_edges/total_edges*100:.1f}%)")

# 计算法线
normals = np.zeros_like(new_verts)
v0 = new_verts[new_faces[:, 0]]
v1 = new_verts[new_faces[:, 1]]
v2 = new_verts[new_faces[:, 2]]
fn = np.cross(v1 - v0, v2 - v0)
for i in range(3):
    np.add.at(normals, new_faces[:, i], fn)
lengths = np.linalg.norm(normals, axis=1, keepdims=True)
lengths[lengths < 1e-10] = 1.0
normals = (normals / lengths).astype(np.float32)

# xatlas UV 展开
print("\n=== xatlas maxCost=16.0, iter=4 (焊接后) ===")
atlas = xatlas.Atlas()
atlas.add_mesh(new_verts, new_faces, normals)

co = xatlas.ChartOptions()
co.max_cost = 16.0
co.max_iterations = 4

po = xatlas.PackOptions()
po.resolution = 4096
po.padding = 2
po.bilinear = True

atlas.generate(co, po, verbose=False)
vmapping, indices, uvs = atlas[0]
print(f"输出: {len(uvs)} UV vertices, {len(indices)} faces")

# 分析 UV 连续性
edge_to_faces = defaultdict(list)
for fi in range(len(indices)):
    face = indices[fi]
    for i in range(3):
        ov0 = vmapping[face[i]]
        ov1 = vmapping[face[(i+1)%3]]
        key = (min(ov0, ov1), max(ov0, ov1))
        uvi0 = face[i]
        uvi1 = face[(i+1)%3]
        edge_to_faces[key].append((fi, ov0, ov1, uvi0, uvi1))

shared = 0
total_interior = 0
for key, face_list in edge_to_faces.items():
    if len(face_list) >= 2:
        total_interior += 1
        _, ov0a, ov1a, uvi0a, uvi1a = face_list[0]
        _, ov0b, ov1b, uvi0b, uvi1b = face_list[1]
        map_a = {}
        if ov0a == key[0]: map_a[key[0]] = uvi0a; map_a[key[1]] = uvi1a
        else: map_a[key[0]] = uvi1a; map_a[key[1]] = uvi0a
        map_b = {}
        if ov0b == key[0]: map_b[key[0]] = uvi0b; map_b[key[1]] = uvi1b
        else: map_b[key[0]] = uvi1b; map_b[key[1]] = uvi0b
        if map_a[key[0]] == map_b[key[0]] and map_a[key[1]] == map_b[key[1]]:
            shared += 1

continuity = shared / total_interior * 100 if total_interior > 0 else 0

# UV island 数量
parent2 = list(range(len(indices)))
def find2(x):
    while parent2[x] != x:
        parent2[x] = parent2[parent2[x]]
        x = parent2[x]
    return x
def union2(a, b):
    a, b = find2(a), find2(b)
    if a != b: parent2[a] = b

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
            union2(fi0, fi1)

islands = len(set(find2(i) for i in range(len(indices))))

print(f"  内部边: {total_interior}, UV连续边: {shared}, 连续率: {continuity:.1f}%")
print(f"  UV island (chart) 数量: {islands}")
print(f"  平均每个 chart 面数: {len(indices)/islands:.1f}")
