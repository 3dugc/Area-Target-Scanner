using NUnit.Framework;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    public class KalmanPoseFilterTests
    {
        [Test]
        public void BarePoseFacade_UsesCoreDefaultConfirmation()
        {
            using (var filter = new KalmanPoseFilter())
            {
                var pose = Matrix4x4.Translate(new Vector3(1, 2, 3));
                NativeSessionBridgeTests.AssertPose(Matrix4x4.identity, filter.UpdateAt(pose, 1000000000));
                Assert.That(filter.IsInitialized, Is.False);
                NativeSessionBridgeTests.AssertPose(pose, filter.UpdateAt(pose, 1100000000));
                Assert.That(filter.IsInitialized, Is.True);
            }
        }
        [Test]
        public void Facade_ProducesSameOutputAsDirectCore_ForGateAndSmoothing()
        {
            using (var filter = new KalmanPoseFilter())
            using (var core = new NativeSessionBridge())
            {
                var offsets = new[] { 0f, 0f, .05f, .10f, 4f, .12f };
                for (int index = 0; index < offsets.Length; index++)
                {
                    var pose = Matrix4x4.Translate(new Vector3(1 + offsets[index], 2, 3));
                    long time = 1000000000 + index * 100000000L;
                    var expected = core.UpdateWorldPose(pose, index + 1, time);
                    NativeSessionBridgeTests.AssertPose(expected.Pose, filter.UpdateAt(pose, time));
                }
            }
        }
        [Test]
        public void Reset_ClearsCoreStateAndRequiresNewConfirmation()
        {
            using (var filter = new KalmanPoseFilter())
            {
                filter.UpdateAt(Matrix4x4.identity, 1000000000);
                filter.UpdateAt(Matrix4x4.identity, 1100000000);
                Assert.That(filter.IsInitialized, Is.True);
                filter.Reset();
                Assert.That(filter.IsInitialized, Is.False);
                filter.UpdateAt(Matrix4x4.identity, 1200000000);
                Assert.That(filter.IsInitialized, Is.False);
            }
        }
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
