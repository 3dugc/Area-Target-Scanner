using System;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Unit tests for tracking state management and resource lifecycle.
    /// Validates: Requirements 14.1, 14.4, 14.5
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class TrackingStateTests
    {
        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
        }

        #region Initial State Tests (Requirement 14.1)

        [Test]
        public void NewTracker_InitialState_IsInitializing()
        {
            var tracker = new AreaTargetTracker();

            Assert.AreEqual(TrackingState.INITIALIZING, tracker.GetTrackingState());
            tracker.Dispose();
        }

        #endregion

        #region ProcessFrame Without Initialization Tests (Requirement 14.1)

        [Test]
        public void ProcessFrame_NotInitialized_ReturnsLost()
        {
            var tracker = new AreaTargetTracker();
            var frame = CreateDummyFrame();

            TrackingResult result = tracker.ProcessFrame(frame);

            Assert.AreEqual(TrackingState.LOST, result.State);
            Assert.AreEqual(0f, result.Confidence);
            Assert.AreEqual(0, result.MatchedFeatures);
            tracker.Dispose();
        }

        [Test]
        public void ProcessFrame_AfterDispose_ReturnsLost()
        {
            var tracker = new AreaTargetTracker();
            tracker.Dispose();

            var frame = CreateDummyFrame();
            TrackingResult result = tracker.ProcessFrame(frame);

            Assert.AreEqual(TrackingState.LOST, result.State);
            Assert.AreEqual(0f, result.Confidence);
            Assert.AreEqual(0, result.MatchedFeatures);
        }

        #endregion

        #region Reset Tests (Requirement 14.4)

        [Test]
        public void Reset_SetsStateToInitializing()
        {
            var tracker = new AreaTargetTracker();

            tracker.Reset();

            Assert.AreEqual(TrackingState.INITIALIZING, tracker.GetTrackingState());
            tracker.Dispose();
        }

        [Test]
        public void Reset_WhenNotInitialized_DoesNotThrow()
        {
            var tracker = new AreaTargetTracker();

            Assert.DoesNotThrow(() => tracker.Reset());
            tracker.Dispose();
        }

        #endregion

        #region Dispose Tests (Requirement 14.5)

        [Test]
        public void Dispose_SetsStateToLost()
        {
            var tracker = new AreaTargetTracker();

            tracker.Dispose();

            Assert.AreEqual(TrackingState.LOST, tracker.GetTrackingState());
        }

        [Test]
        public void Initialize_AfterDispose_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            var tracker = new AreaTargetTracker();
            tracker.Dispose();

            bool result = tracker.Initialize("/any/path");

            Assert.IsFalse(result);
        }

        [Test]
        public void Dispose_CalledMultipleTimes_DoesNotThrow()
        {
            var tracker = new AreaTargetTracker();

            Assert.DoesNotThrow(() =>
            {
                tracker.Dispose();
                tracker.Dispose();
                tracker.Dispose();
            });
        }

        #endregion

        #region Helper Methods

        private static CameraFrame CreateDummyFrame()
        {
            return new CameraFrame
            {
                ImageData = new byte[100],
                Width = 10,
                Height = 10,
                Intrinsics = Matrix4x4.identity
            };
        }

        #endregion
    }
}
