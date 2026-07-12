using System;
using System.Collections.Generic;
using UnityEngine;

namespace VideoPlaybackTestScene
{
    /// <summary>
    /// poses.json 的顶层结构
    /// </summary>
    [Serializable]
    public class PosesData
    {
        public List<FrameEntry> frames;
    }

    /// <summary>
    /// poses.json 中每一帧的条目
    /// transform 是 16 个浮点数，列优先（column-major）4x4 camera-to-world 矩阵
    /// </summary>
    [Serializable]
    public class FrameEntry
    {
        public int index;
        public double timestamp;
        public string imageFile;
        public float[] transform; // 16 floats, column-major
    }

    /// <summary>
    /// intrinsics.json 的结构
    /// </summary>
    [Serializable]
    public class IntrinsicsData
    {
        public float fx;
        public float fy;
        public float cx;
        public float cy;
        public int width;
        public int height;
    }

    /// <summary>
    /// 扫描数据工具方法：列优先矩阵转换和内参矩阵构建
    /// </summary>
    public static class ScanDataUtils
    {
        /// <summary>
        /// 将列优先（column-major）16-float 数组转换为 Unity Matrix4x4（行优先存储）
        /// 列优先布局：colMajor[col * 4 + row]
        /// </summary>
        /// <param name="colMajor">16 个浮点数，列优先排列</param>
        /// <returns>对应的 Matrix4x4</returns>
        public static Matrix4x4 ColumnMajorToMatrix4x4(float[] colMajor)
        {
            if (colMajor == null || colMajor.Length != 16)
                throw new ArgumentException("colMajor must have exactly 16 elements", nameof(colMajor));

            var m = new Matrix4x4();
            // matrix[row, col] = colMajor[col * 4 + row]
            for (int col = 0; col < 4; col++)
                for (int row = 0; row < 4; row++)
                    m[row, col] = colMajor[col * 4 + row];
            return m;
        }

        /// <summary>
        /// 将 Unity Matrix4x4 转换为列优先（column-major）16-float 数组
        /// </summary>
        /// <param name="m">Unity Matrix4x4</param>
        /// <returns>16 个浮点数，列优先排列</returns>
        public static float[] Matrix4x4ToColumnMajor(Matrix4x4 m)
        {
            var colMajor = new float[16];
            // colMajor[col * 4 + row] = matrix[row, col]
            for (int col = 0; col < 4; col++)
                for (int row = 0; row < 4; row++)
                    colMajor[col * 4 + row] = m[row, col];
            return colMajor;
        }

        /// <summary>
        /// 根据 IntrinsicsData 构建 3x3 相机内参矩阵（存储在 Matrix4x4 的左上角）
        /// m00=fx, m11=fy, m02=cx, m12=cy, m22=1，其余为 0
        /// </summary>
        /// <param name="data">相机内参数据</param>
        /// <returns>内参矩阵（Matrix4x4，仅使用左上 3x3）</returns>
        public static Matrix4x4 BuildIntrinsicsMatrix(IntrinsicsData data)
        {
            if (data == null)
                throw new ArgumentNullException(nameof(data));

            var m = Matrix4x4.zero;
            m.m00 = data.fx;
            m.m11 = data.fy;
            m.m02 = data.cx;
            m.m12 = data.cy;
            m.m22 = 1f;
            return m;
        }
    }
}
