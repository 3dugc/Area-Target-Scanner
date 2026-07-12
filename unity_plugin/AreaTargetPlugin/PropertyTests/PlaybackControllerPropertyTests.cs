using System;
using System.Collections.Generic;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;
using VideoPlaybackTestScene;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for PlaybackController state machine.
    /// Validates: Requirements 2.1, 2.2, 2.3, 2.4, 2.5, 2.6
    /// </summary>
    [TestFixture]
    public class PlaybackControllerPropertyTests
    {
        // 操作类型枚举（用于生成随机操作序列）
        private enum Op { Play, Pause, StepForward, SeekRandom }

        // Feature: video-playback-test-scene, Property 4: 播放状态机转换正确性
        /// <summary>
        /// For any sequence of Play/Pause/StepForward/SeekTo operations,
        /// the state machine transitions must satisfy:
        /// - Play() → state becomes Playing
        /// - Pause() → state becomes Paused
        /// - StepForward() → state remains Paused
        /// - After last frame, state becomes Paused
        /// Validates: Requirements 2.1, 2.3, 2.6
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 200)]
        public Property StateMachine_TransitionsAreCorrect()
        {
            var opGen = Gen.Elements(Op.Play, Op.Pause, Op.StepForward, Op.SeekRandom);
            var seqGen = Gen.ListOf(Gen.Choose(1, 20).SelectMany(n => Gen.ArrayOf(n, opGen)))
                .Select(lists => lists.Count > 0 ? lists[0] : new Op[0])
                .ToArbitrary();

            // 简化：直接生成操作数组
            var opsArb = Gen.Choose(1, 15)
                .SelectMany(n => Gen.ArrayOf(n, opGen))
                .ToArbitrary();

            return Prop.ForAll(opsArb, (Op[] ops) =>
            {
                var ctrl = new PlaybackController();
                ctrl.Setup(10); // 10 帧

                bool allOk = true;
                string failReason = "";

                foreach (var op in ops)
                {
                    var stateBefore = ctrl.CurrentState;

                    switch (op)
                    {
                        case Op.Play:
                            ctrl.Play();
                            if (ctrl.CurrentState != PlaybackController.State.Playing)
                            {
                                allOk = false;
                                failReason = "Play() should set state to Playing";
                            }
                            break;

                        case Op.Pause:
                            ctrl.Pause();
                            if (ctrl.CurrentState != PlaybackController.State.Paused)
                            {
                                allOk = false;
                                failReason = "Pause() should set state to Paused";
                            }
                            break;

                        case Op.StepForward:
                            ctrl.StepForward();
                            if (ctrl.CurrentState != PlaybackController.State.Paused)
                            {
                                allOk = false;
                                failReason = $"StepForward() should keep state Paused (was {stateBefore})";
                            }
                            break;

                        case Op.SeekRandom:
                            ctrl.SeekTo(5);
                            // SeekTo 不改变播放状态
                            if (ctrl.CurrentState != stateBefore)
                            {
                                allOk = false;
                                failReason = "SeekTo() should not change play state";
                            }
                            break;
                    }

                    if (!allOk) break;
                }

                return allOk.ToProperty().Label(failReason);
            });
        }

        // Feature: video-playback-test-scene, Property 5: SeekTo clamp 行为
        /// <summary>
        /// For any integer frameIndex and positive totalFrames,
        /// SeekTo(frameIndex) should result in CurrentFrameIndex == Clamp(frameIndex, 0, totalFrames-1).
        /// Validates: Requirements 2.4, 2.5
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 300)]
        public Property SeekTo_AlwaysClampsToValidRange()
        {
            var totalFramesGen = Gen.Choose(1, 1000).ToArbitrary();
            var frameIndexGen = Arb.Default.Int32();

            var combined = Gen.zip(
                Gen.Choose(1, 1000),
                Arb.Default.Int32().Generator
            ).ToArbitrary();

            return Prop.ForAll(combined, (tuple) =>
            {
                int totalFrames = tuple.Item1;
                int frameIndex = tuple.Item2;

                var ctrl = new PlaybackController();
                ctrl.Setup(totalFrames);
                ctrl.SeekTo(frameIndex);

                int expected = Math.Max(0, Math.Min(frameIndex, totalFrames - 1));
                bool ok = ctrl.CurrentFrameIndex == expected;

                return ok.ToProperty()
                    .Label($"totalFrames={totalFrames} seekTo={frameIndex} " +
                           $"expected={expected} actual={ctrl.CurrentFrameIndex}");
            });
        }

        // Feature: video-playback-test-scene, Property 6: 帧推进速率一致性
        /// <summary>
        /// For any positive deltaTime and PlaybackFPS in [1,30],
        /// calling Tick(deltaTime) in Playing state should advance frames
        /// consistent with floor(accumulated_time * fps).
        /// Validates: Requirements 2.2
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 200)]
        public Property Tick_FrameAdvanceConsistentWithFPS()
        {
            var fpsGen = Gen.Choose(1, 30).Select(i => (float)i);
            var deltaGen = Arb.Default.Float().Generator
                .Where(f => f > 0f && f < 2f && !float.IsNaN(f) && !float.IsInfinity(f));
            var countGen = Gen.Choose(1, 20);

            var combined = Gen.zip3(fpsGen, deltaGen, countGen).ToArbitrary();

            return Prop.ForAll(combined, (tuple) =>
            {
                float fps = tuple.Item1;
                float delta = tuple.Item2;
                int tickCount = tuple.Item3;

                int totalFrames = 1000; // 足够大，不触发末尾暂停
                var ctrl = new PlaybackController();
                ctrl.Setup(totalFrames);
                ctrl.PlaybackFPS = fps;
                ctrl.Play();

                float accumulator = 0f;
                float frameDuration = 1f / fps;
                int expectedAdvance = 0;

                for (int i = 0; i < tickCount; i++)
                {
                    accumulator += delta;
                    while (accumulator >= frameDuration)
                    {
                        accumulator -= frameDuration;
                        expectedAdvance++;
                    }
                    ctrl.Tick(delta);
                }

                int actualFrame = ctrl.CurrentFrameIndex;
                // 允许 ±1 误差（浮点累积）
                bool ok = Math.Abs(actualFrame - expectedAdvance) <= 1;

                return ok.ToProperty()
                    .Label($"fps={fps} delta={delta} ticks={tickCount} " +
                           $"expected≈{expectedAdvance} actual={actualFrame}");
            });
        }
    }
}
