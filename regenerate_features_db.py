#!/usr/bin/env python3
"""
用当前 scan zip 中的 poses.json 重新生成 features.db。
解决 DB pose 和 scan pose 不一致的问题。
"""
import json
import os
import shutil
import tempfile
import zipfile

import numpy as np

SCAN_ZIP = "data/scan_20260317_155524.zip"
GLB_PATH = "unity_project/Assets/StreamingAssets/SLAMTestAssets/optimized.glb"
DB_PATH  = "unity_project/Assets/StreamingAssets/SLAMTestAssets/features.db"

def main():
    import logging
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    # 1. 解压 scan zip 到临时目录
    tmp_dir = tempfile.mkdtemp(prefix="regen_db_")
    print(f"临时目录: {tmp_dir}")

    try:
        z = zipfile.ZipFile(SCAN_ZIP)
        z.extractall(tmp_dir)
        z.close()

        scan_dir = os.path.join(tmp_dir, "scan_20260317_155524")

        # 2. 用 optimized_pipeline 的 validate_input 加载 poses
        from processing_pipeline.optimized_pipeline import OptimizedPipeline
        pipeline = OptimizedPipeline()
        scan_input = pipeline.validate_input(scan_dir)

        print(f"帧数: {len(scan_input.images)}")
        print(f"内参: {scan_input.intrinsics}")

        # 3. 加载 GLB mesh
        import trimesh
        scene = trimesh.load(GLB_PATH)
        if isinstance(scene, trimesh.Scene):
            mesh_tri = trimesh.util.concatenate(scene.geometry.values())
        else:
            mesh_tri = scene
        print(f"GLB: {len(mesh_tri.vertices)} verts, {len(mesh_tri.faces)} faces")

        # 4. 构建 feature database
        features = pipeline.build_feature_database(
            mesh_tri, scan_input.images, scan_input.intrinsics
        )
        print(f"Keyframes: {len(features.keyframes)}")
        for kf in features.keyframes:
            print(f"  KF{kf.image_id}: {len(kf.keypoints)} features")

        # 5. 备份旧 DB 并删除，确保写入干净文件
        if os.path.exists(DB_PATH):
            backup = DB_PATH + ".bak"
            if not os.path.exists(backup):
                shutil.copy2(DB_PATH, backup)
                print(f"旧 DB 已备份到: {backup}")
            os.remove(DB_PATH)
            print(f"已删除旧 DB")

        # 6. 保存新 DB
        from processing_pipeline.feature_db import save_feature_database
        save_feature_database(features, DB_PATH)
        print(f"新 features.db 已保存到: {DB_PATH}")

        # 7. 验证：重新加载并对比 pose
        from processing_pipeline.feature_db import load_feature_database
        db_reloaded = load_feature_database(DB_PATH)
        print(f"\n=== 验证新 DB ===")
        for kf in db_reloaded.keyframes:
            scan_pose = scan_input.images[kf.image_id]["pose"]
            diff = np.abs(kf.camera_pose - scan_pose).max()
            t_diff = np.linalg.norm(kf.camera_pose[:3, 3] - scan_pose[:3, 3])
            status = "✅" if diff < 1e-10 else "❌"
            print(f"  KF{kf.image_id}: max_diff={diff:.2e}, t_diff={t_diff:.6f}m {status}")

    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)

    print("\n完成！现在可以运行 debug_render_overlay.py 验证 _scan 图的红绿对齐。")


if __name__ == "__main__":
    main()
