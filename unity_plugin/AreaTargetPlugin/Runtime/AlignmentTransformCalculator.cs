using System.Collections.Generic;
using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>
    /// A successful coordinate pair for one frame. The names make both source and
    /// destination spaces explicit and prevent raw T_C_S poses being treated as T_U_S.
    /// </summary>
    internal readonly struct LocalizationFramePair
    {
        public Matrix4x4 UnityWorldFromCamera { get; }
        public Matrix4x4 CameraFromScan { get; }
        public Matrix4x4 UnityWorldFromScan { get; }

        public LocalizationFramePair(
            Matrix4x4 unityWorldFromCamera,
            Matrix4x4 cameraFromScan)
        {
            CoordinateTransform.ValidateFiniteRigidTransform(
                unityWorldFromCamera, nameof(unityWorldFromCamera));
            CoordinateTransform.ValidateFiniteRigidTransform(
                cameraFromScan, nameof(cameraFromScan));

            UnityWorldFromCamera = unityWorldFromCamera;
            CameraFromScan = cameraFromScan;
            UnityWorldFromScan = CoordinateTransform.ComposeUnityWorldFromScan(
                unityWorldFromCamera, cameraFromScan);
        }
    }

    /// <summary>
    /// Computes a robust runtime alignment candidate from named successful frame pairs
    /// and compares alignment candidates for the tracker safety valve.
    /// </summary>
    internal static class AlignmentTransformCalculator
    {
        /// <summary>
        /// Selects the T_U_S sample whose translation is nearest the translation
        /// centroid. The result is always composed through CoordinateTransform.
        /// </summary>
        public static bool TryCompute(
            IReadOnlyList<LocalizationFramePair> successfulFramePairs,
            out Matrix4x4 unityWorldFromScan)
        {
            unityWorldFromScan = Matrix4x4.identity;

            if (successfulFramePairs == null || successfulFramePairs.Count == 0)
                return false;

            Vector3 centroid = Vector3.zero;
            for (int index = 0; index < successfulFramePairs.Count; index++)
            {
                Matrix4x4 pose = successfulFramePairs[index].UnityWorldFromScan;
                if (!CoordinateTransform.IsFiniteRigidTransform(pose))
                    return false;
                centroid += ExtractTranslation(pose);
            }
            centroid /= successfulFramePairs.Count;

            int medianIndex = 0;
            float minimumDistance = float.MaxValue;
            for (int index = 0; index < successfulFramePairs.Count; index++)
            {
                Vector3 translation = ExtractTranslation(
                    successfulFramePairs[index].UnityWorldFromScan);
                float squaredDistance = (translation - centroid).sqrMagnitude;
                if (squaredDistance < minimumDistance)
                {
                    minimumDistance = squaredDistance;
                    medianIndex = index;
                }
            }

            unityWorldFromScan = successfulFramePairs[medianIndex].UnityWorldFromScan;
            return CoordinateTransform.IsFiniteRigidTransform(unityWorldFromScan);
        }

        /// <summary>
        /// Compares two T_U_S candidates and returns rotation difference in degrees
        /// and translation difference in metres.
        /// </summary>
        public static (float rotationDeg, float translationM) ComputeDifference(
            Matrix4x4 unityWorldFromScanOld,
            Matrix4x4 unityWorldFromScanNew)
        {
            CoordinateTransform.ValidateFiniteRigidTransform(
                unityWorldFromScanOld, nameof(unityWorldFromScanOld));
            CoordinateTransform.ValidateFiniteRigidTransform(
                unityWorldFromScanNew, nameof(unityWorldFromScanNew));

            Vector3 previousTranslation = ExtractTranslation(unityWorldFromScanOld);
            Vector3 currentTranslation = ExtractTranslation(unityWorldFromScanNew);
            float translationDifference = (currentTranslation - previousTranslation).magnitude;

            Matrix4x4 relativeRotation = MultiplyRotations(
                unityWorldFromScanNew,
                TransposeRotation(unityWorldFromScanOld));
            float trace = relativeRotation.m00 + relativeRotation.m11 + relativeRotation.m22;
            float cosine = Mathf.Clamp((trace - 1f) / 2f, -1f, 1f);
            float rotationDegrees = Mathf.Acos(cosine) * Mathf.Rad2Deg;

            return (rotationDegrees, translationDifference);
        }

        internal static bool IsValidMatrix(Matrix4x4 matrix)
        {
            return CoordinateTransform.IsFiniteRigidTransform(matrix);
        }

        internal static Matrix4x4 TransposeRotation(Matrix4x4 matrix)
        {
            var result = Matrix4x4.identity;
            result.m00 = matrix.m00; result.m01 = matrix.m10; result.m02 = matrix.m20;
            result.m10 = matrix.m01; result.m11 = matrix.m11; result.m12 = matrix.m21;
            result.m20 = matrix.m02; result.m21 = matrix.m12; result.m22 = matrix.m22;
            return result;
        }

        internal static Matrix4x4 MultiplyRotations(Matrix4x4 first, Matrix4x4 second)
        {
            var result = Matrix4x4.identity;
            result.m00 = first.m00 * second.m00 + first.m01 * second.m10 + first.m02 * second.m20;
            result.m01 = first.m00 * second.m01 + first.m01 * second.m11 + first.m02 * second.m21;
            result.m02 = first.m00 * second.m02 + first.m01 * second.m12 + first.m02 * second.m22;

            result.m10 = first.m10 * second.m00 + first.m11 * second.m10 + first.m12 * second.m20;
            result.m11 = first.m10 * second.m01 + first.m11 * second.m11 + first.m12 * second.m21;
            result.m12 = first.m10 * second.m02 + first.m11 * second.m12 + first.m12 * second.m22;

            result.m20 = first.m20 * second.m00 + first.m21 * second.m10 + first.m22 * second.m20;
            result.m21 = first.m20 * second.m01 + first.m21 * second.m11 + first.m22 * second.m21;
            result.m22 = first.m20 * second.m02 + first.m21 * second.m12 + first.m22 * second.m22;
            return result;
        }

        private static Vector3 ExtractTranslation(Matrix4x4 matrix)
        {
            return new Vector3(matrix.m03, matrix.m13, matrix.m23);
        }
    }
}
