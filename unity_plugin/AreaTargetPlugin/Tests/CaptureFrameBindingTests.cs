using NUnit.Framework;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    public class CaptureFrameBindingTests
    {
        [Test]
        public void KnownProviderClockAndSameExposure_MapWithoutFreshening()
        {
            var snapshot = new CapturePoseSnapshot(2000000000, 3000000000,
                Matrix4x4.Translate(new Vector3(1, 2, 3)), 7, 2, true);
            Assert.That(CaptureFrameBinding.TryBind(2.0, snapshot,
                new FixedOffsetCaptureClockMapper(1000000000, 9), 12, out var binding), Is.True);
            Assert.That(binding.CaptureTimestampNs, Is.EqualTo(3000000000));
            Assert.That(binding.TrackingMetadata.PoseTimestampNs, Is.EqualTo(3000000000));
            Assert.That(binding.TrackingMetadata.ClockMappingValid, Is.True);
            Assert.That(binding.TrackingMetadata.CaptureClockEpoch, Is.EqualTo(9));
            Assert.That(binding.UnityWorldFromCamera.m03, Is.EqualTo(1));
        }
        [Test]
        public void UnprovenClockOrPose_PreservesImageExposureButDisablesAlignment()
        {
            var snapshot = new CapturePoseSnapshot(2000000000, 9000000000,
                Matrix4x4.identity, 0, 2, false);
            Assert.That(CaptureFrameBinding.TryBind(2.0, snapshot, null, 1, out var binding), Is.True);
            Assert.That(binding.CaptureTimestampNs, Is.EqualTo(2000000000));
            Assert.That(binding.TrackingMetadata.ClockMappingValid, Is.False);
            Assert.That(binding.TrackingMetadata.ExtrinsicsValid, Is.False);
        }
        [Test]
        public void CpuImageFromDifferentEvent_DoesNotBorrowLatestPose()
        {
            var snapshot = new CapturePoseSnapshot(2000000000, 3000000000,
                Matrix4x4.identity, 0, 2, true);
            CaptureFrameBinding.TryBind(1.9, snapshot, new FixedOffsetCaptureClockMapper(1000000000), 1, out var binding);
            Assert.That(binding.CaptureTimestampNs, Is.EqualTo(2900000000));
            Assert.That(binding.TrackingMetadata.ClockMappingValid, Is.False);
            Assert.That(binding.TrackingMetadata.ExtrinsicsValid, Is.False);
        }
        [Test]
        public void DuplicateImageTimestamp_RemainsDuplicate_NotInventedNextNanosecond()
        {
            var snapshot = new CapturePoseSnapshot(2000000000, 3000000000, Matrix4x4.identity, 0, 2, true);
            var mapper = new FixedOffsetCaptureClockMapper(1000000000);
            CaptureFrameBinding.TryBind(2.0, snapshot, mapper, 1, out var first);
            CaptureFrameBinding.TryBind(2.0, snapshot, mapper, 1, out var duplicate);
            Assert.That(duplicate.CaptureTimestampNs, Is.EqualTo(first.CaptureTimestampNs));
        }
        [TestCase(double.NaN)] [TestCase(double.PositiveInfinity)] [TestCase(-1.0)]
        public void InvalidImageTimestamp_IsRejected(double timestamp)
            => Assert.That(CaptureFrameBinding.TryBind(timestamp, default, null, 1, out _), Is.False);
        [Test]
        public void ExplicitClockMapping_RejectsNegativeOrOverflow()
        {
            Assert.That(new FixedOffsetCaptureClockMapper(-2).TryMap(1, out _), Is.False);
            Assert.That(new FixedOffsetCaptureClockMapper(1).TryMap(long.MaxValue, out _), Is.False);
        }
    }
}
