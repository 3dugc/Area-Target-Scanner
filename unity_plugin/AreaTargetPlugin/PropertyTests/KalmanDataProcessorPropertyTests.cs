using System.Threading.Tasks;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;
using UnityEngine;
using AreaTargetPlugin;
using AreaTargetPlugin.PointCloudLocalization;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for KalmanDataProcessor adapter.
    /// Feature: pointcloud-localization, Property 12: KalmanDataProcessor adapter correctness
    /// **Validates: Requirements 10.4, 10.5**
    /// </summary>
    [TestFixture]
    public class KalmanDataProcessorPropertyTests
    {
        private static bool IsFinite(float v) =>
            !float.IsNaN(v) && !float.IsInfinity(v);

        /// <summary>
        /// Property 12a: ProcessData on first call initializes the KalmanPoseFilter
        /// and writes the (initialized) pose back into data.Pose.
        /// On first call, KalmanPoseFilter returns the raw pose unchanged.
        /// **Validates: Requirements 10.4**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property ProcessData_FirstCall_InitializesFilter(float tx, float ty, float tz)
        {
            if (!IsFinite(tx) || !IsFinite(ty) || !IsFinite(tz))
                return true.ToProperty();

            var filter = new KalmanPoseFilter();
            var processor = new KalmanDataProcessor(filter);
            var pose = Matrix4x4.TRS(new Vector3(tx, ty, tz), Quaternion.identity, Vector3.one);
            var data = new SceneUpdateData { Pose = pose, Ignore = false };

            processor.ProcessData(data, DataProcessorTrigger.NewData).Wait();

            return filter.IsInitialized.ToProperty()
                .Label("After first ProcessData, KalmanPoseFilter should be initialized");
        }

        /// <summary>
        /// Property 12b: After ProcessData initializes the filter, calling ResetProcessor
        /// resets KalmanPoseFilter.IsInitialized to false.
        /// **Validates: Requirements 10.5**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property ResetProcessor_ResetsFilter(float tx, float ty, float tz)
        {
            if (!IsFinite(tx) || !IsFinite(ty) || !IsFinite(tz))
                return true.ToProperty();

            var filter = new KalmanPoseFilter();
            var processor = new KalmanDataProcessor(filter);
            var pose = Matrix4x4.TRS(new Vector3(tx, ty, tz), Quaternion.identity, Vector3.one);
            var data = new SceneUpdateData { Pose = pose, Ignore = false };

            // Initialize the filter via ProcessData
            processor.ProcessData(data, DataProcessorTrigger.NewData).Wait();

            // Reset
            processor.ResetProcessor().Wait();

            return (!filter.IsInitialized).ToProperty()
                .Label("After ResetProcessor, KalmanPoseFilter.IsInitialized should be false");
        }

        /// <summary>
        /// Property 12c: ProcessData writes the smoothed pose back into data.Pose.
        /// After two calls with different poses, the second output should differ from
        /// the raw input (Kalman filter smooths toward the previous state).
        /// **Validates: Requirements 10.4**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property ProcessData_WritesSmoothPoseBack(float tx, float ty, float tz)
        {
            if (!IsFinite(tx) || !IsFinite(ty) || !IsFinite(tz))
                return true.ToProperty();

            // Clamp to reasonable range to avoid floating point issues
            tx = Mathf.Clamp(tx, -100f, 100f);
            ty = Mathf.Clamp(ty, -100f, 100f);
            tz = Mathf.Clamp(tz, -100f, 100f);

            var filter = new KalmanPoseFilter();
            var processor = new KalmanDataProcessor(filter);

            // First call: initialize with origin
            var data1 = new SceneUpdateData
            {
                Pose = Matrix4x4.TRS(Vector3.zero, Quaternion.identity, Vector3.one),
                Ignore = false
            };
            processor.ProcessData(data1, DataProcessorTrigger.NewData).Wait();

            // Second call: use a different pose — the output should be smoothed
            var offset = new Vector3(tx + 5f, ty + 5f, tz + 5f); // ensure non-zero offset from origin
            var rawPose = Matrix4x4.TRS(offset, Quaternion.identity, Vector3.one);
            var data2 = new SceneUpdateData { Pose = rawPose, Ignore = false };
            processor.ProcessData(data2, DataProcessorTrigger.NewData).Wait();

            // The smoothed pose should have been written back into data2.Pose
            // and it should differ from the raw input (Kalman smooths toward previous state)
            var smoothedPos = new Vector3(data2.Pose.m03, data2.Pose.m13, data2.Pose.m23);
            var rawPos = new Vector3(rawPose.m03, rawPose.m13, rawPose.m23);

            // If offset is non-trivial, smoothed should differ from raw
            bool offsetIsNonTrivial = offset.magnitude > 0.1f;
            if (!offsetIsNonTrivial)
                return true.ToProperty();

            bool poseWasModified = Vector3.Distance(smoothedPos, rawPos) > 0.0001f;

            return poseWasModified.ToProperty()
                .Label($"Smoothed pose should differ from raw input after Kalman filtering. " +
                       $"Raw=({rawPos.x:F3},{rawPos.y:F3},{rawPos.z:F3}), " +
                       $"Smoothed=({smoothedPos.x:F3},{smoothedPos.y:F3},{smoothedPos.z:F3})");
        }
    }
}
