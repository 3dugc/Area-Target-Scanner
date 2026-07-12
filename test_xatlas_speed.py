#!/usr/bin/env python3
"""xatlas 参数对比测试：bruteForce + max_iterations 对速度和质量的影响"""
import logging
import time
import sys
import os
import shutil
import numpy as np
import xatlas

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
sys.path.insert(0, ".")
from processing_pipeline.uv_unwrap import parse_obj, ATLAS_SIZE

SCAN_DIR = "/tmp/test_uv_data2/scan_20260323_175533"
BACKUP_DIR = os.path.join(SCAN_DIR, "_backup_pre_unwrap")

obj_path = os.path.join(BACKUP_DIR, "model.obj")
vertices, normals, _, faces_v, _ = parse_obj(obj_path)
print(f"Mesh: {len(vertices)} verts, {len(faces_v)} faces\n")

configs = [
    {"name": "当前配置 (brute=T, iter=4)", "brute": True,  "iters": 4, "block": False},
    {"name": "brute=F, iter=4",            "brute": False, "iters": 4, "block": False},
    {"name": "brute=F, iter=2",            "brute": False, "iters": 2, "block": False},
    {"name": "brute=F, iter=1",            "brute": False, "iters": 1, "block": False},
    {"name": "brute=F, iter=1, block=T",   "brute": False, "iters": 1, "block": True},
    {"name": "brute=F, iter=2, block=T",   "brute": False, "iters": 2, "block": True},
]

for cfg in configs:
    print(f"--- {cfg['name']} ---")
    atlas = xatlas.Atlas()
    atlas.add_mesh(vertices, faces_v, normals)

    chart_opts = xatlas.ChartOptions()
    chart_opts.max_iterations = cfg["iters"]
    chart_opts.normal_deviation_weight = 2.0
    chart_opts.normal_seam_weight = 4.0

    pack_opts = xatlas.PackOptions()
    pack_opts.resolution = ATLAS_SIZE
    pack_opts.padding = 2
    pack_opts.bilinear = True
    pack_opts.bruteForce = cfg["brute"]
    pack_opts.blockAlign = cfg["block"]
    pack_opts.create_image = True

    t0 = time.time()
    atlas.generate(chart_opts, pack_opts, verbose=False)
    elapsed = time.time() - t0

    vmapping, indices, new_uvs = atlas[0]
    # UV utilization: % of UV area actually used
    uv_area = 0.0
    for face in indices:
        a, b, c = new_uvs[face[0]], new_uvs[face[1]], new_uvs[face[2]]
        uv_area += abs(np.cross(b - a, c - a)) * 0.5

    print(f"  时间: {elapsed:.1f}s")
    print(f"  Charts: {atlas.chart_count}, Atlas: {atlas.width}x{atlas.height}")
    print(f"  UV利用率: {uv_area*100:.1f}%")
    print(f"  顶点: {len(vmapping)}, 面: {len(indices)}")
    print()
