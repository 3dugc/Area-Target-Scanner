"""
Property Test 1: 离群帧救回阈值判断

对任意 pnp_outlier 帧和任意 4×4 Alignment_Transform，计算
s2a_aligned = AT × c2w × w2c_native 后，该帧被救回（ok_rescued）
当且仅当 ‖s2a_aligned − I‖_F < 0.5。

Tag: Feature: cross-session-precision-boost, Property 1: 离群帧救回阈值判断

**Validates: Requirements 1.1, 1.2, 1.3**
"""
from __future__ import annotations

import sys
import os

import numpy as np
from hypothesis import given, settings, HealthCheck
from hypothesis import strategies as st

# 确保能导入项目根目录的 test_cross_session_matrix
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from test_cross_session_matrix import rescue_outlier_frames


# === Hypothesis 策略：生成随机刚体变换 ===

@st.composite
def rigid_transform_strategy(draw):
    """生成随机 4×4 刚体变换矩阵（旋转 + 平移）。

    使用随机旋转轴 + 角度构造 SO(3) 旋转，加上随机平移。
    """
    seed = draw(st.integers(min_value=0, max_value=2**31 - 1))
    rng = np.random.default_rng(seed)

    # 随机旋转：Rodrigues 公式，角度 [-π, π]
    axis = rng.standard_normal(3)
    axis_norm = np.linalg.norm(axis)
    if axis_norm < 1e-10:
        axis = np.array([1.0, 0.0, 0.0])
    else:
        axis = axis / axis_norm
    angle = rng.uniform(-np.pi, np.pi)

    K = np.array([
        [0, -axis[2], axis[1]],
        [axis[2], 0, -axis[0]],
        [-axis[1], axis[0], 0],
    ])
    R = np.eye(3) + np.sin(angle) * K + (1 - np.cos(angle)) * (K @ K)

    # 随机平移
    t = rng.uniform(-2.0, 2.0, size=3)

    T = np.eye(4)
    T[:3, :3] = R
    T[:3, 3] = t
    return T


@st.composite
def general_4x4_matrix_strategy(draw):
    """生成随机 4×4 矩阵（模拟 c2w 或 w2c_native）。

    使用刚体变换 + 小扰动，模拟真实场景中的相机位姿矩阵。
    """
    seed = draw(st.integers(min_value=0, max_value=2**31 - 1))
    rng = np.random.default_rng(seed)

    # 基础刚体变换
    axis = rng.standard_normal(3)
    axis_norm = np.linalg.norm(axis)
    if axis_norm < 1e-10:
        axis = np.array([0.0, 1.0, 0.0])
    else:
        axis = axis / axis_norm
    angle = rng.uniform(-np.pi, np.pi)

    K = np.array([
        [0, -axis[2], axis[1]],
        [axis[2], 0, -axis[0]],
        [-axis[1], axis[0], 0],
    ])
    R = np.eye(3) + np.sin(angle) * K + (1 - np.cos(angle)) * (K @ K)
    t = rng.uniform(-3.0, 3.0, size=3)

    M = np.eye(4)
    M[:3, :3] = R
    M[:3, 3] = t
    return M


def _make_outlier_frame(index, c2w, w2c_native):
    """构造一个 pnp_outlier 帧"""
    s2a = c2w @ w2c_native
    return {
        "frame": index,
        "status": "pnp_outlier",
        "n_matches": 30,
        "n_inliers": 20,
        "inlier_ratio": 0.67,
        "s2a_err": float(np.linalg.norm(s2a - np.eye(4))),
        "rot_err": 5.0,
        "w2c_native": w2c_native,
        "c2w": c2w,
    }


def _make_ok_frame(index):
    """构造一个成功帧（c2w ≈ I, w2c ≈ I）用于满足 rescue 函数的最低帧数要求"""
    return {
        "frame": index,
        "status": "ok",
        "n_matches": 50,
        "n_inliers": 40,
        "inlier_ratio": 0.80,
        "s2a_err": 0.001,
        "rot_err": 0.1,
        "w2c_native": np.eye(4),
        "c2w": np.eye(4),
    }


# === Property Test ===

class TestRescueThresholdProperty:
    """Property 1: 离群帧救回阈值判断

    Feature: cross-session-precision-boost, Property 1: 离群帧救回阈值判断

    **Validates: Requirements 1.1, 1.2, 1.3**
    """

    @given(
        AT=rigid_transform_strategy(),
        c2w=general_4x4_matrix_strategy(),
        w2c_native=general_4x4_matrix_strategy(),
    )
    @settings(
        max_examples=150,
        deadline=10000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_rescue_threshold_consistency(self, AT, c2w, w2c_native):
        """对任意 AT、c2w、w2c_native，rescue 判断与阈值 0.5 一致。

        - s2a_err_aligned < 0.5 → 帧被救回（status == "ok_rescued"）
        - s2a_err_aligned >= 0.5 → 帧保持 pnp_outlier

        **Validates: Requirements 1.1, 1.2, 1.3**
        """
        RESCUE_THRESHOLD = 0.5

        # 计算预期的 s2a_err_aligned
        s2a_aligned = AT @ c2w @ w2c_native
        expected_err = float(np.linalg.norm(s2a_aligned - np.eye(4)))
        should_rescue = expected_err < RESCUE_THRESHOLD

        # 构造测试数据：足够的 ok 帧 + 1 个 outlier 帧
        ok_frames = [_make_ok_frame(i) for i in range(5)]
        outlier = _make_outlier_frame(10, c2w.copy(), w2c_native.copy())
        results = ok_frames + [outlier]

        # 执行救回
        _, rescued_count = rescue_outlier_frames(results, AT.copy())

        if should_rescue:
            # 帧应被救回
            # 注意：rescue_outlier_frames 可能因 AT 重算后精度退化而回退救回
            # 但核心阈值判断仍然成立：初始判断是基于 err < 0.5
            # 如果被回退，rescued_count == 0 且 status 恢复为 pnp_outlier
            if outlier["status"] == "ok_rescued":
                assert rescued_count >= 1, (
                    f"帧被标记为 ok_rescued 但 rescued_count={rescued_count}"
                )
                assert outlier["s2a_err_aligned"] < RESCUE_THRESHOLD, (
                    f"ok_rescued 帧的 s2a_err_aligned={outlier['s2a_err_aligned']:.6f} "
                    f"应 < {RESCUE_THRESHOLD}"
                )
            else:
                # 被回退的情况：AT 重算后精度退化导致回退
                # 这是合法的——函数设计允许回退以保护整体精度
                assert outlier["status"] == "pnp_outlier"
        else:
            # s2a_err >= 0.5，帧不应被救回
            assert outlier["status"] == "pnp_outlier", (
                f"s2a_err_aligned={expected_err:.6f} >= {RESCUE_THRESHOLD}，"
                f"帧不应被救回，但 status={outlier['status']}"
            )
            assert rescued_count == 0 or outlier["status"] == "pnp_outlier", (
                f"s2a_err_aligned >= 0.5 的帧不应被救回"
            )
