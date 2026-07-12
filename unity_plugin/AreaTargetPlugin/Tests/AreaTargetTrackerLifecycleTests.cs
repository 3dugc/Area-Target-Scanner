using System;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Lifecycle and state machine tests for AreaTargetTracker.
    /// Covers: dispose safety, reset behavior, ProcessFrame after dispose,
    /// double-init, and state transitions.
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class AreaTargetTrackerLifecycleTests
    {
        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
        }

        #region Dispose Safety

        [Test]
        public void Dispose_MultipleCalls_DoesNotThrow()
        {
            var tracker = new AreaTargetTracker();
            Assert.DoesNotThrow(() =>
            {
                tracker.Dispose();
                tracker.Dispose();
                tracker.Dispose();
            });
        }

        [Test]
        public void Dispose_SetsStateLost()
        {
            var tracker = new AreaTargetTracker();
            tracker.Dispose();
            Assert.AreEqual(TrackingState.LOST, tracker.GetTrackingState());
        }

        [Test]
        public void ProcessFrame_AfterDispose_ReturnsLost()
        {
            var tracker = new AreaTargetTracker();
            tracker.Dispose();

            var frame = new CameraFrame
            {
                ImageData = new byte[100],
                Width = 10,
                Height = 10,
                Intrinsics = Matrix4x4.identity
            };

            TrackingResult result = tracker.ProcessFrame(frame);

            Assert.AreEqual(TrackingState.LOST, result.State);
            Assert.AreEqual(0f, result.Confidence);
            Assert.AreEqual(0, result.MatchedFeatures);
        }

        [Test]
        public void Initialize_AfterDispose_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            var tracker = new AreaTargetTracker();
            tracker.Dispose();

            bool result = tracker.Initialize("/some/path");

            Assert.IsFalse(result);
        }

        #endregion

        #region Reset Behavior

        [Test]
        public void Reset_BeforeInitialize_DoesNotThrow()
        {
            var tracker = new AreaTargetTracker();
            Assert.DoesNotThrow(() => tracker.Reset());
            tracker.Dispose();
        }

        [Test]
        public void Reset_SetsStateToInitializing()
        {
            var tracker = new AreaTargetTracker();
            // Even without initialization, Reset should set state
            tracker.Reset();
            Assert.AreEqual(TrackingState.INITIALIZING, tracker.GetTrackingState());
            tracker.Dispose();
        }

        #endregion

        #region Initial State

        [Test]
        public void NewTracker_StateIsInitializing()
        {
            var tracker = new AreaTargetTracker();
            Assert.AreEqual(TrackingState.INITIALIZING, tracker.GetTrackingState());
            tracker.Dispose();
        }

        [Test]
        public void ProcessFrame_BeforeInit_ReturnsLostWithIdentityPose()
        {
            var tracker = new AreaTargetTracker();
            var frame = new CameraFrame
            {
                ImageData = new byte[64 * 64],
                Width = 64,
                Height = 64,
                Intrinsics = Matrix4x4.identity
            };

            TrackingResult result = tracker.ProcessFrame(frame);

            Assert.AreEqual(TrackingState.LOST, result.State);
            Assert.AreEqual(Matrix4x4.identity, result.Pose);
            tracker.Dispose();
        }

        #endregion

        #region KalmanPoseFilter Integration

        /// <summary>
        /// Tests that KalmanPoseFilter.PoseToState and StateToPose are inverse operations
        /// for an identity pose.
        /// </summary>
        [Test]
        public void KalmanFilter_PoseToState_StateToPose_RoundTrip_Identity()
        {
            float[] state = KalmanPoseFilter.PoseToState(Matrix4x4.identity);
            Assert.AreEqual(6, state.Length); // [x, y, z, rx, ry, rz]
            Assert.AreEqual(0f, state[0], 0.001f); // x
            Assert.AreEqual(0f, state[1], 0.001f); // y
            Assert.AreEqual(0f, state[2], 0.001f); // z

            Matrix4x4 restored = KalmanPoseFilter.StateToPose(state);
            Assert.AreEqual(1f, restored.m00, 0.01f);
            Assert.AreEqual(1f, restored.m11, 0.01f);
            Assert.AreEqual(1f, restored.m22, 0.01f);
            Assert.AreEqual(1f, restored.m33, 0.01f);
        }

        /// <summary>
        /// Tests that KalmanPoseFilter.PoseToState extracts correct translation.
        /// </summary>
        [Test]
        public void KalmanFilter_PoseToState_ExtractsTranslation()
        {
            var pose = Matrix4x4.identity;
            pose.m03 = 5f;
            pose.m13 = -3f;
            pose.m23 = 7f;

            float[] state = KalmanPoseFilter.PoseToState(pose);

            Assert.AreEqual(5f, state[0], 0.001f);
            Assert.AreEqual(-3f, state[1], 0.001f);
            Assert.AreEqual(7f, state[2], 0.001f);
        }

        /// <summary>
        /// Tests that KalmanPoseFilter.Reset clears internal state so next Update
        /// starts fresh.
        /// </summary>
        [Test]
        public void KalmanFilter_Reset_ThenUpdate_DoesNotThrow()
        {
            var filter = new KalmanPoseFilter();

            // Feed some poses
            filter.Update(Matrix4x4.identity);
            filter.Update(Matrix4x4.TRS(new Vector3(1, 0, 0), Quaternion.identity, Vector3.one));

            // Reset
            filter.Reset();

            // Should work fine after reset
            Matrix4x4 result = filter.Update(Matrix4x4.identity);
            Assert.AreEqual(1f, result.m33, 0.01f);
        }

        /// <summary>
        /// Tests that KalmanPoseFilter smooths consecutive identical poses to approximately
        /// the same pose (convergence).
        /// </summary>
        [Test]
        public void KalmanFilter_RepeatedIdenticalPose_ConvergesToInput()
        {
            var filter = new KalmanPoseFilter();
            var targetPose = Matrix4x4.TRS(new Vector3(2, 3, 4), Quaternion.identity, Vector3.one);

            Matrix4x4 result = Matrix4x4.identity;
            for (int i = 0; i < 50; i++)
            {
                result = filter.Update(targetPose);
            }

            // After many identical updates, should converge close to target
            Assert.AreEqual(2f, result.m03, 0.1f);
            Assert.AreEqual(3f, result.m13, 0.1f);
            Assert.AreEqual(4f, result.m23, 0.1f);
        }

        /// <summary>
        /// Tests EulerToMatrix → MatrixToEuler round-trip for small angles.
        /// </summary>
        [Test]
        public void KalmanFilter_EulerRoundTrip_SmallAngles()
        {
            float rx = 0.1f, ry = 0.2f, rz = 0.3f;
            Matrix4x4 m = KalmanPoseFilter.EulerToMatrix(rx, ry, rz);
            float[] euler = KalmanPoseFilter.MatrixToEuler(m);

            Assert.AreEqual(rx, euler[0], 0.01f);
            Assert.AreEqual(ry, euler[1], 0.01f);
            Assert.AreEqual(rz, euler[2], 0.01f);
        }

        #endregion
    }
}
