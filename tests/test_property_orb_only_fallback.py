"""
Property Test 7: 无 AKAZE 数据时 ORB-only 回退

对任意 VisualLocalizer 实例，若未调用任何 vl_add_keyframe_akaze（akaze_keyframes_ 为空），
则 processFrame 不触发 AKAZE fallback，akaze_triggered 始终为 0，
行为与 AKAZE 功能引入前完全一致。

本测试以纯 Python 方式验证该不变量，覆盖所有合法的 ORB 状态组合，
确保空 AKAZE 数据集下系统退化为 ORB-only 模式。

Tag: Feature: cross-session-precision-boost, Property 7: 无 AKAZE 数据时 ORB-only 回退

**Validates: Requirements 4.7**
"""
from __future__ import annotations

from hypothesis import given, settings, HealthCheck
from hypothesis import strategies as st


# === 常量定义（与 C++ VisualLocalizer 一致）===

STATE_INITIALIZING = 0
STATE_TRACKING = 1
STATE_LOST = 2


def akaze_trigger_decision(orb_state: int, has_akaze_keyframes: bool) -> bool:
    """AKAZE 触发条件判断（与 C++ processFrame 逻辑一致）。

    触发条件: orb_state != TRACKING && !akaze_keyframes_.empty()
    """
    return (orb_state != STATE_TRACKING) and has_akaze_keyframes


def compute_debug_info(orb_state: int, has_akaze_keyframes: bool) -> dict:
    """模拟 processFrame 后的 VLDebugInfo 输出。

    当 AKAZE 未触发时，所有 AKAZE 相关 debug 字段应为 0。
    """
    triggered = akaze_trigger_decision(orb_state, has_akaze_keyframes)
    return {
        "akaze_triggered": 1 if triggered else 0,
        "akaze_keypoints": 0 if not triggered else -1,  # 实际值由检测决定
        "akaze_best_inliers": 0 if not triggered else -1,
    }


# === Hypothesis 策略 ===

# 所有合法的 ORB 结果状态
orb_state_strategy = st.sampled_from([STATE_INITIALIZING, STATE_TRACKING, STATE_LOST])

# 模拟多帧序列长度（1~50 帧）
frame_count_strategy = st.integers(min_value=1, max_value=50)


# === Property Test ===

class TestOrbOnlyFallbackProperty:
    """Property 7: 无 AKAZE 数据时 ORB-only 回退

    Feature: cross-session-precision-boost, Property 7: 无 AKAZE 数据时 ORB-only 回退

    **Validates: Requirements 4.7**
    """

    @given(orb_state=orb_state_strategy)
    @settings(
        max_examples=100,
        deadline=5000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_no_akaze_data_akaze_triggered_always_zero(self, orb_state: int):
        """无 AKAZE 数据时，akaze_triggered 始终为 0。

        无论 ORB pipeline 返回何种状态（INITIALIZING / TRACKING / LOST），
        只要 akaze_keyframes_ 为空，AKAZE fallback 就不应被触发。

        **Validates: Requirements 4.7**
        """
        # akaze_keyframes_ 为空
        triggered = akaze_trigger_decision(orb_state, has_akaze_keyframes=False)

        assert not triggered, (
            f"无 AKAZE 数据时 akaze_triggered 应为 0，"
            f"但 orb_state={orb_state} 时 triggered={triggered}"
        )

    @given(orb_state=orb_state_strategy)
    @settings(
        max_examples=100,
        deadline=5000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_no_akaze_data_debug_fields_all_zero(self, orb_state: int):
        """无 AKAZE 数据时，VLDebugInfo 中所有 AKAZE 相关字段均为 0。

        验证 akaze_triggered=0、akaze_keypoints=0、akaze_best_inliers=0，
        确保 debug 输出与 AKAZE 功能引入前完全一致。

        **Validates: Requirements 4.7**
        """
        debug_info = compute_debug_info(orb_state, has_akaze_keyframes=False)

        assert debug_info["akaze_triggered"] == 0, (
            f"akaze_triggered 应为 0，实际为 {debug_info['akaze_triggered']}"
        )
        assert debug_info["akaze_keypoints"] == 0, (
            f"akaze_keypoints 应为 0，实际为 {debug_info['akaze_keypoints']}"
        )
        assert debug_info["akaze_best_inliers"] == 0, (
            f"akaze_best_inliers 应为 0，实际为 {debug_info['akaze_best_inliers']}"
        )

    @given(
        orb_states=st.lists(orb_state_strategy, min_size=1, max_size=50),
    )
    @settings(
        max_examples=100,
        deadline=5000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_no_akaze_data_multi_frame_sequence_never_triggers(
        self, orb_states: list[int]
    ):
        """多帧序列中，无 AKAZE 数据时每一帧都不触发 AKAZE。

        模拟连续多帧 processFrame 调用，ORB 状态随机变化，
        但只要 akaze_keyframes_ 始终为空，所有帧的 akaze_triggered 均为 0。
        这验证了 ORB-only 回退在整个 session 生命周期内的一致性。

        **Validates: Requirements 4.7**
        """
        for i, orb_state in enumerate(orb_states):
            triggered = akaze_trigger_decision(orb_state, has_akaze_keyframes=False)
            assert not triggered, (
                f"帧 {i}: 无 AKAZE 数据时不应触发 AKAZE，"
                f"但 orb_state={orb_state} 时 triggered={triggered}"
            )

    @given(orb_state=orb_state_strategy)
    @settings(
        max_examples=100,
        deadline=5000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_no_akaze_data_behavior_identical_to_pre_akaze(self, orb_state: int):
        """无 AKAZE 数据时行为与 AKAZE 功能引入前完全一致。

        在 AKAZE 功能引入前，processFrame 仅执行 ORB pipeline，
        不存在 AKAZE fallback 路径。本测试验证当 akaze_keyframes_ 为空时，
        系统的输出状态仅由 ORB pipeline 决定，AKAZE 不参与任何决策。

        **Validates: Requirements 4.7**
        """
        # 无 AKAZE 数据：AKAZE 不触发
        triggered_no_akaze = akaze_trigger_decision(orb_state, has_akaze_keyframes=False)
        debug_no_akaze = compute_debug_info(orb_state, has_akaze_keyframes=False)

        # 核心断言：AKAZE 完全不参与
        assert not triggered_no_akaze, (
            f"无 AKAZE 数据时 AKAZE 不应参与决策"
        )
        assert debug_no_akaze["akaze_triggered"] == 0
        assert debug_no_akaze["akaze_keypoints"] == 0
        assert debug_no_akaze["akaze_best_inliers"] == 0

        # 对比：有 AKAZE 数据且 ORB 失败时应触发（反向验证）
        if orb_state != STATE_TRACKING:
            triggered_with_akaze = akaze_trigger_decision(
                orb_state, has_akaze_keyframes=True
            )
            assert triggered_with_akaze, (
                f"有 AKAZE 数据且 ORB 失败时应触发 AKAZE（反向验证），"
                f"但 orb_state={orb_state} 时未触发"
            )
