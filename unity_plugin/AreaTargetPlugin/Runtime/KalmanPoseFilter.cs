using System;
using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>
    /// Source-compatible pose facade. Smoothing and residual decisions delegate
    /// to the same C++ Session used by Tracker. Active localization does not
    /// apply this facade a second time. Legacy noise parameters are unused.
    /// </summary>
    public sealed class KalmanPoseFilter : IDisposable
    {
        private const int StateSize = 6;
        private NativeSessionBridge _session;
        private long _nextFrameId;
        public KalmanPoseFilter() { }
        [Obsolete("Noise parameters are retained for source compatibility; the shared native profile owns smoothing.")]
        public KalmanPoseFilter(float processNoise = .01f, float measurementNoise = .1f) { }
        public bool IsInitialized => _session != null && _session.LastNativeResult.AlignmentValid != 0;
        public void Reset()
        {
            _session?.Dispose(); _session = null; _nextFrameId = 0;
        }
        public Matrix4x4 Update(Matrix4x4 rawPose) => UpdateAt(rawPose, LocalizationClock.NowTimestampNs);
        internal Matrix4x4 UpdateAt(Matrix4x4 rawPose, long captureTimestampNs)
        {
            if (_session == null) _session = new NativeSessionBridge();
            return _session.UpdateWorldPose(rawPose, ++_nextFrameId, captureTimestampNs).Pose;
        }
        public void Dispose() => Reset();

        /// <summary>
        /// Decomposes a 4x4 pose matrix into [tx, ty, tz, rx, ry, rz].
        /// </summary>
        internal static float[] PoseToState(Matrix4x4 pose)
        {
            float[] state = new float[StateSize];
            // Translation
            state[0] = pose.m03;
            state[1] = pose.m13;
            state[2] = pose.m23;
            // Euler angles from rotation matrix
            float[] euler = MatrixToEuler(pose);
            state[3] = euler[0];
            state[4] = euler[1];
            state[5] = euler[2];
            return state;
        }

        /// <summary>
        /// Reconstructs a 4x4 pose matrix from state [tx, ty, tz, rx, ry, rz].
        /// </summary>
        internal static Matrix4x4 StateToPose(float[] state)
        {
            Matrix4x4 rot = EulerToMatrix(state[3], state[4], state[5]);
            Matrix4x4 pose = rot;
            pose.m03 = state[0];
            pose.m13 = state[1];
            pose.m23 = state[2];
            pose.m30 = 0f;
            pose.m31 = 0f;
            pose.m32 = 0f;
            pose.m33 = 1f;
            return pose;
        }

        /// <summary>
        /// Extracts Euler angles (rx, ry, rz) from a rotation matrix using ZYX convention.
        /// </summary>
        internal static float[] MatrixToEuler(Matrix4x4 m)
        {
            float sy = -m.m20;
            float ry, rx, rz;

            if (Mathf.Abs(sy) < 0.99999f)
            {
                ry = Mathf.Asin(sy);
                rx = Mathf.Atan2(m.m21, m.m22);
                rz = Mathf.Atan2(m.m10, m.m00);
            }
            else
            {
                // Gimbal lock
                ry = sy > 0 ? Mathf.PI / 2f : -Mathf.PI / 2f;
                rx = Mathf.Atan2(-m.m12, m.m11);
                rz = 0f;
            }

            return new float[] { rx, ry, rz };
        }

        /// <summary>
        /// Constructs a rotation matrix from Euler angles (rx, ry, rz) using ZYX convention.
        /// </summary>
        internal static Matrix4x4 EulerToMatrix(float rx, float ry, float rz)
        {
            float cx = Mathf.Cos(rx), sx = Mathf.Sin(rx);
            float cy = Mathf.Cos(ry), sy = Mathf.Sin(ry);
            float cz = Mathf.Cos(rz), sz = Mathf.Sin(rz);

            Matrix4x4 m = new Matrix4x4();
            m.m00 = cy * cz;
            m.m01 = sx * sy * cz - cx * sz;
            m.m02 = cx * sy * cz + sx * sz;
            m.m10 = cy * sz;
            m.m11 = sx * sy * sz + cx * cz;
            m.m12 = cx * sy * sz - sx * cz;
            m.m20 = -sy;
            m.m21 = sx * cy;
            m.m22 = cx * cy;
            m.m30 = 0f; m.m31 = 0f; m.m32 = 0f; m.m33 = 1f;
            m.m03 = 0f; m.m13 = 0f; m.m23 = 0f;
            return m;
        }

    }
}
