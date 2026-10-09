using System;

namespace AreaTargetPlugin
{
    /// <summary>Host-owned identity and calibrated time/pose metadata for one exposure.</summary>
    public readonly struct LocalizationTrackingMetadata
    {
        public ulong CameraId { get; }
        public ulong CaptureClockEpoch { get; }
        public ulong TrackingEpoch { get; }
        public long PoseTimestampNs { get; }
        public uint TrackingQuality { get; }
        public bool ClockMappingValid { get; }
        public bool ExtrinsicsValid { get; }
        public LocalizationTrackingMetadata(ulong cameraId, ulong captureClockEpoch, ulong trackingEpoch,
            long poseTimestampNs, uint trackingQuality, bool clockMappingValid, bool extrinsicsValid = true)
        {
            if (poseTimestampNs < 0) throw new ArgumentOutOfRangeException(nameof(poseTimestampNs));
            if (trackingQuality > 2) throw new ArgumentOutOfRangeException(nameof(trackingQuality));
            CameraId = cameraId; CaptureClockEpoch = captureClockEpoch; TrackingEpoch = trackingEpoch;
            PoseTimestampNs = poseTimestampNs; TrackingQuality = trackingQuality;
            ClockMappingValid = clockMappingValid; ExtrinsicsValid = extrinsicsValid;
        }
        // Existing LocalizationFrame callers already promise a host-monotonic
        // capture timestamp and matching pose. Provider adapters must be explicit.
        public static LocalizationTrackingMetadata KnownClock(long timestampNs)
            => new LocalizationTrackingMetadata(1, 0, 0, timestampNs, 2, true);
    }
}
