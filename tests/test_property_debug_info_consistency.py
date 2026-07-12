"""
Property Test 11: VLDebugInfo 新增字段一致性

对任意 processFrame 调用后获取的 VLDebugInfo：
- akaze_triggered 的值为 0 或 1
- consistency_rejected 的值为 0 或 1
- 若 akaze_triggered == 0，则 akaze_keypoints == 0 且 akaze_best_inliers == 0
- 若 akaze_triggered == 1，则 akaze_keypoints >= 0 且 akaze_best_inliers >= 0

本测试以纯 Python 方式建模 VLDebugInfo 的字段约束，通过 hypothesis
生成随机 debug info 字典并验证不变量。

Tag: Feature: cross-session-precision-boost, Property 11: VLDebugInfo 新增字段一致性

**Validates: Requirements 8.1, 8.2, 8.3, 8.4**
"""
from __future__ import annotations

from hypothesis import given, settings, HealthCheck
from hypothesis import strategies as st


# === VLDebugInfo 字段约束验证 ===

def validate_debug_info(info: dict) -> list[str]:
    """验证 VLDebugInfo 新增字段的一致性约束。

    返回违反约束的错误消息列表（空列表表示全部通过）。

    约束规则（与 C++ processFrame 填充逻辑一致）:
    1. akaze_triggered ∈ {0, 1}
    2. consistency_rejected ∈ {0, 1}
    3. akaze_triggered == 0 → akaze_keypoints == 0 且 akaze_best_inliers == 0
    4. akaze_triggered == 1 → akaze_keypoints >= 0 且 akaze_best_inliers >= 0
    """
    errors = []

    # 约束 1: akaze_triggered 为 0 或 1
    if info["akaze_triggered"] not in (0, 1):
        errors.append(
            f"akaze_triggered 应为 0 或 1，实际为 {info['akaze_triggered']}"
        )

    # 约束 2: consistency_rejected 为 0 或 1
    if info["consistency_rejected"] not in (0, 1):
        errors.append(
            f"consistency_rejected 应为 0 或 1，实际为 {info['consistency_rejected']}"
        )

    # 约束 3: AKAZE 未触发时，相关计数字段必须为 0
    if info["akaze_triggered"] == 0:
        if info["akaze_keypoints"] != 0:
            errors.append(
                f"akaze_triggered=0 时 akaze_keypoints 应为 0，"
                f"实际为 {info['akaze_keypoints']}"
            )
        if info["akaze_best_inliers"] != 0:
            errors.append(
                f"akaze_triggered=0 时 akaze_best_inliers 应为 0，"
                f"实际为 {info['akaze_best_inliers']}"
            )

    # 约束 4: AKAZE 触发时，计数字段必须非负
    if info["akaze_triggered"] == 1:
        if info["akaze_keypoints"] < 0:
            errors.append(
                f"akaze_triggered=1 时 akaze_keypoints 应 >= 0，"
                f"实际为 {info['akaze_keypoints']}"
            )
        if info["akaze_best_inliers"] < 0:
            errors.append(
                f"akaze_triggered=1 时 akaze_best_inliers 应 >= 0，"
                f"实际为 {info['akaze_best_inliers']}"
            )

    return errors


def build_debug_info(
    akaze_triggered: int,
    akaze_keypoints: int,
    akaze_best_inliers: int,
    consistency_rejected: int,
) -> dict:
    """构造 VLDebugInfo 字典（仅包含新增的 4 个字段）。"""
    return {
        "akaze_triggered": akaze_triggered,
        "akaze_keypoints": akaze_keypoints,
        "akaze_best_inliers": akaze_best_inliers,
        "consistency_rejected": consistency_rejected,
    }


# === 模拟 processFrame 填充逻辑 ===

# ORB 状态枚举
STATE_TRACKING = 1
STATE_LOST = 2
STATE_INITIALIZING = 0


def simulate_process_frame_debug(
    orb_state: int,
    has_akaze_keyframes: bool,
    akaze_detected_kps: int,
    akaze_best_inlier_count: int,
    is_consistency_rejected: bool,
) -> dict:
    """模拟 processFrame 中 VLDebugInfo 新增字段的填充逻辑。

    与 C++ visual_localizer_impl.cpp 中的填充逻辑一致:
    - AKAZE 仅在 ORB 失败且有 AKAZE 数据时触发
    - 未触发时所有 AKAZE 计数字段归零
    - consistency_rejected 由一致性过滤结果决定
    """
    akaze_triggered = (orb_state != STATE_TRACKING) and has_akaze_keyframes

    if akaze_triggered:
        return build_debug_info(
            akaze_triggered=1,
            akaze_keypoints=max(0, akaze_detected_kps),
            akaze_best_inliers=max(0, akaze_best_inlier_count),
            consistency_rejected=1 if is_consistency_rejected else 0,
        )
    else:
        return build_debug_info(
            akaze_triggered=0,
            akaze_keypoints=0,
            akaze_best_inliers=0,
            consistency_rejected=1 if is_consistency_rejected else 0,
        )


# === Hypothesis 策略 ===

orb_state_strategy = st.sampled_from([STATE_INITIALIZING, STATE_TRACKING, STATE_LOST])
has_akaze_strategy = st.booleans()
keypoints_strategy = st.integers(min_value=0, max_value=5000)
inliers_strategy = st.integers(min_value=0, max_value=500)
rejected_strategy = st.booleans()


@st.composite
def valid_debug_info_strategy(draw):
    """生成符合 processFrame 填充逻辑的合法 VLDebugInfo。"""
    orb_state = draw(orb_state_strategy)
    has_akaze = draw(has_akaze_strategy)
    akaze_kps = draw(keypoints_strategy)
    akaze_inliers = draw(inliers_strategy)
    rejected = draw(rejected_strategy)

    return simulate_process_frame_debug(
        orb_state, has_akaze, akaze_kps, akaze_inliers, rejected
    )


@st.composite
def arbitrary_debug_info_strategy(draw):
    """生成任意字段值的 VLDebugInfo（可能违反约束，用于负面测试）。"""
    return build_debug_info(
        akaze_triggered=draw(st.integers(min_value=-1, max_value=2)),
        akaze_keypoints=draw(st.integers(min_value=-10, max_value=5000)),
        akaze_best_inliers=draw(st.integers(min_value=-10, max_value=500)),
        consistency_rejected=draw(st.integers(min_value=-1, max_value=2)),
    )


# === Property Tests ===

class TestDebugInfoConsistencyProperty:
    """Property 11: VLDebugInfo 新增字段一致性

    Feature: cross-session-precision-boost, Property 11: VLDebugInfo 新增字段一致性

    **Validates: Requirements 8.1, 8.2, 8.3, 8.4**
    """

    @given(info=valid_debug_info_strategy())
    @settings(
        max_examples=200,
        deadline=5000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_valid_debug_info_passes_all_invariants(self, info: dict):
        """由 processFrame 填充逻辑生成的 debug info 应满足所有不变量。

        验证 simulate_process_frame_debug 产生的输出始终满足:
        1. akaze_triggered ∈ {0, 1}
        2. consistency_rejected ∈ {0, 1}
        3. akaze_triggered=0 → akaze_keypoints=0, akaze_best_inliers=0
        4. akaze_triggered=1 → akaze_keypoints >= 0, akaze_best_inliers >= 0

        **Validates: Requirements 8.1, 8.2, 8.3, 8.4**
        """
        errors = validate_debug_info(info)
        assert not errors, (
            f"VLDebugInfo 不变量违反:\n" + "\n".join(f"  - {e}" for e in errors)
        )

    @given(
        orb_state=orb_state_strategy,
        has_akaze=has_akaze_strategy,
        akaze_kps=keypoints_strategy,
        akaze_inliers=inliers_strategy,
        rejected=rejected_strategy,
    )
    @settings(
        max_examples=200,
        deadline=5000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_akaze_not_triggered_fields_zeroed(
        self,
        orb_state: int,
        has_akaze: bool,
        akaze_kps: int,
        akaze_inliers: int,
        rejected: bool,
    ):
        """AKAZE 未触发时，akaze_keypoints 和 akaze_best_inliers 必须为 0。

        无论输入的 akaze_kps/akaze_inliers 值是多少，只要 AKAZE 未触发，
        填充逻辑应将这些字段归零。

        **Validates: Requirements 8.1, 8.2, 8.3**
        """
        info = simulate_process_frame_debug(
            orb_state, has_akaze, akaze_kps, akaze_inliers, rejected
        )

        if info["akaze_triggered"] == 0:
            assert info["akaze_keypoints"] == 0, (
                f"akaze_triggered=0 时 akaze_keypoints 应为 0，"
                f"实际为 {info['akaze_keypoints']}"
            )
            assert info["akaze_best_inliers"] == 0, (
                f"akaze_triggered=0 时 akaze_best_inliers 应为 0，"
                f"实际为 {info['akaze_best_inliers']}"
            )

    @given(
        orb_state=st.sampled_from([STATE_INITIALIZING, STATE_LOST]),
        akaze_kps=keypoints_strategy,
        akaze_inliers=inliers_strategy,
        rejected=rejected_strategy,
    )
    @settings(
        max_examples=100,
        deadline=5000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_akaze_triggered_fields_non_negative(
        self,
        orb_state: int,
        akaze_kps: int,
        akaze_inliers: int,
        rejected: bool,
    ):
        """AKAZE 触发时，akaze_keypoints 和 akaze_best_inliers 必须 >= 0。

        **Validates: Requirements 8.2, 8.3**
        """
        # has_akaze=True + ORB 非 TRACKING → AKAZE 触发
        info = simulate_process_frame_debug(
            orb_state, has_akaze_keyframes=True,
            akaze_detected_kps=akaze_kps,
            akaze_best_inlier_count=akaze_inliers,
            is_consistency_rejected=rejected,
        )

        assert info["akaze_triggered"] == 1, (
            f"ORB 失败且有 AKAZE 数据时应触发 AKAZE"
        )
        assert info["akaze_keypoints"] >= 0, (
            f"akaze_triggered=1 时 akaze_keypoints 应 >= 0，"
            f"实际为 {info['akaze_keypoints']}"
        )
        assert info["akaze_best_inliers"] >= 0, (
            f"akaze_triggered=1 时 akaze_best_inliers 应 >= 0，"
            f"实际为 {info['akaze_best_inliers']}"
        )

    @given(
        orb_state=orb_state_strategy,
        has_akaze=has_akaze_strategy,
        akaze_kps=keypoints_strategy,
        akaze_inliers=inliers_strategy,
        rejected=rejected_strategy,
    )
    @settings(
        max_examples=200,
        deadline=5000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_boolean_fields_are_binary(
        self,
        orb_state: int,
        has_akaze: bool,
        akaze_kps: int,
        akaze_inliers: int,
        rejected: bool,
    ):
        """akaze_triggered 和 consistency_rejected 只能取 0 或 1。

        **Validates: Requirements 8.1, 8.4**
        """
        info = simulate_process_frame_debug(
            orb_state, has_akaze, akaze_kps, akaze_inliers, rejected
        )

        assert info["akaze_triggered"] in (0, 1), (
            f"akaze_triggered 应为 0 或 1，实际为 {info['akaze_triggered']}"
        )
        assert info["consistency_rejected"] in (0, 1), (
            f"consistency_rejected 应为 0 或 1，"
            f"实际为 {info['consistency_rejected']}"
        )

    @given(info=arbitrary_debug_info_strategy())
    @settings(
        max_examples=200,
        deadline=5000,
        suppress_health_check=[HealthCheck.too_slow],
    )
    def test_validator_detects_invalid_debug_info(self, info: dict):
        """验证器能正确检测不合法的 VLDebugInfo 字段组合。

        生成任意字段值（可能违反约束），验证 validate_debug_info
        能准确识别所有违规情况。

        **Validates: Requirements 8.1, 8.2, 8.3, 8.4**
        """
        errors = validate_debug_info(info)

        # 逐条检查验证器是否正确报告了违规
        at = info["akaze_triggered"]
        cr = info["consistency_rejected"]
        kps = info["akaze_keypoints"]
        inl = info["akaze_best_inliers"]

        expected_error_count = 0

        # 约束 1: akaze_triggered ∈ {0, 1}
        if at not in (0, 1):
            expected_error_count += 1

        # 约束 2: consistency_rejected ∈ {0, 1}
        if cr not in (0, 1):
            expected_error_count += 1

        # 约束 3: akaze_triggered=0 → 计数字段为 0
        if at == 0:
            if kps != 0:
                expected_error_count += 1
            if inl != 0:
                expected_error_count += 1

        # 约束 4: akaze_triggered=1 → 计数字段非负
        if at == 1:
            if kps < 0:
                expected_error_count += 1
            if inl < 0:
                expected_error_count += 1

        assert len(errors) == expected_error_count, (
            f"验证器报告 {len(errors)} 个错误，预期 {expected_error_count} 个。"
            f"\n  info={info}\n  errors={errors}"
        )
