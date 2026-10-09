using NUnit.Framework;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    [TestFixture]
    public class SharedSessionTrackerTests
    {
        [Test]
        public void FirstFreshSuccess_IsCandidateWithoutDisplayedPose()
        {
            using (var tracker = new AreaTargetTracker())
            {
                TrackingResult result = tracker.ApplyFrameResultAt(
                    NativeSessionBridgeTests.Raw(1, 1000000000), 1010000000);
                Assert.That(result.State, Is.EqualTo(TrackingState.INITIALIZING));
                Assert.That(result.Quality, Is.EqualTo(LocalizationQuality.NONE));
                Assert.That(result.MatchedFeatures, Is.Zero);
                Assert.That(result.Confidence, Is.Zero);
            }
        }

        [Test, IgnoreLogErrors]
        public void ReinitializeActiveTracker_IsRejectedWithoutMutatingMapOrAlignment()
        {
            using (var tracker = new AreaTargetTracker())
            {
                tracker.ApplyFrameResultAt(NativeSessionBridgeTests.Raw(1, 1000000000), 1010000000);
                tracker.ApplyFrameResultAt(NativeSessionBridgeTests.Raw(2, 1100000000), 1110000000);
                var flags = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance;
                var loader = (AssetBundleLoader)typeof(AreaTargetTracker).GetField("_loader", flags).GetValue(tracker);
                typeof(AssetBundleLoader).GetProperty("Manifest").SetValue(loader, new AssetManifest { name = "active-map" });
                typeof(AreaTargetTracker).GetField("_initialized", flags).SetValue(tracker, true);
                Assert.That(tracker.Initialize("/missing-reinitialization-map"), Is.False);
                Assert.That(tracker.MapId, Is.EqualTo("active-map"));
                Assert.That(tracker.GetTrackingState(), Is.EqualTo(TrackingState.TRACKING));
            }
        }

        [Test]
        public void SecondConsistentSuccess_DisplaysSharedCoreAlignment()
        {
            using (var tracker = new AreaTargetTracker())
            {
                tracker.ApplyFrameResultAt(NativeSessionBridgeTests.Raw(1, 1000000000), 1010000000);
                TrackingResult result = tracker.ApplyFrameResultAt(
                    NativeSessionBridgeTests.Raw(2, 1100000000), 1110000000);
                Assert.That(result.State, Is.EqualTo(TrackingState.TRACKING));
                Assert.That(result.Quality, Is.EqualTo(LocalizationQuality.LOCALIZED));
                NativeSessionBridgeTests.AssertPose(Matrix4x4.Translate(new Vector3(2, 3, 4)), result.Pose);
            }
        }
    }
}
