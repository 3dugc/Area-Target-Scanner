using System;
using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for pose smoothing (Kalman filter).
    /// **Validates: Requirements 13.2, 13.3**
    ///
    /// Property P6: Pose smoothing does not introduce large deviations —
    /// For all (rawPose, smoothedPose) pairs:
    ///   translationDifference &lt; 0.5m and rotationDifference &lt; 15 degrees.
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class PoseSmoothingPropertyTests
    {
        private const float MaxTranslationDiff = 0.5f;  // meters
        private const float MaxRotationDiffDeg = 15.0f;  // degrees

        /// <summary>
        /// Generates random pose test cases with varying translations and rotations.
        /// Each case feeds a raw pose through the Kalman filter and checks P6.
        /// </summary>
        private static IEnumerable<TestCaseData> RandomPoseTestCases()
        {
            var rng = new System.Random(54321);
            int numCases = 50;

            for (int i = 0; i < numCases; i++)
            {
                // Random translation
                float tx = (float)(rng.NextDouble() - 0.5) * 10.0f;  // [-5, 5] m
                float ty = (float)(rng.NextDouble() - 0.5) * 10.0f;
                float tz = (float)(rng.NextDouble()) * 10.0f + 1.0f;  // [1, 11] m

                // Random Euler angles (moderate range)
                float rx = (float)(rng.NextDouble() - 0.5) * 1.0f;  // [-0.5, 0.5] rad
                float ry = (float)(rng.NextDouble() - 0.5) * 1.0f;
                float rz = (float)(rng.NextDouble() - 0.5) * 1.0f;

                yield return new TestCaseData(tx, ty, tz, rx, ry, rz, i)
                    .SetName($"P6_PoseSmoothing_Case{i}_T({tx:F2},{ty:F2},{tz:F2})_R({rx:F2},{ry:F2},{rz:F2})");
            }
        }

        /// <summary>
        /// Property P6: For each raw pose fed through the Kalman filter,
        /// the smoothed pose has translation difference &lt; 0.5m and rotation difference &lt; 15°.
        /// **Validates: Requirements 13.2, 13.3**
        /// </summary>
        [Test, TestCaseSource(nameof(RandomPoseTestCases))]
        public void P6_SmoothedPose_DoesNotDeviateFromRaw(
            float tx, float ty, float tz,
            float rx, float ry, float rz,
            int caseIndex)
        {
            var filter = new KalmanPoseFilter();

            // Build a raw pose from the given parameters
            Matrix4x4 rawPose = KalmanPoseFilter.EulerToMatrix(rx, ry, rz);
            rawPose.m03 = tx;
            rawPose.m13 = ty;
            rawPose.m23 = tz;
            rawPose.m30 = 0f; rawPose.m31 = 0f; rawPose.m32 = 0f; rawPose.m33 = 1f;

            // Feed the pose through the filter
            Matrix4x4 smoothed = filter.Update(rawPose);

            // P6.1: Requirement 13.2 — Translation difference < 0.5m
            Vector3 rawT = new Vector3(rawPose.m03, rawPose.m13, rawPose.m23);
            Vector3 smoothedT = new Vector3(smoothed.m03, smoothed.m13, smoothed.m23);
            float translationDiff = Vector3.Distance(rawT, smoothedT);

            Assert.Less(translationDiff, MaxTranslationDiff,
                $"[Case {caseIndex}] Translation diff {translationDiff:F4}m exceeds {MaxTranslationDiff}m");

            // P6.2: Requirement 13.3 — Rotation difference < 15°
            float rotationDiffDeg = ComputeRotationDifferenceDegrees(rawPose, smoothed);

            Assert.Less(rotationDiffDeg, MaxRotationDiffDeg,
                $"[Case {caseIndex}] Rotation diff {rotationDiffDeg:F2}° exceeds {MaxRotationDiffDeg}°");
        }

        /// <summary>
        /// Property P6 with a sequence of poses: after multiple updates,
        /// each smoothed pose still stays within bounds of its raw input.
        /// **Validates: Requirements 13.2, 13.3**
        /// </summary>
        [Test, TestCaseSource(nameof(RandomPoseSequenceTestCases))]
        public void P6_SmoothedPoseSequence_EachStepWithinBounds(
            float baseTx, float baseTy, float baseTz,
            float baseRx, float baseRy, float baseRz,
            int caseIndex)
        {
            var filter = new KalmanPoseFilter();
            var rng = new System.Random(caseIndex + 100);

            // Generate a sequence of 10 poses with small perturbations
            for (int step = 0; step < 10; step++)
            {
                float tx = baseTx + (float)(rng.NextDouble() - 0.5) * 0.2f;
                float ty = baseTy + (float)(rng.NextDouble() - 0.5) * 0.2f;
                float tz = baseTz + (float)(rng.NextDouble() - 0.5) * 0.2f;
                float rx = baseRx + (float)(rng.NextDouble() - 0.5) * 0.1f;
                float ry = baseRy + (float)(rng.NextDouble() - 0.5) * 0.1f;
                float rz = baseRz + (float)(rng.NextDouble() - 0.5) * 0.1f;

                Matrix4x4 rawPose = KalmanPoseFilter.EulerToMatrix(rx, ry, rz);
                rawPose.m03 = tx; rawPose.m13 = ty; rawPose.m23 = tz;
                rawPose.m30 = 0f; rawPose.m31 = 0f; rawPose.m32 = 0f; rawPose.m33 = 1f;

                Matrix4x4 smoothed = filter.Update(rawPose);

                // Check P6 bounds at every step
                Vector3 rawT = new Vector3(rawPose.m03, rawPose.m13, rawPose.m23);
                Vector3 smoothedT = new Vector3(smoothed.m03, smoothed.m13, smoothed.m23);
                float translationDiff = Vector3.Distance(rawT, smoothedT);

                Assert.Less(translationDiff, MaxTranslationDiff,
                    $"[Case {caseIndex}, Step {step}] Translation diff {translationDiff:F4}m exceeds {MaxTranslationDiff}m");

                float rotationDiffDeg = ComputeRotationDifferenceDegrees(rawPose, smoothed);
                Assert.Less(rotationDiffDeg, MaxRotationDiffDeg,
                    $"[Case {caseIndex}, Step {step}] Rotation diff {rotationDiffDeg:F2}° exceeds {MaxRotationDiffDeg}°");
            }
        }

        private static IEnumerable<TestCaseData> RandomPoseSequenceTestCases()
        {
            var rng = new System.Random(77777);
            int numCases = 20;

            for (int i = 0; i < numCases; i++)
            {
                float tx = (float)(rng.NextDouble() - 0.5) * 6.0f;
                float ty = (float)(rng.NextDouble() - 0.5) * 6.0f;
                float tz = (float)(rng.NextDouble()) * 8.0f + 1.0f;
                float rx = (float)(rng.NextDouble() - 0.5) * 0.8f;
                float ry = (float)(rng.NextDouble() - 0.5) * 0.8f;
                float rz = (float)(rng.NextDouble() - 0.5) * 0.8f;

                yield return new TestCaseData(tx, ty, tz, rx, ry, rz, i)
                    .SetName($"P6_PoseSequence_Case{i}");
            }
        }

        #region Helper Methods

        /// <summary>
        /// Computes the rotation difference between two poses in degrees
        /// using the angle of the relative rotation matrix.
        /// </summary>
        private static float ComputeRotationDifferenceDegrees(Matrix4x4 a, Matrix4x4 b)
        {
            // Extract 3x3 rotation matrices and compute R_diff = R_a^T * R_b
            // Then angle = acos((trace(R_diff) - 1) / 2)
            float r00 = a.m00 * b.m00 + a.m10 * b.m10 + a.m20 * b.m20;
            float r11 = a.m01 * b.m01 + a.m11 * b.m11 + a.m21 * b.m21;
            float r22 = a.m02 * b.m02 + a.m12 * b.m12 + a.m22 * b.m22;

            float trace = r00 + r11 + r22;
            float cosAngle = Mathf.Clamp((trace - 1f) / 2f, -1f, 1f);
            float angleRad = Mathf.Acos(cosAngle);
            return angleRad * Mathf.Rad2Deg;
        }

        #endregion
    }
}
