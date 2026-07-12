"""
Property Test 2: 救回帧后 AT 精度不退化

对任意一组 N ≥ 3 个成功帧和 M ≥ 0 个救回帧（救回帧的 s2a_err_aligned < 0.5），
用成功帧 + 救回帧重新计算 Alignment_Transform 后，所有帧的对齐后 s2a_err 均值应 < 0.2。

Tag: Feature: cross-session-precision-boost, Property 2: 救回帧后 AT 精度不退化

**Validates: Requirements 1.5**
"""
from __future__ import annotations

import sys
import os

import numpy as np
from hypothesis import given, settings, HealthCheck, assume
from hypothesis import strategies as st

# 确保能导入项目根目录的 test_cross_session_matrix
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from test_cross_session_matrix import rescue_outlier_frames, compute_alignment_transform


# === 辅助函数 ===

def _make_rotation(axis, angle):
    """Rodrigues 公式构造旋转矩阵"""
    axis = axis / (np.linalg.norm(axis) + 1e-12)
    K = np.array([
        [0, -axis[2], axis[1]],
        [axis[2], 0, -axis[0]],
        [-axis[1], axis[0], 0],
    ])
    return np.eye(3) + np.sin(angle) * K + (1 - np.cos(angle)) * (K @ K)


def _make_rigid_transform(R, t):
    """构造 4×4 刚体变换矩阵"""
    T = np.eye(4)
    T[:3, :3] = R
    T[:3, 3] = t
    return T


def _perturb_transform(T, rng, rot_noise_deg, trans_noise):
    """对刚体变换施加小扰动（模拟定位噪声）"""
    # 随机旋转扰动
    axis = rng.standard_normal(3)
    axis_norm = np.linalg.norm(axis)
    if axis_norm < 1e-10:
        axis = np.array([1.0, 0.0, 0.0])
    else:
        axis = axis / axis_norm
    angle = rng.uniform(-np.radians(rot_noise_deg), np.radians(rot_noise_deg))
    dR = _make_rotation(axis, angle)

    # 随机平移扰动
    dt = rng.uniform(-trans_noise, trans_noise, size=3)

    perturbed = T.copy()
    perturbed[:3, :3] = dR @ T[:3, :3]
    perturbed[:3, 3] = T[:3, 3] + dt
    return perturbed


# === Hypothesis 策略 ===

@st.composite
def frame_set_strategy(draw):
    """生成模拟帧集合：成功帧 + 可选的救回帧。

    模拟场景：
    - 存在一个 "真实" 坐标系偏差 T_true（s2a 的真实值）
    - 成功帧的 c2w @ w2c_native ≈ T_true（小噪声）
    - 救回帧的 c2w @ w2c_native ≈ T_true（稍大噪声，但对齐后 err < 0.5）
    """
    seed = draw(st.integers(min_value=0, max_value=2**31 - 1))
    rng = np.random.default_rng(seed)

    # 生成真实坐标系偏差 T_true（小旋转 + 小平移）
    axis = rng.standard_normal(3)
    axis_norm = np.linalg.norm(axis)
    if axis_norm < 1e-10:
        axis = np.array([0.0, 0.0, 1.0])
    else:
        axis = axis / axis_norm
    # 限制旋转角度在 ±30°，模拟真实跨 session 坐标系偏差
    angle = rng.uniform(-np.radians(30), np.radians(30))
    R_true = _make_rotation(axis, angle)
    t_true = rng.uniform(-1.0, 1.0, size=3)
    T_true = _make_rigid_transform(R_true, t_true)

    # 成功帧数量 [3, 10]
    n_ok = draw(st.integers(min_value=3, max_value=10))
    # 救回帧数量 [0, 5]
    n_rescued = draw(st.integers(min_value=0, max_value=5))

    frames = []

    # 生成成功帧：s2a ≈ T_true，小噪声
    for i in range(n_ok):
        # c2w @ w2c_native ≈ T_true
        # 设 w2c_native = I（简化），则 c2w ≈ T_true
        w2c_native = np.eye(4)
        c2w = _perturb_transform(T_true, rng, rot_noise_deg=1.0, trans_noise=0.01)

        s2a = c2w @ w2c_native
        s2a_err = float(np.linalg.norm(s2a - np.eye(4)))

        frames.append({
            "frame": i,
            "status": "ok",
            "n_matches": 50,
            "n_inliers": 40,
            "inlier_ratio": 0.80,
            "s2a_err": s2a_err,
            "rot_err": 0.5,
            "w2c_native": w2c_native,
            "c2w": c2w,
        })

    # 生成救回帧：s2a ≈ T_true，稍大噪声，但对齐后 err 应 < 0.5
    for j in range(n_rescued):
        w2c_native = np.eye(4)
        # 稍大噪声（旋转 ≤ 3°，平移 ≤ 0.03），确保对齐后 err 仍然较小
        c2w = _perturb_transform(T_true, rng, rot_noise_deg=3.0, trans_noise=0.03)

        s2a = c2w @ w2c_native
        s2a_err = float(np.linalg.norm(s2a - np.eye(4)))

        frames.append({
            "frame": n_ok + j,
            "status": "pnp_outlier",
            "n_matches": 30,
            "n_inliers": 15,
            "inlier_ratio": 0.50,
            "s2a_err": s2a_err,
            "rot_err": 3.0,
            "w2c_native": w2c_native,
            "c2w": c2w,
        })

    return frames, T_true


# === Property Test ===

class TestATNonDegradationProperty:
    """Property 2: 救回帧后 AT 精度不退化

    Feature: cross-session-precision-boost, Property 2: 救回帧后 AT 精度不退化

    **Validates: Requirements 1.5**
    """

    @given(data=frame_set_strategy())
    @settings(
        max_examples=150,
        deadline=15000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_at_precision_after_rescue(self, data):
        """救回帧后重算 AT，对齐精度均值应 < 0.2。

        步骤：
        1. 用成功帧计算初始 AT
        2. 调用 rescue_outlier_frames() 救回离群帧
        3. 验证重算后所有成功帧（ok + ok_rescued）的对齐 s2a_err 均值 < 0.2

        **Validates: Requirements 1.5**
        """
        frames, T_true = data

        # 用成功帧计算初始 AT
        ok_frames = [f for f in frames if f["status"] == "ok"]
        assert len(ok_frames) >= 3, "至少需要 3 个成功帧"

        s2a_matrices = [f["c2w"] @ f["w2c_native"] for f in ok_frames]
        initial_AT = compute_alignment_transform(s2a_matrices)

        # 执行救回
        new_AT, rescued_count = rescue_outlier_frames(frames, initial_AT.copy())

        # 收集所有成功帧（ok + ok_rescued）
        success_frames = [f for f in frames if f["status"] in ("ok", "ok_rescued")]
        assert len(success_frames) >= 3, "救回后成功帧数不应少于初始成功帧数"

        # 计算重算后的对齐精度
        errs = []
        for f in success_frames:
            s2a_aligned = new_AT @ f["c2w"] @ f["w2c_native"]
            err = float(np.linalg.norm(s2a_aligned - np.eye(4)))
            errs.append(err)

        mean_err = np.mean(errs)

        # 核心断言：对齐精度均值 < 0.2
        assert mean_err < 0.2, (
            f"救回帧后对齐精度退化: mean_s2a_err={mean_err:.6f} >= 0.2, "
            f"成功帧数={len(ok_frames)}, 救回帧数={rescued_count}, "
            f"总成功帧数={len(success_frames)}"
        )
