using System;
using System.Globalization;
using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>
    /// Immutable, image-free summary of one localization lifecycle event.
    /// The JSON representation is schema-versioned and deliberately excludes raw
    /// camera bytes, scan archives, file paths, and complete pose matrices.
    /// </summary>
    public sealed class LocalizationDiagnosticRecord
    {
        public const int CurrentSchemaVersion = 1;

        public DateTime TimestampUtc { get; }
        public string BuildVersion { get; }
        public string PackageVersion { get; }
        public string MapId { get; }
        public string MapVersion { get; }
        public string MapHash { get; }
        public string DeviceModel { get; }
        public string OperatingSystem { get; }
        public long FrameId { get; }
        public long CaptureTimestampNs { get; }
        public long MapGeneration { get; }
        public long OverwrittenPendingFrames { get; }
        public long ResultAgeNs { get; }
        public long WorkerProcessingTimeNs { get; }
        public TrackingState State { get; }
        public LocalizationQuality Quality { get; }
        public float Confidence { get; }
        public bool PoseApplied { get; }
        public LocalizationFailureCategory FailureCategory { get; }
        public string FailureReason { get; }
        public VLDebugInfo NativeDebugInfo { get; }

        public LocalizationDiagnosticRecord(
            DateTime timestampUtc,
            string buildVersion,
            string packageVersion,
            string mapId,
            string mapVersion,
            string mapHash,
            string deviceModel,
            string operatingSystem,
            long frameId,
            long captureTimestampNs,
            long mapGeneration,
            long overwrittenPendingFrames,
            long resultAgeNs,
            long workerProcessingTimeNs,
            TrackingState state,
            LocalizationQuality quality,
            float confidence,
            bool poseApplied,
            LocalizationFailureCategory failureCategory,
            string failureReason,
            VLDebugInfo nativeDebugInfo)
        {
            TimestampUtc = timestampUtc.Kind == DateTimeKind.Utc
                ? timestampUtc
                : timestampUtc.ToUniversalTime();
            BuildVersion = buildVersion ?? string.Empty;
            PackageVersion = packageVersion ?? string.Empty;
            MapId = mapId ?? string.Empty;
            MapVersion = mapVersion ?? string.Empty;
            MapHash = mapHash ?? string.Empty;
            DeviceModel = deviceModel ?? string.Empty;
            OperatingSystem = operatingSystem ?? string.Empty;
            FrameId = frameId;
            CaptureTimestampNs = captureTimestampNs;
            MapGeneration = mapGeneration;
            OverwrittenPendingFrames = overwrittenPendingFrames;
            ResultAgeNs = resultAgeNs;
            WorkerProcessingTimeNs = workerProcessingTimeNs;
            State = state;
            Quality = quality;
            Confidence = confidence;
            PoseApplied = poseApplied;
            FailureCategory = failureCategory;
            FailureReason = failureReason ?? string.Empty;
            NativeDebugInfo = nativeDebugInfo;
        }

        /// <summary>Serializes only the documented numeric and identity summaries.</summary>
        public string ToJson()
        {
            return JsonUtility.ToJson(new JsonPayload
            {
                schemaVersion = CurrentSchemaVersion,
                timestampUtc = TimestampUtc.ToString("O", CultureInfo.InvariantCulture),
                buildVersion = BuildVersion,
                packageVersion = PackageVersion,
                mapId = MapId,
                mapVersion = MapVersion,
                mapHash = MapHash,
                deviceModel = DeviceModel,
                operatingSystem = OperatingSystem,
                frameId = FrameId,
                captureTimestampNs = CaptureTimestampNs,
                mapGeneration = MapGeneration,
                overwrittenPendingFrames = OverwrittenPendingFrames,
                resultAgeNs = ResultAgeNs,
                workerProcessingTimeNs = WorkerProcessingTimeNs,
                state = State,
                quality = Quality,
                confidence = Confidence,
                poseApplied = PoseApplied,
                failureCategory = FailureCategory,
                failureReason = FailureReason,
                orbKeypoints = NativeDebugInfo.orb_keypoints,
                candidateKeyframes = NativeDebugInfo.candidate_keyframes,
                bestKeyframeId = NativeDebugInfo.best_kf_id,
                bestRawMatches = NativeDebugInfo.best_raw_matches,
                bestGoodMatches = NativeDebugInfo.best_good_matches,
                bestInliers = NativeDebugInfo.best_inliers,
                bestBowSimilarity = NativeDebugInfo.best_bow_sim,
                akazeTriggered = NativeDebugInfo.akaze_triggered,
                consistencyRejected = NativeDebugInfo.consistency_rejected
            });
        }

        [Serializable]
        private sealed class JsonPayload
        {
            public int schemaVersion;
            public string timestampUtc;
            public string buildVersion;
            public string packageVersion;
            public string mapId;
            public string mapVersion;
            public string mapHash;
            public string deviceModel;
            public string operatingSystem;
            public long frameId;
            public long captureTimestampNs;
            public long mapGeneration;
            public long overwrittenPendingFrames;
            public long resultAgeNs;
            public long workerProcessingTimeNs;
            public TrackingState state;
            public LocalizationQuality quality;
            public float confidence;
            public bool poseApplied;
            public LocalizationFailureCategory failureCategory;
            public string failureReason;
            public int orbKeypoints;
            public int candidateKeyframes;
            public int bestKeyframeId;
            public int bestRawMatches;
            public int bestGoodMatches;
            public int bestInliers;
            public float bestBowSimilarity;
            public int akazeTriggered;
            public int consistencyRejected;
        }
    }
}
