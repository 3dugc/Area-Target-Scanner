using System.Collections.Generic;
using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>
    /// 纯计算类：从一组 Raw 定位位姿计算 Alignment Transform (AT) 矩阵，
    /// 以及比较两个 AT 矩阵的差异（用于安全阀判断）。
    /// </summary>
    internal static class AlignmentTransformCalculator
    {
        /// <summary>
        /// 从一组 Raw 定位位姿计算 Alignment Transform。
        /// 使用位姿的中位数（距质心最近的位姿）作为参考，
        /// 计算从 Raw 坐标系到目标坐标系的刚体变换。
        /// </summary>
        /// <param name="poses">Raw 模式下成功定位的位姿列表。</param>
        /// <param name="at">输出的 AT 矩阵。</param>
        /// <returns>计算成功返回 true；输入为空或结果无效时返回 false。</returns>
        public static bool TryCompute(List<Matrix4x4> poses, out Matrix4x4 at)
        {
            at = Matrix4x4.identity;

            if (poses == null || poses.Count == 0)
                return false;

            // 计算所有位姿平移的质心
            Vector3 centroid = Vector3.zero;
            foreach (var p in poses)
                centroid += new Vector3(p.m03, p.m13, p.m23);
            centroid /= poses.Count;

            // 找到距质心最近的位姿（中位数近似）
            int medianIdx = 0;
            float minDist = float.MaxValue;
            for (int i = 0; i < poses.Count; i++)
            {
                Vector3 t = new Vector3(poses[i].m03, poses[i].m13, poses[i].m23);
                float dist = (t - centroid).sqrMagnitude;
                if (dist < minDist)
                {
                    minDist = dist;
                    medianIdx = i;
                }
            }

            // AT 即为中位数位姿（从 Raw 原点到该位姿坐标系的刚体变换）
            at = poses[medianIdx];

            // 验证结果矩阵不含 NaN/Inf
            if (!IsValidMatrix(at))
            {
                at = Matrix4x4.identity;
                return false;
            }

            return true;
        }

        /// <summary>
        /// 比较两个 AT 矩阵的差异，返回旋转角度差（度）和平移距离差（米）。
        /// 用于 AT 安全阀判断：旋转 > 5° 或平移 > 0.5m 时应丢弃新 AT。
        /// </summary>
        public static (float rotationDeg, float translationM) ComputeDifference(
            Matrix4x4 atOld, Matrix4x4 atNew)
        {
            // 平移差异
            Vector3 tOld = new Vector3(atOld.m03, atOld.m13, atOld.m23);
            Vector3 tNew = new Vector3(atNew.m03, atNew.m13, atNew.m23);
            float translationDiff = (tNew - tOld).magnitude;

            // 旋转差异：计算相对旋转 R = Rnew * Rold^T
            // 然后从 trace 提取角度：angle = acos((trace(R) - 1) / 2)
            Matrix4x4 relativeRot = MultiplyRotations(atNew, TransposeRotation(atOld));
            float trace = relativeRot.m00 + relativeRot.m11 + relativeRot.m22;
            float cosAngle = Mathf.Clamp((trace - 1f) / 2f, -1f, 1f);
            float rotationRad = Mathf.Acos(cosAngle);
            float rotationDeg = rotationRad * Mathf.Rad2Deg;

            return (rotationDeg, translationDiff);
        }

        /// <summary>
        /// 检查 4x4 矩阵是否包含 NaN 或 Infinity。
        /// </summary>
        internal static bool IsValidMatrix(Matrix4x4 m)
        {
            for (int i = 0; i < 16; i++)
            {
                float v = m[i];
                if (float.IsNaN(v) || float.IsInfinity(v))
                    return false;
            }
            return true;
        }

        /// <summary>
        /// 将 4x4 矩阵的 3x3 旋转部分转置（不影响平移列）。
        /// 返回一个新矩阵，其旋转部分为原矩阵旋转的转置。
        /// </summary>
        internal static Matrix4x4 TransposeRotation(Matrix4x4 m)
        {
            var result = new Matrix4x4();
            // 转置 3x3 旋转部分
            result.m00 = m.m00; result.m01 = m.m10; result.m02 = m.m20;
            result.m10 = m.m01; result.m11 = m.m11; result.m12 = m.m21;
            result.m20 = m.m02; result.m21 = m.m12; result.m22 = m.m22;
            // 清零平移和齐次行
            result.m03 = 0f; result.m13 = 0f; result.m23 = 0f;
            result.m30 = 0f; result.m31 = 0f; result.m32 = 0f; result.m33 = 1f;
            return result;
        }

        /// <summary>
        /// 仅乘以两个矩阵的 3x3 旋转部分，返回结果矩阵（平移为零）。
        /// </summary>
        internal static Matrix4x4 MultiplyRotations(Matrix4x4 a, Matrix4x4 b)
        {
            var result = new Matrix4x4();
            result.m00 = a.m00 * b.m00 + a.m01 * b.m10 + a.m02 * b.m20;
            result.m01 = a.m00 * b.m01 + a.m01 * b.m11 + a.m02 * b.m21;
            result.m02 = a.m00 * b.m02 + a.m01 * b.m12 + a.m02 * b.m22;

            result.m10 = a.m10 * b.m00 + a.m11 * b.m10 + a.m12 * b.m20;
            result.m11 = a.m10 * b.m01 + a.m11 * b.m11 + a.m12 * b.m21;
            result.m12 = a.m10 * b.m02 + a.m11 * b.m12 + a.m12 * b.m22;

            result.m20 = a.m20 * b.m00 + a.m21 * b.m10 + a.m22 * b.m20;
            result.m21 = a.m20 * b.m01 + a.m21 * b.m11 + a.m22 * b.m21;
            result.m22 = a.m20 * b.m02 + a.m21 * b.m12 + a.m22 * b.m22;

            result.m03 = 0f; result.m13 = 0f; result.m23 = 0f;
            result.m30 = 0f; result.m31 = 0f; result.m32 = 0f; result.m33 = 1f;
            return result;
        }
    }
}
