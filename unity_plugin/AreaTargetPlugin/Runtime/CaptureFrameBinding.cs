using System;
using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>Pose snapshot taken in frameReceived, before CPU image conversion.</summary>
    public readonly struct CapturePoseSnapshot
    {
        public long? ProviderFrameTimestampNs { get; }
        public long HostPoseTimestampNs { get; }
        public Matrix4x4 UnityWorldFromCamera { get; }
        public ulong TrackingEpoch { get; }
        public uint TrackingQuality { get; }
        public bool PoseSampleIsFrameBound { get; }
        public CapturePoseSnapshot(long? providerFrameTimestampNs, long hostPoseTimestampNs,
            Matrix4x4 unityWorldFromCamera, ulong trackingEpoch, uint trackingQuality, bool poseSampleIsFrameBound)
        {
            ProviderFrameTimestampNs = providerFrameTimestampNs;
            HostPoseTimestampNs = hostPoseTimestampNs;
            UnityWorldFromCamera = unityWorldFromCamera;
            TrackingEpoch = trackingEpoch; TrackingQuality = trackingQuality;
            PoseSampleIsFrameBound = poseSampleIsFrameBound;
        }
    }
    /// <summary>
    /// Converts CPU exposure seconds and binds only a matching event snapshot.
    /// AR Foundation does not guarantee a Stopwatch origin or an exposure pose.
    /// A validated host explicitly supplies both contracts; otherwise raw only.
    /// </summary>
    public readonly struct CaptureFrameBinding
    {
        public long CaptureTimestampNs { get; }
        public Matrix4x4 UnityWorldFromCamera { get; }
        public LocalizationTrackingMetadata TrackingMetadata { get; }
        private CaptureFrameBinding(long exposure, CapturePoseSnapshot snapshot,
            LocalizationTrackingMetadata metadata)
        {
            CaptureTimestampNs = exposure; UnityWorldFromCamera = snapshot.UnityWorldFromCamera;
            TrackingMetadata = metadata;
        }
        public static bool TryBind(double cpuImageTimestampSeconds, CapturePoseSnapshot snapshot,
            ICaptureClockMapper mapper, ulong cameraId, out CaptureFrameBinding binding)
        {
            binding = default;
            double ns = cpuImageTimestampSeconds * 1000000000.0;
            if (double.IsNaN(ns) || double.IsInfinity(ns) || ns < 0 || ns >= long.MaxValue) return false;
            long sourceNs = (long)Math.Round(ns);
            long mappedNs = sourceNs;
            bool mapped = mapper != null && mapper.TryMap(sourceNs, out mappedNs);
            if (!mapped) mappedNs = sourceNs;
            // Timestamp unit conversion can round a double by sub-microseconds.
            // This tolerance only matches identifiers; core alone gates pose skew.
            bool sameExposure = snapshot.ProviderFrameTimestampNs.HasValue
                && Math.Abs((double)snapshot.ProviderFrameTimestampNs.Value - sourceNs) <= 1000.0;
            bool bindingVerified = mapped && sameExposure && snapshot.PoseSampleIsFrameBound;
            var metadata = new LocalizationTrackingMetadata(cameraId,
                mapper?.CaptureClockEpoch ?? 0, snapshot.TrackingEpoch,
                bindingVerified ? mappedNs : Math.Max(0, snapshot.HostPoseTimestampNs),
                snapshot.TrackingQuality, bindingVerified, bindingVerified);
            binding = new CaptureFrameBinding(mappedNs, snapshot, metadata);
            return true;
        }
    }
}
