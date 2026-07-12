using NUnit.Framework;
using UnityEngine;
using VideoPlaybackTestScene;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Unit tests for ScanDataModels: column-major matrix conversion and intrinsics matrix building.
    /// Validates: Requirements 7.1, 7.2, 7.3
    /// </summary>
    [TestFixture]
    public class ScanDataModelsTests
    {
        // --- ColumnMajorToMatrix4x4 ---

        [Test]
        public void ColumnMajorToMatrix4x4_IdentityArray_ReturnsIdentityMatrix()
        {
            // 单位矩阵的列优先表示：对角线元素为 1，其余为 0
            float[] colMajor = {
                1, 0, 0, 0,  // col 0
                0, 1, 0, 0,  // col 1
                0, 0, 1, 0,  // col 2
                0, 0, 0, 1   // col 3
            };

            var result = ScanDataUtils.ColumnMajorToMatrix4x4(colMajor);

            Assert.That(result, Is.EqualTo(Matrix4x4.identity).Using(Matrix4x4Comparer.Instance));
        }

        [Test]
        public void ColumnMajorToMatrix4x4_KnownARKitPose_CorrectLayout()
        {
            // 模拟 ARKit CameraPose.swift 导出的列优先矩阵
            // 旋转 90° 绕 Y 轴，平移 (1, 2, 3)
            // 列优先：col0=(0,0,-1,0), col1=(0,1,0,0), col2=(1,0,0,0), col3=(1,2,3,1)
            float[] colMajor = {
                0, 0, -1, 0,   // col 0: 第一列
                0, 1,  0, 0,   // col 1: 第二列
                1, 0,  0, 0,   // col 2: 第三列
                1, 2,  3, 1    // col 3: 第四列（平移）
            };

            var result = ScanDataUtils.ColumnMajorToMatrix4x4(colMajor);

            // 验证行优先存储：matrix[row, col] = colMajor[col * 4 + row]
            Assert.That(result.m00, Is.EqualTo(0f).Within(1e-6f));   // [0,0] = col0[0]
            Assert.That(result.m10, Is.EqualTo(0f).Within(1e-6f));   // [1,0] = col0[1]
            Assert.That(result.m20, Is.EqualTo(-1f).Within(1e-6f));  // [2,0] = col0[2]
            Assert.That(result.m01, Is.EqualTo(0f).Within(1e-6f));   // [0,1] = col1[0]
            Assert.That(result.m11, Is.EqualTo(1f).Within(1e-6f));   // [1,1] = col1[1]
            Assert.That(result.m03, Is.EqualTo(1f).Within(1e-6f));   // [0,3] = col3[0] (tx)
            Assert.That(result.m13, Is.EqualTo(2f).Within(1e-6f));   // [1,3] = col3[1] (ty)
            Assert.That(result.m23, Is.EqualTo(3f).Within(1e-6f
));   // [2,3] = col3[2] (tz)
            Assert.That(result.m33, Is.EqualTo(1f).Within(1e-6f));   // [3,3] = col3[3]
        }

        [Test]
        public void Matrix4x4ToColumnMajor_IdentityMatrix_ReturnsIdentityArray()
        {
            var result = ScanDataUtils.Matrix4x4ToColumnMajor(Matrix4x4.identity);

            float[] expected = {
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1
            };

            Assert.That(result.Length, Is.EqualTo(16));
            for (int i = 0; i < 16; i++)
                Assert.That(result[i], Is.EqualTo(expected[i]).Within(1e-6f), $"Index {i}");
        }

        [Test]
        public void ColumnMajorRoundTrip_ArbitraryMatrix_IsExact()
        {
            float[] original = {
                1, 2, 3, 4,
                5, 6, 7, 8,
                9, 10, 11, 12,
                13, 14, 15, 16
            };

            var matrix = ScanDataUtils.ColumnMajorToMatrix4x4(original);
            var roundTripped = ScanDataUtils.Matrix4x4ToColumnMajor(matrix);

            for (int i = 0; i < 16; i++)
                Assert.That(roundTripped[i], Is.EqualTo(original[i]).Within(1e-6f), $"Index {i}");
        }

        [Test]
        public void ColumnMajorToMatrix4x4_NullArray_ThrowsArgumentException()
        {
            Assert.Throws<System.ArgumentException>(() =>
                ScanDataUtils.ColumnMajorToMatrix4x4(null));
        }

        [Test]
        public void ColumnMajorToMatrix4x4_WrongLength_ThrowsArgumentException()
        {
            Assert.Throws<System.ArgumentException>(() =>
                ScanDataUtils.ColumnMajorToMatrix4x4(new float[15]));
        }

        // --- BuildIntrinsicsMatrix ---

        [Test]
        public void BuildIntrinsicsMatrix_TypicalValues_CorrectElements()
        {
            var data = new IntrinsicsData
            {
                fx = 1113.5f,
                fy = 1113.5f,
                cx = 480.0f,
                cy = 640.0f,
                width = 960,
                height = 1280
            };

            var m = ScanDataUtils.BuildIntrinsicsMatrix(data);

            Assert.That(m.m00, Is.EqualTo(1113.5f).Within(1e-4f), "fx → m00");
            Assert.That(m.m11, Is.EqualTo(1113.5f).Within(1e-4f), "fy → m11");
            Assert.That(m.m02, Is.EqualTo(480.0f).Within(1e-4f),  "cx → m02");
            Assert.That(m.m12, Is.EqualTo(640.0f).Within(1e-4f),  "cy → m12");
            Assert.That(m.m22, Is.EqualTo(1.0f).Within(1e-6f),    "m22 = 1");
        }

        [Test]
        public void BuildIntrinsicsMatrix_OffDiagonalElements_AreZero()
        {
            var data = new IntrinsicsData { fx = 500f, fy = 500f, cx = 320f, cy = 240f };
            var m = ScanDataUtils.BuildIntrinsicsMatrix(data);

            Assert.That(m.m01, Is.EqualTo(0f).Within(1e-6f), "m01");
            Assert.That(m.m10, Is.EqualTo(0f).Within(1e-6f), "m10");
            Assert.That(m.m20, Is.EqualTo(0f).Within(1e-6f), "m20");
            Assert.That(m.m21, Is.EqualTo(0f).Within(1e-6f), "m21");
            Assert.That(m.m03, Is.EqualTo(0f).Within(1e-6f), "m03");
            Assert.That(m.m13, Is.EqualTo(0f).Within(1e-6f), "m13");
            Assert.That(m.m23, Is.EqualTo(0f).Within(1e-6f), "m23");
        }

        [Test]
        public void BuildIntrinsicsMatrix_NullData_ThrowsArgumentNullException()
        {
            Assert.Throws<System.ArgumentNullException>(() =>
                ScanDataUtils.BuildIntrinsicsMatrix(null));
        }

        // --- Matrix4x4Comparer helper ---

        private class Matrix4x4Comparer : System.Collections.Generic.IEqualityComparer<Matrix4x4>
        {
            public static readonly Matrix4x4Comparer Instance = new Matrix4x4Comparer();
            private const float Tolerance = 1e-6f;

            public bool Equals(Matrix4x4 x, Matrix4x4 y)
            {
                for (int r = 0; r < 4; r++)
                    for (int c = 0; c < 4; c++)
                        if (System.Math.Abs(x[r, c] - y[r, c]) > Tolerance) return false;
                return true;
            }

            public int GetHashCode(Matrix4x4 obj) => obj.GetHashCode();
        }
    }
}
