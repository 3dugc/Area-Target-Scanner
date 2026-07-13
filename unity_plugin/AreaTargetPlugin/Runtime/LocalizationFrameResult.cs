using System;
using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>Stable categories for a localization result that cannot be applied.</summary>
    public enum LocalizationFailureCategory
    {
        None = 0,
        UnsupportedDevice = 1,
        InvalidFrame = 2,
        MapLoadFailed = 3,
        NativeInitializationFailed = 4,
        SqliteFailed = 5,
        LocalizationFailed = 6,
        StaleResult = 7,
        LifecycleFailure = 8,

        [Obsolete("Use LocalizationFailed for diagnostics.")]
        NativeLocalizationFailed = LocalizationFailed,
        [Obsolete("Use InvalidFrame for diagnostics.")]
        InvalidNativePose = InvalidFrame
    }

    /// <summary>
    /// Immutable outcome for one LocalizationFrame. A failed result has no pose;
    /// identity is never used to impersonate a valid localization.
    /// </summary>
    public readonly struct LocalizationFrameResult
    {
        public long FrameId { get; }
        public long CaptureTimestampNs { get; }
        public string MapId { get; }
        public long MapGeneration { get; }
        public long WorkerStartedTimestampNs { get; }
        public long WorkerCompletedTimestampNs { get; }
        public long WorkerProcessingTimeNs => WorkerCompletedTimestampNs - WorkerStartedTimestampNs;

        /// <summary>T_U_C captured with the input frame, retained for alignment only.</summary>
        public Matrix4x4 UnityWorldFromCamera { get; }
        public Matrix4x4? CameraFromScan { get; }
        public Matrix4x4? UnityWorldFromScan { get; }
        public TrackingState State { get; }
        public LocalizationQuality Quality { get; }
        public float Confidence { get; }
        public int MatchedFeatures { get; }
        public LocalizationFailureCategory FailureCategory { get; }
        public VLDebugInfo NativeDebugInfo { get; }

        public bool IsSuccess => State == TrackingState.TRACKING
            && FailureCategory == LocalizationFailureCategory.None
            && CameraFromScan.HasValue
            && UnityWorldFromScan.HasValue;

        private LocalizationFrameResult(
            LocalizationFrame frame,
            long mapGeneration,
            long workerStartedTimestampNs,
            long workerCompletedTimestampNs,
            Matrix4x4? cameraFromScan,
            Matrix4x4? unityWorldFromScan,
            TrackingState state,
            LocalizationQuality quality,
            float confidence,
            int matchedFeatures,
            LocalizationFailureCategory failureCategory,
            VLDebugInfo nativeDebugInfo)
        {
            ValidateTimingAndGeneration(mapGeneration, workerStartedTimestampNs, workerCompletedTimestampNs);
            FrameId = frame.FrameId;
            CaptureTimestampNs = frame.CaptureTimestampNs;
            MapId = frame.MapId;
            MapGeneration = mapGeneration;
            WorkerStartedTimestampNs = workerStartedTimestampNs;
            WorkerCompletedTimestampNs = workerCompletedTimestampNs;
            UnityWorldFromCamera = frame.UnityWorldFromCamera;
            CameraFromScan = cameraFromScan;
            UnityWorldFromScan = unityWorldFromScan;
            State = state;
            Quality = quality;
            Confidence = confidence;
            MatchedFeatures = matchedFeatures;
            FailureCategory = failureCategory;
            NativeDebugInfo = nativeDebugInfo;
        }

        public static LocalizationFrameResult Succeeded(
            LocalizationFrame frame,
            long mapGeneration,
            long workerStartedTimestampNs,
            long workerCompletedTimestampNs,
            Matrix4x4 cameraFromScan,
            LocalizationQuality quality,
            float confidence,
            int matchedFeatures,
            VLDebugInfo nativeDebugInfo)
        {
            CoordinateTransform.ValidateFiniteRigidTransform(cameraFromScan, nameof(cameraFromScan));
            if (quality == LocalizationQuality.NONE)
                throw new ArgumentException("A successful result requires a non-empty quality.", nameof(quality));
            if (float.IsNaN(confidence) || float.IsInfinity(confidence) || confidence < 0f || confidence > 1f)
                throw new ArgumentException("Confidence must be finite and in [0, 1].", nameof(confidence));
            if (matchedFeatures < 0)
                throw new ArgumentException("Matched feature count must be non-negative.", nameof(matchedFeatures));

            Matrix4x4 unityWorldFromScan = CoordinateTransform.ComposeUnityWorldFromScan(
                frame.UnityWorldFromCamera, cameraFromScan);
            return new LocalizationFrameResult(
                frame,
                mapGeneration,
                workerStartedTimestampNs,
                workerCompletedTimestampNs,
                cameraFromScan,
                unityWorldFromScan,
                TrackingState.TRACKING,
                quality,
                confidence,
                matchedFeatures,
                LocalizationFailureCategory.None,
                nativeDebugInfo);
        }

        public static LocalizationFrameResult Failed(
            LocalizationFrame frame,
            long mapGeneration,
            long workerStartedTimestampNs,
            long workerCompletedTimestampNs,
            LocalizationFailureCategory failureCategory,
            VLDebugInfo nativeDebugInfo)
        {
            if (failureCategory == LocalizationFailureCategory.None)
                throw new ArgumentException("A failed result requires a failure category.", nameof(failureCategory));

            return new LocalizationFrameResult(
                frame,
                mapGeneration,
                workerStartedTimestampNs,
                workerCompletedTimestampNs,
                null,
                null,
                TrackingState.LOST,
                LocalizationQuality.NONE,
                0f,
                0,
                failureCategory,
                nativeDebugInfo);
        }

        private static void ValidateTimingAndGeneration(
            long mapGeneration,
            long workerStartedTimestampNs,
            long workerCompletedTimestampNs)
        {
            if (mapGeneration < 0)
                throw new ArgumentException("Map generation must be non-negative.", nameof(mapGeneration));
            if (workerStartedTimestampNs < 0 || workerCompletedTimestampNs < workerStartedTimestampNs)
                throw new ArgumentException("Worker timestamps must be monotonic and non-negative.");
        }
    }
}
