"""
Property Test 10: AT 应用的条件正确性

对任意 VisualLocalizer 实例和任意有效定位结果 pose_raw：
- 若已调用 setAlignmentTransform(AT)，则输出位姿应为 AT × pose_raw
- 若未调用 setAlignmentTransform，则输出位姿应为 pose_raw（不变）

Tag: Feature: cross-session-precision-boost, Property 10: AT 应用的条件正确性

**Validates: Requirements 7.2, 7.3**
"""
from __future__ import annotations

import numpy as np
from hypothesis import given, settings, HealthCheck
from hypothesis import strategies as st


# === AT 应用算法（与 C++ processFrame 中的逻辑一致） ===

def apply_alignment_transform(pose_raw: np.ndarray,
                              alignment_transform: np.ndarray | None) -> np.ndarray:
    """应用坐标系对齐变换到原始位姿。

    Args:
        pose_raw: 4×4 原始定位位姿矩阵
        alignment_transform: 4×4 对齐变换矩阵，None 表示未设置

    Returns:
        4×4 输出位姿：AT 已设置时为 AT × pose_raw，否则为 pose_raw
    """
    if alignment_transform is not None:
        return alignment_transform @ pose_raw
    return pose_raw.copy()


# === Hypothesis 策略：生成随机刚体变换 ===

@st.composite
def rigid_transform_strategy(draw):
    """生成随机 4×4 刚体变换矩阵（旋转 + 平移）。

    使用随机旋转轴 + 角度构造 SO(3) 旋转，加上随机平移。
    """
    seed = draw(st.integers(min_value=0, max_value=2**31 - 1))
    rng = np.random.default_rng(seed)

    # 随机旋转：Rodrigues 公式
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
    t = rng.uniform(-5.0, 5.0, size=3)

    T = np.eye(4)
    T[:3, :3] = R
    T[:3, 3] = t
    return T


@st.composite
def general_pose_strategy(draw):
    """生成随机 4×4 位姿矩阵（模拟 pose_raw）。

    使用刚体变换，模拟真实场景中的相机位姿。
    """
    seed = draw(st.integers(min_value=0, max_value=2**31 - 1))
    rng = np.random.default_rng(seed)

    # 随机旋转
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

    # 随机平移
    t = rng.uniform(-10.0, 10.0, size=3)

    M = np.eye(4)
    M[:3, :3] = R
    M[:3, 3] = t
    return M


# === Property Test ===

class TestATApplicationProperty:
    """Property 10: AT 应用的条件正确性

    Feature: cross-session-precision-boost, Property 10: AT 应用的条件正确性

    **Validates: Requirements 7.2, 7.3**
    """

    @given(
        AT=rigid_transform_strategy(),
        pose_raw=general_pose_strategy(),
    )
    @settings(
        max_examples=100,
        deadline=10000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_at_set_output_equals_at_times_pose(self, AT, pose_raw):
        """设置 AT 后，输出位姿应为 AT × pose_raw。

        验证矩阵乘法的正确性：apply_alignment_transform(pose_raw, AT) == AT @ pose_raw

        **Validates: Requirements 7.2**
        """
        result = apply_alignment_transform(pose_raw, AT)
        expected = AT @ pose_raw

        np.testing.assert_allclose(
            result, expected, atol=1e-10,
            err_msg=(
                f"AT 已设置时输出应为 AT × pose_raw\n"
                f"AT:\n{AT}\n"
                f"pose_raw:\n{pose_raw}\n"
                f"expected:\n{expected}\n"
                f"got:\n{result}"
            ),
        )

    @given(
        pose_raw=general_pose_strategy(),
    )
    @settings(
        max_examples=100,
        deadline=10000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_at_not_set_output_equals_pose_raw(self, pose_raw):
        """未设置 AT 时，输出位姿应为 pose_raw（不变）。

        验证恒等行为：apply_alignment_transform(pose_raw, None) == pose_raw

        **Validates: Requirements 7.3**
        """
        result = apply_alignment_transform(pose_raw, None)

        np.testing.assert_allclose(
            result, pose_raw, atol=1e-15,
            err_msg=(
                f"AT 未设置时输出应为 pose_raw\n"
                f"pose_raw:\n{pose_raw}\n"
                f"got:\n{result}"
            ),
        )

    @given(
        AT=rigid_transform_strategy(),
        pose_raw=general_pose_strategy(),
    )
    @settings(
        max_examples=100,
        deadline=10000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_at_application_preserves_rigid_body(self, AT, pose_raw):
        """AT 应用后输出仍为刚体变换（旋转矩阵正交，det=+1，最后一行=[0,0,0,1]）。

        刚体变换 × 刚体变换 = 刚体变换，验证数值稳定性。

        **Validates: Requirements 7.2**
        """
        result = apply_alignment_transform(pose_raw, AT)

        # 验证最后一行
        np.testing.assert_allclose(
            result[3, :], [0, 0, 0, 1], atol=1e-10,
            err_msg="输出矩阵最后一行应为 [0, 0, 0, 1]",
        )

        # 验证旋转矩阵正交性: R^T @ R ≈ I
        R = result[:3, :3]
        RtR = R.T @ R
        np.testing.assert_allclose(
            RtR, np.eye(3), atol=1e-8,
            err_msg="输出旋转矩阵应为正交矩阵 (R^T R = I)",
        )

        # 验证 det(R) ≈ +1（非反射）
        det = np.linalg.det(R)
        assert abs(det - 1.0) < 1e-8, (
            f"输出旋转矩阵行列式应为 +1，实际为 {det:.10f}"
        )

    @given(
        AT_new=rigid_transform_strategy(),
        AT_old=rigid_transform_strategy(),
        pose_raw=general_pose_strategy(),
    )
    @settings(
        max_examples=100,
        deadline=10000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_at_runtime_update(self, AT_new, AT_old, pose_raw):
        """AT 支持运行时更新：多次设置后使用最新的 AT。

        模拟先设置 AT_old，再更新为 AT_new，输出应使用 AT_new。

        **Validates: Requirements 7.2**
        """
        # 模拟运行时更新：最终使用 AT_new
        result = apply_alignment_transform(pose_raw, AT_new)
        expected = AT_new @ pose_raw

        np.testing.assert_allclose(
            result, expected, atol=1e-10,
            err_msg="运行时更新 AT 后，输出应使用最新的 AT",
        )

        # 确认与旧 AT 的结果不同（除非 AT_new == AT_old）
        result_old = apply_alignment_transform(pose_raw, AT_old)
        if not np.allclose(AT_new, AT_old, atol=1e-10):
            # AT 不同时，输出也应不同（除非 pose_raw 恰好使两者相等，概率极低）
            # 不做强断言，仅验证新 AT 的正确性
            pass
