using System;
using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>
    /// The sole Runtime boundary that composes named coordinate transforms.
    /// All matrices use column vectors, while native interop uses row-major float[16].
    /// </summary>
    public static class CoordinateTransform
    {
        private const float RigidTolerance = 0.001f;

        /// <summary>
        /// Computes T_U_S = T_U_C × T_C_S.
        /// </summary>
        public static Matrix4x4 ComposeUnityWorldFromScan(
            Matrix4x4 unityWorldFromCamera,
            Matrix4x4 cameraFromScan)
        {
            ValidateFiniteRigidTransform(unityWorldFromCamera, nameof(unityWorldFromCamera));
            ValidateFiniteRigidTransform(cameraFromScan, nameof(cameraFromScan));
            return unityWorldFromCamera * cameraFromScan;
        }

        /// <summary>
        /// Serializes a finite rigid transform to native row-major float[16].
        /// </summary>
        public static float[] ToNativeRowMajor(Matrix4x4 matrix)
        {
            ValidateFiniteRigidTransform(matrix, nameof(matrix));
            return new[]
            {
                matrix.m00, matrix.m01, matrix.m02, matrix.m03,
                matrix.m10, matrix.m11, matrix.m12, matrix.m13,
                matrix.m20, matrix.m21, matrix.m22, matrix.m23,
                matrix.m30, matrix.m31, matrix.m32, matrix.m33
            };
        }

        /// <summary>
        /// Deserializes and validates a native row-major float[16] transform.
        /// </summary>
        public static Matrix4x4 FromNativeRowMajor(float[] values)
        {
            if (values == null)
                throw new ArgumentNullException(nameof(values));
            if (values.Length != 16)
                throw new ArgumentException("Native pose must contain exactly 16 row-major values.", nameof(values));

            var matrix = new Matrix4x4
            {
                m00 = values[0], m01 = values[1], m02 = values[2], m03 = values[3],
                m10 = values[4], m11 = values[5], m12 = values[6], m13 = values[7],
                m20 = values[8], m21 = values[9], m22 = values[10], m23 = values[11],
                m30 = values[12], m31 = values[13], m32 = values[14], m33 = values[15]
            };
            ValidateFiniteRigidTransform(matrix, nameof(values));
            return matrix;
        }

        /// <summary>
        /// Returns whether a matrix is finite and represents an orientation-preserving rigid transform.
        /// </summary>
        public static bool IsFiniteRigidTransform(Matrix4x4 matrix)
        {
            for (int index = 0; index < 16; index++)
            {
                float value = matrix[index];
                if (float.IsNaN(value) || float.IsInfinity(value))
                    return false;
            }

            if (Mathf.Abs(matrix.m30) > RigidTolerance
                || Mathf.Abs(matrix.m31) > RigidTolerance
                || Mathf.Abs(matrix.m32) > RigidTolerance
                || Mathf.Abs(matrix.m33 - 1f) > RigidTolerance)
            {
                return false;
            }

            Vector3 xAxis = new Vector3(matrix.m00, matrix.m10, matrix.m20);
            Vector3 yAxis = new Vector3(matrix.m01, matrix.m11, matrix.m21);
            Vector3 zAxis = new Vector3(matrix.m02, matrix.m12, matrix.m22);
            if (Mathf.Abs(xAxis.magnitude - 1f) > RigidTolerance
                || Mathf.Abs(yAxis.magnitude - 1f) > RigidTolerance
                || Mathf.Abs(zAxis.magnitude - 1f) > RigidTolerance
                || Mathf.Abs(Vector3.Dot(xAxis, yAxis)) > RigidTolerance
                || Mathf.Abs(Vector3.Dot(xAxis, zAxis)) > RigidTolerance
                || Mathf.Abs(Vector3.Dot(yAxis, zAxis)) > RigidTolerance)
            {
                return false;
            }

            float determinant = Vector3.Dot(xAxis, Vector3.Cross(yAxis, zAxis));
            return Mathf.Abs(determinant - 1f) <= RigidTolerance;
        }

        internal static void ValidateFiniteRigidTransform(Matrix4x4 matrix, string parameterName)
        {
            if (!IsFiniteRigidTransform(matrix))
                throw new ArgumentException("Matrix must be a finite rigid transform.", parameterName);
        }
    }
}
