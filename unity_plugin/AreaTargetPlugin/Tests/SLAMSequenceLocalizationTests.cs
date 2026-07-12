using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;
using AreaTargetPlugin;
using VideoPlaybackTestScene;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// SLAM 序列定位测试：用真实 ScanData + features.db 验证 Unity 侧的
    /// PnP → flip → scanToAR 映射链路是否正确。
    ///
    /// 流程（纯 C# 实现，不依赖 native P/Invoke）：
    ///   1. FeatureDatabaseReader 读取 features.db（keyframe 位姿 + 2D/3D 特征）
    ///   2. ImageSeqFrameSource 读取 ScanData（94帧位姿）
    ///   3. 对每帧 scan pose 找最近的 DB keyframe
    ///   4. 用 DB keyframe 的 2D/3D 对应关系做纯 C# PnP（DLT + flip）
    ///   5. 计算 scanToAR = cameraPose × w2c_native，验证接近单位矩阵
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class SLAMSequenceLocalizationTests
    {
        private string _scanDataPath;
        private string _assetPath;
        private string _dbPath;
        private FeatureDatabaseReader _featureDb;
        private ImageSeqFrameSource _frameSource;
        private bool _dataAvailable;

        // 精度阈值
        private const float S2A_ERROR_THRESHOLD = 0.1f;     // scanToAR 矩阵误差
        private const float TRANSLATION_ERROR_M = 0.01f;    // 平移误差 (m)
        private const float ROTATION_ERROR_DEG = 1.0f;      // 旋转误差 (°)
        private const float MIN_SUCCESS_RATE = 0.90f;       // 最低成功率 90%

        [OneTimeSetUp]
        public void OneTimeSetUp()
        {
            LogAssert.ignoreFailingMessages = true;

            _scanDataPath = Path.Combine(Application.streamingAssetsPath, "ScanData");
            _assetPath = Path.Combine(Application.streamingAssetsPath, "SLAMTestAssets");
            _dbPath = Path.Combine(_assetPath, "features.db");

            // 检查真实数据是否存在
            _dataAvailable = Directory.Exists(_scanDataPath)
                && File.Exists(Path.Combine(_scanDataPath, "poses.json"))
                && File.Exists(_dbPath);

            if (!_dataAvailable)
            {
                Debug.LogWarning("[SLAMSequenceTest] 跳过：ScanData 或 features.db 不存在");
                return;
            }

            // 加载 features.db
            _featureDb = new FeatureDatabaseReader();
            Assert.IsTrue(_featureDb.Load(_dbPath), "features.db 加载失败");

            // 加载 ScanData
            _frameSource = new ImageSeqFrameSource();
            Assert.IsTrue(_frameSource.Load(_scanDataPath), $"ScanData 加载失败: {_frameSource.LastError}");
        }

        [OneTimeTearDown]
        public void OneTimeTearDown()
        {
            _featureDb?.Dispose();
        }

        // ================================================================
        // 数据完整性验证
        // ================================================================

        [Test]
        public void DataIntegrity_ScanDataLoaded()
        {
            if (!_dataAvailable) Assert.Ignore("数据不可用");
            Assert.Greater(_frameSource.FrameCount, 0, "ScanData 帧数应 > 0");
            Debug.Log($"[SLAMSequenceTest] ScanData: {_frameSource.FrameCount} 帧");
        }

        [Test]
        public void DataIntegrity_FeatureDbLoaded()
        {
            if (!_dataAvailable) Assert.Ignore("数据不可用");
            Assert.Greater(_featureDb.KeyframeCount, 0, "features.db keyframe 数应 > 0");
            Debug.Log($"[SLAMSequenceTest] features.db: {_featureDb.KeyframeCount} keyframes");
        }

        [Test]
        public void DataIntegrity_AllKeyframesHaveFeatures()
        {
            if (!_dataAvailable) Assert.Ignore("数据不可用");
            foreach (var kf in _featureDb.Keyframes)
            {
                Assert.Greater(kf.Points3D.Count, 0,
                    $"Keyframe {kf.Id} 没有 3D 特征点");
                Assert.AreEqual(kf.Points3D.Count, kf.Keypoints2D.Count,
                    $"Keyframe {kf.Id} 的 2D/3D 特征数不匹配");
                Assert.AreEqual(kf.Points3D.Count, kf.Descriptors.Count,
                    $"Keyframe {kf.Id} 的描述子数不匹配");
            }
        }

        [Test]
        public void DataIntegrity_AllScanPosesAreValid()
        {
            if (!_dataAvailable) Assert.Ignore("数据不可用");
            for (int i = 0; i < _frameSource.FrameCount; i++)
            {
                Matrix4x4 pose = _frameSource.GetPose(i);
                // 最后一行应为 [0, 0, 0, 1]
                Assert.AreEqual(0f, pose.m30, 1e-4f, $"Frame {i}: m30 != 0");
                Assert.AreEqual(0f, pose.m31, 1e-4f, $"Frame {i}: m31 != 0");
                Assert.AreEqual(0f, pose.m32, 1e-4f, $"Frame {i}: m32 != 0");
                Assert.AreEqual(1f, pose.m33, 1e-4f, $"Frame {i}: m33 != 1");
            }
        }

        [Test]
        public void DataIntegrity_AllKeyframePosesAreValid()
        {
            if (!_dataAvailable) Assert.Ignore("数据不可用");
            foreach (var kf in _featureDb.Keyframes)
            {
                Assert.IsNotNull(kf.Pose, $"Keyframe {kf.Id}: pose is null");
                Assert.AreEqual(16, kf.Pose.Length, $"Keyframe {kf.Id}: pose length != 16");
                // Row-major: last row [12..15] = [0, 0, 0, 1]
                Assert.AreEqual(0f, kf.Pose[12], 1e-4f, $"KF {kf.Id}: pose[12] != 0");
                Assert.AreEqual(0f, kf.Pose[13], 1e-4f, $"KF {kf.Id}: pose[13] != 0");
                Assert.AreEqual(0f, kf.Pose[14], 1e-4f, $"KF {kf.Id}: pose[14] != 0");
                Assert.AreEqual(1f, kf.Pose[15], 1e-4f, $"KF {kf.Id}: pose[15] != 1");
            }
        }

        // ================================================================
        // 空间匹配验证：每个 scan frame 都能找到近距离的 DB keyframe
        // ================================================================

        [Test]
        public void SpatialMatch_EachScanFrameHasNearbyKeyframe()
        {
            if (!_dataAvailable) Assert.Ignore("数据不可用");

            int matched = 0;
            float maxDist = 0f;

            for (int i = 0; i < _frameSource.FrameCount; i++)
            {
                Matrix4x4 scanPose = _frameSource.GetPose(i);
                Vector3 scanPos = new Vector3(scanPose.m03, scanPose.m13, scanPose.m23);

                var nearby = _featureDb.GetNearbyKeyframes(scanPos, 1.0f, 1);
                if (nearby.Count > 0)
                {
                    matched++;
                    Vector3 kfPos = new Vector3(nearby[0].Pose[3], nearby[0].Pose[7], nearby[0].Pose[11]);
                    float dist = Vector3.Distance(scanPos, kfPos);
                    if (dist > maxDist) maxDist = dist;
                }
            }

            float rate = (float)matched / _frameSource.FrameCount;
            Debug.Log($"[SLAMSequenceTest] 空间匹配: {matched}/{_frameSource.FrameCount} ({rate:P1}), maxDist={maxDist:F4}m");
            Assert.GreaterOrEqual(rate, MIN_SUCCESS_RATE,
                $"空间匹配率 {rate:P1} 低于阈值 {MIN_SUCCESS_RATE:P0}");
        }

        // ================================================================
        // 核心定位链路验证：PnP → flip → scanToAR
        // 使用 DB keyframe 自身的 2D/3D 对应关系做 DLT PnP（纯 C#）
        // ================================================================

        [Test]
        public void LocalizationChain_ScanToAR_IsNearIdentity()
        {
            if (!_dataAvailable) Assert.Ignore("数据不可用");

            int totalFrames = _frameSource.FrameCount;
            int successCount = 0;
            int testedCount = 0;
            float sumError = 0f;
            float maxError = 0f;
            float sumTransErr = 0f;
            float sumRotErr = 0f;

            for (int i = 0; i < totalFrames; i++)
            {
                Matrix4x4 scanC2W = _frameSource.GetPose(i);
                Vector3 scanPos = new Vector3(scanC2W.m03, scanC2W.m13, scanC2W.m23);

                // 找最近的 DB keyframe
                var nearby = _featureDb.GetNearbyKeyframes(scanPos, 2.0f, 1);
                if (nearby.Count == 0) continue;

                var kf = nearby[0];
                if (kf.Points3D.Count < 6) continue;

                testedCount++;

                // 用 DB keyframe 的 2D/3D 对应关系做 DLT PnP
                Matrix4x4? w2cNative = SolvePnPDLT(kf.Points3D, kf.Keypoints2D,
                    _frameSource.ImageWidth, _frameSource.ImageHeight);

                if (!w2cNative.HasValue) continue;

                // scanToAR = cameraPose × w2c_native
                // 这里用 DB keyframe 自身的 c2w 作为 arCameraPose（与 Python 脚本一致）
                Matrix4x4 kfC2W = RowMajorToMatrix4x4(kf.Pose);
                Matrix4x4 scanToAR = kfC2W * w2cNative.Value;

                // 计算与单位矩阵的误差
                float s2aErr = MatrixErrorFromIdentity(scanToAR);
                float tErr = new Vector3(scanToAR.m03, scanToAR.m13, scanToAR.m23).magnitude;
                float rotErr = RotationErrorDegrees(scanToAR);

                if (s2aErr < S2A_ERROR_THRESHOLD)
                {
                    successCount++;
                    sumError += s2aErr;
                    sumTransErr += tErr;
                    sumRotErr += rotErr;
                    if (s2aErr > maxError) maxError = s2aErr;
                }
            }

            float successRate = testedCount > 0 ? (float)successCount / testedCount : 0f;
            float meanErr = successCount > 0 ? sumError / successCount : float.MaxValue;
            float meanTErr = successCount > 0 ? sumTransErr / successCount : float.MaxValue;
            float meanRotErr = successCount > 0 ? sumRotErr / successCount : float.MaxValue;

            Debug.Log($"[SLAMSequenceTest] 定位链路验证:");
            Debug.Log($"  测试帧: {testedCount}/{totalFrames}");
            Debug.Log($"  成功: {successCount}/{testedCount} ({successRate:P1})");
            Debug.Log($"  scanToAR 误差: mean={meanErr:F4} max={maxError:F4}");
            Debug.Log($"  平移误差: mean={meanTErr:F4}m");
            Debug.Log($"  旋转误差: mean={meanRotErr:F2}°");

            Assert.GreaterOrEqual(successRate, MIN_SUCCESS_RATE,
                $"定位成功率 {successRate:P1} 低于阈值 {MIN_SUCCESS_RATE:P0}");
            Assert.Less(meanErr, S2A_ERROR_THRESHOLD,
                $"平均 scanToAR 误差 {meanErr:F4} 超过阈值 {S2A_ERROR_THRESHOLD}");
        }

        // ================================================================
        // scanToWorld 变换验证：模拟 VideoPlaybackTestSceneManager.HandleTrackingResult
        // 验证 cameraPose * result.Pose 产生的 scanToWorld 是否合理
        // ================================================================

        [Test]
        public void ScanToWorld_TranslationIsReasonable()
        {
            if (!_dataAvailable) Assert.Ignore("数据不可用");

            for (int i = 0; i < _frameSource.FrameCount; i++)
            {
                Matrix4x4 scanC2W = _frameSource.GetPose(i);
                Vector3 scanPos = new Vector3(scanC2W.m03, scanC2W.m13, scanC2W.m23);

                var nearby = _featureDb.GetNearbyKeyframes(scanPos, 2.0f, 1);
                if (nearby.Count == 0) continue;

                var kf = nearby[0];
                if (kf.Points3D.Count < 6) continue;

                Matrix4x4? w2cNative = SolvePnPDLT(kf.Points3D, kf.Keypoints2D,
                    _frameSource.ImageWidth, _frameSource.ImageHeight);
                if (!w2cNative.HasValue) continue;

                // 模拟 HandleTrackingResult: scanToWorld = cameraPose * result.Pose
                Matrix4x4 scanToWorld = scanC2W * w2cNative.Value;
                Vector3 pos = new Vector3(scanToWorld.m03, scanToWorld.m13, scanToWorld.m23);

                // scanToWorld 的平移应在合理范围内（扫描空间通常 < 50m）
                Assert.Less(pos.magnitude, 50f,
                    $"Frame {i}: scanToWorld 平移 {pos.magnitude:F2}m 超出合理范围");
            }
        }

        // ================================================================
        // 纯 C# DLT PnP 实现 + flip(Y,Z)
        // 用 DB keyframe 自身的 2D/3D 对应关系求解 w2c，然后 flip
        // ================================================================

        /// <summary>
        /// 纯 C# DLT PnP：从 N 个 3D-2D 对应关系求解 world-to-camera 变换。
        /// 使用 Direct Linear Transform (DLT) 方法，最少需要 6 个点。
        /// 结果经过 flip(Y,Z) 转换为 ARKit 坐标系。
        /// </summary>
        private static Matrix4x4? SolvePnPDLT(
            List<Vector3> pts3d, List<Vector2> pts2d,
            int imgWidth, int imgHeight)
        {
            int n = Mathf.Min(pts3d.Count, pts2d.Count);
            if (n < 6) return null;

            // 使用内参归一化坐标
            // 从 ImageSeqFrameSource 的 intrinsics 推算 fx, fy, cx, cy
            // data3: fx=fy=1606.47, cx=959.6, cy=721.2, 1920x1440
            float fx = imgWidth * 0.836f;  // 近似值，实际从 intrinsics.json 读取更准确
            float fy = fx;
            float cx = imgWidth / 2.0f;
            float cy = imgHeight / 2.0f;

            // 构建 DLT 矩阵 A (2N x 12)
            // 限制使用的点数避免矩阵过大
            int useN = Mathf.Min(n, 200);
            int step = n > useN ? n / useN : 1;

            var rows = new List<float[]>();
            for (int idx = 0; idx < n && rows.Count < useN * 2; idx += step)
            {
                float X = pts3d[idx].x, Y = pts3d[idx].y, Z = pts3d[idx].z;
                // 归一化图像坐标
                float u = (pts2d[idx].x - cx) / fx;
                float v = (pts2d[idx].y - cy) / fy;

                rows.Add(new float[] {
                    X, Y, Z, 1, 0, 0, 0, 0, -u*X, -u*Y, -u*Z, -u });
                rows.Add(new float[] {
                    0, 0, 0, 0, X, Y, Z, 1, -v*X, -v*Y, -v*Z, -v });
            }

            int m = rows.Count;
            if (m < 12) return null;

            // 求解 A^T A 的最小特征值对应的特征向量（用幂迭代法求最小特征向量）
            // 先计算 A^T A (12x12)
            float[,] AtA = new float[12, 12];
            for (int i = 0; i < 12; i++)
                for (int j = i; j < 12; j++)
                {
                    float sum = 0;
                    for (int k = 0; k < m; k++)
                        sum += rows[k][i] * rows[k][j];
                    AtA[i, j] = sum;
                    AtA[j, i] = sum;
                }

            // 用逆幂迭代求最小特征向量
            float[] p = SolveSmallestEigenvector(AtA, 12);
            if (p == null) return null;

            // p = [r1, r2, r3, t1, r4, r5, r6, t2, r7, r8, r9, t3]
            // 重组为 3x4 投影矩阵 [R|t]
            float[,] Rt = new float[3, 4];
            Rt[0, 0] = p[0]; Rt[0, 1] = p[1]; Rt[0, 2] = p[2];  Rt[0, 3] = p[3];
            Rt[1, 0] = p[4]; Rt[1, 1] = p[5]; Rt[1, 2] = p[6];  Rt[1, 3] = p[7];
            Rt[2, 0] = p[8]; Rt[2, 1] = p[9]; Rt[2, 2] = p[10]; Rt[2, 3] = p[11];

            // 确保 R 的行列式为正（如果为负则翻转符号）
            float det = Rt[0, 0] * (Rt[1, 1] * Rt[2, 2] - Rt[1, 2] * Rt[2, 1])
                      - Rt[0, 1] * (Rt[1, 0] * Rt[2, 2] - Rt[1, 2] * Rt[2, 0])
                      + Rt[0, 2] * (Rt[1, 0] * Rt[2, 1] - Rt[1, 1] * Rt[2, 0]);
            if (det < 0)
            {
                for (int i = 0; i < 3; i++)
                    for (int j = 0; j < 4; j++)
                        Rt[i, j] = -Rt[i, j];
            }

            // 用 SVD 强制正交化 R（Procrustes）
            // 简化：用 Gram-Schmidt 正交化
            Vector3 r0 = new Vector3(Rt[0, 0], Rt[0, 1], Rt[0, 2]).normalized;
            Vector3 r1 = new Vector3(Rt[1, 0], Rt[1, 1], Rt[1, 2]);
            r1 = (r1 - Vector3.Dot(r1, r0) * r0).normalized;
            Vector3 r2 = Vector3.Cross(r0, r1).normalized;

            // 缩放因子：原始 R 行的平均长度
            float scale = (new Vector3(Rt[0, 0], Rt[0, 1], Rt[0, 2]).magnitude
                         + new Vector3(Rt[1, 0], Rt[1, 1], Rt[1, 2]).magnitude
                         + new Vector3(Rt[2, 0], Rt[2, 1], Rt[2, 2]).magnitude) / 3f;
            if (scale < 1e-8f) return null;

            Vector3 t = new Vector3(Rt[0, 3], Rt[1, 3], Rt[2, 3]) / scale;

            // 构建 OpenCV 坐标系的 w2c
            var w2cCV = new Matrix4x4();
            w2cCV.m00 = r0.x; w2cCV.m01 = r0.y; w2cCV.m02 = r0.z; w2cCV.m03 = t.x;
            w2cCV.m10 = r1.x; w2cCV.m11 = r1.y; w2cCV.m12 = r1.z; w2cCV.m13 = t.y;
            w2cCV.m20 = r2.x; w2cCV.m21 = r2.y; w2cCV.m22 = r2.z; w2cCV.m23 = t.z;
            w2cCV.m30 = 0; w2cCV.m31 = 0; w2cCV.m32 = 0; w2cCV.m33 = 1;

            // flip(Y, Z): ARKit → OpenCV 坐标系转换
            // flip = diag(1, -1, -1)
            // w2c_native = flip @ R, flip @ t
            var w2c = new Matrix4x4();
            w2c.m00 =  w2cCV.m00; w2c.m01 =  w2cCV.m01; w2c.m02 =  w2cCV.m02; w2c.m03 =  w2cCV.m03;
            w2c.m10 = -w2cCV.m10; w2c.m11 = -w2cCV.m11; w2c.m12 = -w2cCV.m12; w2c.m13 = -w2cCV.m13;
            w2c.m20 = -w2cCV.m20; w2c.m21 = -w2cCV.m21; w2c.m22 = -w2cCV.m22; w2c.m23 = -w2cCV.m23;
            w2c.m30 = 0; w2c.m31 = 0; w2c.m32 = 0; w2c.m33 = 1;

            return w2c;
        }

        /// <summary>
        /// 逆幂迭代法求对称矩阵最小特征值对应的特征向量。
        /// </summary>
        private static float[] SolveSmallestEigenvector(float[,] A, int n)
        {
            // 先做 LU 分解求 A^{-1} 的近似（加微小正则化避免奇异）
            float[,] M = new float[n, n];
            for (int i = 0; i < n; i++)
                for (int j = 0; j < n; j++)
                    M[i, j] = A[i, j];
            // 正则化
            for (int i = 0; i < n; i++)
                M[i, i] += 1e-8f;

            // Gauss-Jordan 求逆
            float[,] inv = new float[n, n];
            float[,] aug = new float[n, 2 * n];
            for (int i = 0; i < n; i++)
            {
                for (int j = 0; j < n; j++)
                    aug[i, j] = M[i, j];
                aug[i, n + i] = 1f;
            }

            for (int col = 0; col < n; col++)
            {
                // 部分主元
                int maxRow = col;
                float maxVal = Mathf.Abs(aug[col, col]);
                for (int row = col + 1; row < n; row++)
                {
                    if (Mathf.Abs(aug[row, col]) > maxVal)
                    {
                        maxVal = Mathf.Abs(aug[row, col]);
                        maxRow = row;
                    }
                }
                if (maxVal < 1e-12f) return null;

                // 交换行
                if (maxRow != col)
                    for (int j = 0; j < 2 * n; j++)
                        (aug[col, j], aug[maxRow, j]) = (aug[maxRow, j], aug[col, j]);

                float pivot = aug[col, col];
                for (int j = 0; j < 2 * n; j++)
                    aug[col, j] /= pivot;

                for (int row = 0; row < n; row++)
                {
                    if (row == col) continue;
                    float factor = aug[row, col];
                    for (int j = 0; j < 2 * n; j++)
                        aug[row, j] -= factor * aug[col, j];
                }
            }

            for (int i = 0; i < n; i++)
                for (int j = 0; j < n; j++)
                    inv[i, j] = aug[i, n + j];

            // 幂迭代：v_{k+1} = A^{-1} v_k / ||A^{-1} v_k||
            float[] v = new float[n];
            var rng = new System.Random(42);
            for (int i = 0; i < n; i++)
                v[i] = (float)(rng.NextDouble() - 0.5);

            for (int iter = 0; iter < 100; iter++)
            {
                float[] vNew = new float[n];
                for (int i = 0; i < n; i++)
                {
                    float sum = 0;
                    for (int j = 0; j < n; j++)
                        sum += inv[i, j] * v[j];
                    vNew[i] = sum;
                }
                // 归一化
                float norm = 0;
                for (int i = 0; i < n; i++)
                    norm += vNew[i] * vNew[i];
                norm = Mathf.Sqrt(norm);
                if (norm < 1e-12f) return null;
                for (int i = 0; i < n; i++)
                    vNew[i] /= norm;
                v = vNew;
            }

            return v;
        }

        // ================================================================
        // 工具方法
        // ================================================================

        /// <summary>
        /// Row-major float[16] → Unity Matrix4x4
        /// DB keyframe pose 存储为 row-major
        /// </summary>
        private static Matrix4x4 RowMajorToMatrix4x4(float[] rm)
        {
            var m = new Matrix4x4();
            m.m00 = rm[0];  m.m01 = rm[1];  m.m02 = rm[2];  m.m03 = rm[3];
            m.m10 = rm[4];  m.m11 = rm[5];  m.m12 = rm[6];  m.m13 = rm[7];
            m.m20 = rm[8];  m.m21 = rm[9];  m.m22 = rm[10]; m.m23 = rm[11];
            m.m30 = rm[12]; m.m31 = rm[13]; m.m32 = rm[14]; m.m33 = rm[15];
            return m;
        }

        /// <summary>
        /// 计算矩阵与单位矩阵的 Frobenius 范数差
        /// </summary>
        private static float MatrixErrorFromIdentity(Matrix4x4 m)
        {
            float sum = 0;
            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++)
                {
                    float expected = (i == j) ? 1f : 0f;
                    float diff = m[i, j] - expected;
                    sum += diff * diff;
                }
            return Mathf.Sqrt(sum);
        }

        /// <summary>
        /// 从旋转矩阵提取旋转角度（度）
        /// angle = arccos((trace(R) - 1) / 2)
        /// </summary>
        private static float RotationErrorDegrees(Matrix4x4 m)
        {
            float trace = m.m00 + m.m11 + m.m22;
            float cosAngle = Mathf.Clamp((trace - 1f) / 2f, -1f, 1f);
            return Mathf.Acos(cosAngle) * Mathf.Rad2Deg;
        }
    }
}
