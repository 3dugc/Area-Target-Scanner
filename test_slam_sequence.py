#!/usr/bin/env python3
"""
SLAM 序列定位测试：对 ScanData 全部帧逐帧验证定位精度。

流程：
  1. 加载 ScanData（94帧 images/ + poses.json + intrinsics.json）
  2. 加载 SLAMTestAssets（features.db + optimized.glb）
  3. 对每一帧扫描图像：
     a. 提取 ORB 特征
     b. 与 features.db 中最近的 keyframe 做特征匹配（BFMatcher Hamming）
     c. 用匹配到的 3D-2D 对应关系做 PnP
     d. PnP 结果经 flip(Y,Z) 得到 w2c_native
     e. 计算 scanToAR = arCameraPose × w2c_native
     f. 评估 scanToAR 与单位矩阵的误差
  4. 输出逐帧结果 + 汇总统计
  5. 生成可视化叠加图（绿色=GT，红色=PnP定位链路）

输出目录: debug/round9_slam_sequence_test/
"""
import json, struct, os, sys, time
import numpy as np
import cv2
import trimesh
import sqlite3
from pathlib import Path

# === 路径配置 ===
SCAN_DIR = "unity_project/Assets/StreamingAssets/ScanData"
ASSET_DIR = "unity_project/Assets/StreamingAssets/SLAMTestAssets"
GLB_PATH = os.path.join(ASSET_DIR, "optimized.glb")
DB_PATH = os.path.join(ASSET_DIR, "features.db")
OUT_DIR = "debug/round9_slam_sequence_test"
os.makedirs(OUT_DIR, exist_ok=True)

# 可视化输出的抽样间隔（每隔 N 帧输出一张叠加图，0=全部输出）
VIS_SAMPLE_INTERVAL = 5

# PnP 参数
PNP_REPROJ_ERROR = 10.0
PNP_CONFIDENCE = 0.99
PNP_ITERATIONS = 300
PNP_MIN_INLIERS = 10

# 特征匹配参数
MATCH_RATIO_THRESH = 0.75  # Lowe's ratio test
MIN_MATCHES_FOR_PNP = 15


def load_scan_data(scan_dir):
    """加载扫描数据：内参 + 帧列表（含 c2w 位姿）"""
    intrinsics = json.load(open(os.path.join(scan_dir, "intrinsics.json")))
    poses_data = json.load(open(os.path.join(scan_dir, "poses.json")))
    frames = []
    for f in poses_data["frames"]:
        c2w = np.array(f["transform"], dtype=np.float64).reshape(4, 4, order='F')
        img_path = os.path.join(scan_dir, f["imageFile"])
        frames.append({"index": f["index"], "c2w": c2w, "img_path": img_path})
    frames.sort(key=lambda x: x["index"])
    return intrinsics, frames


def load_db_keyframes(db_path):
    """从 features.db 加载所有 keyframe 的位姿、2D 特征点、3D 点和描述子"""
    db = sqlite3.connect(db_path)
    rows = db.execute("SELECT id, pose FROM keyframes ORDER BY id").fetchall()
    kfs = {}
    for row in rows:
        kf_id = row[0]
        pose_bytes = row[1]
        pose = np.array(
            [struct.unpack_from("d", pose_bytes, i * 8)[0] for i in range(16)]
        ).reshape(4, 4)

        features = db.execute(
            "SELECT x, y, x3d, y3d, z3d, descriptor FROM features WHERE keyframe_id=?",
            (kf_id,)).fetchall()

        pts2d = np.array([(f[0], f[1]) for f in features], dtype=np.float32)
        pts3d = np.array([(f[2], f[3], f[4]) for f in features], dtype=np.float32)
        descs = np.array([
            np.frombuffer(f[5], dtype=np.uint8) for f in features
        ], dtype=np.uint8) if features else np.empty((0, 32), dtype=np.uint8)

        kfs[kf_id] = {"c2w": pose, "pts2d": pts2d, "pts3d": pts3d, "descriptors": descs}
    db.close()
    return kfs


def find_best_keyframe(scan_c2w, db_kfs):
    """找到与扫描帧位置最近的 DB keyframe"""
    scan_pos = scan_c2w[:3, 3]
    best_dist, best_id = float('inf'), None
    for kf_id, kf in db_kfs.items():
        d = np.linalg.norm(scan_pos - kf["c2w"][:3, 3])
        if d < best_dist:
            best_dist, best_id = d, kf_id
    return best_id, best_dist


def match_features(query_descs, db_descs, ratio_thresh=MATCH_RATIO_THRESH):
    """BFMatcher + Lowe's ratio test 做特征匹配，返回匹配索引对"""
    if len(query_descs) < 2 or len(db_descs) < 2:
        return []
    bf = cv2.BFMatcher(cv2.NORM_HAMMING)
    matches = bf.knnMatch(query_descs, db_descs, k=2)
    good = []
    for m_pair in matches:
        if len(m_pair) == 2:
            m, n = m_pair
            if m.distance < ratio_thresh * n.distance:
                good.append((m.queryIdx, m.trainIdx))
    return good


def do_pnp_from_matches(matched_pts3d, matched_pts2d, K):
    """PnP + flip(Y,Z) = 模拟 native C++ 定位输出"""
    if len(matched_pts3d) < PNP_MIN_INLIERS:
        return None, 0

    ok, rvec, tvec, inliers = cv2.solvePnPRansac(
        matched_pts3d.astype(np.float32),
        matched_pts2d.astype(np.float32),
        K.astype(np.float32), None,
        iterationsCount=PNP_ITERATIONS,
        reprojectionError=PNP_REPROJ_ERROR,
        confidence=PNP_CONFIDENCE)

    if not ok or inliers is None or len(inliers) < PNP_MIN_INLIERS:
        return None, 0 if inliers is None else len(inliers)

    R, _ = cv2.Rodrigues(rvec)
    t = tvec.flatten()
    # flip Y and Z (ARKit → OpenCV convention)
    flip = np.diag([1.0, -1.0, -1.0])
    w2c = np.eye(4)
    w2c[:3, :3] = flip @ R
    w2c[:3, 3] = flip @ t
    return w2c, len(inliers)


def project_verts(verts_world, c2w, K):
    """世界坐标顶点 → 图像坐标"""
    w2c = np.linalg.inv(c2w)
    verts_cam = (w2c[:3, :3] @ verts_world.T).T + w2c[:3, 3]
    verts_cv = verts_cam.copy()
    verts_cv[:, 1] = -verts_cam[:, 1]
    verts_cv[:, 2] = -verts_cam[:, 2]
    visible = verts_cv[:, 2] > 0.01
    z = verts_cv[:, 2].copy()
    z[z == 0] = 1e-9
    pts2d = np.zeros((len(verts_world), 2))
    pts2d[:, 0] = K[0, 0] * verts_cv[:, 0] / z + K[0, 2]
    pts2d[:, 1] = K[1, 1] * verts_cv[:, 1] / z + K[1, 2]
    return pts2d, visible


def draw_edges(img, mesh, pts2d, visible, color, thickness=1):
    h, w = img.shape[:2]
    count = 0
    for e in mesh.edges_unique:
        i, j = e
        if not visible[i] or not visible[j]:
            continue
        x1, y1 = int(pts2d[i, 0]), int(pts2d[i, 1])
        x2, y2 = int(pts2d[j, 0]), int(pts2d[j, 1])
        if abs(x1) > 4000 or abs(y1) > 4000 or abs(x2) > 4000 or abs(y2) > 4000:
            continue
        cv2.line(img, (x1, y1), (x2, y2), color, thickness, cv2.LINE_AA)
        count += 1
    return count


def render_overlay(img, mesh, verts, K, scan_c2w, w2c_native, frame_idx, n_inliers, n_matches):
    """绘制绿色(GT) + 红色(PnP定位链路) 线框叠加图"""
    result = img.copy()
    h, w_img = result.shape[:2]

    # 绿色: GT — 用 scan pose 直接投影
    pts_gt, vis_gt = project_verts(verts, scan_c2w, K)
    g = draw_edges(result, mesh, pts_gt, vis_gt, (0, 255, 0), 1)

    # 红色: PnP+flip+scanToAR
    r = 0
    s2a_info = "PnP FAILED"
    if w2c_native is not None:
        scan_to_ar = scan_c2w @ w2c_native
        verts_h = np.hstack([verts, np.ones((len(verts), 1))])
        verts_ar = (scan_to_ar @ verts_h.T).T[:, :3]
        pts_pnp, vis_pnp = project_verts(verts_ar, scan_c2w, K)
        r = draw_edges(result, mesh, pts_pnp, vis_pnp, (0, 0, 255), 1)
        err = np.linalg.norm(scan_to_ar - np.eye(4))
        s2a_t = scan_to_ar[:3, 3]
        s2a_info = f"s2a_err={err:.4f} t=({s2a_t[0]:+.4f},{s2a_t[1]:+.4f},{s2a_t[2]:+.4f})"

    label = f"Frame {frame_idx:03d}  matches={n_matches} inliers={n_inliers}"
    cv2.putText(result, label, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255,255,255), 2)
    cv2.putText(result, f"GREEN=GT({g}) RED=PnP({r})", (10, 65), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255,255,255), 2)
    cv2.putText(result, s2a_info, (10, 100), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255,255,255), 2)

    # 图例
    cv2.rectangle(result, (w_img-300, 10), (w_img-10, 70), (0,0,0), -1)
    cv2.line(result, (w_img-290, 30), (w_img-240, 30), (0,255,0), 2)
    cv2.putText(result, "GT pose", (w_img-230, 35), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0,255,0), 1)
    cv2.line(result, (w_img-290, 55), (w_img-240, 55), (0,0,255), 2)
    cv2.putText(result, "PnP localization", (w_img-230, 60), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0,0,255), 1)

    return result


def main():
    print("=" * 70)
    print("SLAM 序列定位测试 — 全帧验证")
    print("=" * 70)
    t_start = time.time()

    # 1. 加载扫描数据
    intrinsics, scan_frames = load_scan_data(SCAN_DIR)
    fx, fy = intrinsics["fx"], intrinsics["fy"]
    cx, cy = intrinsics["cx"], intrinsics["cy"]
    K = np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1]], dtype=np.float64)
    print(f"内参: fx={fx:.1f} fy={fy:.1f} cx={cx:.1f} cy={cy:.1f}")
    print(f"扫描帧数: {len(scan_frames)}")

    # 2. 加载 GLB mesh
    scene = trimesh.load(GLB_PATH)
    if isinstance(scene, trimesh.Scene):
        mesh = trimesh.util.concatenate(scene.geometry.values())
    else:
        mesh = scene
    verts = np.array(mesh.vertices, dtype=np.float64)
    print(f"GLB: {len(verts)} verts, {len(mesh.faces)} faces")

    # 3. 加载 features.db
    db_kfs = load_db_keyframes(DB_PATH)
    total_db_features = sum(len(kf["descriptors"]) for kf in db_kfs.values())
    print(f"DB keyframes: {len(db_kfs)}, 总特征数: {total_db_features}")

    # 4. 初始化 ORB 检测器
    orb = cv2.ORB_create(nfeatures=2000)

    print(f"\n开始逐帧定位测试...")
    print("-" * 70)

    results = []

    for i, frame in enumerate(scan_frames):
        frame_idx = frame["index"]
        scan_c2w = frame["c2w"]
        img_path = frame["img_path"]

        # 读取图像
        img = cv2.imread(img_path)
        if img is None:
            print(f"  Frame {frame_idx:03d}: ❌ 无法读取图像")
            results.append({"frame": frame_idx, "status": "img_error"})
            continue

        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

        # 提取 ORB 特征
        kps, descs = orb.detectAndCompute(gray, None)
        if descs is None or len(kps) < 10:
            print(f"  Frame {frame_idx:03d}: ❌ 特征不足 ({0 if descs is None else len(kps)})")
            results.append({"frame": frame_idx, "status": "few_features", "n_features": 0 if descs is None else len(kps)})
            continue

        # 找最近的 DB keyframe
        best_kf_id, kf_dist = find_best_keyframe(scan_c2w, db_kfs)
        kf = db_kfs[best_kf_id]

        # 特征匹配
        good_matches = match_features(descs, kf["descriptors"])
        n_matches = len(good_matches)

        if n_matches < MIN_MATCHES_FOR_PNP:
            print(f"  Frame {frame_idx:03d}: ⚠️  匹配不足 matches={n_matches} (kf={best_kf_id}, dist={kf_dist:.3f}m)")
            results.append({
                "frame": frame_idx, "status": "few_matches",
                "n_features": len(kps), "n_matches": n_matches,
                "kf_id": best_kf_id, "kf_dist": kf_dist
            })
            continue

        # 构建 PnP 输入：从 DB keyframe 取 3D 点，从扫描帧取 2D 点
        matched_pts3d = kf["pts3d"][[m[1] for m in good_matches]]
        matched_pts2d = np.array([kps[m[0]].pt for m in good_matches], dtype=np.float32)

        # PnP + flip
        w2c_native, n_inliers = do_pnp_from_matches(matched_pts3d, matched_pts2d, K)

        if w2c_native is None:
            print(f"  Frame {frame_idx:03d}: ⚠️  PnP 失败 matches={n_matches} inliers={n_inliers}")
            results.append({
                "frame": frame_idx, "status": "pnp_failed",
                "n_features": len(kps), "n_matches": n_matches, "n_inliers": n_inliers,
                "kf_id": best_kf_id, "kf_dist": kf_dist
            })
            continue

        # 计算 scanToAR 误差
        scan_to_ar = scan_c2w @ w2c_native
        s2a_err = np.linalg.norm(scan_to_ar - np.eye(4))
        s2a_t_err = np.linalg.norm(scan_to_ar[:3, 3])  # 平移误差 (m)
        s2a_R = scan_to_ar[:3, :3]
        s2a_angle = np.degrees(np.arccos(np.clip((np.trace(s2a_R) - 1) / 2, -1, 1)))  # 旋转误差 (deg)

        status_icon = "✅" if s2a_err < 0.1 else ("⚠️" if s2a_err < 0.5 else "❌")
        print(f"  Frame {frame_idx:03d}: {status_icon} matches={n_matches} inliers={n_inliers} "
              f"s2a_err={s2a_err:.4f} t_err={s2a_t_err:.4f}m rot_err={s2a_angle:.2f}°")

        results.append({
            "frame": frame_idx, "status": "ok",
            "n_features": len(kps), "n_matches": n_matches, "n_inliers": n_inliers,
            "kf_id": best_kf_id, "kf_dist": kf_dist,
            "s2a_err": s2a_err, "t_err": s2a_t_err, "rot_err": s2a_angle
        })

        # 可视化输出（抽样）
        should_vis = (VIS_SAMPLE_INTERVAL == 0) or (i % VIS_SAMPLE_INTERVAL == 0)
        if should_vis:
            vis = render_overlay(img, mesh, verts, K, scan_c2w, w2c_native, frame_idx, n_inliers, n_matches)
            vis_path = os.path.join(OUT_DIR, f"frame_{frame_idx:03d}.jpg")
            cv2.imwrite(vis_path, vis, [cv2.IMWRITE_JPEG_QUALITY, 85])

    # === 汇总 ===
    elapsed = time.time() - t_start
    print()
    print("=" * 70)
    print("汇总统计")
    print("=" * 70)

    total = len(results)
    ok_results = [r for r in results if r["status"] == "ok"]
    n_ok = len(ok_results)
    n_pnp_fail = len([r for r in results if r["status"] == "pnp_failed"])
    n_few_match = len([r for r in results if r["status"] == "few_matches"])
    n_few_feat = len([r for r in results if r["status"] == "few_features"])
    n_img_err = len([r for r in results if r["status"] == "img_error"])

    print(f"总帧数: {total}")
    print(f"定位成功: {n_ok}/{total} ({100*n_ok/total:.1f}%)")
    if n_pnp_fail: print(f"PnP 失败: {n_pnp_fail}")
    if n_few_match: print(f"匹配不足: {n_few_match}")
    if n_few_feat: print(f"特征不足: {n_few_feat}")
    if n_img_err: print(f"图像错误: {n_img_err}")

    if ok_results:
        errs = [r["s2a_err"] for r in ok_results]
        t_errs = [r["t_err"] for r in ok_results]
        rot_errs = [r["rot_err"] for r in ok_results]
        inliers = [r["n_inliers"] for r in ok_results]
        matches = [r["n_matches"] for r in ok_results]

        print(f"\nscanToAR 矩阵误差:")
        print(f"  mean={np.mean(errs):.4f}  max={np.max(errs):.4f}  min={np.min(errs):.4f}  std={np.std(errs):.4f}")
        print(f"平移误差 (m):")
        print(f"  mean={np.mean(t_errs):.4f}  max={np.max(t_errs):.4f}  min={np.min(t_errs):.4f}")
        print(f"旋转误差 (°):")
        print(f"  mean={np.mean(rot_errs):.2f}  max={np.max(rot_errs):.2f}  min={np.min(rot_errs):.2f}")
        print(f"PnP inliers:")
        print(f"  mean={np.mean(inliers):.0f}  max={np.max(inliers)}  min={np.min(inliers)}")
        print(f"特征匹配数:")
        print(f"  mean={np.mean(matches):.0f}  max={np.max(matches)}  min={np.min(matches)}")

        # 精度分级
        n_excellent = len([e for e in errs if e < 0.05])
        n_good = len([e for e in errs if 0.05 <= e < 0.1])
        n_fair = len([e for e in errs if 0.1 <= e < 0.5])
        n_poor = len([e for e in errs if e >= 0.5])
        print(f"\n精度分级:")
        print(f"  优秀 (err<0.05): {n_excellent}")
        print(f"  良好 (0.05≤err<0.1): {n_good}")
        print(f"  一般 (0.1≤err<0.5): {n_fair}")
        print(f"  较差 (err≥0.5): {n_poor}")

        if np.mean(errs) < 0.1:
            print("\n✅ 整体定位精度良好")
        elif np.mean(errs) < 0.5:
            print("\n⚠️ 整体有一定偏差")
        else:
            print("\n❌ 整体偏差较大")

    # 保存详细结果到 JSON
    report_path = os.path.join(OUT_DIR, "results.json")
    with open(report_path, "w") as f:
        json.dump({
            "summary": {
                "total_frames": total,
                "localized_ok": n_ok,
                "pnp_failed": n_pnp_fail,
                "few_matches": n_few_match,
                "few_features": n_few_feat,
                "success_rate": n_ok / total if total > 0 else 0,
                "mean_s2a_err": float(np.mean([r["s2a_err"] for r in ok_results])) if ok_results else None,
                "mean_t_err": float(np.mean([r["t_err"] for r in ok_results])) if ok_results else None,
                "mean_rot_err": float(np.mean([r["rot_err"] for r in ok_results])) if ok_results else None,
                "elapsed_seconds": elapsed,
            },
            "frames": results
        }, f, indent=2, ensure_ascii=False)
    print(f"\n详细结果: {report_path}")
    print(f"可视化输出: {OUT_DIR}/")
    print(f"耗时: {elapsed:.1f}s")


if __name__ == "__main__":
    main()
