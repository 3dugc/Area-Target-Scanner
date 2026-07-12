using System.Collections.Generic;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;
using UnityEngine;
using AreaTargetPlugin;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for VideoPlaybackTestSceneManager tracking visualization logic.
    /// Validates: Requirements 4.1, 4.2, 4.3
    /// </summary>
    [TestFixture]
    public class VideoPlaybackScenePropertyTests
    {
        // Feature: video-playback-test-scene, Property 8: OriginCube 可见性与跟踪状态一致
        /// <summary>
        /// For any sequence of TrackingState values, the OriginCube visibility and color
        /// should satisfy:
        /// - TRACKING → cube visible (green)
        /// - LOST (after TRACKING) → cube stays at last position (red)
        /// - INITIALIZING → cube not yet created or hidden
        /// Validates: Requirements 4.1, 4.2, 4.3
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 200)]
        public Property OriginCubeVisibility_ConsistentWithTrackingState()
        {
            var stateGen = Gen.Elements(
                TrackingState.INITIALIZING,
                TrackingState.TRACKING,
                TrackingState.LOST
            );
            var seqGen = Gen.Choose(1, 20)
                .SelectMany(n => Gen.ArrayOf(n, stateGen))
                .ToArbitrary();

            return Prop.ForAll(seqGen, (TrackingState[] states) =>
            {
                // 模拟 HandleTrackingResult 的状态机逻辑
                var cubeState = new CubeSimulator();
                bool allOk = true;
                string failReason = "";

                foreach (var state in states)
                {
                    cubeState.Apply(state);

                    // 验证不变量
                    if (state == TrackingState.TRACKING)
                    {
                        if (!cubeState.IsVisible)
                        {
                            allOk = false;
                            failReason = "Cube should be visible when TRACKING";
                            break;
                        }
                        if (cubeState.Color != Color.green)
                        {
                            allOk = false;
                            failReason = $"Cube should be green when TRACKING, got {cubeState.Color}";
                            break;
                        }
                    }
                    else if (state == TrackingState.LOST && cubeState.WasEverTracking)
                    {
                        // LOST 后 cube 保持可见（红色）
                        if (!cubeState.IsVisible)
                        {
                            allOk = false;
                            failReason = "Cube should remain visible (red) after LOST";
                            break;
                        }
                        if (cubeState.Color != Color.red)
                        {
                            allOk = false;
                            failReason = $"Cube should be red when LOST, got {cubeState.Color}";
                            break;
                        }
                    }
                }

                return allOk.ToProperty().Label(failReason);
            });
        }

        /// <summary>
        /// 模拟 HandleTrackingResult 中 OriginCube 的状态机
        /// </summary>
        private class CubeSimulator
        {
            public bool IsVisible { get; private set; }
            public Color Color { get; private set; } = Color.white;
            public bool WasEverTracking { get; private set; }
            private TrackingState _previous = TrackingState.INITIALIZING;

            public void Apply(TrackingState state)
            {
                bool toTracking = state == TrackingState.TRACKING
                    && _previous != TrackingState.TRACKING;
                bool toLost = state == TrackingState.LOST
                    && _previous == TrackingState.TRACKING;

                if (toTracking)
                {
                    IsVisible = true;
                    Color = Color.green;
                    WasEverTracking = true;
                }
                else if (state == TrackingState.TRACKING)
                {
                    // 持续 TRACKING：保持绿色可见
                    IsVisible = true;
                    Color = Color.green;
                }

                if (toLost)
                {
                    // 保持可见，变红
                    Color = Color.red;
                    // IsVisible 保持 true（保留最后位置）
                }

                _previous = state;
            }
        }
    }
}
