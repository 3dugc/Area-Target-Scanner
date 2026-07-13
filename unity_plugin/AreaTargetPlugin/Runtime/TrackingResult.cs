using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>
    /// Contains the result of processing a single camera frame for tracking.
    /// </summary>
    public struct TrackingResult
    {
        /// <summary>Current tracking state (INITIALIZING, TRACKING, or LOST).</summary>
        public TrackingState State;

        /// <summary>
        /// Final content-root pose T_U_S from scan coordinates S into Unity world U.
        /// Failed results retain identity only for this legacy non-nullable wrapper;
        /// LocalizationFrameResult uses null poses for failures.
        /// </summary>
        public Matrix4x4 Pose;

        /// <summary>Tracking confidence in range [0.0, 1.0].</summary>
        public float Confidence;

        /// <summary>Number of matched feature points used for pose estimation.</summary>
        public int MatchedFeatures;

        /// <summary>定位质量等级（默认 NONE）。</summary>
        public LocalizationQuality Quality;
    }
}
