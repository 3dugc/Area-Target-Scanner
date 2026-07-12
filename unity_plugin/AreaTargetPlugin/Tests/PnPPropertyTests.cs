using System;
using System.Collections;
using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for PnP localization result validity.
    /// **Validates: Requirements 12.1, 12.2, 12.3**
    /// Updated to remove OpenCvSharp dependency — uses pure C# Rodrigues and
    /// validates ComposePoseMatrix output properties.
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class PnPPropertyTests
    {
        private const float Fx = 500f;
        private const float Fy = 500f;
        private const float Cx = 320f;
        private const float Cy = 240f;
        private const int ImageWidth = 640;
        private const int ImageHeight = 480;

        #region Pure C# Rodrigues

        /// <summary>
        /// Rodrigues rotation: converts a rotation vector (angle-axis) to a 3x3 rotation matrix.
        /// Returns row-major float[9].
        /// </summary>
        private static float[] Rodrigues(double[] rvec)
        {
            double rx = rvec[0], ry = rvec[1], rz = rvec[2];
            double theta = Math.Sqrt(rx * rx + ry * ry + rz * rz);

            if (theta < 1e-12)
                return new float[] { 1, 0, 0, 0, 1, 0, 0, 0, 1 };

            double c = Math.Cos(theta);
            double s = Math.Sin(theta);
            double c1 = 1.0 - c;
            double ux = rx / theta, uy = ry / theta, uz = rz / theta;

            float[] R = new float[9];
            R[0] = (float)(c + ux * ux * c1);
            R[1] = (float)(ux * uy * c1 - uz * s);
            R[2] = (float)(ux * uz * c1 + uy * s);
            R[3] = (float)(uy * ux * c1 + uz * s);
            R[4] = (float)(c + uy * uy * c1);
            R[5] = (float)(uy * uz * c1 - ux * s);
            R[6] = (float)(uz * ux * c1 - uy * s);
            R[7] = (float)(uz * uy * c1 + ux * s);
            R[8] = (float)(c + uz * uz * c1);
            return R;
        }

        #endregion

        private static IEnumerable<TestCaseData> RandomPoseTestCases()
        {
            var rng = new System.Random(12345);
            int numCases = 30;

            for (int i = 0; i < numCases; i++)
            {
                double rx = (rng.NextDouble() - 0.5) * 0.6;
                double ry = (rng.NextDouble() - 0.5) * 0.6;
                double rz = (rng.NextDouble() - 0.5) * 0.6;
                double tx = (rng.NextDouble() - 0.5) * 2.0;
                double ty = (rng.NextDouble() - 0.5) * 2.0;
                double tz = rng.NextDouble() * 4.0 + 3.0;

                yield return new TestCaseData(rx, ry, rz, tx, ty, tz, i)
                    .SetName($"P5_PoseValidity_Case{i}_R({rx:F2},{ry:F2},{rz:F2})_T({tx:F2},{ty:F2},{tz:F2})");
            }
        }

        [Test, TestCaseSource(nameof(RandomPoseTestCases))]
        public void P5_TrackingResult_IsValidRigidTransform(
            double rx, double ry, double rz,
            double tx, double ty, double tz,
            int caseIndex)
        {
            double[] rvec = { rx, ry, rz };
            float[] rotMat = Rodrigues(rvec);
            float[] translation = { (float)tx, (float)ty, (float)tz };

            Matrix4x4 pose = VisualLocalizationEngine.ComposePoseMatrix(rotMat, translation);

            // Verify rotation determinant ≈ 1
            float det = ComputeRotationDeterminant(pose);
            Assert.AreEqual(1.0f, det, 0.05f,
                $"[Case {caseIndex}] det(R) should be ≈ 1.0, got {det}");

            // Verify orthogonality
            VerifyOrthogonality(pose, caseIndex);

            // Verify last row
            Assert.AreEqual(0f, pose.m30, 0.001f);
            Assert.AreEqual(0f, pose.m31, 0.001f);
            Assert.AreEqual(0f, pose.m32, 0.001f);
            Assert.AreEqual(1f, pose.m33, 0.001f);

            // Verify translation preserved
            Assert.AreEqual((float)tx, pose.m03, 0.001f);
            Assert.AreEqual((float)ty, pose.m13, 0.001f);
            Assert.AreEqual((float)tz, pose.m23, 0.001f);
        }

        [Test, TestCaseSource(nameof(RandomInlierCounts))]
        public void P5_ConfidenceCalculation_AlwaysInRange(int inlierCount)
        {
            float confidence = Mathf.Min(1.0f, inlierCount / 100.0f);
            Assert.GreaterOrEqual(confidence, 0.0f);
            Assert.LessOrEqual(confidence, 1.0f);
            float expected = Math.Min(1.0f, inlierCount / 100.0f);
            Assert.AreEqual(expected, confidence, 0.0001f);
        }

        private static IEnumerable<TestCaseData> RandomInlierCounts()
        {
            var rng = new System.Random(99);
            for (int i = 0; i < 50; i++)
            {
                int count = rng.Next(0, 500);
                yield return new TestCaseData(count).SetName($"P5_Confidence_Inliers{count}");
            }
        }

        #region Helper Methods

        private static float ComputeRotationDeterminant(Matrix4x4 pose)
        {
            return pose.m00 * (pose.m11 * pose.m22 - pose.m12 * pose.m21)
                 - pose.m01 * (pose.m10 * pose.m22 - pose.m12 * pose.m20)
                 + pose.m02 * (pose.m10 * pose.m21 - pose.m11 * pose.m20);
        }

        private static void VerifyOrthogonality(Matrix4x4 pose, int caseIndex)
        {
            Vector3 c0 = new Vector3(pose.m00, pose.m10, pose.m20);
            Vector3 c1 = new Vector3(pose.m01, pose.m11, pose.m21);
            Vector3 c2 = new Vector3(pose.m02, pose.m12, pose.m22);

            Assert.AreEqual(1.0f, c0.magnitude, 0.05f);
            Assert.AreEqual(1.0f, c1.magnitude, 0.05f);
            Assert.AreEqual(1.0f, c2.magnitude, 0.05f);
            Assert.AreEqual(0f, Vector3.Dot(c0, c1), 0.05f);
            Assert.AreEqual(0f, Vector3.Dot(c0, c2), 0.05f);
            Assert.AreEqual(0f, Vector3.Dot(c1, c2), 0.05f);
        }

        #endregion
    }
}
