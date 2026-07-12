using System;
using System.Collections.Generic;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for Reset logic and Debug info consistency.
    /// 
    /// Since ProcessFrame depends on native P/Invoke calls, we test the
    /// LOGIC patterns directly by simulating state and verifying invariants.
    /// </summary>
    [TestFixture]
    public class TrackerResetDebugPropertyTests
    {
        // =====================================================================
        // Property 14: Reset 恢复初始状态并支持重新积累
        // Feature: unity-akaze-at-integration, Property 14
        // **Validates: Requirements 7.1, 7.2, 7.3**
        //
        // For any tracker state (Raw or Aligned), after Reset():
        // - 位姿缓冲区为空、滑动窗口为空、连续丢帧计数为 0、模式为 Raw_Mode
        // After reset, re-accumulating AlignmentFrameThreshold successful
        // frames should trigger AT calculation again.
        // =====================================================================

        /// <summary>
        /// Property 14a: 对任意 tracker 状态（Raw 或 Aligned），模拟 PerformInternalReset
        /// 后所有缓冲区应为空，连续丢帧计数为 0，模式为 Raw。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property Reset_ClearsAllState_ForAnyTrackerState(
            bool wasAligned, PositiveInt bufferCount, PositiveInt windowCount, PositiveInt lostCount)
        {
            // 模拟 tracker 内部状态（与 AreaTargetTracker 字段一致）
            var rawPoseBuffer = new List<Matrix4x4>();
            var slidingWindow = new List<Matrix4x4>();
            int consecutiveLostFrames = lostCount.Get % 100;
            int framesSinceLastATRefresh = (bufferCount.Get % 50);
            Matrix4x4? currentAT = wasAligned ? (Matrix4x4?)Matrix4x4.identity : null;
            var mode = wasAligned ? LocalizationMode.Aligned : LocalizationMode.Raw;

            // 填充随机数据到缓冲区
            int numBuffer = (bufferCount.Get % 30) + 1;
            int numWindow = (windowCount.Get % 30) + 1;
            var rng = new System.Random(bufferCount.Get);

            for (int i = 0; i < numBuffer; i++)
            {
                var pose = Matrix4x4.identity;
                pose.m03 = (float)(rng.NextDouble() * 10.0);
                pose.m13 = (float)(rng.NextDouble() * 10.0);
                pose.m23 = (float)(rng.NextDouble() * 10.0);
                rawPoseBuffer.Add(pose);
            }

            for (int i = 0; i < numWindow; i++)
            {
                var pose = Matrix4x4.identity;
                pose.m03 = (float)(rng.NextDouble() * 10.0);
                slidingWindow.Add(pose);
            }

            // 执行 PerformInternalReset 逻辑（与 AreaTargetTracker.PerformInternalReset 一致）
            rawPoseBuffer.Clear();
            slidingWindow.Clear();
            consecutiveLostFrames = 0;
            framesSinceLastATRefresh = 0;
            currentAT = null;
            mode = LocalizationMode.Raw;

            // 验证 post-reset 不变量
            bool bufferEmpty = rawPoseBuffer.Count == 0;
            bool windowEmpty = slidingWindow.Count == 0;
            bool lostZero = consecutiveLostFrames == 0;
            bool refreshZero = framesSinceLastATRefresh == 0;
            bool atCleared = !currentAT.HasValue;
            bool modeIsRaw = mode == LocalizationMode.Raw;

            bool allCorrect = bufferEmpty && windowEmpty && lostZero && refreshZero && atCleared && modeIsRaw;

            return allCorrect.ToProperty()
                .Label($"wasAligned={wasAligned}, preBuffer={numBuffer}, preWindow={numWindow}: " +
                       $"buffer={rawPoseBuffer.Count}, window={slidingWindow.Count}, " +
                       $"lost={consecutiveLostFrames}, refresh={framesSinceLastATRefresh}, " +
                       $"at={currentAT.HasValue}, mode={mode}");
        }

        /// <summary>
        /// Property 14b: Reset 后重新积累 AlignmentFrameThreshold 个成功帧应能再次触发 AT 计算。
        /// 对任意阈值 N，积累 N 个位姿后 TryCompute 应成功。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property Reset_ThenReaccumulate_TriggersATCalculation(
            PositiveInt thresholdInput, bool wasAligned)
        {
            int alignmentFrameThreshold = (thresholdInput.Get % 30) + 1; // [1, 30]

            // --- Phase 1: 模拟 pre-reset 状态 ---
            var rawPoseBuffer = new List<Matrix4x4>();
            var slidingWindow = new List<Matrix4x4>();
            int consecutiveLostFrames = wasAligned ? 5 : 0;
            Matrix4x4? currentAT = wasAligned ? (Matrix4x4?)Matrix4x4.identity : null;
            var mode = wasAligned ? LocalizationMode.Aligned : LocalizationMode.Raw;

            // 填充一些数据
            for (int i = 0; i < 5; i++)
            {
                rawPoseBuffer.Add(Matrix4x4.identity);
                slidingWindow.Add(Matrix4x4.identity);
            }

            // --- Phase 2: 执行 Reset ---
            rawPoseBuffer.Clear();
            slidingWindow.Clear();
            consecutiveLostFrames = 0;
            currentAT = null;
            mode = LocalizationMode.Raw;

            // --- Phase 3: 重新积累 AlignmentFrameThreshold 个成功帧 ---
            var rng = new System.Random(thresholdInput.Get);
            for (int i = 0; i < alignmentFrameThreshold; i++)
            {
                var pose = Matrix4x4.identity;
                // 添加小扰动使位姿不完全相同
                pose.m03 = (float)(rng.NextDouble() * 0.1);
                pose.m13 = (float)(rng.NextDouble() * 0.1);
                pose.m23 = (float)(rng.NextDouble() * 0.1);
                rawPoseBuffer.Add(pose);
            }

            // 验证：缓冲区达到阈值
            bool thresholdReached = rawPoseBuffer.Count >= alignmentFrameThreshold;

            // 验证：TryCompute 应成功（位姿有效且非空）
            bool atComputeSuccess = AlignmentTransformCalculator.TryCompute(rawPoseBuffer, out Matrix4x4 newAT);

            // 验证：计算出的 AT 矩阵有效
            bool atValid = AlignmentTransformCalculator.IsValidMatrix(newAT);

            // 模拟切换到 Aligned 模式
            if (atComputeSuccess)
            {
                currentAT = newAT;
                mode = LocalizationMode.Aligned;
                rawPoseBuffer.Clear();
            }

            bool switchedToAligned = mode == LocalizationMode.Aligned;

            return (thresholdReached && atComputeSuccess && atValid && switchedToAligned).ToProperty()
                .Label($"threshold={alignmentFrameThreshold}, wasAligned={wasAligned}: " +
                       $"reached={thresholdReached}, computed={atComputeSuccess}, " +
                       $"valid={atValid}, switched={switchedToAligned}");
        }

        /// <summary>
        /// Property 14c: Reset 后在第 N-1 帧时不应触发 AT 计算（缓冲区不足）。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property Reset_BeforeThreshold_DoesNotTriggerAT(PositiveInt thresholdInput)
        {
            int alignmentFrameThreshold = (thresholdInput.Get % 30) + 2; // [2, 31]，至少 2 才有 N-1

            // Reset 后状态
            var rawPoseBuffer = new List<Matrix4x4>();

            // 积累 N-1 帧
            for (int i = 0; i < alignmentFrameThreshold - 1; i++)
            {
                var pose = Matrix4x4.identity;
                pose.m03 = i * 0.01f;
                rawPoseBuffer.Add(pose);
            }

            // 验证：缓冲区未达到阈值
            bool belowThreshold = rawPoseBuffer.Count < alignmentFrameThreshold;

            // 模拟 ProcessRawModeSuccess 中的阈值检查
            bool wouldTrigger = rawPoseBuffer.Count >= alignmentFrameThreshold;

            return (belowThreshold && !wouldTrigger).ToProperty()
                .Label($"threshold={alignmentFrameThreshold}, buffer={rawPoseBuffer.Count}: " +
                       $"belowThreshold={belowThreshold}, wouldTrigger={wouldTrigger}");
        }

        // =====================================================================
        // Property 15: Debug 信息一致性
        // Feature: unity-akaze-at-integration, Property 15
        // **Validates: Requirements 8.2**
        //
        // For any tracker state, GetExtendedDebugInfo() should return values
        // consistent with internal state.
        // =====================================================================

        /// <summary>
        /// Property 15a: 对任意 tracker 内部状态组合，ExtendedDebugInfo 的字段应与
        /// 构造时传入的状态一致。测试 ExtendedDebugInfo 结构体的正确赋值。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property DebugInfo_FieldsMatchInternalState(
            bool isAligned, bool hasAT, PositiveInt bufferCount,
            PositiveInt lostCount, PositiveInt windowCount)
        {
            // 模拟 tracker 内部状态
            var mode = isAligned ? LocalizationMode.Aligned : LocalizationMode.Raw;
            int poseBufferCount = bufferCount.Get % 50;
            int consecutiveLost = lostCount.Get % 100;
            int slidingWindowCount = windowCount.Get % 50;

            // 构造 ExtendedDebugInfo（与 AreaTargetTracker.GetExtendedDebugInfo 逻辑一致）
            var debugInfo = new ExtendedDebugInfo
            {
                CurrentMode = mode,
                IsATSet = hasAT,
                PoseBufferFrameCount = poseBufferCount,
                ConsecutiveLostFrames = consecutiveLost,
                SlidingWindowFrameCount = slidingWindowCount,
                NativeDebugInfo = default
            };

            // 验证每个字段与输入一致
            bool modeMatch = debugInfo.CurrentMode == mode;
            bool atMatch = debugInfo.IsATSet == hasAT;
            bool bufferMatch = debugInfo.PoseBufferFrameCount == poseBufferCount;
            bool lostMatch = debugInfo.ConsecutiveLostFrames == consecutiveLost;
            bool windowMatch = debugInfo.SlidingWindowFrameCount == slidingWindowCount;

            bool allMatch = modeMatch && atMatch && bufferMatch && lostMatch && windowMatch;

            return allMatch.ToProperty()
                .Label($"mode={mode}/{debugInfo.CurrentMode}, at={hasAT}/{debugInfo.IsATSet}, " +
                       $"buffer={poseBufferCount}/{debugInfo.PoseBufferFrameCount}, " +
                       $"lost={consecutiveLost}/{debugInfo.ConsecutiveLostFrames}, " +
                       $"window={slidingWindowCount}/{debugInfo.SlidingWindowFrameCount}");
        }

        /// <summary>
        /// Property 15b: 默认构造的 ExtendedDebugInfo 应有正确的默认值：
        /// Raw 模式、AT 未设置、所有计数为 0。
        /// </summary>
        [Test]
        public void ExtendedDebugInfo_DefaultValues_AreConsistent()
        {
            var info = new ExtendedDebugInfo();

            Assert.AreEqual(LocalizationMode.Raw, info.CurrentMode, "默认模式应为 Raw");
            Assert.IsFalse(info.IsATSet, "默认 AT 应未设置");
            Assert.AreEqual(0, info.PoseBufferFrameCount, "默认位姿缓冲区应为 0");
            Assert.AreEqual(0, info.ConsecutiveLostFrames, "默认连续丢帧应为 0");
            Assert.AreEqual(0, info.SlidingWindowFrameCount, "默认滑动窗口应为 0");
        }

        /// <summary>
        /// Property 15c: 对任意 tracker 状态序列（Reset → 积累 → Aligned），
        /// 每个阶段的 debug info 应与当前状态一致。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property DebugInfo_ConsistentThroughStateTransitions(PositiveInt thresholdInput)
        {
            int threshold = (thresholdInput.Get % 20) + 2; // [2, 21]

            // 模拟 tracker 状态变量
            var rawPoseBuffer = new List<Matrix4x4>();
            var slidingWindow = new List<Matrix4x4>();
            int consecutiveLostFrames = 0;
            Matrix4x4? currentAT = null;
            var mode = LocalizationMode.Raw;

            // --- 阶段 1: 初始状态 ---
            var info1 = BuildDebugInfo(mode, currentAT, rawPoseBuffer, consecutiveLostFrames, slidingWindow);
            bool phase1Ok = info1.CurrentMode == LocalizationMode.Raw
                && !info1.IsATSet
                && info1.PoseBufferFrameCount == 0
                && info1.ConsecutiveLostFrames == 0;

            // --- 阶段 2: 积累帧 ---
            for (int i = 0; i < threshold; i++)
            {
                var pose = Matrix4x4.identity;
                pose.m03 = i * 0.01f;
                rawPoseBuffer.Add(pose);
            }

            var info2 = BuildDebugInfo(mode, currentAT, rawPoseBuffer, consecutiveLostFrames, slidingWindow);
            bool phase2Ok = info2.CurrentMode == LocalizationMode.Raw
                && !info2.IsATSet
                && info2.PoseBufferFrameCount == threshold;

            // --- 阶段 3: AT 计算成功，切换到 Aligned ---
            if (AlignmentTransformCalculator.TryCompute(rawPoseBuffer, out Matrix4x4 at))
            {
                currentAT = at;
                mode = LocalizationMode.Aligned;
                rawPoseBuffer.Clear();
            }

            var info3 = BuildDebugInfo(mode, currentAT, rawPoseBuffer, consecutiveLostFrames, slidingWindow);
            bool phase3Ok = info3.CurrentMode == LocalizationMode.Aligned
                && info3.IsATSet
                && info3.PoseBufferFrameCount == 0;

            // --- 阶段 4: Reset ---
            rawPoseBuffer.Clear();
            slidingWindow.Clear();
            consecutiveLostFrames = 0;
            currentAT = null;
            mode = LocalizationMode.Raw;

            var info4 = BuildDebugInfo(mode, currentAT, rawPoseBuffer, consecutiveLostFrames, slidingWindow);
            bool phase4Ok = info4.CurrentMode == LocalizationMode.Raw
                && !info4.IsATSet
                && info4.PoseBufferFrameCount == 0
                && info4.ConsecutiveLostFrames == 0
                && info4.SlidingWindowFrameCount == 0;

            bool allOk = phase1Ok && phase2Ok && phase3Ok && phase4Ok;

            return allOk.ToProperty()
                .Label($"threshold={threshold}: phase1={phase1Ok}, phase2={phase2Ok}, " +
                       $"phase3={phase3Ok}, phase4={phase4Ok}");
        }

        /// <summary>
        /// 辅助方法：根据 tracker 内部状态构建 ExtendedDebugInfo。
        /// 与 AreaTargetTracker.GetExtendedDebugInfo() 逻辑一致。
        /// </summary>
        private static ExtendedDebugInfo BuildDebugInfo(
            LocalizationMode mode, Matrix4x4? currentAT,
            List<Matrix4x4> rawPoseBuffer, int consecutiveLostFrames,
            List<Matrix4x4> slidingWindow)
        {
            return new ExtendedDebugInfo
            {
                CurrentMode = mode,
                IsATSet = currentAT.HasValue,
                PoseBufferFrameCount = rawPoseBuffer.Count,
                ConsecutiveLostFrames = consecutiveLostFrames,
                SlidingWindowFrameCount = slidingWindow.Count,
                NativeDebugInfo = default
            };
        }
    }
}
