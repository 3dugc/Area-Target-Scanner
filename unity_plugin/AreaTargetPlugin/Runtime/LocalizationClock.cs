using System;
using System.Diagnostics;

namespace AreaTargetPlugin
{
    /// <summary>Host monotonic clock used for delivery and timer polls.</summary>
    public static class LocalizationClock
    {
        public static long NowTimestampNs => checked((long)(Stopwatch.GetTimestamp()
            * (1000000000.0 / Stopwatch.Frequency)));
    }
    public interface ICaptureClockMapper
    {
        ulong CaptureClockEpoch { get; }
        bool TryMap(long sourceTimestampNs, out long hostTimestampNs);
    }
    /// <summary>
    /// Explicit calibration supplied by a host that knows its provider clock.
    /// No offset is estimated from result arrival or adjusted to make data fresh.
    /// </summary>
    public sealed class FixedOffsetCaptureClockMapper : ICaptureClockMapper
    {
        private readonly long _offsetNs;
        public ulong CaptureClockEpoch { get; }
        public FixedOffsetCaptureClockMapper(long offsetNs, ulong captureClockEpoch = 0)
        {
            _offsetNs = offsetNs; CaptureClockEpoch = captureClockEpoch;
        }
        public bool TryMap(long sourceTimestampNs, out long hostTimestampNs)
        {
            hostTimestampNs = 0;
            if (sourceTimestampNs < 0) return false;
            try { hostTimestampNs = checked(sourceTimestampNs + _offsetNs); }
            catch (OverflowException) { return false; }
            return hostTimestampNs >= 0;
        }
    }
    public interface ILocalizationTrackingMetadataSource
    {
        LocalizationTrackingMetadata TrackingMetadata { get; }
    }
}
