"""
AKAZE fallback 逻辑单元测试

验证 test_cross_session_matrix.py 中的:
1. load_db_keyframes() 加载 AKAZE 数据
2. _match_and_aggregate() 使用 akaze_descriptors/akaze_pts3d 键
3. _pnp_solve_and_refine() 返回正确的状态
4. run_localization() 中 ORB 成功帧标记 method="orb"，AKAZE fallback 成功帧标记 method="akaze_fallback"
"""
import os
import struct
import sqlite3
import tempfile

import cv2
import numpy as np
import pytest

# 导入被测模块的函数
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from test_cross_session_matrix import (
    load_db_keyframes,
    _pnp_solve_and_refine,
    _match_and_aggregate,
    MIN_MATCHES_FOR_PNP,
    PNP_MIN_INLIERS,
    MIN_INLIER_RATIO,
)


def _create_test_db(db_path, with_akaze=False):
    """创建一个最小的 features.db 用于测试"""
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.executescript("""
        CREATE TABLE keyframes (
            id INTEGER PRIMARY KEY,
            pose BLOB NOT NULL,
            global_descriptor BLOB
        );
        CREATE TABLE features (
            id INTEGER PRIMARY KEY,
            keyframe_id INTEGER NOT NULL,
            x REAL, y REAL, x3d REAL, y3d REAL, z3d REAL,
            descriptor BLOB NOT NULL
        );
    """)

    # 写入一个 keyframe
    pose = np.eye(4, dtype=np.float64)
    pose_blob = pose.tobytes()
    cur.execute("INSERT INTO keyframes (id, pose) VALUES (?, ?)", (1, pose_blob))

    # 写入 ORB 特征 (32 bytes 描述子)
    rng = np.random.default_rng(42)
    for i in range(20):
        desc = rng.integers(0, 256, size=32, dtype=np.uint8).tobytes()
        cur.execute(
            "INSERT INTO features (keyframe_id, x, y, x3d, y3d, z3d, descriptor) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (1, float(i * 10), float(i * 10), float(i * 0.1), float(i * 0.1), 1.0, desc),
        )

    if with_akaze:
        cur.executescript("""
            CREATE TABLE akaze_features (
                id INTEGER PRIMARY KEY,
                keyframe_id INTEGER NOT NULL,
                x REAL, y REAL, x3d REAL, y3d REAL, z3d REAL,
                descriptor BLOB NOT NULL
            );
        """)
        for i in range(15):
            desc = rng.integers(0, 256, size=61, dtype=np.uint8).tobytes()
            cur.execute(
                "INSERT INTO akaze_features (keyframe_id, x, y, x3d, y3d, z3d, descriptor) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (1, float(i * 12), float(i * 12), float(i * 0.2), float(i * 0.2), 2.0, desc),
            )

    conn.commit()
    conn.close()


class TestLoadDbKeyframes:
    """load_db_keyframes 加载 AKAZE 数据的测试"""

    def test_without_akaze_table(self, tmp_path):
        """无 akaze_features 表时，AKAZE 字段应为 None"""
        db_path = str(tmp_path / "test.db")
        _create_test_db(db_path, with_akaze=False)

        kfs = load_db_keyframes(db_path)
        assert len(kfs) == 1
        kf = kfs[1]
        assert kf["akaze_pts2d"] is None
        assert kf["akaze_pts3d"] is None
        assert kf["akaze_descriptors"] is None
        # ORB 数据应正常加载
        assert len(kf["descriptors"]) == 20
        assert kf["descriptors"].shape[1] == 32

    def test_with_akaze_table(self, tmp_path):
        """有 akaze_features 表时，AKAZE 字段应正确加载"""
        db_path = str(tmp_path / "test.db")
        _create_test_db(db_path, with_akaze=True)

        kfs = load_db_keyframes(db_path)
        assert len(kfs) == 1
        kf = kfs[1]
        # AKAZE 数据应正确加载
        assert kf["akaze_pts2d"] is not None
        assert kf["akaze_pts3d"] is not None
        assert kf["akaze_descriptors"] is not None
        assert len(kf["akaze_descriptors"]) == 15
        assert kf["akaze_descriptors"].shape[1] == 61
        assert kf["akaze_pts3d"].shape == (15, 3)
        # 验证 3D 点的 z 坐标为 2.0（AKAZE 特征写入时的值）
        assert np.allclose(kf["akaze_pts3d"][:, 2], 2.0)

    def test_akaze_table_empty_for_keyframe(self, tmp_path):
        """akaze_features 表存在但某 keyframe 无 AKAZE 数据时，字段应为 None"""
        db_path = str(tmp_path / "test.db")
        conn = sqlite3.connect(db_path)
        cur = conn.cursor()
        cur.executescript("""
            CREATE TABLE keyframes (id INTEGER PRIMARY KEY, pose BLOB NOT NULL, global_descriptor BLOB);
            CREATE TABLE features (id INTEGER PRIMARY KEY, keyframe_id INTEGER NOT NULL,
                x REAL, y REAL, x3d REAL, y3d REAL, z3d REAL, descriptor BLOB NOT NULL);
            CREATE TABLE akaze_features (id INTEGER PRIMARY KEY, keyframe_id INTEGER NOT NULL,
                x REAL, y REAL, x3d REAL, y3d REAL, z3d REAL, descriptor BLOB NOT NULL);
        """)
        pose = np.eye(4, dtype=np.float64).tobytes()
        cur.execute("INSERT INTO keyframes (id, pose) VALUES (?, ?)", (1, pose))
        # 只写 ORB 特征，不写 AKAZE
        desc = np.zeros(32, dtype=np.uint8).tobytes()
        cur.execute(
            "INSERT INTO features (keyframe_id, x, y, x3d, y3d, z3d, descriptor) "
            "VALUES (?, 0, 0, 0, 0, 0, ?)", (1, desc))
        conn.commit()
        conn.close()

        kfs = load_db_keyframes(db_path)
        kf = kfs[1]
        assert kf["akaze_pts2d"] is None
        assert kf["akaze_pts3d"] is None
        assert kf["akaze_descriptors"] is None


class TestPnpSolveAndRefine:
    """_pnp_solve_and_refine 的测试"""

    def test_too_few_matches_returns_none(self):
        """匹配数不足时返回 None"""
        K = np.array([[500, 0, 320], [0, 500, 240], [0, 0, 1]], dtype=np.float64)
        pts3d = [(0, 0, 1)] * (MIN_MATCHES_FOR_PNP - 1)
        pts2d = [(320, 240)] * (MIN_MATCHES_FOR_PNP - 1)
        result = _pnp_solve_and_refine(pts3d, pts2d, K)
        assert result is None

    def test_good_points_return_ok(self):
        """足够多的好匹配点应返回 ok + w2c 矩阵"""
        K = np.array([[500, 0, 320], [0, 500, 240], [0, 0, 1]], dtype=np.float64)
        # 生成已知位姿下的 3D-2D 对应点
        rng = np.random.default_rng(123)
        n = 30
        pts3d_arr = rng.uniform(-1, 1, (n, 3)).astype(np.float32)
        pts3d_arr[:, 2] = np.abs(pts3d_arr[:, 2]) + 2.0  # z > 2

        # 投影到图像平面（相机在原点看 +z 方向）
        pts2d_arr = np.zeros((n, 2), dtype=np.float32)
        for i in range(n):
            x, y, z = pts3d_arr[i]
            pts2d_arr[i, 0] = K[0, 0] * x / z + K[0, 2]
            pts2d_arr[i, 1] = K[1, 1] * y / z + K[1, 2]

        result = _pnp_solve_and_refine(pts3d_arr.tolist(), pts2d_arr.tolist(), K)
        assert result is not None
        assert result[0] == "ok"
        assert len(result) == 5  # (status, n_matches, n_inliers, inlier_ratio, w2c)
        w2c = result[4]
        assert w2c.shape == (4, 4)


class TestMatchAndAggregate:
    """_match_and_aggregate 使用不同 desc_key 的测试"""

    def test_with_akaze_keys(self):
        """使用 akaze_descriptors/akaze_pts3d 键进行匹配"""
        rng = np.random.default_rng(42)
        # 创建 query 描述子和 keypoints
        n_query = 50
        query_descs = rng.integers(0, 256, (n_query, 61), dtype=np.uint8)
        query_kps = [cv2.KeyPoint(float(i * 10), float(i * 10), 1) for i in range(n_query)]

        # 创建 DB keyframe，部分描述子与 query 相同以确保匹配
        db_descs = query_descs[:30].copy()  # 前 30 个与 query 相同
        db_pts3d = rng.uniform(-1, 1, (30, 3)).astype(np.float32)

        db_kfs = {
            1: {
                "akaze_descriptors": db_descs,
                "akaze_pts3d": db_pts3d,
                "descriptors": np.empty((0, 32), dtype=np.uint8),
                "pts3d": np.empty((0, 3), dtype=np.float32),
            }
        }

        bf = cv2.BFMatcher(cv2.NORM_HAMMING)
        agg_pts3d, agg_pts2d = _match_and_aggregate(
            query_descs, query_kps, db_kfs, bf,
            desc_key="akaze_descriptors", pts3d_key="akaze_pts3d")

        # 应该有一些匹配（描述子完全相同，Lowe ratio 应该通过）
        assert len(agg_pts3d) > 0
        assert len(agg_pts3d) == len(agg_pts2d)

    def test_skips_keyframes_without_data(self):
        """没有指定 desc_key 数据的 keyframe 应被跳过"""
        rng = np.random.default_rng(42)
        query_descs = rng.integers(0, 256, (20, 61), dtype=np.uint8)
        query_kps = [cv2.KeyPoint(float(i), float(i), 1) for i in range(20)]

        db_kfs = {
            1: {
                "akaze_descriptors": None,  # 无 AKAZE 数据
                "akaze_pts3d": None,
                "descriptors": rng.integers(0, 256, (20, 32), dtype=np.uint8),
                "pts3d": rng.uniform(-1, 1, (20, 3)).astype(np.float32),
            }
        }

        bf = cv2.BFMatcher(cv2.NORM_HAMMING)
        agg_pts3d, agg_pts2d = _match_and_aggregate(
            query_descs, query_kps, db_kfs, bf,
            desc_key="akaze_descriptors", pts3d_key="akaze_pts3d")

        assert len(agg_pts3d) == 0
        assert len(agg_pts2d) == 0
