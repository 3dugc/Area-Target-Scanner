using NUnit.Framework;
using VideoPlaybackTestScene;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Unit tests for PlaybackController state machine.
    /// Validates: Requirements 2.1, 2.2, 2.3, 2.4, 2.5, 2.6
    /// </summary>
    [TestFixture]
    public class PlaybackControllerTests
    {
        private PlaybackController _ctrl;

        [SetUp]
        public void SetUp()
        {
            _ctrl = new PlaybackController();
            _ctrl.Setup(10);
        }

        // --- Setup ---

        [Test]
        public void Setup_InitialState_IsPaused()
        {
            Assert.AreEqual(PlaybackController.State.Paused, _ctrl.CurrentState);
        }

        [Test]
        public void Setup_InitialFrameIndex_IsZero()
        {
            Assert.AreEqual(0, _ctrl.CurrentFrameIndex);
        }

        [Test]
        public void Setup_HasNewFrame_IsFalse()
        {
            Assert.IsFalse(_ctrl.HasNewFrame);
        }

        // --- Play / Pause ---

        [Test]
        public void Play_SetsStatePlaying()
        {
            _ctrl.Play();
            Assert.AreEqual(PlaybackController.State.Playing, _ctrl.CurrentState);
        }

        [Test]
        public void Pause_SetsStatePaused()
        {
            _ctrl.Play();
            _ctrl.Pause();
            Assert.AreEqual(PlaybackController.State.Paused, _ctrl.CurrentState);
        }

        [Test]
        public void PlayPause_Toggle_WorksRepeatedly()
        {
            _ctrl.Play();
            _ctrl.Pause();
            _ctrl.Play();
            Assert.AreEqual(PlaybackController.State.Playing, _ctrl.CurrentState);
        }

        // --- StepForward ---

        [Test]
        public void StepForward_WhenPaused_AdvancesOneFrame()
        {
            _ctrl.StepForward();
            Assert.AreEqual(1, _ctrl.CurrentFrameIndex);
        }

        [Test]
        public void StepForward_WhenPaused_RemainsPaused()
        {
            _ctrl.StepForward();
            Assert.AreEqual(PlaybackController.State.Paused, _ctrl.CurrentState);
        }

        [Test]
        public void StepForward_WhenPaused_SetsHasNewFrame()
        {
            _ctrl.StepForward();
            Assert.IsTrue(_ctrl.HasNewFrame);
        }

        [Test]
        public void StepForward_WhenPlaying_DoesNotAdvance()
        {
            _ctrl.Play();
            _ctrl.StepForward();
            Assert.AreEqual(0, _ctrl.CurrentFrameIndex);
        }

        [Test]
        public void StepForward_AtLastFrame_DoesNotExceedBound()
        {
            _ctrl.SeekTo(9); // 最后一帧（totalFrames=10）
            _ctrl.StepForward();
            Assert.AreEqual(9, _ctrl.CurrentFrameIndex);
        }

        // --- SeekTo ---

        [Test]
        public void SeekTo_ValidIndex_SetsFrameIndex()
        {
            _ctrl.SeekTo(5);
            Assert.AreEqual(5, _ctrl.CurrentFrameIndex);
        }

        [Test]
        public void SeekTo_SetsHasNewFrame()
        {
            _ctrl.SeekTo(3);
            Assert.IsTrue(_ctrl.HasNewFrame);
        }

        [Test]
        public void SeekTo_NegativeIndex_ClampsToZero()
        {
            _ctrl.SeekTo(-1);
            Assert.AreEqual(0, _ctrl.CurrentFrameIndex);
        }

        [Test]
        public void SeekTo_Zero_SetsZero()
        {
            _ctrl.SeekTo(5);
            _ctrl.SeekTo(0);
            Assert.AreEqual(0, _ctrl.CurrentFrameIndex);
        }

        [Test]
        public void SeekTo_LastFrame_SetsLastFrame()
        {
            _ctrl.SeekTo(9);
            Assert.AreEqual(9, _ctrl.CurrentFrameIndex);
        }

        [Test]
        public void SeekTo_BeyondLastFrame_ClampsToLast()
        {
            _ctrl.SeekTo(10);
            Assert.AreEqual(9, _ctrl.CurrentFrameIndex);
        }

        [Test]
        public void SeekTo_IntMaxValue_ClampsToLast()
        {
            _ctrl.SeekTo(int.MaxValue);
            Assert.AreEqual(9, _ctrl.CurrentFrameIndex);
        }

        // --- Tick ---

        [Test]
        public void Tick_WhenPaused_DoesNotAdvanceFrame()
        {
            _ctrl.Tick(1.0f);
            Assert.AreEqual(0, _ctrl.CurrentFrameIndex);
        }

        [Test]
        public void Tick_At10FPS_After0_1s_AdvancesOneFrame()
        {
            _ctrl.PlaybackFPS = 10f;
            _ctrl.Play();
            _ctrl.Tick(0.1f);
            Assert.AreEqual(1, _ctrl.CurrentFrameIndex);
        }

        [Test]
        public void Tick_At10FPS_After0_05s_DoesNotAdvance()
        {
            _ctrl.PlaybackFPS = 10f;
            _ctrl.Play();
            _ctrl.Tick(0.05f);
            Assert.AreEqual(0, _ctrl.CurrentFrameIndex);
        }

        [Test]
        public void Tick_At10FPS_After0_3s_AdvancesThreeFrames()
        {
            _ctrl.PlaybackFPS = 10f;
            _ctrl.Play();
            _ctrl.Tick(0.1f);
            _ctrl.Tick(0.1f);
            _ctrl.Tick(0.1f);
            Assert.AreEqual(3, _ctrl.CurrentFrameIndex);
        }

        [Test]
        public void Tick_ReachesLastFrame_AutoPauses()
        {
            _ctrl.Setup(3);
            _ctrl.PlaybackFPS = 10f;
            _ctrl.Play();
            // 3 ticks × 0.1s = 3 frames, but only 3 total (indices 0,1,2)
            _ctrl.Tick(0.1f); // → frame 1
            _ctrl.Tick(0.1f); // → frame 2 (last)
            _ctrl.Tick(0.1f); // 已在最后一帧，应暂停
            Assert.AreEqual(PlaybackController.State.Paused, _ctrl.CurrentState);
            Assert.AreEqual(2, _ctrl.CurrentFrameIndex);
        }

        [Test]
        public void Tick_ReachesLastFrame_SetsHasNewFrame()
        {
            _ctrl.Setup(2);
            _ctrl.PlaybackFPS = 10f;
            _ctrl.Play();
            _ctrl.Tick(0.1f); // → frame 1 (last), auto-pause
            Assert.IsTrue(_ctrl.HasNewFrame);
        }

        // --- PlaybackFPS clamp ---

        [Test]
        public void PlaybackFPS_BelowMin_ClampsTo1()
        {
            _ctrl.PlaybackFPS = 0f;
            Assert.AreEqual(1f, _ctrl.PlaybackFPS);
        }

        [Test]
        public void PlaybackFPS_AboveMax_ClampsTo30()
        {
            _ctrl.PlaybackFPS = 100f;
            Assert.AreEqual(30f, _ctrl.PlaybackFPS);
        }

        [Test]
        public void PlaybackFPS_ValidValue_IsSet()
        {
            _ctrl.PlaybackFPS = 15f;
            Assert.AreEqual(15f, _ctrl.PlaybackFPS);
        }

        // --- HasNewFrame 消费行为 ---

        [Test]
        public void Tick_ClearsHasNewFrameAtStart()
        {
            _ctrl.StepForward(); // sets HasNewFrame = true
            _ctrl.Play();
            _ctrl.Tick(0.001f); // 不足以推进帧，但应清除 HasNewFrame
            Assert.IsFalse(_ctrl.HasNewFrame);
        }
    }
}
