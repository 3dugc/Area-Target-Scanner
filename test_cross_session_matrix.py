#!/usr/bin/env python3
"""
跨 Session 定位全排列 Baseline 测试

data1/data2/data3 三个数据集之间的所有跨 session 组合（6 个方向）+ 3 个同 session 自洽。
记录当前成功率和 s2a_err 作为优化前的 baseline。

输出: debug/round14_cross_session_matrix/
"""
import json, struct, os, sys, time
import numpy as np
import cv2
import sqlite3

# === 数据集配置 ===
# 区域 A: data1, data2, data3（同一物理空间）
# 区域 B: data4, data5（另一物理空间）
DATASETS = {
    "data1": {
        "scan_dir": "data/data1/scan_20260325_104732",
        "mesh_path": "data/data1/scan_20260325_104732/model.obj",
        "db_path": "data/data1/features.db",
        "region": "A",
    },
    "data2": {
        "scan_dir": "data/data2/scan_20260323_175533/scan_20260323_175533",
        "mesh_path": "data/data2/scan_20260323_175533/scan_20260323_175533/model.obj",
        "db_path": "data/data2/features.db",
        "region": "A",
    },
    "data3": {
        "scan_dir": "data/data3/scan_20260324_142133",
        "mesh_path": "data/data3/scan_20260324_142133/model.obj",
        "db_path": "unity_project/Assets/StreamingAssets/SLAMTestAssets/features.db",
        "region": "A",
    },
    "data4": {
        "scan_dir": "data/data4/scan_20260325_112038",
        "mesh_path": "data/data4/scan_20260325_112038/model.obj",
        "db_path": "data/data4/features.db",
        "region": "B",
    },
    "data5": {
        "scan_dir": "data/data5/scan_20260325_114342",
        "mesh_path": "data/data5/scan_20260325_114342/model.obj",
        "db_path": "data/data5/features.db",
        "region": "B",
    },
}

OUT_DIR = "debug/round20_consistency_filter"
os.makedirs(OUT_DIR, exist_ok=True)

# 匹配参数（与当前 test_cross_dataset.py 一致）
ORB_FEATURES = 3000
MATCH_RATIO_THRESH = 0.75
MIN_MATCHES_FOR_PNP = 10
PNP_REPROJ_ERROR = 12.0
PNP_CONFIDENCE = 0.99
PNP_ITERATIONS = 300
PNP_MIN_INLIERS = 8
MIN_INLIER_RATIO = 0.15
MULTI_KF_TOP_K = 5


def compute_alignment_transform(s2a_matrices):
    """
    从成功帧的 scanToAR 矩阵中计算对齐变换（带离群帧剔除）。

    理想情况下 s2a = c2w @ w2c_native = I。如果有系统性坐标系偏差，
    大部分成功帧的 s2a 接近同一个矩阵 T。

    使用两轮策略：
    1. 先用所有帧计算初始 T_avg
    2. 剔除与 T_avg 偏差过大的离群帧（s2a_err > median + 2*MAD）
    3. 用剩余帧重新计算 T_avg

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
        R_avg = R_sum / n
        t_avg = t_sum / n
        U, S, Vt = np.linalg.svd(R_avg)
        R_proj = U @ Vt
        if np.linalg.det(R_proj) < 0:
            Vt[-1, :] *= -1
            R_proj = U @ Vt
        T = np.eye(4)
        T[:3, :3] = R_proj
        T[:3, 3] = t_avg
        return T

    # Round 1: 初始平均
    T_avg = _avg_s2a(s2a_matrices)

    # 计算每帧与 T_avg 的偏差
    errs = [np.linalg.norm(s2a - T_avg) for s2a in s2a_matrices]
    median_err = np.median(errs)
    mad = np.median([abs(e - median_err) for e in errs])
    threshold = median_err + 2.0 * max(mad, 0.05)  # 至少 0.05 的容忍度

    # Round 2: 剔除离群帧后重新计算
    inlier_matrices = [s2a for s2a, e in zip(s2a_matrices, errs) if e <= threshold]
    n_outliers = len(s2a_matrices) - len(inlier_matrices)

    if len(inlier_matrices) < 3:
        # 离群帧太多，回退到全部帧
        AT = np.linalg.inv(T_avg)
        return AT

    if n_outliers > 0:
        T_avg = _avg_s2a(inlier_matrices)

    AT = np.linalg.inv(T_avg)
    return AT


def rescue_outlier_frames(results, AT):
    """
    离群帧救回：用已计算的 Alignment_Transform 反向验证被一致性过滤剔除的 pnp_outlier 帧。
    对齐后 s2a_err_aligned < 0.5 的帧救回为 ok_rescued，否则保持 pnp_outlier。
    救回后用所有成功帧（ok + ok_rescued）重新计算 AT，验证对齐精度未退化。

    Args:
        results: 定位结果列表（含 pnp_outlier 帧的 c2w 和 w2c_native）
        AT: 4×4 Alignment_Transform
    Returns:
        new_AT: 重算后的 AT（若有救回帧），否则返回原 AT
        rescued_count: 救回的帧数
    """
    RESCUE_THRESHOLD = 0.5

    outliers = [r for r in results if r["status"] == "pnp_outlier"]
    n_checked = len(outliers)
    if n_checked == 0:
        print(f"    救回统计: 无离群帧需要检查")
        return AT, 0

    rescued = []
    for r in outliers:
        s2a_aligned = AT @ r["c2w"] @ r["w2c_native"]
        err = float(np.linalg.norm(s2a_aligned - np.eye(4)))
        if err < RESCUE_THRESHOLD:
            r["status"] = "ok_rescued"
            r["s2a_err_aligned"] = err
            # 计算对齐后旋转误差
            R_aligned = s2a_aligned[:3, :3]
            r["rot_err_aligned"] = float(np.degrees(np.arccos(
                np.clip((np.trace(R_aligned) - 1) / 2, -1, 1))))
            rescued.append(r)

    rescued_count = len(rescued)
    mean_rescued_err = np.mean([r["s2a_err_aligned"] for r in rescued]) if rescued else float("nan")
    print(f"    救回统计: 检查 {n_checked} 帧, 救回 {rescued_count} 帧, "
          f"救回帧平均 s2a_err_aligned={mean_rescued_err:.4f}")

    # 救回后用所有成功帧（ok + ok_rescued）重新计算 AT
    success_frames = [r for r in results if r["status"] in ("ok", "ok_rescued")]
    if len(success_frames) >= 3:
        s2a_matrices = [r["c2w"] @ r["w2c_native"] for r in success_frames]
        new_AT = compute_alignment_transform(s2a_matrices)

        # 验证重算后对齐精度未退化
        errs_after = []
        for r in success_frames:
            s2a_aligned = new_AT @ r["c2w"] @ r["w2c_native"]
            err = float(np.linalg.norm(s2a_aligned - np.eye(4)))
            errs_after.append(err)
        mean_err_after = np.mean(errs_after)

        if mean_err_after < 0.2:
            print(f"    重算 AT 后对齐精度: s2a_err 均值={mean_err_after:.4f} (< 0.2 ✅)")
            # 用新 AT 更新所有成功帧的对齐误差
            for r, err in zip(success_frames, errs_after):
                r["s2a_err_aligned"] = err
                s2a_aligned = new_AT @ r["c2w"] @ r["w2c_native"]
                R_aligned = s2a_aligned[:3, :3]
                r["rot_err_aligned"] = float(np.degrees(np.arccos(
                    np.clip((np.trace(R_aligned) - 1) / 2, -1, 1))))
            return new_AT, rescued_count
        else:
            print(f"    ⚠️ 重算 AT 后对齐精度退化: s2a_err 均值={mean_err_after:.4f} (>= 0.2)")
            # 精度退化，回退救回操作
            for r in rescued:
                r["status"] = "pnp_outlier"
                r.pop("s2a_err_aligned", None)
                r.pop("rot_err_aligned", None)
            print(f"    回退救回操作，保持原 AT")
            return AT, 0

    return AT, rescued_count


def load_scan_data(scan_dir):
    """加载扫描数据（内参 + 帧列表）"""
    intrinsics = json.load(open(os.path.join(scan_dir, "intrinsics.json")))
    poses_data = json.load(open(os.path.join(scan_dir, "poses.json")))
    frames = []
    for f in poses_data["frames"]:
        c2w = np.array(f["transform"], dtype=np.float64).reshape(4, 4, order='F')
        img_path = os.path.join(scan_dir, f["imageFile"])
        if not os.path.exists(img_path):
            continue
        if np.allclose(c2w, np.eye(4), atol=1e-6):
            continue  # skip identity pose
        frames.append({"index": f["index"], "c2w": c2w, "img_path": img_path})
    frames.sort(key=lambda x: x["index"])
    return intrinsics, frames


def load_db_keyframes(db_path):
    """从 features.db 加载所有 keyframe 数据（ORB + AKAZE）"""
    db = sqlite3.connect(db_path)
    rows = db.execute("SELECT id, pose FROM keyframes ORDER BY id").fetchall()

    # 检查 akaze_features 表是否存在
    has_akaze_table = db.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='akaze_features'"
    ).fetchone() is not None

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

        # AKAZE 数据（若表存在则加载）
        akaze_pts2d, akaze_pts3d, akaze_descriptors = None, None, None
        if has_akaze_table:
            akaze_rows = db.execute(
                "SELECT x, y, x3d, y3d, z3d, descriptor FROM akaze_features WHERE keyframe_id=?",
                (kf_id,)).fetchall()
            if akaze_rows:
                akaze_pts2d = np.array([(f[0], f[1]) for f in akaze_rows], dtype=np.float32)
                akaze_pts3d = np.array([(f[2], f[3], f[4]) for f in akaze_rows], dtype=np.float32)
                akaze_descriptors = np.array([
                    np.frombuffer(f[5], dtype=np.uint8) for f in akaze_rows
                ], dtype=np.uint8)

        kfs[kf_id] = {
            "c2w": pose, "pts2d": pts2d, "pts3d": pts3d, "descriptors": descs,
            "akaze_pts2d": akaze_pts2d, "akaze_pts3d": akaze_pts3d,
            "akaze_descriptors": akaze_descriptors,
        }
    db.close()
    return kfs


def generate_features_db(scan_dir, mesh_path, db_path):
    """用 processing_pipeline 从扫描数据生成 features.db"""
    if os.path.exists(db_path):
        print(f"  features.db 已存在: {db_path}")
        return True
    print(f"  生成 features.db: {db_path} ...")
    try:
        import open3d as o3d
        from processing_pipeline.feature_extraction import build_feature_database
        from processing_pipeline.feature_db import save_feature_database

        intrinsics = json.load(open(os.path.join(scan_dir, "intrinsics.json")))
        poses_data = json.load(open(os.path.join(scan_dir, "poses.json")))

        mesh = o3d.io.read_triangle_mesh(mesh_path)
        if not mesh.has_triangles():
            print(f"  ❌ mesh 无三角面: {mesh_path}")
            return False

        images = []
        for f in poses_data["frames"]:
            c2w = np.array(f["transform"], dtype=np.float64).reshape(4, 4, order='F')
            img_path = os.path.join(scan_dir, f["imageFile"])
            if os.path.exists(img_path) and not np.allclose(c2w, np.eye(4), atol=1e-6):
                images.append({"path": img_path, "pose": c2w})

        db = build_feature_database(images, mesh, intrinsics)
        save_feature_database(db, db_path)
        print(f"  ✅ 生成完成: {len(db.keyframes)} keyframes")
        return True
    except Exception as e:
        print(f"  ❌ 生成失败: {e}")
        return False


def _pnp_solve_and_refine(pts3d, pts2d, K):
    """PnP RANSAC + iterative refinement，返回 (ok, w2c, n_matches, n_inliers, inlier_ratio) 或 None"""
    n_matches = len(pts3d)
    if n_matches < MIN_MATCHES_FOR_PNP:
        return None

    pts3d_arr = np.array(pts3d, dtype=np.float32)
    pts2d_arr = np.array(pts2d, dtype=np.float32)

    ok, rvec, tvec, inliers = cv2.solvePnPRansac(
        pts3d_arr, pts2d_arr, K.astype(np.float32), None,
        iterationsCount=PNP_ITERATIONS, reprojectionError=PNP_REPROJ_ERROR,
        confidence=PNP_CONFIDENCE)

    if not ok or inliers is None or len(inliers) < PNP_MIN_INLIERS:
        n_inliers = 0 if inliers is None else len(inliers)
        return ("pnp_failed", n_matches, n_inliers, 0.0)

    n_inliers = len(inliers)
    inlier_ratio = n_inliers / n_matches if n_matches > 0 else 0
    if inlier_ratio < MIN_INLIER_RATIO:
        return ("pnp_rejected", n_matches, n_inliers, inlier_ratio)

    # PnP refinement: 用 RANSAC inlier 做 iterative PnP
    inlier_idx = inliers.flatten()
    pts3d_inlier = pts3d_arr[inlier_idx]
    pts2d_inlier = pts2d_arr[inlier_idx]
    ok_ref, rvec_ref, tvec_ref = cv2.solvePnP(
        pts3d_inlier, pts2d_inlier, K.astype(np.float32), None,
        rvec=rvec.copy(), tvec=tvec.copy(), useExtrinsicGuess=True,
        flags=cv2.SOLVEPNP_ITERATIVE)
    if ok_ref:
        rvec, tvec = rvec_ref, tvec_ref

    R, _ = cv2.Rodrigues(rvec)
    flip = np.diag([1.0, -1.0, -1.0])
    w2c = np.eye(4)
    w2c[:3, :3] = flip @ R
    w2c[:3, 3] = (flip @ tvec).flatten()

    return ("ok", n_matches, n_inliers, inlier_ratio, w2c)


def _match_and_aggregate(query_descs, query_kps, db_kfs, bf, desc_key="descriptors",
                         pts3d_key="pts3d"):
    """对 query 描述子与 DB keyframes 做 Lowe ratio + 交叉验证 + 多 KF 聚合，
    返回 (agg_pts3d, agg_pts2d) 列表"""
    # Score keyframes by forward Lowe ratio match count
    kf_scores = []
    for kf_id, kf in db_kfs.items():
        kf_descs = kf.get(desc_key)
        if kf_descs is None or len(kf_descs) < 10:
            continue
        try:
            raw = bf.knnMatch(query_descs, kf_descs, k=2)
        except cv2.error:
            continue
        good = [m for pair in raw if len(pair) == 2
                and pair[0].distance < MATCH_RATIO_THRESH * pair[1].distance
                for m in [pair[0]]]
        kf_scores.append((kf_id, len(good), good))

    kf_scores.sort(key=lambda x: x[1], reverse=True)

    # 聚合 top-K keyframe 匹配 + cross-check
    agg_pts3d, agg_pts2d = [], []
    used = set()
    for kf_id, score, good_matches in kf_scores[:MULTI_KF_TOP_K]:
        if score < 5:
            continue
        kf = db_kfs[kf_id]
        kf_descs = kf[desc_key]
        kf_pts3d = kf[pts3d_key]
        try:
            rev = bf.knnMatch(kf_descs, query_descs, k=2)
        except cv2.error:
            continue
        rev_map = {p[0].queryIdx: p[0].trainIdx for p in rev
                   if len(p) == 2 and p[0].distance < MATCH_RATIO_THRESH * p[1].distance}
        for m in good_matches:
            q, t = m.queryIdx, m.trainIdx
            if t not in rev_map or rev_map[t] != q:
                continue
            if q in used:
                continue
            if t < len(kf_pts3d):
                agg_pts3d.append(kf_pts3d[t])
                agg_pts2d.append(query_kps[q].pt)
                used.add(q)

    return agg_pts3d, agg_pts2d


def run_localization(query_frames, query_intrinsics, db_kfs):
    """对查询帧集合 vs DB keyframes 执行定位，返回结果列表。
    ORB 失败帧会尝试 AKAZE fallback（若 DB 有 AKAZE 数据）。"""
    fx, fy = query_intrinsics["fx"], query_intrinsics["fy"]
    cx, cy = query_intrinsics["cx"], query_intrinsics["cy"]
    K = np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1]], dtype=np.float64)

    orb = cv2.ORB_create(nfeatures=ORB_FEATURES)
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    bf = cv2.BFMatcher(cv2.NORM_HAMMING)

    # 检查 DB 是否有 AKAZE 数据（在帧循环外只创建一次 AKAZE 检测器）
    has_akaze_data = any(
        kf.get("akaze_descriptors") is not None for kf in db_kfs.values()
    )
    akaze = cv2.AKAZE_create() if has_akaze_data else None

    results = []
    for frame in query_frames:
        img = cv2.imread(frame["img_path"])
        if img is None:
            results.append({"frame": frame["index"], "status": "img_error"})
            continue

        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        gray = clahe.apply(gray)
        kps, descs = orb.detectAndCompute(gray, None)
        if descs is None or len(kps) < 10:
            results.append({"frame": frame["index"], "status": "few_features"})
            continue

        # --- ORB 匹配 ---
        agg_pts3d, agg_pts2d = _match_and_aggregate(
            descs, kps, db_kfs, bf,
            desc_key="descriptors", pts3d_key="pts3d")

        pnp_result = _pnp_solve_and_refine(agg_pts3d, agg_pts2d, K)

        # ORB 成功
        if pnp_result is not None and pnp_result[0] == "ok":
            _, n_matches, n_inliers, inlier_ratio, w2c = pnp_result
            s2a = frame["c2w"] @ w2c
            s2a_err = float(np.linalg.norm(s2a - np.eye(4)))
            R_s2a = s2a[:3, :3]
            rot_err = float(np.degrees(np.arccos(np.clip((np.trace(R_s2a) - 1) / 2, -1, 1))))
            results.append({
                "frame": frame["index"], "status": "ok", "method": "orb",
                "n_matches": n_matches, "n_inliers": n_inliers,
                "inlier_ratio": inlier_ratio,
                "s2a_err": s2a_err, "rot_err": rot_err,
                "w2c_native": w2c, "c2w": frame["c2w"],
            })
            continue

        # ORB 失败 — 记录失败原因用于判断是否触发 AKAZE
        if pnp_result is None:
            orb_status = "few_matches"
            orb_n_matches = len(agg_pts3d)
            orb_n_inliers = 0
            orb_inlier_ratio = 0.0
        else:
            orb_status = pnp_result[0]
            orb_n_matches = pnp_result[1]
            orb_n_inliers = pnp_result[2]
            orb_inlier_ratio = pnp_result[3]

        # --- AKAZE Fallback ---
        # 仅对 ORB 失败帧（pnp_failed, few_matches, pnp_rejected）触发
        if akaze is not None and orb_status in ("pnp_failed", "few_matches", "pnp_rejected"):
            akaze_kps, akaze_descs = akaze.detectAndCompute(gray, None)
            if akaze_descs is not None and len(akaze_kps) >= 10:
                akaze_agg_pts3d, akaze_agg_pts2d = _match_and_aggregate(
                    akaze_descs, akaze_kps, db_kfs, bf,
                    desc_key="akaze_descriptors", pts3d_key="akaze_pts3d")

                akaze_pnp = _pnp_solve_and_refine(akaze_agg_pts3d, akaze_agg_pts2d, K)

                if akaze_pnp is not None and akaze_pnp[0] == "ok":
                    _, n_matches, n_inliers, inlier_ratio, w2c = akaze_pnp
                    s2a = frame["c2w"] @ w2c
                    s2a_err = float(np.linalg.norm(s2a - np.eye(4)))
                    R_s2a = s2a[:3, :3]
                    rot_err = float(np.degrees(np.arccos(
                        np.clip((np.trace(R_s2a) - 1) / 2, -1, 1))))
                    results.append({
                        "frame": frame["index"], "status": "ok",
                        "method": "akaze_fallback",
                        "n_matches": n_matches, "n_inliers": n_inliers,
                        "inlier_ratio": inlier_ratio,
                        "s2a_err": s2a_err, "rot_err": rot_err,
                        "w2c_native": w2c, "c2w": frame["c2w"],
                    })
                    continue

        # ORB 和 AKAZE 都失败，记录 ORB 的失败状态
        fail_result = {"frame": frame["index"], "status": orb_status,
                       "n_matches": orb_n_matches}
        if orb_status == "pnp_failed":
            fail_result["n_inliers"] = orb_n_inliers
        elif orb_status == "pnp_rejected":
            fail_result["n_inliers"] = orb_n_inliers
            fail_result["inlier_ratio"] = orb_inlier_ratio
        results.append(fail_result)

    return results


def summarize(results, label):
    """汇总并打印结果，分别统计 ORB/AKAZE/rescued 帧数"""
    total = len(results)
    # 成功帧包括 ok 和 ok_rescued
    ok = [r for r in results if r["status"] in ("ok", "ok_rescued")]
    n_ok = len(ok)
    # 按定位方法分类统计
    n_orb = len([r for r in results
                 if r.get("method") == "orb" and r["status"] in ("ok", "ok_rescued")])
    n_akaze = len([r for r in results
                   if r.get("method") == "akaze_fallback" and r["status"] in ("ok", "ok_rescued")])
    n_rescued = len([r for r in results if r["status"] == "ok_rescued"])
    n_failed = total - n_ok
    rate = n_ok / total if total > 0 else 0

    mean_err = np.mean([r["s2a_err"] for r in ok]) if ok else float("nan")
    mean_rot = np.mean([r["rot_err"] for r in ok]) if ok else float("nan")
    mean_ir = np.mean([r["inlier_ratio"] for r in ok]) if ok else float("nan")

    # 对齐后统计
    has_aligned = ok and ok[0].get("s2a_err_aligned") is not None
    mean_err_aligned = np.mean([r["s2a_err_aligned"] for r in ok]) if has_aligned else float("nan")
    mean_rot_aligned = np.mean([r["rot_err_aligned"] for r in ok]) if has_aligned else float("nan")

    status_counts = {}
    for r in results:
        s = r["status"]
        status_counts[s] = status_counts.get(s, 0) + 1

    aligned_info = f" | aligned_s2a={mean_err_aligned:.4f}" if has_aligned else ""
    # 方法分类明细（orb/akaze/rescued/failed）
    method_info = f" (orb={n_orb}, akaze={n_akaze}, rescued={n_rescued})"
    print(f"  {label}: {n_ok}/{total} ({rate:.1%}){method_info} | "
          f"s2a_err={mean_err:.4f}{aligned_info} | rot={mean_rot:.1f}° | "
          f"inlier_ratio={mean_ir:.1%} | failed={n_failed} | {status_counts}")

    if has_aligned and mean_err_aligned >= 0.5:
        print(f"    ⚠️ 对齐后 s2a_err 均值 >= 0.5")

    summary = {
        "label": label, "total": total, "ok": n_ok, "rate": rate,
        "n_orb": n_orb, "n_akaze": n_akaze,
        "n_rescued": n_rescued, "n_failed": n_failed,
        "mean_s2a_err": float(mean_err) if ok else None,
        "mean_rot_err": float(mean_rot) if ok else None,
        "mean_inlier_ratio": float(mean_ir) if ok else None,
        "status_counts": status_counts,
    }
    if has_aligned:
        summary["mean_s2a_err_aligned"] = float(mean_err_aligned)
        summary["mean_rot_err_aligned"] = float(mean_rot_aligned)
    return summary


def main():
    print("=" * 70)
    print("跨 Session 定位全排列 Baseline 测试")
    print("data1-5 × data1-5 = 25 组合 (区域A: data1/2/3, 区域B: data4/5)")
    print("=" * 70)
    t0 = time.time()

    # Step 1: 确保所有 features.db 存在
    print("\n[Step 1] 检查/生成 features.db ...")
    for name, cfg in DATASETS.items():
        print(f"  {name}:")
        if not os.path.exists(cfg["scan_dir"]):
            print(f"    ❌ 扫描目录不存在: {cfg['scan_dir']}")
            continue
        if not generate_features_db(cfg["scan_dir"], cfg["mesh_path"], cfg["db_path"]):
            print(f"    ⚠️ features.db 生成失败，跳过以该数据集为 DB 的测试")

    # Step 2: 加载所有扫描数据和 DB
    print("\n[Step 2] 加载数据 ...")
    scan_data = {}  # name -> (intrinsics, frames)
    db_data = {}    # name -> kfs dict

    for name, cfg in DATASETS.items():
        if os.path.exists(os.path.join(cfg["scan_dir"], "poses.json")):
            intrinsics, frames = load_scan_data(cfg["scan_dir"])
            scan_data[name] = (intrinsics, frames)
            print(f"  {name} scan: {len(frames)} 有效帧")
        else:
            print(f"  {name} scan: ❌ 不可用")

        if os.path.exists(cfg["db_path"]):
            kfs = load_db_keyframes(cfg["db_path"])
            total_feat = sum(len(kf["descriptors"]) for kf in kfs.values())
            db_data[name] = kfs
            print(f"  {name} DB: {len(kfs)} keyframes, {total_feat} 特征")
        else:
            print(f"  {name} DB: ❌ 不可用")

    # Step 3: 跑全排列
    print("\n[Step 3] 全排列定位测试 ...")
    print("-" * 70)

    all_results = {}
    names = ["data1", "data2", "data3", "data4", "data5"]

    for query_name in names:
        for db_name in names:
            label = f"{query_name}→{db_name}"
            if query_name not in scan_data:
                print(f"  {label}: ⏭️ 查询数据不可用")
                continue
            if db_name not in db_data:
                print(f"  {label}: ⏭️ DB 不可用")
                continue

            intrinsics, frames = scan_data[query_name]
            kfs = db_data[db_name]

            results = run_localization(frames, intrinsics, kfs)

            # 多帧一致性过滤：剔除 s2a 与多数帧差异过大的离群帧
            ok_frames = [r for r in results if r["status"] == "ok"]
            if len(ok_frames) >= 3:
                s2a_list = [r["c2w"] @ r["w2c_native"] for r in ok_frames]
                s2a_errs = [r["s2a_err"] for r in ok_frames]
                median_err = np.median(s2a_errs)
                mad = np.median([abs(e - median_err) for e in s2a_errs])
                outlier_thresh = median_err + 3.0 * max(mad, 0.1)
                for r in ok_frames:
                    if r["s2a_err"] > outlier_thresh:
                        r["status"] = "pnp_outlier"
                        r["outlier_reason"] = f"s2a_err={r['s2a_err']:.2f} > thresh={outlier_thresh:.2f}"

            # 坐标系对齐 (方案 B) — 用过滤后的帧
            ok_frames = [r for r in results if r["status"] == "ok"]
            if ok_frames:
                # 从成功帧的 s2a 矩阵计算对齐变换
                s2a_matrices = [r["c2w"] @ r["w2c_native"] for r in ok_frames]
                AT = compute_alignment_transform(s2a_matrices)
                for r in ok_frames:
                    s2a_aligned = AT @ r["c2w"] @ r["w2c_native"]
                    r["s2a_err_aligned"] = float(np.linalg.norm(s2a_aligned - np.eye(4)))
                    R_aligned = s2a_aligned[:3, :3]
                    r["rot_err_aligned"] = float(np.degrees(np.arccos(
                        np.clip((np.trace(R_aligned) - 1) / 2, -1, 1))))

                # 离群帧救回：用 AT 反向验证 pnp_outlier 帧
                AT, rescued_count = rescue_outlier_frames(results, AT)

            # 清理 numpy 对象（不序列化到 JSON）
            for r in results:
                r.pop("w2c_native", None)
                r.pop("c2w", None)

            summary = summarize(results, label)
            all_results[label] = summary

    # Step 4: 输出成功率矩阵
    print("\n" + "=" * 70)
    print("成功率矩阵 (query → db)")
    print("=" * 70)
    header = f"{'query↓ db→':>12s}"
    for db_name in names:
        header += f" {db_name:>10s}"
    print(header)

    for query_name in names:
        row = f"{query_name:>12s}"
        for db_name in names:
            label = f"{query_name}→{db_name}"
            if label in all_results:
                rate = all_results[label]["rate"]
                row += f" {rate:>9.1%}"
            else:
                row += f" {'N/A':>10s}"
        print(row)

    # Step 5: 输出 s2a_err 矩阵
    print(f"\ns2a_err 均值矩阵")
    print("-" * 70)
    header = f"{'query↓ db→':>12s}"
    for db_name in names:
        header += f" {db_name:>10s}"
    print(header)

    for query_name in names:
        row = f"{query_name:>12s}"
        for db_name in names:
            label = f"{query_name}→{db_name}"
            if label in all_results and all_results[label]["mean_s2a_err"] is not None:
                err = all_results[label]["mean_s2a_err"]
                row += f" {err:>10.4f}"
            else:
                row += f" {'N/A':>10s}"
        print(row)

    # Step 6: 输出对齐后 s2a_err 矩阵
    print(f"\n对齐后 s2a_err 均值矩阵 (aligned)")
    print("-" * 70)
    header = f"{'query↓ db→':>12s}"
    for db_name in names:
        header += f" {db_name:>10s}"
    print(header)

    for query_name in names:
        row = f"{query_name:>12s}"
        for db_name in names:
            label = f"{query_name}→{db_name}"
            if label in all_results and all_results[label].get("mean_s2a_err_aligned") is not None:
                err = all_results[label]["mean_s2a_err_aligned"]
                row += f" {err:>10.4f}"
            else:
                row += f" {'N/A':>10s}"
        print(row)

    # Step 7: 区域分析（同区域 vs 跨区域）
    print(f"\n区域分析")
    print("-" * 70)
    same_region_cross = []  # 同区域跨 session
    diff_region_cross = []  # 跨区域
    same_session = []       # 同 session

    for label, summary in all_results.items():
        q, d = label.split("→")
        q_region = DATASETS[q]["region"]
        d_region = DATASETS[d]["region"]
        if q == d:
            same_session.append(summary)
        elif q_region == d_region:
            same_region_cross.append(summary)
        else:
            diff_region_cross.append(summary)

    def avg_rate(items):
        if not items:
            return float("nan")
        return np.mean([s["rate"] for s in items])

    print(f"  同 session 自洽 ({len(same_session)} 组): 平均成功率 {avg_rate(same_session):.1%}")
    print(f"  同区域跨 session ({len(same_region_cross)} 组): 平均成功率 {avg_rate(same_region_cross):.1%}")
    print(f"  跨区域 ({len(diff_region_cross)} 组): 平均成功率 {avg_rate(diff_region_cross):.1%}")

    # 跨区域应该成功率很低（不同物理空间），这是"区分不同"的能力
    # 同区域跨 session 应该有一定成功率，这是"识别相同"的能力
    if diff_region_cross:
        diff_rates = [s["rate"] for s in diff_region_cross]
        print(f"\n  跨区域误识别率（应接近 0%）:")
        print(f"    mean={np.mean(diff_rates):.1%}  max={np.max(diff_rates):.1%}  min={np.min(diff_rates):.1%}")
    if same_region_cross:
        same_rates = [s["rate"] for s in same_region_cross]
        print(f"  同区域识别率（越高越好）:")
        print(f"    mean={np.mean(same_rates):.1%}  max={np.max(same_rates):.1%}  min={np.min(same_rates):.1%}")

    # JSON 报告
    elapsed = time.time() - t0
    report = os.path.join(OUT_DIR, "baseline_matrix.json")
    with open(report, "w") as f:
        json.dump({
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
            "elapsed_s": elapsed,
            "config": {
                "orb_features": ORB_FEATURES,
                "match_ratio": MATCH_RATIO_THRESH,
                "min_matches": MIN_MATCHES_FOR_PNP,
                "min_inlier_ratio": MIN_INLIER_RATIO,
                "multi_kf_top_k": MULTI_KF_TOP_K,
            },
            "region_analysis": {
                "same_session_avg_rate": float(avg_rate(same_session)),
                "same_region_cross_avg_rate": float(avg_rate(same_region_cross)),
                "diff_region_cross_avg_rate": float(avg_rate(diff_region_cross)),
            },
            "results": all_results,
        }, f, indent=2, ensure_ascii=False)

    print(f"\n报告: {report}")
    print(f"耗时: {elapsed:.1f}s")


if __name__ == "__main__":
    main()
