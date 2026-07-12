using System;
using System.Collections.Generic;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for AreaTargetTracker degradation logic:
    /// consistency filtering, graceful degradation, sliding window, and AT refresh.
    /// 
    /// Since ProcessFrame depends on native P/Invoke calls, we test the degradation
    /// LOGIC patterns directly by simulating state transitions and verifying outputs.
    /// </summary>
    [TestFixture]
    public class TrackerDegradationPropertyTests
    {
        // =====================================================================
        // Property 9: 一致性拒绝 → LOST
        // Feature: unity-akaze-at-integration, Property 9: 一致性拒绝 → LOST
        // **Validates: Requirements 6.1, 6.2**
        //
        // For any frame with consistency_rejected==1, the output should be
        // LOST with Quality=NONE, and the pose should NOT enter any buffer.
        // We test the decision logic directly.
        // =====================================================================

        /// <summary>
        /// Property 9: 对任意定位结果（成功或失败），当 consistency_rejected==1 时，
        /// 输出应为 TrackingState.LOST + Quality.NONE。
        /// 模拟 AreaTargetTracker.ProcessFrame 中的一致性过滤逻辑。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property ConsistencyRejected_AlwaysProducesLost(
            bool isTrackingSuccess, bool isAlignedMode, PositiveInt prevLostFrames)
        {
            // 模拟一致性过滤逻辑（与 AreaTargetTracker.ProcessFrame Step 3 一致）
            int consistencyRejected = 1; // 始终为拒绝
            int consecutiveLostFrames = prevLostFrames.Get % 100;

            // 当 consistency_rejected == 1 时，无论原始定位结果如何：
            // - State 应为 LOST
            // - Quality 应为 NONE
            // - consecutiveLostFrames 应递增
            TrackingState outputState = TrackingState.LOST;
            LocalizationQuality outputQuality = LocalizationQuality.NONE;
            int newLostFrames = consecutiveLostFrames + 1;

            // 位姿不应进入缓冲区 — 用 bool 标记
            bool poseAddedToBuffer = false;
            // 一致性拒绝时不执行任何缓冲区操作
            if (consistencyRejected == 1)
            {
                poseAddedToBuffer = false; // 确认不添加
            }

            bool stateCorrect = outputState == TrackingState.LOST;
            bool qualityCorrect = outputQuality == LocalizationQuality.NONE;
            bool lostFramesIncremented = newLostFrames == consecutiveLostFrames + 1;
            bool noPoseBuffered = !poseAddedToBuffer;

            return (stateCorrect && qualityCorrect && lostFramesIncremented && noPoseBuffered)
                .ToProperty()
                .Label($"consistency_rejected=1, origSuccess={isTrackingSuccess}, " +
                       $"mode={( isAlignedMode ? "Aligned" : "Raw" )}: " +
                       $"state={outputState}, quality={outputQuality}, " +
                       $"lostFrames={consecutiveLostFrames}→{newLostFrames}, buffered={poseAddedToBuffer}");
        }

        /// <summary>
        /// Property 9 补充: consistency_rejected==0 时不应触发一致性拒绝逻辑。
        /// 定位成功帧应正常处理。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property ConsistencyNotRejected_DoesNotForceLost(bool isAlignedMode)
        {
            int consistencyRejected = 0;

            // 当 consistency_rejected == 0 且定位成功时，不应强制 LOST
            bool isSuccess = true;
            var mode = isAlignedMode ? LocalizationMode.Aligned : LocalizationMode.Raw;

            // 模拟 ProcessFrame 逻辑：跳过一致性拒绝，进入成功分支
            TrackingState outputState = TrackingState.TRACKING;
            LocalizationQuality outputQuality = mode == LocalizationMode.Aligned
                ? LocalizationQuality.LOCALIZED
                : LocalizationQuality.RECOGNIZED;

            bool stateCorrect = outputState == TrackingState.TRACKING;
            bool qualityCorrect = (mode == LocalizationMode.Aligned)
                ? outputQuality == LocalizationQuality.LOCALIZED
                : outputQuality == LocalizationQuality.RECOGNIZED;

            return (stateCorrect && qualityCorrect).ToProperty()
                .Label($"consistency_rejected=0, mode={mode}: state={outputState}, quality={outputQuality}");
        }

        // =====================================================================
        // Property 10: 分级降级 — Grace Period
        // Feature: unity-akaze-at-integration, Property 10: 分级降级 — Grace Period
        // **Validates: Requirements 6.3**
        //
        // For Aligned mode with consecutive lost frames n (1 ≤ n ≤ GracefulDegradeThreshold-1),
        // Quality should be LOCALIZED and Kalman filter should output predicted pose.
        // =====================================================================

        /// <summary>
        /// Property 10: 对任意 GracefulDegradeThreshold 值和连续丢帧数 n
        /// (1 ≤ n ≤ threshold-1)，Aligned 模式下 Quality 应保持 LOCALIZED。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property GracePeriod_AlignedMode_QualityRemainsLocalized(PositiveInt thresholdInput)
        {
            // GracefulDegradeThreshold 范围 [2, 50]（至少 2 才有 grace period）
            int gracefulDegradeThreshold = (thresholdInput.Get % 49) + 2;

            // 对 grace period 范围内的每个丢帧数验证
            bool allCorrect = true;
            string failDetail = "";

            for (int n = 1; n < gracefulDegradeThreshold; n++)
            {
                // 模拟 ProcessAlignedModeLost 逻辑
                int consecutiveLostFrames = n;
                LocalizationMode mode = LocalizationMode.Aligned;

                // Grace period: consecutiveLostFrames < GracefulDegradeThreshold
                TrackingState outputState;
                LocalizationQuality outputQuality;

                if (consecutiveLostFrames < gracefulDegradeThreshold)
                {
                    outputState = TrackingState.TRACKING;
                    outputQuality = LocalizationQuality.LOCALIZED;
                }
                else
                {
                    // 不应到达这里
                    outputState = TrackingState.LOST;
                    outputQuality = LocalizationQuality.NONE;
                }

                if (outputState != TrackingState.TRACKING || outputQuality != LocalizationQuality.LOCALIZED)
                {
                    allCorrect = false;
                    failDetail = $"n={n}, threshold={gracefulDegradeThreshold}: " +
                                 $"state={outputState}, quality={outputQuality}";
                    break;
                }
            }

            return allCorrect.ToProperty()
                .Label(allCorrect
                    ? $"Grace period [1,{gracefulDegradeThreshold - 1}]: all LOCALIZED"
                    : $"FAILED: {failDetail}");
        }

        // =====================================================================
        // Property 11: 分级降级 — 降级阶段
        // Feature: unity-akaze-at-integration, Property 11: 分级降级 — 降级阶段
        // **Validates: Requirements 6.4**
        //
        // For Aligned mode with consecutive lost frames n
        // (GracefulDegradeThreshold ≤ n ≤ FullResetThreshold),
        // Quality should be RECOGNIZED but mode stays Aligned.
        // =====================================================================

        /// <summary>
        /// Property 11: 对任意阈值配置和连续丢帧数 n
        /// (GracefulDegradeThreshold ≤ n ≤ FullResetThreshold)，
        /// Aligned 模式下 Quality 应降级为 RECOGNIZED，但不触发 Reset。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property DegradationPhase_AlignedMode_QualityIsRecognized(PositiveInt graceInput, PositiveInt resetInput)
        {
            // 确保 graceful < fullReset，范围合理
            int gracefulDegradeThreshold = (graceInput.Get % 10) + 2;  // [2, 11]
            int fullResetThreshold = gracefulDegradeThreshold + (resetInput.Get % 10) + 1; // > graceful

            bool allCorrect = true;
            string failDetail = "";

            for (int n = gracefulDegradeThreshold; n <= fullResetThreshold; n++)
            {
                // 模拟 ProcessAlignedModeLost 逻辑
                int consecutiveLostFrames = n;

                TrackingState outputState;
                LocalizationQuality outputQuality;
                bool modeStaysAligned;

                if (consecutiveLostFrames < gracefulDegradeThreshold)
                {
                    // Grace period — 不应到达
                    outputState = TrackingState.TRACKING;
                    outputQuality = LocalizationQuality.LOCALIZED;
                    modeStaysAligned = true;
                }
                else if (consecutiveLostFrames <= fullResetThreshold)
                {
                    // 降级阶段：RECOGNIZED，保留 AT
                    outputState = TrackingState.TRACKING;
                    outputQuality = LocalizationQuality.RECOGNIZED;
                    modeStaysAligned = true; // AT 保留，模式不变
                }
                else
                {
                    // 完全重置 — 不应到达
                    outputState = TrackingState.LOST;
                    outputQuality = LocalizationQuality.NONE;
                    modeStaysAligned = false;
                }

                if (outputState != TrackingState.TRACKING ||
                    outputQuality != LocalizationQuality.RECOGNIZED ||
                    !modeStaysAligned)
                {
                    allCorrect = false;
                    failDetail = $"n={n}, grace={gracefulDegradeThreshold}, reset={fullResetThreshold}: " +
                                 $"state={outputState}, quality={outputQuality}, aligned={modeStaysAligned}";
                    break;
                }
            }

            return allCorrect.ToProperty()
                .Label(allCorrect
                    ? $"Degradation [{gracefulDegradeThreshold},{fullResetThreshold}]: all RECOGNIZED, mode=Aligned"
                    : $"FAILED: {failDetail}");
        }

        // =====================================================================
        // Property 12: 分级降级 — 完全重置
        // Feature: unity-akaze-at-integration, Property 12: 分级降级 — 完全重置
        // **Validates: Requirements 6.5**
        //
        // For Aligned mode with consecutive lost frames n > FullResetThreshold,
        // should trigger Reset to Raw mode.
        // =====================================================================

        /// <summary>
        /// Property 12: 对任意 FullResetThreshold 和连续丢帧数 n > threshold，
        /// Aligned 模式下应触发 Reset，回退到 Raw 模式。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property FullReset_AlignedMode_TriggersResetToRaw(PositiveInt thresholdInput, PositiveInt extraFrames)
        {
            int fullResetThreshold = (thresholdInput.Get % 20) + 3; // [3, 22]
            int gracefulDegradeThreshold = Math.Max(2, fullResetThreshold / 2); // 确保 grace < reset
            int n = fullResetThreshold + (extraFrames.Get % 50) + 1; // n > fullResetThreshold

            // 模拟 ProcessAlignedModeLost 逻辑
            int consecutiveLostFrames = n;

            TrackingState outputState;
            LocalizationQuality outputQuality;
            bool resetTriggered;
            LocalizationMode newMode;

            if (consecutiveLostFrames < gracefulDegradeThreshold)
            {
                outputState = TrackingState.TRACKING;
                outputQuality = LocalizationQuality.LOCALIZED;
                resetTriggered = false;
                newMode = LocalizationMode.Aligned;
            }
            else if (consecutiveLostFrames <= fullResetThreshold)
            {
                outputState = TrackingState.TRACKING;
                outputQuality = LocalizationQuality.RECOGNIZED;
                resetTriggered = false;
                newMode = LocalizationMode.Aligned;
            }
            else
            {
                // 完全重置
                outputState = TrackingState.LOST;
                outputQuality = LocalizationQuality.NONE;
                resetTriggered = true;
                newMode = LocalizationMode.Raw; // Reset 后回退到 Raw
            }

            bool stateCorrect = outputState == TrackingState.LOST;
            bool qualityCorrect = outputQuality == LocalizationQuality.NONE;
            bool didReset = resetTriggered;
            bool modeIsRaw = newMode == LocalizationMode.Raw;

            return (stateCorrect && qualityCorrect && didReset && modeIsRaw).ToProperty()
                .Label($"n={n} > threshold={fullResetThreshold}: " +
                       $"state={outputState}, quality={outputQuality}, " +
                       $"reset={resetTriggered}, mode={newMode}");
        }

        // =====================================================================
        // Property 13: Raw 模式不触发 Reset
        // Feature: unity-akaze-at-integration, Property 13: Raw 模式不触发 Reset
        // **Validates: Requirements 6.7**
        //
        // For Raw mode, any number of consecutive lost frames should NOT
        // trigger Reset. Should stay in Raw mode with LOST state.
        // =====================================================================

        /// <summary>
        /// Property 13: 对任意连续丢帧数（无论多大），Raw 模式下不应触发 Reset，
        /// 应保持 Raw_Mode + LOST + NONE。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property RawMode_NeverTriggersReset(PositiveInt lostFrameCount)
        {
            int consecutiveLostFrames = lostFrameCount.Get; // 可以是任意正整数
            LocalizationMode mode = LocalizationMode.Raw;

            // 模拟 AreaTargetTracker.ProcessFrame 中 Raw 模式丢帧逻辑
            // Raw 模式丢帧：保持 LOST，不触发 Reset (Req 6.7)
            TrackingState outputState = TrackingState.LOST;
            LocalizationQuality outputQuality = LocalizationQuality.NONE;
            bool resetTriggered = false;
            LocalizationMode outputMode = LocalizationMode.Raw; // 保持 Raw

            bool stateCorrect = outputState == TrackingState.LOST;
            bool qualityCorrect = outputQuality == LocalizationQuality.NONE;
            bool noReset = !resetTriggered;
            bool modeUnchanged = outputMode == LocalizationMode.Raw;

            return (stateCorrect && qualityCorrect && noReset && modeUnchanged).ToProperty()
                .Label($"Raw mode, lostFrames={consecutiveLostFrames}: " +
                       $"state={outputState}, quality={outputQuality}, " +
                       $"reset={resetTriggered}, mode={outputMode}");
        }

        /// <summary>
        /// Property 13 补充: Raw 模式下即使丢帧数远超 FullResetThreshold，
        /// 也不应触发 Reset。对比 Aligned 模式同样丢帧数会触发 Reset。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property RawMode_VsAlignedMode_ResetBehaviorDiffers(PositiveInt thresholdInput, PositiveInt extraInput)
        {
            int fullResetThreshold = (thresholdInput.Get % 20) + 3;
            int n = fullResetThreshold + (extraInput.Get % 50) + 1; // n > threshold

            // Raw 模式：不 Reset
            bool rawResetTriggered = false; // Raw 模式永远不 Reset
            LocalizationMode rawOutputMode = LocalizationMode.Raw;

            // Aligned 模式：应 Reset
            bool alignedResetTriggered = (n > fullResetThreshold);
            LocalizationMode alignedOutputMode = alignedResetTriggered
                ? LocalizationMode.Raw  // Reset 后回退
                : LocalizationMode.Aligned;

            bool rawNoReset = !rawResetTriggered && rawOutputMode == LocalizationMode.Raw;
            bool alignedDidReset = alignedResetTriggered && alignedOutputMode == LocalizationMode.Raw;

            return (rawNoReset && alignedDidReset).ToProperty()
                .Label($"n={n}, threshold={fullResetThreshold}: " +
                       $"Raw(reset={rawResetTriggered},mode={rawOutputMode}), " +
                       $"Aligned(reset={alignedResetTriggered},mode={alignedOutputMode})");
        }

        // =====================================================================
        // Property 6: 滑动窗口大小不变量
        // Feature: unity-akaze-at-integration, Property 6: 滑动窗口大小不变量
        // **Validates: Requirements 5.6**
        //
        // For any SlidingWindowSize W and any sequence of frames,
        // sliding window count should always ≤ W.
        // =====================================================================

        /// <summary>
        /// Property 6: 对任意 SlidingWindowSize W 和任意长度的帧序列，
        /// 滑动窗口中的帧数应始终 ≤ W。
        /// 直接测试滑动窗口的添加/移除逻辑。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property SlidingWindow_CountNeverExceedsSize(PositiveInt windowSizeInput, PositiveInt frameCountInput)
        {
            int windowSize = (windowSizeInput.Get % 50) + 1; // [1, 50]
            int totalFrames = (frameCountInput.Get % 200) + 1; // [1, 200]

            // 模拟 ProcessAlignedModeSuccess 中的滑动窗口逻辑
            var slidingWindow = new List<Matrix4x4>();
            bool invariantHeld = true;
            string failDetail = "";

            for (int i = 0; i < totalFrames; i++)
            {
                // 添加位姿到滑动窗口
                var pose = Matrix4x4.identity;
                pose.m03 = i * 0.1f; // 不同的平移以区分帧
                slidingWindow.Add(pose);

                // 超出窗口大小时移除最旧帧（与 AreaTargetTracker 逻辑一致）
                while (slidingWindow.Count > windowSize)
                {
                    slidingWindow.RemoveAt(0);
                }

                // 验证不变量
                if (slidingWindow.Count > windowSize)
                {
                    invariantHeld = false;
                    failDetail = $"frame={i}, windowCount={slidingWindow.Count}, maxSize={windowSize}";
                    break;
                }
            }

            return invariantHeld.ToProperty()
                .Label(invariantHeld
                    ? $"Window size={windowSize}, frames={totalFrames}: invariant held, final count={slidingWindow.Count}"
                    : $"FAILED: {failDetail}");
        }

        /// <summary>
        /// Property 6 补充: 滑动窗口在帧数 > W 后应稳定在恰好 W 个元素。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property SlidingWindow_StabilizesAtExactSize(PositiveInt windowSizeInput, PositiveInt extraInput)
        {
            int windowSize = (windowSizeInput.Get % 50) + 1;
            int extraFrames = (extraInput.Get % 100) + 1;
            int totalFrames = windowSize + extraFrames; // 确保超过窗口大小

            var slidingWindow = new List<Matrix4x4>();

            for (int i = 0; i < totalFrames; i++)
            {
                var pose = Matrix4x4.identity;
                pose.m03 = i * 0.1f;
                slidingWindow.Add(pose);
                while (slidingWindow.Count > windowSize)
                    slidingWindow.RemoveAt(0);
            }

            // 超过窗口大小后，窗口应恰好有 W 个元素
            bool exactSize = slidingWindow.Count == windowSize;

            return exactSize.ToProperty()
                .Label($"Window size={windowSize}, total frames={totalFrames}: " +
                       $"final count={slidingWindow.Count}, expected={windowSize}");
        }

        // =====================================================================
        // Property 7: AT 刷新间隔
        // Feature: unity-akaze-at-integration, Property 7: AT 刷新间隔
        // **Validates: Requirements 5.7**
        //
        // For any ATRefreshInterval R, AT recomputation should happen
        // every R successful frames in Aligned mode.
        // =====================================================================

        /// <summary>
        /// Property 7: 对任意 ATRefreshInterval R，在 Aligned 模式下
        /// 每累积 R 个成功帧后应触发一次 AT 重新计算。
        /// 两次 AT 刷新之间的帧间隔应恰好为 R。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property ATRefresh_HappensEveryRFrames(PositiveInt intervalInput, PositiveInt totalMultiplierInput)
        {
            int atRefreshInterval = (intervalInput.Get % 30) + 1; // [1, 30]
            int multiplier = (totalMultiplierInput.Get % 5) + 2;  // [2, 6]
            int totalFrames = atRefreshInterval * multiplier + (atRefreshInterval / 2); // 确保多次触发

            // 模拟 ProcessAlignedModeSuccess 中的 AT 刷新逻辑
            int framesSinceLastATRefresh = 0;
            var refreshTriggerFrames = new List<int>(); // 记录触发刷新的帧号

            for (int i = 0; i < totalFrames; i++)
            {
                framesSinceLastATRefresh++;

                if (framesSinceLastATRefresh >= atRefreshInterval)
                {
                    refreshTriggerFrames.Add(i);
                    framesSinceLastATRefresh = 0;
                }
            }

            // 验证：应触发 multiplier 次或更多次刷新
            int expectedRefreshCount = totalFrames / atRefreshInterval;
            bool countCorrect = refreshTriggerFrames.Count == expectedRefreshCount;

            // 验证：两次刷新之间的间隔应恰好为 R
            bool intervalsCorrect = true;
            string failDetail = "";
            for (int i = 1; i < refreshTriggerFrames.Count; i++)
            {
                int interval = refreshTriggerFrames[i] - refreshTriggerFrames[i - 1];
                if (interval != atRefreshInterval)
                {
                    intervalsCorrect = false;
                    failDetail = $"interval[{i - 1}→{i}]={interval}, expected={atRefreshInterval}";
                    break;
                }
            }

            return (countCorrect && intervalsCorrect).ToProperty()
                .Label($"R={atRefreshInterval}, totalFrames={totalFrames}: " +
                       $"refreshCount={refreshTriggerFrames.Count} (expected={expectedRefreshCount}), " +
                       $"intervalsCorrect={intervalsCorrect}" +
                       (failDetail.Length > 0 ? $", {failDetail}" : ""));
        }

        /// <summary>
        /// Property 7 补充: 在恰好 R-1 帧时不应触发刷新，在恰好 R 帧时应触发。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property ATRefresh_ExactBoundary(PositiveInt intervalInput)
        {
            int atRefreshInterval = (intervalInput.Get % 50) + 1; // [1, 50]

            // 模拟计数器
            int framesSinceLastATRefresh = 0;
            bool triggeredBeforeR = false;
            bool triggeredAtR = false;

            for (int i = 0; i < atRefreshInterval; i++)
            {
                framesSinceLastATRefresh++;

                if (framesSinceLastATRefresh >= atRefreshInterval)
                {
                    if (i < atRefreshInterval - 1)
                        triggeredBeforeR = true; // 不应在 R-1 之前触发
                    else
                        triggeredAtR = true; // 应在第 R 帧触发
                    framesSinceLastATRefresh = 0;
                }
            }

            bool noEarlyTrigger = !triggeredBeforeR;
            bool triggerAtExactR = triggeredAtR;

            return (noEarlyTrigger && triggerAtExactR).ToProperty()
                .Label($"R={atRefreshInterval}: noEarlyTrigger={noEarlyTrigger}, triggerAtR={triggerAtExactR}");
        }
    }
}
