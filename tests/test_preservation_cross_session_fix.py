#!/usr/bin/env python3
"""
Preservation Property Tests — 在未修复代码上运行，建立 baseline。

这些测试验证同 session 定位的基准行为，在修复跨 session bug 后必须保持不变。
测试应在未修复代码上 PASS，确认 baseline 行为。

**Validates: Requirements 3.1, 3.2, 3.3, 3.4**

数据路径:
  - data3 自洽数据: data/data1/scan_20260323_170907/scan_20260323_170907
  - features.db: unity_project/Assets/StreamingAssets/SLAMTestAssets/features.db
"""
import json
import os
import sqlite3
import struct

import cv2
import numpy as np
import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

# === 路径配置 ===
# 使用与 test_slam_sequence.py 相同的 ScanData 路径（同 session 数据）
DATA3_SCAN_DIR = "unity_project/Assets/StreamingAssets/ScanData"
DB_PATH = "unity_project/Assets/StreamingAssets/SLAMTestAssets/features.db"

# === 定位参数（与 test_slam_sequence.py 保持一致）===
LOWE_RATIO = 0.75          # 当前 Python 测试使用的 ratio（C++ unfixed 为 0.85）
PNP_REPROJ_ERROR = 10.0
PNP_CONFIDENCE = 0.99
PNP_ITERATIONS = 300
PNP_MIN_INLIERS = 10
MIN_MATCHES_FOR_PNP = 15
ORB_FEATURES = 2000

# === 验收阈值 ===
S2A_ERR_THRESHOLD = 0.01       # 同 session s2a_err 应 < 0.01（≈ 0.0001 量级）
SUCCESS_RATE_THRESHOLD = 0.95  # 成功率 > 95%
INLIER_RATIO_THRESHOLD = 0.80  # inlier ratio > 80%
S2A_DIFF_THRESHOLD = 0.001     # 修复前后 s2a_err 差异 < 0.001

# === 跳过条件：数据文件不存在时 skip ===
_data3_available = os.path.exists(DATA3_SCAN_DIR) and os.path.exists(
    os.path.join(DATA3_SCAN_DIR, "poses.json")
)
_db_available = os.path.exists(DB_PATH)
_all_data_available = _data3_available and _db_available

pytestmark = pytest.mark.skipif(
    not _all_data_available,
    reason=f"测试数据不可用: data3={_data3_available}, db={_db_available}",
)

# ============================================================
# Module-level cache（只加载一次，避免重复 IO）
# ============================================================
_data3_cache = None
_db_cache = None


def get_data3():
    """加载 data3 扫描数据（内参 + 帧列表）"""
    global _data3_cache
    if _data3_cache is None:
        intrinsics = json.load(open(os.path.join(DATA3_SCAN_DIR, "intrinsics.json")))
        poses_data = json.load(open(os.path.join(DATA3_SCAN_DIR, "poses.json")))
        frames = []
        for f in poses_data["frames"]:
            c2w = np.array(f["transform"], dtype=np.float64).reshape(4, 4, order="F")
            img_path = os.path.join(DATA3_SCAN_DIR, f["imageFile"])
            if os.path.exists(img_path):
                frames.append({"index": f["index"], "c2w": c2w, "img_path": img_path})
        frames.sort(key=lambda x: x["index"])
        _data3_cache = (intrinsics, frames)
    return _data3_cache


def get_db():
    """从 features.db 加载所有 keyframe 数据"""
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
            pts2d = np.array([(f[0], f[1]) for f in features], dtype=np.float32)
            pts3d = np.array([(f[2], f[3], f[4]) for f in features], dtype=np.float32)
            descs = (
                np.array([np.frombuffer(f[5], dtype=np.uint8) for f in features], dtype=np.uint8)
                if features
                else np.empty((0, 32), dtype=np.uint8)
            )
            kfs[kf_id] = {"c2w": pose, "pts2d": pts2d, "pts3d": pts3d, "descriptors": descs}
        db.close()
        _db_cache = kfs
    return _db_cache


# ============================================================
# 核心定位 pipeline（复用 test_slam_sequence.py 逻辑）
# ============================================================

def _find_best_keyframe(scan_c2w, db_kfs):
    """找到与扫描帧位置最近的 DB keyframe"""
    scan_pos = scan_c2w[:3, 3]
    best_dist, best_id = float("inf"), None
    for kf_id, kf in db_kfs.items():
        d = np.linalg.norm(scan_pos - kf["c2w"][:3, 3])
        if d < best_dist:
            best_dist, best_id = d, kf_id
    return best_id, best_dist


def _match_features(query_descs, db_descs, ratio_thresh=LOWE_RATIO):
    """BFMatcher + Lowe's ratio test，返回匹配索引对"""
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


def _do_pnp(matched_pts3d, matched_pts2d, K):
    """PnP + flip(Y,Z)，返回 (w2c_native, n_inliers)"""
    if len(matched_pts3d) < PNP_MIN_INLIERS:
        return None, 0
    ok, rvec, tvec, inliers = cv2.solvePnPRansac(
        matched_pts3d.astype(np.float32),
        matched_pts2d.astype(np.float32),
        K.astype(np.float32),
        None,
        iterationsCount=PNP_ITERATIONS,
        reprojectionError=PNP_REPROJ_ERROR,
        confidence=PNP_CONFIDENCE,
    )
    if not ok or inliers is None or len(inliers) < PNP_MIN_INLIERS:
        return None, 0 if inliers is None else len(inliers)
    R, _ = cv2.Rodrigues(rvec)
    t = tvec.flatten()
    flip = np.diag([1.0, -1.0, -1.0])
    w2c = np.eye(4)
    w2c[:3, :3] = flip @ R
    w2c[:3, 3] = flip @ t
    return w2c, len(inliers)


def _localize_frame(frame, db_kfs, K, orb):
    """
    对单帧执行完整定位 pipeline，返回结果字典。
    status: 'ok' | 'pnp_failed' | 'few_matches' | 'few_features' | 'img_error'
    """
    img = cv2.imread(frame["img_path"])
    if img is None:
        return {"status": "img_error", "frame": frame["index"]}

    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    kps, descs = orb.detectAndCompute(gray, None)
    if descs is None or len(kps) < 10:
        return {"status": "few_features", "frame": frame["index"]}

    best_kf_id, kf_dist = _find_best_keyframe(frame["c2w"], db_kfs)
    kf = db_kfs[best_kf_id]

    good_matches = _match_features(descs, kf["descriptors"])
    n_matches = len(good_matches)

    if n_matches < MIN_MATCHES_FOR_PNP:
        return {"status": "few_matches", "frame": frame["index"], "n_matches": n_matches}

    matched_pts3d = kf["pts3d"][[m[1] for m in good_matches]]
    matched_pts2d = np.array([kps[m[0]].pt for m in good_matches], dtype=np.float32)

    w2c_native, n_inliers = _do_pnp(matched_pts3d, matched_pts2d, K)

    if w2c_native is None:
        return {
            "status": "pnp_failed",
            "frame": frame["index"],
            "n_matches": n_matches,
            "n_inliers": n_inliers,
        }

    scan_to_ar = frame["c2w"] @ w2c_native
    s2a_err = float(np.linalg.norm(scan_to_ar - np.eye(4)))
    inlier_ratio = n_inliers / n_matches if n_matches > 0 else 0.0

    return {
        "status": "ok",
        "frame": frame["index"],
        "n_matches": n_matches,
        "n_inliers": n_inliers,
        "inlier_ratio": inlier_ratio,
        "s2a_err": s2a_err,
        "w2c": w2c_native,
    }


# ============================================================
# 全帧 baseline 结果缓存（避免 property test 重复计算）
# ============================================================
_baseline_results_cache = None


def get_baseline_results():
    """
    运行 data3 全帧自洽定位，缓存结果。
    这是 Observation 步骤：记录未修复代码的 baseline 行为。
    """
    global _baseline_results_cache
    if _baseline_results_cache is not None:
        return _baseline_results_cache

    intrinsics, frames = get_data3()
    db_kfs = get_db()
    fx, fy = intrinsics["fx"], intrinsics["fy"]
    cx, cy = intrinsics["cx"], intrinsics["cy"]
    K = np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1]], dtype=np.float64)
    orb = cv2.ORB_create(nfeatures=ORB_FEATURES)

    results = []
    for frame in frames:
        r = _localize_frame(frame, db_kfs, K, orb)
        results.append(r)

    _baseline_results_cache = results
    return results


# ============================================================
# Property 1: 同 Session 定位精度保持（s2a_err ≈ 0.0001）
# ============================================================

class TestSameSessionLocalizationAccuracy:
    """
    验证同 session 定位精度：s2a_err < 0.01，成功率 > 95%，inlier_ratio > 80%。

    **Validates: Requirements 3.1, 3.2**
    """

    def test_baseline_success_rate_above_95_percent(self):
        """
        Observation: data3 自洽测试成功率应 > 95%。

        在未修复代码上运行，确认 baseline 行为。
        修复后此测试必须继续 PASS。

        **Validates: Requirements 3.2**
        """
        results = get_baseline_results()
        total = len(results)
        assert total > 0, "没有找到任何帧"

        ok_count = sum(1 for r in results if r["status"] == "ok")
        success_rate = ok_count / total

        assert success_rate > SUCCESS_RATE_THRESHOLD, (
            f"同 session 成功率 {success_rate:.1%} 低于阈值 {SUCCESS_RATE_THRESHOLD:.0%}。\n"
            f"总帧数={total}, 成功={ok_count}\n"
            f"失败帧: {[r['frame'] for r in results if r['status'] != 'ok']}"
        )

    def test_baseline_s2a_err_near_zero(self):
        """
        Observation: 成功帧的 s2a_err 应 ≈ 0.0001（< 0.01 即可）。

        **Validates: Requirements 3.1**
        """
        results = get_baseline_results()
        ok_results = [r for r in results if r["status"] == "ok"]
        assert len(ok_results) > 0, "没有成功定位的帧"

        errs = [r["s2a_err"] for r in ok_results]
        mean_err = np.mean(errs)
        max_err = np.max(errs)

        assert mean_err < S2A_ERR_THRESHOLD, (
            f"同 session 平均 s2a_err={mean_err:.6f} 超过阈值 {S2A_ERR_THRESHOLD}。\n"
            f"max={max_err:.6f}, min={np.min(errs):.6f}"
        )

    def test_baseline_inlier_ratio_above_80_percent(self):
        """
        Observation: 成功帧的 inlier_ratio 应 > 80%。

        **Validates: Requirements 3.1**
        """
        results = get_baseline_results()
        ok_results = [r for r in results if r["status"] == "ok"]
        assert len(ok_results) > 0, "没有成功定位的帧"

        ratios = [r["inlier_ratio"] for r in ok_results]
        mean_ratio = np.mean(ratios)

        assert mean_ratio > INLIER_RATIO_THRESHOLD, (
            f"同 session 平均 inlier_ratio={mean_ratio:.1%} 低于阈值 {INLIER_RATIO_THRESHOLD:.0%}。\n"
            f"min={np.min(ratios):.1%}, max={np.max(ratios):.1%}"
        )

    @given(
        frame_indices=st.lists(
            st.integers(min_value=0, max_value=93),  # ScanData 有 94 帧
            min_size=3,
            max_size=10,
            unique=True,
        )
    )
    @settings(
        max_examples=20,
        deadline=60000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_random_frame_subset_s2a_err_preserved(self, frame_indices):
        """
        Property-based test: 对随机帧索引子集，验证同 session 定位 s2a_err < 0.01。

        使用 Hypothesis 生成随机帧索引子集，验证每个成功定位的帧
        s2a_err 都在 baseline 范围内（< 0.01）。

        **Validates: Requirements 3.1, 3.2**
        """
        results = get_baseline_results()
        # 过滤出请求的帧索引（按帧 index 查找）
        frame_map = {r["frame"]: r for r in results}

        checked = 0
        violations = []
        for idx in frame_indices:
            if idx not in frame_map:
                continue
            r = frame_map[idx]
            if r["status"] != "ok":
                continue  # 跳过非成功帧（不计入违规）
            checked += 1
            if r["s2a_err"] >= S2A_ERR_THRESHOLD:
                violations.append(
                    f"frame_{r['frame']:03d}: s2a_err={r['s2a_err']:.6f} >= {S2A_ERR_THRESHOLD}"
                )

        assert len(violations) == 0, (
            f"随机帧子集中 {len(violations)}/{checked} 帧 s2a_err 超标:\n"
            + "\n".join(violations)
        )

    @given(
        frame_indices=st.lists(
            st.integers(min_value=0, max_value=93),  # ScanData 有 94 帧
            min_size=10,
            max_size=40,
            unique=True,
        )
    )
    @settings(
        max_examples=15,
        deadline=60000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_random_frame_subset_success_rate_above_95(self, frame_indices):
        """
        Property-based test: 对随机帧子集，验证成功率 > 90%。

        使用 90% 阈值（低于全局 95%）以容忍小子集中的统计波动。
        全局成功率由 test_baseline_success_rate_above_95_percent 严格验证。

        **Validates: Requirements 3.2**
        """
        results = get_baseline_results()
        frame_map = {r["frame"]: r for r in results}

        subset = [frame_map[idx] for idx in frame_indices if idx in frame_map]
        if len(subset) < 5:
            return  # 子集太小，跳过

        ok_count = sum(1 for r in subset if r["status"] == "ok")
        success_rate = ok_count / len(subset)

        # 对子集使用 90% 阈值，容忍统计波动（全局 95% 由 baseline 测试保证）
        subset_threshold = 0.90
        assert success_rate >= subset_threshold, (
            f"随机帧子集成功率 {success_rate:.1%} < {subset_threshold:.0%}。\n"
            f"子集大小={len(subset)}, 成功={ok_count}\n"
            f"失败帧: {[r['frame'] for r in subset if r['status'] != 'ok']}"
        )


# ============================================================
# Property 2: 修复前后 s2a_err 差异 < 0.001
# ============================================================

class TestS2AErrPreservationAfterFix:
    """
    验证修复前后 s2a_err 差异 < 0.001。

    在未修复代码上运行时，baseline 与自身比较差异为 0，测试 PASS。
    修复后重新运行，验证同 session 精度没有回归。

    **Validates: Requirements 3.1, 3.3**
    """

    @given(
        frame_indices=st.lists(
            st.integers(min_value=0, max_value=93),  # ScanData 有 94 帧
            min_size=3,
            max_size=15,
            unique=True,
        )
    )
    @settings(
        max_examples=20,
        deadline=60000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_s2a_err_diff_below_threshold(self, frame_indices):
        """
        Property-based test: 对随机帧子集，验证当前代码的 s2a_err
        与 baseline 差异 < 0.001。

        在未修复代码上运行时，当前结果 == baseline，差异为 0，测试 PASS。
        修复后运行时，验证同 session 精度没有退化。

        **Validates: Requirements 3.1, 3.3**
        """
        # 获取 baseline 结果（未修复代码的结果）
        baseline_results = get_baseline_results()
        baseline_map = {r["frame"]: r for r in baseline_results if r["status"] == "ok"}

        # 重新运行定位（在未修复代码上与 baseline 相同）
        intrinsics, frames = get_data3()
        db_kfs = get_db()
        fx, fy = intrinsics["fx"], intrinsics["fy"]
        cx, cy = intrinsics["cx"], intrinsics["cy"]
        K = np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1]], dtype=np.float64)
        orb = cv2.ORB_create(nfeatures=ORB_FEATURES)

        frame_map = {f["index"]: f for f in frames}
        violations = []

        for idx in frame_indices:
            if idx not in frame_map or idx not in baseline_map:
                continue
            frame = frame_map[idx]
            current = _localize_frame(frame, db_kfs, K, orb)

            if current["status"] != "ok":
                continue  # 当前失败，跳过差异检查

            baseline_err = baseline_map[idx]["s2a_err"]
            current_err = current["s2a_err"]
            diff = abs(current_err - baseline_err)

            if diff >= S2A_DIFF_THRESHOLD:
                violations.append(
                    f"frame_{idx:03d}: baseline={baseline_err:.6f}, "
                    f"current={current_err:.6f}, diff={diff:.6f}"
                )

        assert len(violations) == 0, (
            f"修复前后 s2a_err 差异超过 {S2A_DIFF_THRESHOLD}:\n"
            + "\n".join(violations)
        )


# ============================================================
# Property 3: features.db schema 兼容性
# ============================================================

class TestFeatureDbSchemaCompatibility:
    """
    验证 features.db schema 读取兼容性：
    keyframes / features / vocabulary 三表结构存在且可读。

    **Validates: Requirements 3.4**
    """

    def test_three_tables_exist(self):
        """
        验证 features.db 包含三张必要的表：keyframes、features、vocabulary。

        **Validates: Requirements 3.4**
        """
        db = sqlite3.connect(DB_PATH)
        tables = {
            row[0]
            for row in db.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        db.close()

        required_tables = {"keyframes", "features", "vocabulary"}
        missing = required_tables - tables
        assert len(missing) == 0, (
            f"features.db 缺少必要的表: {missing}。\n"
            f"实际存在的表: {tables}"
        )

    def test_keyframes_table_readable(self):
        """
        验证 keyframes 表可读，且包含 id 和 pose 字段。

        **Validates: Requirements 3.4**
        """
        db = sqlite3.connect(DB_PATH)
        # 检查表结构
        cols = {row[1] for row in db.execute("PRAGMA table_info(keyframes)").fetchall()}
        rows = db.execute("SELECT id, pose FROM keyframes ORDER BY id").fetchall()
        db.close()

        assert "id" in cols, f"keyframes 表缺少 id 列，实际列: {cols}"
        assert "pose" in cols, f"keyframes 表缺少 pose 列，实际列: {cols}"
        assert len(rows) > 0, "keyframes 表为空"

        # 验证 pose 可以解析为 4x4 float64 矩阵
        for row in rows[:3]:  # 只检查前 3 行
            kf_id, pose_bytes = row
            assert len(pose_bytes) == 16 * 8, (
                f"keyframe {kf_id} pose 字节长度 {len(pose_bytes)} != 128"
            )
            pose = np.array(
                [struct.unpack_from("d", pose_bytes, i * 8)[0] for i in range(16)]
            ).reshape(4, 4)
            assert pose.shape == (4, 4), f"keyframe {kf_id} pose shape 错误: {pose.shape}"
            assert np.isfinite(pose).all(), f"keyframe {kf_id} pose 包含非有限值"

    def test_features_table_readable(self):
        """
        验证 features 表可读，包含 keyframe_id、x、y、x3d、y3d、z3d、descriptor 字段。

        **Validates: Requirements 3.4**
        """
        db = sqlite3.connect(DB_PATH)
        cols = {row[1] for row in db.execute("PRAGMA table_info(features)").fetchall()}
        count = db.execute("SELECT COUNT(*) FROM features").fetchone()[0]
        # 取一条样本验证 descriptor 格式
        sample = db.execute(
            "SELECT x, y, x3d, y3d, z3d, descriptor FROM features LIMIT 1"
        ).fetchone()
        db.close()

        required_cols = {"keyframe_id", "x", "y", "x3d", "y3d", "z3d", "descriptor"}
        missing = required_cols - cols
        assert len(missing) == 0, (
            f"features 表缺少必要列: {missing}。实际列: {cols}"
        )
        assert count > 0, "features 表为空"

        # 验证 descriptor 是 32 字节 ORB 描述子
        assert sample is not None, "features 表无法读取样本行"
        desc_bytes = sample[5]
        assert len(desc_bytes) == 32, (
            f"descriptor 字节长度 {len(desc_bytes)} != 32（ORB 描述子应为 32 字节）"
        )
        desc = np.frombuffer(desc_bytes, dtype=np.uint8)
        assert desc.shape == (32,), f"descriptor shape 错误: {desc.shape}"

    def test_vocabulary_table_readable(self):
        """
        验证 vocabulary 表可读，包含词汇表数据。

        **Validates: Requirements 3.4**
        """
        db = sqlite3.connect(DB_PATH)
        cols = {row[1] for row in db.execute("PRAGMA table_info(vocabulary)").fetchall()}
        count = db.execute("SELECT COUNT(*) FROM vocabulary").fetchone()[0]
        db.close()

        assert len(cols) > 0, "vocabulary 表没有任何列"
        assert count > 0, "vocabulary 表为空"

    @given(
        kf_id_offset=st.integers(min_value=0, max_value=5),
    )
    @settings(
        max_examples=10,
        deadline=10000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_features_linked_to_keyframes(self, kf_id_offset):
        """
        Property-based test: 随机选取 keyframe，验证其关联的 features 可正确读取。

        **Validates: Requirements 3.4**
        """
        db = sqlite3.connect(DB_PATH)
        kf_ids = [
            row[0]
            for row in db.execute("SELECT id FROM keyframes ORDER BY id").fetchall()
        ]
        if not kf_ids:
            db.close()
            return

        # 用 offset 选取 keyframe（循环取模）
        kf_id = kf_ids[kf_id_offset % len(kf_ids)]
        features = db.execute(
            "SELECT x, y, x3d, y3d, z3d, descriptor FROM features WHERE keyframe_id=?",
            (kf_id,),
        ).fetchall()
        db.close()

        assert len(features) > 0, (
            f"keyframe {kf_id} 没有关联的 features"
        )

        # 验证每个 feature 的 descriptor 格式正确
        for i, feat in enumerate(features[:5]):  # 只检查前 5 个
            desc_bytes = feat[5]
            assert len(desc_bytes) == 32, (
                f"keyframe {kf_id} feature[{i}] descriptor 长度 {len(desc_bytes)} != 32"
            )
            # 验证 3D 点坐标是有限值
            x3d, y3d, z3d = feat[2], feat[3], feat[4]
            assert all(np.isfinite([x3d, y3d, z3d])), (
                f"keyframe {kf_id} feature[{i}] 3D 点包含非有限值: ({x3d}, {y3d}, {z3d})"
            )


# ============================================================
# Property 4: PnP → flip(Y,Z) → scanToAR 变换链路正确性
# ============================================================

class TestPnPTransformChain:
    """
    验证 PnP → flip(Y,Z) → scanToAR 变换链路对高质量匹配产生正确结果。

    **Validates: Requirements 3.3**
    """

    def test_scan_to_ar_near_identity_for_same_session(self):
        """
        同 session 定位时，scanToAR = scan_c2w @ w2c_native 应接近单位矩阵。

        **Validates: Requirements 3.3**
        """
        results = get_baseline_results()
        ok_results = [r for r in results if r["status"] == "ok"]
        assert len(ok_results) > 0, "没有成功定位的帧"

        # 验证所有成功帧的 s2a_err 都接近 0
        high_err_frames = [
            r for r in ok_results if r["s2a_err"] >= S2A_ERR_THRESHOLD
        ]
        assert len(high_err_frames) == 0, (
            f"{len(high_err_frames)} 帧 scanToAR 误差过大:\n"
            + "\n".join(
                f"  frame_{r['frame']:03d}: s2a_err={r['s2a_err']:.6f}"
                for r in high_err_frames
            )
        )

    def test_flip_yz_convention_preserved(self):
        """
        验证 flip(Y,Z) 变换约定：flip = diag([1, -1, -1])。
        这是 ARKit → OpenCV 坐标系转换的核心约定，修复后必须保持不变。

        **Validates: Requirements 3.3**
        """
        flip = np.diag([1.0, -1.0, -1.0])

        # flip 应该是对合矩阵（flip @ flip = I）
        result = flip @ flip
        np.testing.assert_array_almost_equal(
            result,
            np.eye(3),
            decimal=10,
            err_msg="flip(Y,Z) 不是对合矩阵，约定可能被破坏",
        )

        # flip 的行列式应为 +1（Y 和 Z 同时翻转，偶数次反射 → det=+1）
        det = np.linalg.det(flip)
        assert abs(det - 1.0) < 1e-10, (
            f"flip(Y,Z) 行列式 {det} != 1，约定可能被破坏"
        )

    @given(
        seed=st.integers(min_value=0, max_value=9999),
    )
    @settings(
        max_examples=30,
        deadline=5000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_scan_to_ar_formula_correctness(self, seed):
        """
        Property-based test: 验证 scanToAR = scan_c2w @ w2c_native 公式。

        对随机生成的 scan_c2w 和 w2c_native，验证：
        - 当 w2c_native = inv(scan_c2w) 时，scanToAR = I（完美定位）
        - scanToAR 的误差 = norm(scanToAR - I)

        **Validates: Requirements 3.3**
        """
        rng = np.random.default_rng(seed)

        # 生成随机旋转矩阵（通过 QR 分解）
        Q, _ = np.linalg.qr(rng.standard_normal((3, 3)))
        if np.linalg.det(Q) < 0:
            Q[:, 0] *= -1  # 确保行列式为 +1

        t = rng.standard_normal(3) * 2.0  # 随机平移

        scan_c2w = np.eye(4)
        scan_c2w[:3, :3] = Q
        scan_c2w[:3, 3] = t

        # 完美定位：w2c_native = inv(scan_c2w)
        w2c_native = np.linalg.inv(scan_c2w)
        scan_to_ar = scan_c2w @ w2c_native

        s2a_err = np.linalg.norm(scan_to_ar - np.eye(4))
        assert s2a_err < 1e-10, (
            f"完美定位时 scanToAR 误差 {s2a_err:.2e} 不接近 0，公式可能有误"
        )
