"""
rescue_outlier_frames() 单元测试

验证离群帧救回逻辑：
- 对齐后 s2a_err < 0.5 的帧被救回为 ok_rescued
- 对齐后 s2a_err >= 0.5 的帧保持 pnp_outlier
- 救回后重算 AT，对齐精度未退化
- 无离群帧时为空操作
"""
import numpy as np
import pytest
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from test_cross_session_matrix import rescue_outlier_frames, compute_alignment_transform


def _make_rigid_transform(angle_deg=5.0, tx=0.1, ty=0.05, tz=-0.02):
    """生成一个小角度刚体变换作为坐标系偏差"""
    angle = np.radians(angle_deg)
    R = np.array([
        [np.cos(angle), -np.sin(angle), 0],
        [np.sin(angle),  np.cos(angle), 0],
        [0, 0, 1],
    ])
    T = np.eye(4)
    T[:3, :3] = R
    T[:3, 3] = [tx, ty, tz]
    return T


def _make_frame(index, c2w, w2c_native, status="ok", s2a_err=None):
    """构造一个模拟帧结果"""
    s2a = c2w @ w2c_native
    if s2a_err is None:
        s2a_err = float(np.linalg.norm(s2a - np.eye(4)))
    return {
        "frame": index,
        "status": status,
        "n_matches": 30,
        "n_inliers": 20,
        "inlier_ratio": 0.67,
        "s2a_err": s2a_err,
        "rot_err": 5.0,
        "w2c_native": w2c_native,
        "c2w": c2w,
    }


class TestRescueOutlierFrames:
    def test_no_outliers(self):
        """无离群帧时返回原 AT，rescued_count=0"""
        AT = np.eye(4)
        results = [
            _make_frame(0, np.eye(4), np.eye(4), status="ok"),
            _make_frame(1, np.eye(4), np.eye(4), status="ok"),
        ]
        new_AT, count = rescue_outlier_frames(results, AT)
        assert count == 0
        np.testing.assert_array_equal(new_AT, AT)

    def test_rescue_good_outlier(self):
        """对齐后 s2a_err < 0.5 的离群帧应被救回"""
        # 构造一个系统性坐标系偏差
        T_offset = _make_rigid_transform(angle_deg=3.0, tx=0.05)
        AT = np.linalg.inv(T_offset)

        # 成功帧：c2w @ w2c_native ≈ T_offset
        ok_frames = []
        for i in range(5):
            noise = np.eye(4)
            noise[:3, 3] = np.random.randn(3) * 0.001
            c2w = T_offset @ noise
            w2c = np.eye(4)
            ok_frames.append(_make_frame(i, c2w, w2c, status="ok"))

        # 离群帧：s2a_err 较大但对齐后 < 0.5
        c2w_outlier = T_offset.copy()
        c2w_outlier[:3, 3] += np.array([0.02, -0.01, 0.01])  # 小偏移
        outlier = _make_frame(10, c2w_outlier, np.eye(4), status="pnp_outlier")

        results = ok_frames + [outlier]
        new_AT, count = rescue_outlier_frames(results, AT)

        assert count == 1
        assert outlier["status"] == "ok_rescued"
        assert outlier["s2a_err_aligned"] < 0.5

    def test_keep_bad_outlier(self):
        """对齐后 s2a_err >= 0.5 的离群帧应保持 pnp_outlier"""
        AT = np.eye(4)

        # 成功帧
        ok_frames = []
        for i in range(5):
            c2w = np.eye(4)
            c2w[:3, 3] = np.random.randn(3) * 0.001
            ok_frames.append(_make_frame(i, c2w, np.eye(4), status="ok"))

        # 离群帧：大偏差，对齐后 s2a_err 仍 >= 0.5
        c2w_bad = np.eye(4)
        angle = np.radians(30)
        c2w_bad[:3, :3] = np.array([
            [np.cos(angle), -np.sin(angle), 0],
            [np.sin(angle),  np.cos(angle), 0],
            [0, 0, 1],
        ])
        c2w_bad[:3, 3] = [1.0, 0.5, -0.3]
        outlier = _make_frame(10, c2w_bad, np.eye(4), status="pnp_outlier")

        results = ok_frames + [outlier]
        _, count = rescue_outlier_frames(results, AT)

        assert count == 0
        assert outlier["status"] == "pnp_outlier"

    def test_threshold_boundary_below(self):
        """s2a_err_aligned 刚好 < 0.5 时应被救回"""
        # 构造 AT 使得 AT @ c2w @ w2c ≈ I + small_err (Frobenius < 0.5)
        AT = np.eye(4)
        # c2w @ w2c = I + delta，使 ||delta||_F 略小于 0.5
        delta = np.zeros((4, 4))
        # Frobenius norm of delta = 0.49
        delta[0, 3] = 0.49
        c2w = np.eye(4) + delta
        w2c = np.eye(4)

        ok_frames = [_make_frame(i, np.eye(4), np.eye(4), status="ok") for i in range(5)]
        outlier = _make_frame(10, c2w, w2c, status="pnp_outlier")
        results = ok_frames + [outlier]

        _, count = rescue_outlier_frames(results, AT)
        assert count == 1
        assert outlier["status"] == "ok_rescued"
        assert outlier["s2a_err_aligned"] < 0.5

    def test_threshold_boundary_above(self):
        """s2a_err_aligned 刚好 >= 0.5 时不应被救回"""
        AT = np.eye(4)
        delta = np.zeros((4, 4))
        delta[0, 3] = 0.51
        c2w = np.eye(4) + delta
        w2c = np.eye(4)

        ok_frames = [_make_frame(i, np.eye(4), np.eye(4), status="ok") for i in range(5)]
        outlier = _make_frame(10, c2w, w2c, status="pnp_outlier")
        results = ok_frames + [outlier]

        _, count = rescue_outlier_frames(results, AT)
        assert count == 0
        assert outlier["status"] == "pnp_outlier"

    def test_rescued_frames_included_in_at_recompute(self):
        """救回帧应参与 AT 重算，且重算后精度 < 0.2"""
        T_offset = _make_rigid_transform(angle_deg=2.0, tx=0.03)
        AT = np.linalg.inv(T_offset)

        # 成功帧
        results = []
        for i in range(8):
            noise = np.eye(4)
            noise[:3, 3] = np.random.randn(3) * 0.0005
            c2w = T_offset @ noise
            results.append(_make_frame(i, c2w, np.eye(4), status="ok"))

        # 可救回的离群帧
        c2w_outlier = T_offset.copy()
        c2w_outlier[:3, 3] += np.array([0.01, 0.005, -0.005])
        results.append(_make_frame(20, c2w_outlier, np.eye(4), status="pnp_outlier"))

        new_AT, count = rescue_outlier_frames(results, AT)
        assert count == 1

        # 验证重算后所有成功帧的对齐精度
        success = [r for r in results if r["status"] in ("ok", "ok_rescued")]
        errs = []
        for r in success:
            s2a_aligned = new_AT @ r["c2w"] @ r["w2c_native"]
            errs.append(float(np.linalg.norm(s2a_aligned - np.eye(4))))
        assert np.mean(errs) < 0.2
