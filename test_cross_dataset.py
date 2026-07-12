#!/usr/bin/env python3
"""
跨数据集定位测试：data1 扫描图像 vs data3 features.db

模拟真实设备场景：用不同扫描 session 的图像去定位 data3 的特征数据库。
  - data1: 64帧, 1920x1440, fx=fy=1588.85 (2026-03-23 扫描)
  - data3: features.db + optimized.glb (2026-03-24 扫描)

流程：
  1. 加载 data1 扫描帧（images/ + poses.json + intrinsics.json）
  2. 加载 data3 的 features.db（keyframe 位姿 + 2D/3D 特征 + ORB 描述子）
  3. 加载 data3 的 optimized.glb（用于可视化叠加）
  4. 对每帧 data1 图像：
     a. ORB 特征提取
     b. 与 data3 DB 中所有 keyframe 做 BFMatcher Hamming 匹配
     c. 选最佳匹配 keyframe，用匹配的 3D-2D 做 PnP
     d. PnP → flip(Y,Z) → w2c_native
     e. scanToAR = data1_scan_pose × w2c_native
     f. 评估 scanToAR 误差
  5. 生成红绿线叠加图（绿=GT, 红=PnP链路）
  6. 输出 JSON 报告

输出: debug/round10_cross_dataset/
"""
import json, struct, os, time
import numpy as np
import cv2
import trimesh
import sqlite3

# === 路径配置 ===
DATA1_SCAN_DIR = "data/data1/scan_20260323_170907"
ASSET_DIR = "unity_project/Assets/StreamingAssets/SLAMTestAssets"
GLB_PATH = os.path.join(ASSET_DIR, "optimized.glb")
DB_PATH = os.path.join(ASSET_DIR, "features.db")
OUT_DIR = "debug/round13_cross_dataset_optimized_v3"
os.makedirs(OUT_DIR, exist_ok=True)

# PnP 参数
PNP_REPROJ_ERROR = 12.0
PNP_CONFIDENCE = 0.99
PNP_ITERATIONS = 300
PNP_MIN_INLIERS = 8

# 特征匹配参数
ORB_FEATURES = 3000          # 2000→3000: 提取更多特征点，增加跨 session 匹配机会
MATCH_RATIO_THRESH = 0.75
MIN_MATCHES_FOR_PNP = 10     # 12→10: 略微放宽，让更多帧进入 PnP
MULTI_KF_TOP_K = 5           # 3→5: 聚合更多 keyframe 的匹配
CROSSCHECK_FALLBACK = False   # 关闭 fallback，保持严格交叉验证

# 可视化：每 N 帧输出一张（0=全部）
VIS_INTERVAL = 3


def compute_alignment_transform(s2a_matrices):
    """
    从成功帧的 scanToAR 矩阵中计算对齐变换（带离群帧剔除）。

    两轮策略：先算初始平均，剔除离群帧（median + 2*MAD），再重新计算。

    Args:
        s2a_matrices: list of (4, 4) numpy arrays — 成功帧的 scanToAR 矩阵
    Returns:
        alignment_transform: (4, 4) 刚体变换矩阵
    """
    if len(s2a_matrices) < 3:
        print(f"  ⚠️ 对齐失败：成功帧不足 ({len(s2a_matrices)} < 3)，回退到无对齐模式")
        return np.eye(4)

    def _avg_s2a(matrices):
        R_sum = np.zeros((3, 3), dtype=np.float64)
        t_sum = np.zeros(3, dtype=np.float64)
        for s2a in matrices:
            R_sum += s2a[:3, :3]
            t_sum += s2a[:3, 3]
        n = len(matrices)
        U, S, Vt = np.linalg.svd(R_sum / n)
        R_proj = U @ Vt
        if np.linalg.det(R_proj) < 0:
            Vt[-1, :] *= -1
            R_proj = U @ Vt
        T = np.eye(4)
        T[:3, :3] = R_proj
        T[:3, 3] = t_sum / n
        return T

    T_avg = _avg_s2a(s2a_matrices)
    errs = [np.linalg.norm(s2a - T_avg) for s2a in s2a_matrices]
    median_err = np.median(errs)
    mad = np.median([abs(e - median_err) for e in errs])
    threshold = median_err + 2.0 * max(mad, 0.05)

    inlier_matrices = [s2a for s2a, e in zip(s2a_matrices, errs) if e <= threshold]
    if len(inlier_matrices) >= 3 and len(inlier_matrices) < len(s2a_matrices):
        T_avg = _avg_s2a(inlier_matrices)

    return np.linalg.inv(T_avg)


def load_scan_data(scan_dir):
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


def match_against_all_keyframes(query_descs, db_kfs, ratio_thresh):
    """对所有 DB keyframe 做匹配，聚合 top-K keyframe 的匹配后做 PnP"""
    bf = cv2.BFMatcher(cv2.NORM_HAMMING)

    # Score each keyframe by forward Lowe ratio match count
    kf_scores = []
    for kf_id, kf in db_kfs.items():
        if len(kf["descriptors"]) < 10:
            continue
        try:
            raw = bf.knnMatch(query_descs, kf["descriptors"], k=2)
        except cv2.error:
            continue
        good = []
        for pair in raw:
            if len(pair) == 2:
                m, n = pair
                if m.distance < ratio_thresh * n.distance:
                    good.append(m)
        kf_scores.append((kf_id, len(good), good))

    kf_scores.sort(key=lambda x: x[1], reverse=True)

    # 聚合 top-K keyframe 的匹配（去重 query 描述子，保留最佳匹配）
    aggregated_pts3d = []
    aggregated_pts2d_idx = []  # query keypoint index
    used_query_idx = set()
    agg_kf_ids = []

    for kf_id, score, good_matches in kf_scores[:MULTI_KF_TOP_K]:
        if score < 5:
            continue
        kf = db_kfs[kf_id]

        # Cross-check for this keyframe
        try:
            reverse_raw = bf.knnMatch(kf["descriptors"], query_descs, k=2)
        except cv2.error:
            continue
        reverse_map = {}
        for pair in reverse_raw:
            if len(pair) == 2:
                m, n = pair
                if m.distance < ratio_thresh * n.distance:
                    reverse_map[m.queryIdx] = m.trainIdx

        for m in good_matches:
            q_idx, t_idx = m.queryIdx, m.trainIdx
            # Cross-check
            if t_idx not in reverse_map or reverse_map[t_idx] != q_idx:
                if not CROSSCHECK_FALLBACK:
                    continue
                # Fallback: 交叉验证失败但单向匹配距离足够小（< 50 Hamming），仍保留
                if m.distance >= 50:
                    continue
            # 去重：每个 query 描述子只用一次（保留第一个匹配到的 keyframe）
            if q_idx in used_query_idx:
                continue
            if t_idx < len(kf["pts3d"]):
                aggregated_pts3d.append(kf["pts3d"][t_idx])
                aggregated_pts2d_idx.append(q_idx)
                used_query_idx.add(q_idx)

        agg_kf_ids.append(kf_id)

    best_kf_id = kf_scores[0][0] if kf_scores else None
    best_matches = list(zip(aggregated_pts2d_idx, range(len(aggregated_pts3d))))

    return best_kf_id, best_matches, aggregated_pts3d, agg_kf_ids


def do_pnp_flip(pts3d, pts2d, K):
    if len(pts3d) < PNP_MIN_INLIERS:
        return None, 0
    ok, rvec, tvec, inliers = cv2.solvePnPRansac(
        pts3d.astype(np.float32), pts2d.astype(np.float32),
        K.astype(np.float32), None,
        iterationsCount=PNP_ITERATIONS,
        reprojectionError=PNP_REPROJ_ERROR,
        confidence=PNP_CONFIDENCE)
    if not ok or inliers is None or len(inliers) < PNP_MIN_INLIERS:
        return None, 0 if inliers is None else len(inliers)
    R, _ = cv2.Rodrigues(rvec)
    t = tvec.flatten()
    flip = np.diag([1.0, -1.0, -1.0])
    w2c = np.eye(4)
    w2c[:3, :3] = flip @ R
    w2c[:3, 3] = flip @ t
    return w2c, len(inliers)


def project_verts(verts, c2w, K):
    w2c = np.linalg.inv(c2w)
    cam = (w2c[:3, :3] @ verts.T).T + w2c[:3, 3]
    cv_cam = cam.copy()
    cv_cam[:, 1] = -cam[:, 1]
    cv_cam[:, 2] = -cam[:, 2]
    vis = cv_cam[:, 2] > 0.01
    z = cv_cam[:, 2].copy(); z[z == 0] = 1e-9
    p2d = np.zeros((len(verts), 2))
    p2d[:, 0] = K[0, 0] * cv_cam[:, 0] / z + K[0, 2]
    p2d[:, 1] = K[1, 1] * cv_cam[:, 1] / z + K[1, 2]
    return p2d, vis


def draw_edges(img, mesh, pts2d, vis, color, thick=1):
    cnt = 0
    for e in mesh.edges_unique:
        i, j = e
        if not vis[i] or not vis[j]: continue
        x1, y1 = int(pts2d[i, 0]), int(pts2d[i, 1])
        x2, y2 = int(pts2d[j, 0]), int(pts2d[j, 1])
        if abs(x1) > 4000 or abs(y1) > 4000 or abs(x2) > 4000 or abs(y2) > 4000: continue
        cv2.line(img, (x1, y1), (x2, y2), color, thick, cv2.LINE_AA)
        cnt += 1
    return cnt


def render_overlay(img, mesh, verts, K, scan_c2w, w2c_native, frame_idx,
                   n_matches, n_inliers, kf_id):
    result = img.copy()
    h, w = result.shape[:2]

    # 绿色: GT — 用 data1 scan pose 直接投影 data3 mesh
    pts_gt, vis_gt = project_verts(verts, scan_c2w, K)
    g = draw_edges(result, mesh, pts_gt, vis_gt, (0, 255, 0), 1)

    # 红色: PnP+flip+scanToAR 链路
    r = 0
    s2a_info = "PnP FAILED"
    if w2c_native is not None:
        s2a = scan_c2w @ w2c_native
        vh = np.hstack([verts, np.ones((len(verts), 1))])
        v_ar = (s2a @ vh.T).T[:, :3]
        pts_pnp, vis_pnp = project_verts(v_ar, scan_c2w, K)
        r = draw_edges(result, mesh, pts_pnp, vis_pnp, (0, 0, 255), 1)
        err = np.linalg.norm(s2a - np.eye(4))
        t = s2a[:3, 3]
        s2a_info = f"s2a_err={err:.4f} t=({t[0]:+.4f},{t[1]:+.4f},{t[2]:+.4f})"

    cv2.putText(result, f"data1 Frame {frame_idx:03d} -> data3 KF{kf_id}  "
                f"matches={n_matches} inliers={n_inliers}",
                (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)
    cv2.putText(result, f"GREEN=GT({g}) RED=PnP({r})",
                (10, 60), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)
    cv2.putText(result, s2a_info,
                (10, 90), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 2)

    # 图例
    cv2.rectangle(result, (w - 320, 10), (w - 10, 70), (0, 0, 0), -1)
    cv2.line(result, (w - 310, 30), (w - 260, 30), (0, 255, 0), 2)
    cv2.putText(result, "GT (data1 pose)", (w - 250, 35),
                cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 0), 1)
    cv2.line(result, (w - 310, 55), (w - 260, 55), (0, 0, 255), 2)
    cv2.putText(result, "PnP (data3 DB)", (w - 250, 60),
                cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 255), 1)
    return result


def main():
    print("=" * 70)
    print("跨数据集定位测试: data1 图像 vs data3 features.db")
    print("=" * 70)
    t0 = time.time()

    # 1. 加载 data1 扫描数据
    intrinsics, frames = load_scan_data(DATA1_SCAN_DIR)
    fx, fy = intrinsics["fx"], intrinsics["fy"]
    cx, cy = intrinsics["cx"], intrinsics["cy"]
    K = np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1]], dtype=np.float64)
    print(f"data1 内参: fx={fx:.1f} fy={fy:.1f} cx={cx:.1f} cy={cy:.1f}")
    print(f"data1 帧数: {len(frames)}")

    # 2. 加载 data3 GLB
    scene = trimesh.load(GLB_PATH)
    mesh = trimesh.util.concatenate(scene.geometry.values()) if isinstance(scene, trimesh.Scene) else scene
    verts = np.array(mesh.vertices, dtype=np.float64)
    print(f"data3 GLB: {len(verts)} verts, {len(mesh.faces)} faces")

    # 3. 加载 data3 features.db
    db_kfs = load_db_keyframes(DB_PATH)
    total_feat = sum(len(kf["descriptors"]) for kf in db_kfs.values())
    print(f"data3 DB: {len(db_kfs)} keyframes, {total_feat} 总特征")

    # 4. ORB 检测器
    orb = cv2.ORB_create(nfeatures=ORB_FEATURES)

    print(f"\n开始跨数据集逐帧定位...")
    print("-" * 70)

    results = []
    for i, frame in enumerate(frames):
        idx = frame["index"]
        c2w = frame["c2w"]

        # 跳过 identity pose 帧（tracking 未就绪）
        if np.allclose(c2w, np.eye(4), atol=1e-6):
            print(f"  Frame {idx:03d}: ⏭️  identity pose, 跳过")
            results.append({"frame": idx, "status": "identity_skip"})
            continue

        img = cv2.imread(frame["img_path"])
        if img is None:
            results.append({"frame": idx, "status": "img_error"})
            continue

        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        # CLAHE 预处理：减少跨 session 光照差异对 ORB 的影响
        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        gray = clahe.apply(gray)
        kps, descs = orb.detectAndCompute(gray, None)
        if descs is None or len(kps) < 10:
            print(f"  Frame {idx:03d}: ❌ 特征不足 ({0 if descs is None else len(kps)})")
            results.append({"frame": idx, "status": "few_features",
                            "n_features": 0 if descs is None else len(kps)})
            continue

        # 对所有 DB keyframe 做匹配（多候选聚合）
        best_kf_id, good_matches, agg_pts3d, agg_kf_ids = match_against_all_keyframes(
            descs, db_kfs, MATCH_RATIO_THRESH)

        n_matches = len(good_matches)
        if best_kf_id is None or n_matches < MIN_MATCHES_FOR_PNP:
            print(f"  Frame {idx:03d}: ⚠️  匹配不足 matches={n_matches}")
            results.append({"frame": idx, "status": "few_matches",
                            "n_features": len(kps), "n_matches": n_matches})
            continue

        matched_pts3d = np.array(agg_pts3d, dtype=np.float32)
        matched_pts2d = np.array([kps[m[0]].pt for m in good_matches], dtype=np.float32)

        w2c_native, n_inliers = do_pnp_flip(matched_pts3d, matched_pts2d, K)

        if w2c_native is None:
            print(f"  Frame {idx:03d}: ⚠️  PnP 失败 kf={best_kf_id} matches={n_matches} inliers={n_inliers}")
            results.append({"frame": idx, "status": "pnp_failed",
                            "n_features": len(kps), "n_matches": n_matches,
                            "n_inliers": n_inliers, "kf_id": best_kf_id})
            continue

        # Inlier ratio quality gate
        inlier_ratio = n_inliers / n_matches if n_matches > 0 else 0.0
        MIN_INLIER_RATIO = 0.15
        if inlier_ratio < MIN_INLIER_RATIO:
            print(f"  Frame {idx:03d}: ⚠️  PnP rejected (inlier_ratio={inlier_ratio:.1%} < {MIN_INLIER_RATIO:.0%}) kf={best_kf_id}")
            results.append({"frame": idx, "status": "pnp_rejected",
                            "n_features": len(kps), "n_matches": n_matches,
                            "n_inliers": n_inliers, "kf_id": best_kf_id,
                            "inlier_ratio": inlier_ratio})
            continue

        # scanToAR = data1_c2w × w2c_native
        s2a = c2w @ w2c_native
        s2a_err = np.linalg.norm(s2a - np.eye(4))
        t_err = np.linalg.norm(s2a[:3, 3])
        R_s2a = s2a[:3, :3]
        rot_err = np.degrees(np.arccos(np.clip((np.trace(R_s2a) - 1) / 2, -1, 1)))

        inlier_ratio_val = n_inliers / n_matches if n_matches > 0 else 0.0
        icon = "✅" if s2a_err < 0.5 else ("⚠️" if s2a_err < 2.0 else "❌")
        print(f"  Frame {idx:03d}: {icon} kf={best_kf_id} matches={n_matches} "
              f"inliers={n_inliers} inlier_ratio={inlier_ratio_val:.1%} s2a={s2a_err:.4f} t={t_err:.4f}m rot={rot_err:.2f}°")

        results.append({
            "frame": idx, "status": "ok",
            "n_features": len(kps), "n_matches": n_matches,
            "n_inliers": n_inliers, "kf_id": best_kf_id,
            "s2a_err": float(s2a_err), "t_err": float(t_err), "rot_err": float(rot_err),
            "inlier_ratio": float(inlier_ratio_val),
            "w2c_native": w2c_native, "c2w": c2w,
        })

        # 可视化
        if VIS_INTERVAL == 0 or i % VIS_INTERVAL == 0:
            vis = render_overlay(img, mesh, verts, K, c2w, w2c_native,
                                 idx, n_matches, n_inliers, best_kf_id)
            cv2.imwrite(os.path.join(OUT_DIR, f"frame_{idx:03d}.jpg"), vis,
                        [cv2.IMWRITE_JPEG_QUALITY, 85])

    # === 坐标系对齐 (方案 B) ===
    ok_frames = [r for r in results if r["status"] == "ok"]
    if ok_frames:
        # 提取成功帧的 s2a 矩阵计算对齐变换
        s2a_matrices = [r["c2w"] @ r["w2c_native"] for r in ok_frames]

        AT = compute_alignment_transform(s2a_matrices)

        # 计算对齐后的 s2a_err
        print(f"\n[坐标系对齐] 使用 {len(ok_frames)} 个成功帧计算 Alignment_Transform")
        for r in ok_frames:
            s2a_aligned = AT @ r["c2w"] @ r["w2c_native"]
            r["s2a_err_aligned"] = float(np.linalg.norm(s2a_aligned - np.eye(4)))
            R_aligned = s2a_aligned[:3, :3]
            r["rot_err_aligned"] = float(np.degrees(np.arccos(
                np.clip((np.trace(R_aligned) - 1) / 2, -1, 1))))
            r["t_err_aligned"] = float(np.linalg.norm(s2a_aligned[:3, 3]))

        aligned_errs = [r["s2a_err_aligned"] for r in ok_frames]
        unaligned_errs = [r["s2a_err"] for r in ok_frames]
        print(f"  对齐前 s2a_err: mean={np.mean(unaligned_errs):.4f}  max={np.max(unaligned_errs):.4f}")
        print(f"  对齐后 s2a_err: mean={np.mean(aligned_errs):.4f}  max={np.max(aligned_errs):.4f}")

        if np.mean(aligned_errs) >= 0.5:
            # 输出诊断信息
            R_at = AT[:3, :3]
            t_at = AT[:3, 3]
            rot_angle = np.degrees(np.arccos(np.clip((np.trace(R_at) - 1) / 2, -1, 1)))
            t_mag = np.linalg.norm(t_at)
            print(f"  ⚠️ 对齐后 s2a_err 均值 >= 0.5，诊断信息:")
            print(f"    AT 旋转角度: {rot_angle:.2f}°")
            print(f"    AT 平移量: {t_mag:.4f}m")
            print(f"    AT 平移向量: ({t_at[0]:+.4f}, {t_at[1]:+.4f}, {t_at[2]:+.4f})")
    else:
        AT = np.eye(4)

    # 清理 results 中的 numpy 对象（不序列化到 JSON）
    for r in results:
        r.pop("w2c_native", None)
        r.pop("c2w", None)

    # === 汇总 ===
    elapsed = time.time() - t0
    total = len(results)
    ok = [r for r in results if r["status"] == "ok"]
    n_ok = len(ok)
    n_skip = len([r for r in results if r["status"] == "identity_skip"])
    n_pnp_fail = len([r for r in results if r["status"] == "pnp_failed"])
    n_pnp_reject = len([r for r in results if r["status"] == "pnp_rejected"])
    n_few_match = len([r for r in results if r["status"] == "few_matches"])
    n_few_feat = len([r for r in results if r["status"] == "few_features"])

    print()
    print("=" * 70)
    print("汇总")
    print("=" * 70)
    print(f"总帧数: {total} (跳过 identity: {n_skip})")
    tested = total - n_skip
    print(f"有效帧: {tested}")
    print(f"定位成功: {n_ok}/{tested} ({100*n_ok/tested:.1f}%)" if tested > 0 else "无有效帧")
    if n_pnp_fail: print(f"PnP 失败: {n_pnp_fail}")
    if n_pnp_reject: print(f"PnP 拒绝 (inlier ratio 过低): {n_pnp_reject}")
    if n_few_match: print(f"匹配不足: {n_few_match}")
    if n_few_feat: print(f"特征不足: {n_few_feat}")

    if ok:
        errs = [r["s2a_err"] for r in ok]
        t_errs = [r["t_err"] for r in ok]
        rot_errs = [r["rot_err"] for r in ok]
        inliers = [r["n_inliers"] for r in ok]
        matches = [r["n_matches"] for r in ok]
        print(f"\nscanToAR 误差:")
        print(f"  mean={np.mean(errs):.4f}  max={np.max(errs):.4f}  min={np.min(errs):.4f}")
        print(f"平移误差 (m):")
        print(f"  mean={np.mean(t_errs):.4f}  max={np.max(t_errs):.4f}")
        print(f"旋转误差 (°):")
        print(f"  mean={np.mean(rot_errs):.2f}  max={np.max(rot_errs):.2f}")
        print(f"匹配数: mean={np.mean(matches):.0f}  inliers: mean={np.mean(inliers):.0f}")
        inlier_ratios = [r["inlier_ratio"] for r in ok]
        print(f"Inlier ratio:")
        print(f"  mean={np.mean(inlier_ratios):.1%}  max={np.max(inlier_ratios):.1%}  min={np.min(inlier_ratios):.1%}")

        n_good = len([e for e in errs if e < 0.5])
        n_fair = len([e for e in errs if 0.5 <= e < 2.0])
        n_poor = len([e for e in errs if e >= 2.0])
        print(f"\n精度分级 (未对齐):")
        print(f"  良好 (err<0.5): {n_good}")
        print(f"  一般 (0.5≤err<2.0): {n_fair}")
        print(f"  较差 (err≥2.0): {n_poor}")

        # 对齐后统计
        if ok[0].get("s2a_err_aligned") is not None:
            aligned_errs = [r["s2a_err_aligned"] for r in ok]
            aligned_rot = [r["rot_err_aligned"] for r in ok]
            aligned_t = [r["t_err_aligned"] for r in ok]
            print(f"\n对齐后 scanToAR 误差:")
            print(f"  mean={np.mean(aligned_errs):.4f}  max={np.max(aligned_errs):.4f}  min={np.min(aligned_errs):.4f}")
            print(f"对齐后平移误差 (m):")
            print(f"  mean={np.mean(aligned_t):.4f}  max={np.max(aligned_t):.4f}")
            print(f"对齐后旋转误差 (°):")
            print(f"  mean={np.mean(aligned_rot):.2f}  max={np.max(aligned_rot):.2f}")

            n_good_a = len([e for e in aligned_errs if e < 0.5])
            n_fair_a = len([e for e in aligned_errs if 0.5 <= e < 2.0])
            n_poor_a = len([e for e in aligned_errs if e >= 2.0])
            print(f"\n精度分级 (对齐后):")
            print(f"  良好 (err<0.5): {n_good_a}")
            print(f"  一般 (0.5≤err<2.0): {n_fair_a}")
            print(f"  较差 (err≥2.0): {n_poor_a}")

            if np.mean(aligned_errs) < 0.5:
                print("\n✅ 对齐后跨数据集定位精度良好")
            elif np.mean(aligned_errs) < 2.0:
                print("\n⚠️ 对齐后仍有一定偏差")
            else:
                print("\n❌ 对齐后偏差仍较大")
        else:
            if np.mean(errs) < 0.5:
                print("\n✅ 跨数据集定位精度良好")
            elif np.mean(errs) < 2.0:
                print("\n⚠️ 跨数据集有一定偏差（可能是不同场景或坐标系差异）")
            else:
                print("\n❌ 跨数据集定位偏差较大（可能是不同物理空间）")

    # JSON 报告
    report = os.path.join(OUT_DIR, "results.json")
    summary_data = {
        "total_frames": total,
        "identity_skipped": n_skip,
        "tested": tested,
        "localized_ok": n_ok,
        "pnp_rejected": n_pnp_reject,
        "success_rate": n_ok / tested if tested > 0 else 0,
        "mean_s2a_err": float(np.mean([r["s2a_err"] for r in ok])) if ok else None,
        "mean_t_err": float(np.mean([r["t_err"] for r in ok])) if ok else None,
        "mean_rot_err": float(np.mean([r["rot_err"] for r in ok])) if ok else None,
        "mean_inlier_ratio": float(np.mean([r["inlier_ratio"] for r in ok])) if ok else None,
        "elapsed_s": elapsed,
    }
    if ok and ok[0].get("s2a_err_aligned") is not None:
        summary_data["mean_s2a_err_aligned"] = float(np.mean([r["s2a_err_aligned"] for r in ok]))
        summary_data["mean_t_err_aligned"] = float(np.mean([r["t_err_aligned"] for r in ok]))
        summary_data["mean_rot_err_aligned"] = float(np.mean([r["rot_err_aligned"] for r in ok]))
    with open(report, "w") as f:
        json.dump({
            "config": {
                "data1_scan": DATA1_SCAN_DIR,
                "data3_db": DB_PATH,
                "data3_glb": GLB_PATH,
                "orb_features": ORB_FEATURES,
                "match_ratio": MATCH_RATIO_THRESH,
                "pnp_reproj_err": PNP_REPROJ_ERROR,
            },
            "summary": summary_data,
            "frames": results
        }, f, indent=2, ensure_ascii=False)

    print(f"\n报告: {report}")
    print(f"可视化: {OUT_DIR}/")
    print(f"耗时: {elapsed:.1f}s")


if __name__ == "__main__":
    main()
