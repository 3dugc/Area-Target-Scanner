using System;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Unit tests for the Kalman pose filter.
    /// Validates: Requirements 13.1, 13.2, 13.3
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class KalmanPoseFilterTests
    {
        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
        }

        #region Initialization Tests

        [Test]
        public void NewFilter_IsNotInitialized()
        {
            var filter = new KalmanPoseFilter();
            Assert.IsFalse(filter.IsInitialized);
        }

        [Test]
        public void FirstUpdate_InitializesFilter_ReturnsInputPose()
        {
            var filter = new KalmanPoseFilter();
            Matrix4x4 pose = CreatePose(1f, 2f, 3f, 0.1f, 0.2f, 0.3f);

            Matrix4x4 result = filter.Update(pose);

            Assert.IsTrue(filter.IsInitialized);
            // First update should return the raw pose unchanged
            AssertPosesEqual(pose, result, 0.001f);
        }

        [Test]
        public void Reset_ClearsInitialization()
        {
            var filter = new KalmanPoseFilter();
            filter.Update(Matrix4x4.identity);
            Assert.IsTrue(filter.IsInitialized);

            filter.Reset();
            Assert.IsFalse(filter.IsInitialized);
        }

        #endregion

        #region Smoothing Behavior Tests (Requirement 13.1)

        [Test]
        public void NoisySequence_SmoothedOutputIsLessNoisy()
        {
            var filter = new KalmanPoseFilter(processNoise: 0.01f, measurementNoise: 0.1f);
            var rng = new System.Random(42);

            float baseTx = 1.0f, baseTy = 2.0f, baseTz = 5.0f;
            float noiseStd = 0.05f;
            int steps = 30;

            float rawVarianceSum = 0f;
            float smoothedVarianceSum = 0f;
            float[] rawTx = new float[steps];
            float[] smoothedTx = new float[steps];

            for (int i = 0; i < steps; i++)
            {
                float noise = (float)(rng.NextDouble() - 0.5) * 2f * noiseStd;
                float tx = baseTx + noise;
                Matrix4x4 rawPose = CreatePose(tx, baseTy, baseTz, 0f, 0f, 0f);
                Matrix4x4 smoothed = filter.Update(rawPose);

                rawTx[i] = tx;
                smoothedTx[i] = smoothed.m03;
            }

            // Compute variance of raw and smoothed tx values (skip first few for filter warmup)
            int startIdx = 5;
            float rawMean = 0f, smoothedMean = 0f;
            int count = steps - startIdx;
            for (int i = startIdx; i < steps; i++)
            {
                rawMean += rawTx[i];
                smoothedMean += smoothedTx[i];
            }
            rawMean /= count;
            smoothedMean /= count;

            for (int i = startIdx; i < steps; i++)
            {
                rawVarianceSum += (rawTx[i] - rawMean) * (rawTx[i] - rawMean);
                smoothedVarianceSum += (smoothedTx[i] - smoothedMean) * (smoothedTx[i] - smoothedMean);
            }

            float rawVariance = rawVarianceSum / count;
            float smoothedVariance = smoothedVarianceSum / count;

            // Smoothed output should have less variance than raw noisy input
            Assert.Less(smoothedVariance, rawVariance,
                $"Smoothed variance ({smoothedVariance:F6}) should be less than raw variance ({rawVariance:F6})");
        }

        [Test]
        public void ConstantPose_SmoothedConvergesToInput()
        {
            var filter = new KalmanPoseFilter();
            Matrix4x4 constantPose = CreatePose(2f, 3f, 4f, 0.1f, -0.1f, 0.05f);

            Matrix4x4 smoothed = Matrix4x4.identity;
            for (int i = 0; i < 20; i++)
            {
                smoothed = filter.Update(constantPose);
            }

            // After many updates with the same pose, smoothed should converge
            Vector3 rawT = new Vector3(constantPose.m03, constantPose.m13, constantPose.m23);
            Vector3 smoothedT = new Vector3(smoothed.m03, smoothed.m13, smoothed.m23);
            float translationDiff = Vector3.Distance(rawT, smoothedT);

            Assert.Less(translationDiff, 0.01f,
                $"After convergence, translation diff should be very small, got {translationDiff:F4}m");
        }

        #endregion

        #region Deviation Bounds Tests (Requirements 13.2, 13.3)

        [Test]
        public void Update_TranslationDifference_LessThanHalfMeter()
        {
            var filter = new KalmanPoseFilter();
            var rng = new System.Random(123);

            // Feed a sequence of poses with moderate noise
            for (int i = 0; i < 20; i++)
            {
                float tx = 1f + (float)(rng.NextDouble() - 0.5) * 0.3f;
                float ty = 2f + (float)(rng.NextDouble() - 0.5) * 0.3f;
                float tz = 5f + (float)(rng.NextDouble() - 0.5) * 0.3f;

                Matrix4x4 rawPose = CreatePose(tx, ty, tz, 0.1f, 0f, 0f);
                Matrix4x4 smoothed = filter.Update(rawPose);

                Vector3 rawT = new Vector3(rawPose.m03, rawPose.m13, rawPose.m23);
                Vector3 smoothedT = new Vector3(smoothed.m03, smoothed.m13, smoothed.m23);
                float diff = Vector3.Distance(rawT, smoothedT);

                Assert.Less(diff, 0.5f,
                    $"Step {i}: Translation diff {diff:F4}m exceeds 0.5m");
            }
        }

        [Test]
        public void Update_RotationDifference_LessThan15Degrees()
        {
            var filter = new KalmanPoseFilter();
            var rng = new System.Random(456);

            for (int i = 0; i < 20; i++)
            {
                float rx = 0.2f + (float)(rng.NextDouble() - 0.5) * 0.1f;
                float ry = -0.1f + (float)(rng.NextDouble() - 0.5) * 0.1f;
                float rz = 0.05f + (float)(rng.NextDouble() - 0.5) * 0.1f;

                Matrix4x4 rawPose = CreatePose(1f, 2f, 5f, rx, ry, rz);
                Matrix4x4 smoothed = filter.Update(rawPose);

                float rotDiff = ComputeRotationDifferenceDegrees(rawPose, smoothed);

                Assert.Less(rotDiff, 15f,
                    $"Step {i}: Rotation diff {rotDiff:F2}° exceeds 15°");
            }
        }

        #endregion

        #region Euler Conversion Round-Trip Tests

        [Test]
        public void EulerToMatrix_MatrixToEuler_RoundTrip()
        {
            float rx = 0.3f, ry = -0.2f, rz = 0.1f;
            Matrix4x4 mat = KalmanPoseFilter.EulerToMatrix(rx, ry, rz);
            float[] recovered = KalmanPoseFilter.MatrixToEuler(mat);

            Assert.AreEqual(rx, recovered[0], 0.001f, "rx round-trip failed");
            Assert.AreEqual(ry, recovered[1], 0.001f, "ry round-trip failed");
            Assert.AreEqual(rz, recovered[2], 0.001f, "rz round-trip failed");
        }

        [Test]
        public void PoseToState_StateToPose_RoundTrip()
        {
            Matrix4x4 original = CreatePose(1.5f, -2.3f, 4.7f, 0.2f, -0.15f, 0.1f);
            float[] state = KalmanPoseFilter.PoseToState(original);
            Matrix4x4 reconstructed = KalmanPoseFilter.StateToPose(state);

            // Translation should match exactly
            Assert.AreEqual(original.m03, reconstructed.m03, 0.001f, "tx mismatch");
            Assert.AreEqual(original.m13, reconstructed.m13, 0.001f, "ty mismatch");
            Assert.AreEqual(original.m23, reconstructed.m23, 0.001f, "tz mismatch");

            // Rotation should be very close
            float rotDiff = ComputeRotationDifferenceDegrees(original, reconstructed);
            Assert.Less(rotDiff, 0.1f, $"Rotation round-trip error: {rotDiff:F4}°");
        }

        [Test]
        public void EulerToMatrix_IdentityRotation_ProducesIdentity()
        {
            Matrix4x4 mat = KalmanPoseFilter.EulerToMatrix(0f, 0f, 0f);

            Assert.AreEqual(1f, mat.m00, 0.001f);
            Assert.AreEqual(0f, mat.m01, 0.001f);
            Assert.AreEqual(0f, mat.m02, 0.001f);
            Assert.AreEqual(0f, mat.m10, 0.001f);
            Assert.AreEqual(1f, mat.m11, 0.001f);
            Assert.AreEqual(0f, mat.m12, 0.001f);
            Assert.AreEqual(0f, mat.m20, 0.001f);
            Assert.AreEqual(0f, mat.m21, 0.001f);
            Assert.AreEqual(1f, mat.m22, 0.001f);
        }

        #endregion

        #region Helper Methods

        private static Matrix4x4 CreatePose(float tx, float ty, float tz, float rx, float ry, float rz)
        {
            Matrix4x4 pose = KalmanPoseFilter.EulerToMatrix(rx, ry, rz);
            pose.m03 = tx;
            pose.m13 = ty;
            pose.m23 = tz;
            pose.m30 = 0f; pose.m31 = 0f; pose.m32 = 0f; pose.m33 = 1f;
            return pose;
        }

        private static void AssertPosesEqual(Matrix4x4 expected, Matrix4x4 actual, float tolerance)
        {
            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++)
                    Assert.AreEqual(expected[i, j], actual[i, j], tolerance,
                        $"Pose mismatch at [{i},{j}]");
        }

        private static float ComputeRotationDifferenceDegrees(Matrix4x4 a, Matrix4x4 b)
        {
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
