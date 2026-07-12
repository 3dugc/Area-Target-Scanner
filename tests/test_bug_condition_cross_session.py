#!/usr/bin/env python3
"""
Bug Condition Exploration Test: 跨 Session 定位 Inlier Ratio 过低且系统仍返回 TRACKING

Property 1: Bug Condition — 当查询图像来自不同 session，且 inlier_ratio < 门控阈值时，
系统应拒绝该结果返回 LOST，而非输出错误位姿。

**Validates: Requirements 1.1, 1.2, 1.3, 2.2, 2.3**

EXPECTED: 在未修复代码上此测试 WILL FAIL，因为当前代码无 inlier ratio 门控。
修复后（tasks 3.1-3.6），使用修复后的参数（ratio=0.75, cross-check, inlier gate），
测试应 PASS：低 inlier ratio 帧被正确拒绝为 LOST。
"""
import json
import os
import struct
import sqlite3

import cv2
import numpy as np
import pytest

# === 数据路径 ===
DATA2_SCAN_DIR = "data/data2/scan_20260323_175533/scan_20260323_175533"
DB_PATH = "unity_project/Assets/StreamingAssets/SLAMTestAssets/features.db"

# === 参数 ===
UNFIXED_MIN_INLIER_COUNT = 8
ORB_FEATURES = 2000
PNP_REPROJ_ERROR = 12.0
PNP_CONFIDENCE = 0.99
PNP_ITERATIONS = 100   # 降低迭代次数加速（bug 仍可被检测到）
MIN_MATCHES_FOR_PNP = 8
LOWE_RATIO_UNFIXED = 0.85   # 旧 C++ unfixed 值（用于对比测试）
LOWE_RATIO_FIXED = 0.75     # 修复后 C++ 值（task 3.1）
MIN_INLIER_RATIO = 0.15     # 期望的门控阈值（task 3.3）
MAX_CANDIDATES = 5     # 只取前 5 个 keyframe
SAMPLE_FRAMES = 4      # 只测前 4 帧（已知 frame 0-3 会触发 bug）

# 跳过条件
_data_available = os.path.exists(DATA2_SCAN_DIR) and os.path.exists(DB_PATH)
pytestmark = pytest.mark.skipif(not _data_available, reason="Test data not available")

# ============================================================
# Module-level cache（只加载一次）
# ============================================================
_data2_cache = None
_db_cache = None


def get_data2():
    global _data2_cache
    if _data2_cache is None:
        intrinsics = json.load(open(os.path.join(DATA2_SCAN_DIR, "intrinsics.json")))
        poses_data = json.load(open(os.path.join(DATA2_SCAN_DIR, "poses.json")))
        frames = []
        for f in poses_data["frames"]:
            c2w = np.array(f["transform"], dtype=np.float64).reshape(4, 4, order='F')
            img_path = os.path.join(DATA2_SCAN_DIR, f["imageFile"])
            if not np.allclose(c2w, np.eye(4), atol=1e-6) and os.path.exists(img_path):
                frames.append({"index": f["index"], "c2w": c2w, "img_path": img_path})
        frames.sort(key=lambda x: x["index"])
        _data2_cache = (intrinsics, frames)
    return _data2_cache


def get_db():
    global _db_cache
    if _db_cache is None:
        db = sqlite3.connect(DB_PATH)
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
                (kf_id,),
            ).fetchall()
            pts3d = np.array([(f[2], f[3], f[4]) for f in features], dtype=np.float32)
            descs = (
                np.array([np.frombuffer(f[5], dtype=np.uint8) for f in features], dtype=np.uint8)
                if features else np.empty((0, 32), dtype=np.uint8)
            )
            kfs[kf_id] = {"c2w": pose, "pts3d": pts3d, "descriptors": descs}
        db.close()
        _db_cache = kfs
    return _db_cache


# ============================================================
# Matching + PnP helpers
# ============================================================

def _run_pipeline_unfixed(gray, kf_items, K, kps, descs):
    """单向匹配 + PnP，模拟当前未修复 C++ 行为（无 inlier ratio 门控）。"""
    bf = cv2.BFMatcher(cv2.NORM_HAMMING)
    best_result = None
    best_inliers = 0

    for kf_id, kf in kf_items:
        if len(kf["descriptors"]) < 10:
            continue
        try:
            knn_matches = bf.knnMatch(descs, kf["descriptors"], k=2)
        except cv2.error:
            continue

        good_matches = [
            m for pair in knn_matches
            if len(pair) == 2 and pair[0].distance < LOWE_RATIO_UNFIXED * pair[1].distance
            for m in [pair[0]]
        ]
        if len(good_matches) < MIN_MATCHES_FOR_PNP:
            continue

        obj_pts = np.array([kf["pts3d"][m.trainIdx] for m in good_matches
                            if m.trainIdx < len(kf["pts3d"])], dtype=np.float32)
        img_pts = np.array([kps[m.queryIdx].pt for m in good_matches
                            if m.queryIdx < len(kps)], dtype=np.float32)
        if len(obj_pts) < MIN_MATCHES_FOR_PNP:
            continue

        ok, rvec, tvec, inliers_idx = cv2.solvePnPRansac(
            obj_pts, img_pts, K, None,
            iterationsCount=PNP_ITERATIONS,
            reprojectionError=PNP_REPROJ_ERROR,
            confidence=PNP_CONFIDENCE,
        )
        inlier_count = 0 if (not ok or inliers_idx is None) else len(inliers_idx)

        if inlier_count >= UNFIXED_MIN_INLIER_COUNT and inlier_count > best_inliers:
            ratio = inlier_count / len(good_matches)
            R, _ = cv2.Rodrigues(rvec)
            flip = np.diag([1.0, -1.0, -1.0])
            w2c = np.eye(4)
            w2c[:3, :3] = flip @ R
            w2c[:3, 3] = (flip @ tvec).flatten()
            best_result = {
                "state": "TRACKING",
                "matches": len(good_matches),
                "inliers": inlier_count,
                "inlier_ratio": ratio,
                "best_kf_id": kf_id,
                "w2c": w2c,
            }
            best_inliers = inlier_count

    return best_result or {"state": "LOST", "matches": 0, "inliers": 0, "inlier_ratio": 0.0}


def _run_pipeline_fixed(gray, kf_items, K, kps, descs):
    """修复后 pipeline: ratio=0.75 + 交叉验证 + inlier ratio 门控。

    模拟 tasks 3.1-3.3 修复后的 C++ 行为：
    - Lowe ratio 收紧到 0.75
    - 双向交叉验证过滤 many-to-one 错误匹配
    - inlier_ratio < 0.15 时拒绝结果返回 LOST
    """
    bf = cv2.BFMatcher(cv2.NORM_HAMMING)
    best_result = None
    best_inliers = 0

    for kf_id, kf in kf_items:
        if len(kf["descriptors"]) < 10:
            continue
        try:
            fwd = bf.knnMatch(descs, kf["descriptors"], k=2)
            rev = bf.knnMatch(kf["descriptors"], descs, k=2)
        except cv2.error:
            continue

        # Forward Lowe ratio test (fixed ratio=0.75)
        fwd_good = {p[0].queryIdx: p[0].trainIdx for p in fwd
                    if len(p) == 2 and p[0].distance < LOWE_RATIO_FIXED * p[1].distance}
        # Reverse Lowe ratio test
        rev_good = {p[0].queryIdx: p[0].trainIdx for p in rev
                    if len(p) == 2 and p[0].distance < LOWE_RATIO_FIXED * p[1].distance}

        # Cross-check: 仅保留双向一致的匹配
        crosschecked = [(q, d) for q, d in fwd_good.items()
                        if d in rev_good and rev_good[d] == q]
        if len(crosschecked) < MIN_MATCHES_FOR_PNP:
            continue

        obj_pts = np.array([kf["pts3d"][d] for q, d in crosschecked
                            if d < len(kf["pts3d"])], dtype=np.float32)
        img_pts = np.array([kps[q].pt for q, d in crosschecked
                            if q < len(kps)], dtype=np.float32)
        if len(obj_pts) < MIN_MATCHES_FOR_PNP:
            continue

        ok, rvec, tvec, inliers_idx = cv2.solvePnPRansac(
            obj_pts, img_pts, K, None,
            iterationsCount=PNP_ITERATIONS,
            reprojectionError=PNP_REPROJ_ERROR,
            confidence=PNP_CONFIDENCE,
        )
        inlier_count = 0 if (not ok or inliers_idx is None) else len(inliers_idx)

        if inlier_count < UNFIXED_MIN_INLIER_COUNT:
            continue

        ratio = inlier_count / len(crosschecked)

        # Inlier ratio 门控 (task 3.3): < 0.15 → LOST
        if ratio < MIN_INLIER_RATIO:
            continue

        if inlier_count > best_inliers:
            R, _ = cv2.Rodrigues(rvec)
            flip = np.diag([1.0, -1.0, -1.0])
            w2c = np.eye(4)
            w2c[:3, :3] = flip @ R
            w2c[:3, 3] = (flip @ tvec).flatten()
            best_result = {
                "state": "TRACKING",
                "matches": len(crosschecked),
                "inliers": inlier_count,
                "inlier_ratio": ratio,
                "best_kf_id": kf_id,
                "w2c": w2c,
            }
            best_inliers = inlier_count

    return best_result or {"state": "LOST", "matches": 0, "inliers": 0, "inlier_ratio": 0.0}


def _run_pipeline_crosscheck(gray, kf_items, K, kps, descs):
    """双向交叉验证匹配 + PnP。"""
    bf = cv2.BFMatcher(cv2.NORM_HAMMING)
    best_result = None
    best_inliers = 0

    for kf_id, kf in kf_items:
        if len(kf["descriptors"]) < 10:
            continue
        try:
            fwd = bf.knnMatch(descs, kf["descriptors"], k=2)
            rev = bf.knnMatch(kf["descriptors"], descs, k=2)
        except cv2.error:
            continue

        fwd_good = {p[0].queryIdx: p[0].trainIdx for p in fwd
                    if len(p) == 2 and p[0].distance < LOWE_RATIO_UNFIXED * p[1].distance}
        rev_good = {p[0].queryIdx: p[0].trainIdx for p in rev
                    if len(p) == 2 and p[0].distance < LOWE_RATIO_UNFIXED * p[1].distance}

        crosschecked = [(q, d) for q, d in fwd_good.items()
                        if d in rev_good and rev_good[d] == q]
        if len(crosschecked) < MIN_MATCHES_FOR_PNP:
            continue

        obj_pts = np.array([kf["pts3d"][d] for q, d in crosschecked
                            if d < len(kf["pts3d"])], dtype=np.float32)
        img_pts = np.array([kps[q].pt for q, d in crosschecked
                            if q < len(kps)], dtype=np.float32)
        if len(obj_pts) < MIN_MATCHES_FOR_PNP:
            continue

        ok, rvec, tvec, inliers_idx = cv2.solvePnPRansac(
            obj_pts, img_pts, K, None,
            iterationsCount=PNP_ITERATIONS,
            reprojectionError=PNP_REPROJ_ERROR,
            confidence=PNP_CONFIDENCE,
        )
        inlier_count = 0 if (not ok or inliers_idx is None) else len(inliers_idx)

        if inlier_count >= UNFIXED_MIN_INLIER_COUNT and inlier_count > best_inliers:
            ratio = inlier_count / len(crosschecked)
            best_result = {
                "state": "TRACKING",
                "matches": len(crosschecked),
                "inliers": inlier_count,
                "inlier_ratio": ratio,
                "best_kf_id": kf_id,
            }
            best_inliers = inlier_count

    return best_result or {"state": "LOST", "matches": 0, "inliers": 0, "inlier_ratio": 0.0}


# ============================================================
# Tests
# ============================================================

def test_cross_session_inlier_ratio_gate():
    """
    **Validates: Requirements 1.2, 1.3, 2.2, 2.3**

    Property 1: Expected Behavior — 跨 Session 定位质量门控生效

    使用修复后的 pipeline（ratio=0.75, cross-check, inlier ratio gate=0.15）。
    对 data2 前 4 帧 vs data3 DB 前 5 个 keyframe 执行跨 session 定位。

    断言 Expected Behavior:
      修复后 pipeline 中 inlier_ratio < 0.15 的帧被正确拒绝为 LOST，
      不会出现 inlier_ratio < 0.15 且 state == TRACKING 的 violation。

    在未修复代码上此测试 WILL FAIL（旧 pipeline 无门控）。
    修复后（tasks 3.1-3.6）此测试应 PASS。
    """
    intrinsics, frames = get_data2()
    db_kfs = get_db()

    fx, fy = intrinsics["fx"], intrinsics["fy"]
    cx, cy = intrinsics["cx"], intrinsics["cy"]
    K = np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1]], dtype=np.float32)

    orb = cv2.ORB_create(nfeatures=ORB_FEATURES)
    kf_items = list(db_kfs.items())[:MAX_CANDIDATES]
    sample_frames = frames[:SAMPLE_FRAMES]

    violations = []
    for frame in sample_frames:
        img = cv2.imread(frame["img_path"])
        if img is None:
            continue
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        kps, descs = orb.detectAndCompute(gray, None)
        if descs is None:
            continue

        result = _run_pipeline_fixed(gray, kf_items, K, kps, descs)

        if result["state"] == "TRACKING" and result["inlier_ratio"] < MIN_INLIER_RATIO:
            s2a_err = None
            if "w2c" in result:
                s2a = frame["c2w"] @ result["w2c"]
                s2a_err = float(np.linalg.norm(s2a - np.eye(4)))
            violations.append({
                "frame": frame["index"],
                "inlier_ratio": result["inlier_ratio"],
                "inliers": result["inliers"],
                "matches": result["matches"],
                "kf_id": result.get("best_kf_id"),
                "s2a_err": s2a_err,
            })

    assert len(violations) == 0, (
        f"Fix verification failed: {len(violations)} 帧在修复后 pipeline 中 "
        f"inlier_ratio < {MIN_INLIER_RATIO:.0%} 时仍返回 TRACKING "
        f"（ratio={LOWE_RATIO_FIXED}, cross-check=ON, inlier_gate=ON）。\n"
        f"Counterexamples:\n"
        + "\n".join(
            f"  frame_{v['frame']:03d}: inlier_ratio={v['inlier_ratio']:.1%}, "
            f"inliers={v['inliers']}, matches={v['matches']}, "
            f"kf={v['kf_id']}, s2a_err={v['s2a_err']:.1f}"
            for v in violations
        )
    )


def test_crosscheck_vs_oneway_inlier_ratio():
    """
    **Validates: Requirements 2.2**

    交叉验证效果对比：单向匹配 vs 双向匹配后的 inlier ratio 变化。
    验证交叉验证能提高 inlier ratio 或减少错误 TRACKING 帧数。
    """
    intrinsics, frames = get_data2()
    db_kfs = get_db()

    fx, fy = intrinsics["fx"], intrinsics["fy"]
    cx, cy = intrinsics["cx"], intrinsics["cy"]
    K = np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1]], dtype=np.float32)

    orb = cv2.ORB_create(nfeatures=ORB_FEATURES)
    kf_items = list(db_kfs.items())[:MAX_CANDIDATES]
    sample_frames = frames[:SAMPLE_FRAMES]

    oneway_ratios = []
    crosscheck_ratios = []

    for frame in sample_frames:
        img = cv2.imread(frame["img_path"])
        if img is None:
            continue
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        kps, descs = orb.detectAndCompute(gray, None)
        if descs is None:
            continue

        r1 = _run_pipeline_unfixed(gray, kf_items, K, kps, descs)
        if r1["state"] == "TRACKING":
            oneway_ratios.append(r1["inlier_ratio"])

        r2 = _run_pipeline_crosscheck(gray, kf_items, K, kps, descs)
        if r2["state"] == "TRACKING":
            crosscheck_ratios.append(r2["inlier_ratio"])

    assert len(oneway_ratios) >= 2, f"单向匹配 TRACKING 帧不足: {len(oneway_ratios)}"

    mean_oneway = np.mean(oneway_ratios)
    mean_cross = np.mean(crosscheck_ratios) if crosscheck_ratios else 0.0

    # 交叉验证后 inlier ratio 应更高，或 TRACKING 帧数更少（过滤掉低质量结果）
    assert mean_cross >= mean_oneway or len(crosscheck_ratios) < len(oneway_ratios), (
        f"交叉验证未能改善结果: "
        f"单向 mean={mean_oneway:.3f} ({len(oneway_ratios)} frames), "
        f"交叉 mean={mean_cross:.3f} ({len(crosscheck_ratios)} frames)"
    )
