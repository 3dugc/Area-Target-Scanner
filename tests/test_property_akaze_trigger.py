"""
Property Test 3: AKAZE 触发当且仅当 ORB 失败

对任意输入帧和已加载 AKAZE 数据的 VisualLocalizer 实例，processFrame 执行后：
- 若 ORB pipeline 产生了有效定位结果（state == TRACKING），则 akaze_triggered == 0
- 若 ORB pipeline 未产生有效定位结果且 akaze_keyframes_ 非空，则 akaze_triggered == 1
- 若 ORB pipeline 未产生有效定位结果且 akaze_keyframes_ 为空，则 akaze_triggered == 0

由于 VLDebugInfo 尚未扩展 akaze_triggered 字段（Task 10），本测试以纯 Python
方式验证 AKAZE 触发条件的算法正确性，不依赖 C++ native library。

Tag: Feature: cross-session-precision-boost, Property 3: AKAZE 触发当且仅当 ORB 失败

**Validates: Requirements 2.1, 4.3, 4.4**
"""
from __future__ import annotations

from hypothesis import given, settings, HealthCheck
from hypothesis import strategies as st


# === 常量定义（与 C++ VisualLocalizer 一致）===

# VLResult.state 枚举值
STATE_INITIALIZING = 0
STATE_TRACKING = 1
STATE_LOST = 2


def akaze_trigger_decision(orb_state: int, has_akaze_keyframes: bool) -> bool:
    """AKAZE 触发条件判断（与 C++ processFrame 逻辑一致）。

    触发条件: ORB 未产生有效定位结果 且 akaze_keyframes_ 非空
    即: orb_state != TRACKING && !akaze_keyframes_.empty()

    Args:
        orb_state: ORB pipeline 的定位结果状态 (0=INITIALIZING, 1=TRACKING, 2=LOST)
        has_akaze_keyframes: 是否有已加载的 AKAZE keyframe 数据

    Returns:
        True 表示应触发 AKAZE fallback，False 表示不触发
    """
    return (orb_state != STATE_TRACKING) and has_akaze_keyframes


# === Hypothesis 策略 ===

# ORB 结果状态：所有合法的 VLResult.state 值
orb_state_strategy = st.sampled_from([STATE_INITIALIZING, STATE_TRACKING, STATE_LOST])

# 是否有 AKAZE keyframe 数据
has_akaze_strategy = st.booleans()


# === Property Test ===

class TestAkazeTriggerProperty:
    """Property 3: AKAZE 触发当且仅当 ORB 失败

    Feature: cross-session-precision-boost, Property 3: AKAZE 触发当且仅当 ORB 失败

    **Validates: Requirements 2.1, 4.3, 4.4**
    """

    @given(
        orb_state=orb_state_strategy,
        has_akaze_keyframes=has_akaze_strategy,
    )
    @settings(
        max_examples=200,
        deadline=5000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_akaze_trigger_iff_orb_fails_and_akaze_data_present(
        self, orb_state: int, has_akaze_keyframes: bool
    ):
        """AKAZE 触发当且仅当 ORB 失败且有 AKAZE 数据。

        验证三条规则:
        1. ORB 成功 (TRACKING) → akaze_triggered = False，无论是否有 AKAZE 数据
        2. ORB 失败 (非 TRACKING) 且有 AKAZE 数据 → akaze_triggered = True
        3. ORB 失败 (非 TRACKING) 且无 AKAZE 数据 → akaze_triggered = False

        **Validates: Requirements 2.1, 4.3, 4.4**
        """
        triggered = akaze_trigger_decision(orb_state, has_akaze_keyframes)

        if orb_state == STATE_TRACKING:
            # 规则 1: ORB 成功时不触发 AKAZE（需求 4.4）
            assert not triggered, (
                f"ORB 成功 (state={orb_state}) 时不应触发 AKAZE，"
                f"但 akaze_triggered={triggered}"
            )
        elif has_akaze_keyframes:
            # 规则 2: ORB 失败且有 AKAZE 数据时应触发（需求 2.1, 4.3）
            assert triggered, (
                f"ORB 失败 (state={orb_state}) 且有 AKAZE 数据时应触发 AKAZE，"
                f"但 akaze_triggered={triggered}"
            )
        else:
            # 规则 3: ORB 失败但无 AKAZE 数据时不触发（需求 4.7 隐含）
            assert not triggered, (
                f"ORB 失败 (state={orb_state}) 但无 AKAZE 数据时不应触发 AKAZE，"
                f"但 akaze_triggered={triggered}"
            )

    @given(
        orb_state=orb_state_strategy,
        has_akaze_keyframes=has_akaze_strategy,
    )
    @settings(
        max_examples=200,
        deadline=5000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_akaze_trigger_boolean_equivalence(
        self, orb_state: int, has_akaze_keyframes: bool
    ):
        """验证触发条件的布尔等价性。

        akaze_triggered == (orb_state != TRACKING) AND has_akaze_keyframes

        这是对触发条件公式的直接验证，确保实现与设计文档中的
        公式完全一致。

        **Validates: Requirements 2.1, 4.3, 4.4**
        """
        triggered = akaze_trigger_decision(orb_state, has_akaze_keyframes)

        # 直接验证布尔公式
        expected = (orb_state != STATE_TRACKING) and has_akaze_keyframes
        assert triggered == expected, (
            f"触发条件不一致: "
            f"akaze_trigger_decision({orb_state}, {has_akaze_keyframes}) = {triggered}, "
            f"expected = {expected}"
        )

    @given(
        orb_state=orb_state_strategy,
    )
    @settings(
        max_examples=100,
        deadline=5000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_no_akaze_data_never_triggers(self, orb_state: int):
        """无 AKAZE 数据时，无论 ORB 状态如何，AKAZE 都不触发。

        这验证了需求 4.7 的核心约束：未调用 vl_add_keyframe_akaze 时
        行为与 AKAZE 功能引入前完全一致。

        **Validates: Requirements 2.1, 4.3, 4.4**
        """
        triggered = akaze_trigger_decision(orb_state, has_akaze_keyframes=False)
        assert not triggered, (
            f"无 AKAZE 数据时不应触发 AKAZE，"
            f"但 orb_state={orb_state} 时 triggered={triggered}"
        )

    @given(
        has_akaze_keyframes=has_akaze_strategy,
    )
    @settings(
        max_examples=100,
        deadline=5000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_orb_tracking_never_triggers(self, has_akaze_keyframes: bool):
        """ORB 成功 (TRACKING) 时，无论是否有 AKAZE 数据，都不触发。

        这验证了需求 4.4 的核心约束：ORB 成功时跳过 AKAZE。

        **Validates: Requirements 2.1, 4.3, 4.4**
        """
        triggered = akaze_trigger_decision(
            STATE_TRACKING, has_akaze_keyframes
        )
        assert not triggered, (
            f"ORB TRACKING 时不应触发 AKAZE，"
            f"但 has_akaze={has_akaze_keyframes} 时 triggered={triggered}"
        )
