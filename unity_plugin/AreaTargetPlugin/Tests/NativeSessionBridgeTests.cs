using System;
using System.Runtime.InteropServices;
using NUnit.Framework;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    [TestFixture]
    public class NativeSessionBridgeTests
    {
        [Test]
        public void VersionedPods_MatchNative64BitAbi()
        {
            Assert.That(Marshal.SizeOf<AtcConsensusConfig>(), Is.EqualTo(32));
            Assert.That(Marshal.SizeOf<AtcConsensusResult>(), Is.EqualTo(100));
            Assert.That(Marshal.SizeOf<AtcSessionConfig>(), Is.EqualTo(64));
            Assert.That(Marshal.SizeOf<AtcRawResult>(), Is.EqualTo(144));
            Assert.That(Marshal.SizeOf<AtcTrackingSample>(), Is.EqualTo(144));
            Assert.That(Marshal.SizeOf<AtcSessionResult>(), Is.EqualTo(232));
            Assert.That(Marshal.OffsetOf<AtcRawResult>(nameof(AtcRawResult.CameraFromScan)).ToInt32(), Is.EqualTo(64));
            Assert.That(Marshal.OffsetOf<AtcTrackingSample>(nameof(AtcTrackingSample.WorldFromCamera)).ToInt32(), Is.EqualTo(80));
            Assert.That(Marshal.OffsetOf<AtcSessionResult>(nameof(AtcSessionResult.WorldFromScan)).ToInt32(), Is.EqualTo(168));
        }

        [Test]
        public void NativeDefaultProfile_ConfirmsTwoFramesThenPollExpiresWithoutRawSuccess()
        {
            using (var session = new NativeSessionBridge())
            {
                TrackingResult first = session.Update(Raw(1, 1000000000), 1010000000);
                Assert.That(first.State, Is.EqualTo(TrackingState.INITIALIZING));
                Assert.That(first.Quality, Is.EqualTo(LocalizationQuality.NONE));
                TrackingResult confirmed = session.Update(Raw(2, 1100000000), 1110000000);
                Assert.That(confirmed.State, Is.EqualTo(TrackingState.TRACKING));
                Assert.That(confirmed.Quality, Is.EqualTo(LocalizationQuality.LOCALIZED));
                Assert.That(confirmed.MatchedFeatures, Is.EqualTo(50));
                TrackingResult held = session.Poll(1200000000);
                Assert.That(held.State, Is.EqualTo(TrackingState.TRACKING));
                Assert.That(held.MatchedFeatures, Is.Zero);
                Assert.That(held.Confidence, Is.Zero);
                AssertPose(confirmed.Pose, held.Pose);
                TrackingResult expired = session.Poll(4200000000);
                Assert.That(expired.State, Is.EqualTo(TrackingState.LOST));
                Assert.That(expired.Quality, Is.EqualTo(LocalizationQuality.NONE));
                AssertPose(Matrix4x4.identity, expired.Pose);
            }
        }

        [Test]
        public void Reset_ClearsConfirmedAlignmentAndRequiresNewConfirmation()
        {
            using (var session = new NativeSessionBridge())
            {
                session.Update(Raw(1, 1000000000), 1010000000);
                session.Update(Raw(2, 1100000000), 1110000000);
                session.Reset(1, 0);
                Assert.That(session.Poll(1200000000).Quality, Is.EqualTo(LocalizationQuality.NONE));
                Assert.That(session.Update(Raw(3, 1300000000, 1), 1310000000).State,
                    Is.EqualTo(TrackingState.INITIALIZING));
            }
        }

        [Test]
        public void OldExposure_IsRejectedByNativeResultAgePolicy()
        {
            using (var session = new NativeSessionBridge())
            {
                session.Update(Raw(1, 1000000000), 1010000000);
                session.Update(Raw(2, 1100000000), 1110000000);
                TrackingResult stale = session.Update(Raw(3, 1200000000), 5000000000);
                Assert.That(stale.Quality, Is.EqualTo(LocalizationQuality.NONE));
                Assert.That(stale.MatchedFeatures, Is.Zero);
                Assert.That(session.LastNativeResult.RejectionReason, Is.EqualTo(10));
            }
        }

        [Test]
        public void FreshExposureWithOlderFrameId_IsRejectedByNativeOrderPolicy()
        {
            using (var session = new NativeSessionBridge())
            {
                session.Update(Raw(1, 1000000000), 1010000000);
                session.Update(Raw(2, 1100000000), 1110000000);
                var reordered = session.Update(Raw(1, 1200000000), 1210000000);
                Assert.That(reordered.MatchedFeatures, Is.Zero);
                Assert.That(reordered.Confidence, Is.Zero);
                Assert.That(session.LastNativeResult.RejectionReason, Is.EqualTo(8));
            }
        }

        [Test]
        public void HandednessConversion_MapsKnownControlPointAndRoundTrips()
        {
            Matrix4x4 legacy = Matrix4x4.Translate(new Vector3(2, 3, -4));
            Matrix4x4 optical = NativeSessionBridge.LegacyCameraToOptical(legacy);
            Assert.That(optical.MultiplyPoint3x4(new Vector3(1, 2, -5)),
                Is.EqualTo(new Vector3(3, -5, 9)));
            Matrix4x4 camera = NativeSessionBridge.UnityCameraToRightHandedOptical(Matrix4x4.identity);
            Matrix4x4 content = NativeSessionBridge.RightHandedWorldToUnity(camera * optical);
            Assert.That(content.MultiplyPoint3x4(new Vector3(1, 2, 5)),
                Is.EqualTo(new Vector3(3, 5, 9)));
            Assert.That(CoordinateTransform.IsFiniteRigidTransform(camera), Is.True);
            Assert.That(CoordinateTransform.IsFiniteRigidTransform(content), Is.True);
        }

        [Test]
        public void CompatibilityConsensus_RejectsInconsistentMeasuredPairs()
        {
            var pairs = new System.Collections.Generic.List<LocalizationFramePair>();
            foreach (float x in new[] { 1f, 2f, 3f })
                pairs.Add(new LocalizationFramePair(Matrix4x4.Translate(new Vector3(x, 0, 0)), Matrix4x4.identity));
            Assert.That(AlignmentTransformCalculator.TryCompute(pairs, out _), Is.False);
        }

        internal static LocalizationFrameResult Raw(long id, long timestamp, long generation = 0)
        {
            var frame = new LocalizationFrame(id, timestamp, new byte[4], 2, 2,
                new Vector4(100, 100, 1, 1), ImageOrientation.LandscapeRight,
                Matrix4x4.identity, "shared-session-fixture");
            return LocalizationFrameResult.Succeeded(frame, generation, timestamp, timestamp + 1000000,
                Matrix4x4.Translate(new Vector3(2, 3, -4)),
                LocalizationQuality.RECOGNIZED, .8f, 50, default);
        }

        internal static void AssertPose(Matrix4x4 expected, Matrix4x4 actual)
        {
            for (int row = 0; row < 4; row++)
                for (int col = 0; col < 4; col++)
                    Assert.That(actual[row, col], Is.EqualTo(expected[row, col]).Within(1e-5));
        }
    }
}
