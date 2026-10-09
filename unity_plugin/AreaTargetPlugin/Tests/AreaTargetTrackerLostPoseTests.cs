using NUnit.Framework;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    public class AreaTargetTrackerLostPoseTests
    {
        [Test]
        public void RawFailure_HoldsConfirmedPoseWithoutVisualEvidence()
        {
            using (var tracker = new AreaTargetTracker())
            {
                tracker.ApplyFrameResultAt(NativeSessionBridgeTests.Raw(1, 1000000000), 1010000000);
                var confirmed = tracker.ApplyFrameResultAt(NativeSessionBridgeTests.Raw(2, 1100000000), 1110000000);
                var failed = tracker.ApplyFrameResultAt(Failure(3, 1200000000), 1210000000);
                Assert.That(failed.State, Is.EqualTo(TrackingState.TRACKING));
                Assert.That(failed.Quality, Is.EqualTo(LocalizationQuality.RECOGNIZED));
                Assert.That(failed.MatchedFeatures, Is.Zero);
                Assert.That(failed.Confidence, Is.Zero);
                NativeSessionBridgeTests.AssertPose(confirmed.Pose, failed.Pose);
            }
        }
        [Test]
        public void ManyRapidFailures_DoNotExpireByFrameCount()
        {
            using (var tracker = new AreaTargetTracker())
            {
                tracker.ApplyFrameResultAt(NativeSessionBridgeTests.Raw(1, 1000000000), 1010000000);
                tracker.ApplyFrameResultAt(NativeSessionBridgeTests.Raw(2, 1100000000), 1110000000);
                for (int i = 3; i <= 30; i++)
                {
                    var result = tracker.ApplyFrameResultAt(Failure(i, 1100000000 + i * 1000000), 1200000000 + i * 1000000);
                    Assert.That(result.State, Is.EqualTo(TrackingState.TRACKING));
                    Assert.That(result.MatchedFeatures, Is.Zero);
                }
            }
        }
        [Test]
        public void ElapsedHold_ExpiresRegardlessOfFailureCount()
        {
            using (var tracker = new AreaTargetTracker())
            {
                tracker.ApplyFrameResultAt(NativeSessionBridgeTests.Raw(1, 1000000000), 1010000000);
                tracker.ApplyFrameResultAt(NativeSessionBridgeTests.Raw(2, 1100000000), 1110000000);
                var result = tracker.ApplyFrameResultAt(Failure(3, 4200000000), 4210000000);
                Assert.That(result.State, Is.EqualTo(TrackingState.LOST));
                Assert.That(result.Quality, Is.EqualTo(LocalizationQuality.NONE));
                NativeSessionBridgeTests.AssertPose(Matrix4x4.identity, result.Pose);
            }
        }
        [Test]
        public void Reset_RequiresSharedProfileConfirmationAgain()
        {
            using (var tracker = new AreaTargetTracker())
            {
                tracker.ApplyFrameResultAt(NativeSessionBridgeTests.Raw(1, 1000000000), 1010000000);
                tracker.ApplyFrameResultAt(NativeSessionBridgeTests.Raw(2, 1100000000), 1110000000);
                tracker.Reset();
                var result = tracker.ApplyFrameResultAt(NativeSessionBridgeTests.Raw(3, 1300000000), 1310000000);
                Assert.That(result.State, Is.EqualTo(TrackingState.INITIALIZING));
                Assert.That(result.Quality, Is.EqualTo(LocalizationQuality.NONE));
            }
        }
        private static LocalizationFrameResult Failure(long id, long exposure)
        {
            var frame = new LocalizationFrame(id, exposure, new byte[4], 2, 2,
                new Vector4(100, 100, 1, 1), ImageOrientation.LandscapeRight, Matrix4x4.identity, "shared-session-fixture");
            return LocalizationFrameResult.Failed(frame, 0, exposure, exposure + 1000000,
                LocalizationFailureCategory.LocalizationFailed, default);
        }
    }
}
