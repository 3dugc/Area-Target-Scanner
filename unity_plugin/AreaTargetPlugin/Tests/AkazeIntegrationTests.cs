using System;
using System.IO;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;
using SQLite;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// AKAZE + AT 集成基础类型单元测试。
    /// Validates: Requirements 3.1, 3.2, 9.1, 9.4
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class AkazeIntegrationTests
    {
        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
        }

        #region LocalizationQuality 枚举测试 (Requirement 3.1)

        [Test]
        public void LocalizationQuality_ContainsNone()
        {
            Assert.IsTrue(Enum.IsDefined(typeof(LocalizationQuality), LocalizationQuality.NONE));
        }

        [Test]
        public void LocalizationQuality_ContainsRecognized()
        {
            Assert.IsTrue(Enum.IsDefined(typeof(LocalizationQuality), LocalizationQuality.RECOGNIZED));
        }

        [Test]
        public void LocalizationQuality_ContainsLocalized()
        {
            Assert.IsTrue(Enum.IsDefined(typeof(LocalizationQuality), LocalizationQuality.LOCALIZED));
        }

        [Test]
        public void LocalizationQuality_HasExactlyThreeValues()
        {
            var values = Enum.GetValues(typeof(LocalizationQuality));
            Assert.AreEqual(3, values.Length);
        }

        [Test]
        public void LocalizationQuality_NoneIsZero()
        {
            Assert.AreEqual(0, (int)LocalizationQuality.NONE);
        }

        #endregion

        #region TrackingResult.Quality 默认值测试 (Requirement 3.2, 9.4)

        [Test]
        public void TrackingResult_DefaultQuality_IsNone()
        {
            var result = new TrackingResult();
            Assert.AreEqual(LocalizationQuality.NONE, result.Quality);
        }

        [Test]
        public void TrackingResult_ExistingFieldsUnchanged()
        {
            // 验证现有字段仍然存在且默认值正确
            var result = new TrackingResult();
            Assert.AreEqual(TrackingState.INITIALIZING, result.State); // 枚举默认值 0
            Assert.AreEqual(Matrix4x4.zero, result.Pose);
            Assert.AreEqual(0f, result.Confidence);
            Assert.AreEqual(0, result.MatchedFeatures);
        }

        #endregion

        #region TrackingState 向后兼容测试 (Requirement 9.1)

        [Test]
        public void TrackingState_StillContainsOriginalValues()
        {
            Assert.IsTrue(Enum.IsDefined(typeof(TrackingState), TrackingState.INITIALIZING));
            Assert.IsTrue(Enum.IsDefined(typeof(TrackingState), TrackingState.TRACKING));
            Assert.IsTrue(Enum.IsDefined(typeof(TrackingState), TrackingState.LOST));
        }

        [Test]
        public void TrackingState_OriginalValuesUnchanged()
        {
            Assert.AreEqual(0, (int)TrackingState.INITIALIZING);
            Assert.AreEqual(1, (int)TrackingState.TRACKING);
            Assert.AreEqual(2, (int)TrackingState.LOST);
        }

        #endregion

        #region ExtendedDebugInfo 结构体测试 (Requirement 8.2)

        [Test]
        public void ExtendedDebugInfo_DefaultValues()
        {
            var info = new ExtendedDebugInfo();
            Assert.AreEqual(LocalizationMode.Raw, info.CurrentMode);
            Assert.IsFalse(info.IsATSet);
            Assert.AreEqual(0, info.PoseBufferFrameCount);
            Assert.AreEqual(0, info.ConsecutiveLostFrames);
            Assert.AreEqual(0, info.SlidingWindowFrameCount);
        }

        #endregion

        #region P/Invoke 方法签名验证 (Requirement 2.3, 4.2, 8.1)

        [Test]
        public void VlAddKeyframeAkaze_MethodExists()
        {
            var method = typeof(NativeLocalizerBridge).GetMethod("vl_add_keyframe_akaze",
                System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic);
            Assert.IsNotNull(method, "vl_add_keyframe_akaze should exist");
            var parameters = method.GetParameters();
            Assert.AreEqual(7, parameters.Length);
            Assert.AreEqual(typeof(IntPtr), parameters[0].ParameterType); // handle
            Assert.AreEqual(typeof(int), parameters[1].ParameterType);    // kf_id
            Assert.AreEqual(typeof(byte[]), parameters[2].ParameterType); // descriptors
            Assert.AreEqual(typeof(int), parameters[3].ParameterType);    // desc_count
            Assert.AreEqual(typeof(int), parameters[4].ParameterType);    // desc_len
            Assert.AreEqual(typeof(float[]), parameters[5].ParameterType); // points3d
            Assert.AreEqual(typeof(float[]), parameters[6].ParameterType); // points2d
        }

        [Test]
        public void VlAddKeyframeAkaze_ReturnsInt()
        {
            var method = typeof(NativeLocalizerBridge).GetMethod("vl_add_keyframe_akaze",
                System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic);
            Assert.IsNotNull(method);
            Assert.AreEqual(typeof(int), method.ReturnType);
        }

        [Test]
        public void VlSetAlignmentTransform_MethodExists()
        {
            var method = typeof(NativeLocalizerBridge).GetMethod("vl_set_alignment_transform",
                System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic);
            Assert.IsNotNull(method, "vl_set_alignment_transform should exist");
            var parameters = method.GetParameters();
            Assert.AreEqual(2, parameters.Length);
            Assert.AreEqual(typeof(IntPtr), parameters[0].ParameterType); // handle
            Assert.AreEqual(typeof(float[]), parameters[1].ParameterType); // at_4x4
        }

        [Test]
        public void VlSetAlignmentTransform_ReturnsVoid()
        {
            var method = typeof(NativeLocalizerBridge).GetMethod("vl_set_alignment_transform",
                System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic);
            Assert.IsNotNull(method);
            Assert.AreEqual(typeof(void), method.ReturnType);
        }

        [Test]
        public void VLDebugInfo_ContainsNewFields()
        {
            var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public;
            var debugType = typeof(VLDebugInfo);

            // 验证新增字段存在且类型正确
            var bestInlierRatio = debugType.GetField("best_inlier_ratio", flags);
            Assert.IsNotNull(bestInlierRatio, "best_inlier_ratio field should exist");
            Assert.AreEqual(typeof(float), bestInlierRatio.FieldType);

            var akazeTriggered = debugType.GetField("akaze_triggered", flags);
            Assert.IsNotNull(akazeTriggered, "akaze_triggered field should exist");
            Assert.AreEqual(typeof(int), akazeTriggered.FieldType);

            var akazeKeypoints = debugType.GetField("akaze_keypoints", flags);
            Assert.IsNotNull(akazeKeypoints, "akaze_keypoints field should exist");
            Assert.AreEqual(typeof(int), akazeKeypoints.FieldType);

            var akazeBestInliers = debugType.GetField("akaze_best_inliers", flags);
            Assert.IsNotNull(akazeBestInliers, "akaze_best_inliers field should exist");
            Assert.AreEqual(typeof(int), akazeBestInliers.FieldType);

            var consistencyRejected = debugType.GetField("consistency_rejected", flags);
            Assert.IsNotNull(consistencyRejected, "consistency_rejected field should exist");
            Assert.AreEqual(typeof(int), consistencyRejected.FieldType);
        }

        [Test]
        public void VLDebugInfo_NewFieldsDefaultToZero()
        {
            var info = new VLDebugInfo();
            Assert.AreEqual(0f, info.best_inlier_ratio);
            Assert.AreEqual(0, info.akaze_triggered);
            Assert.AreEqual(0, info.akaze_keypoints);
            Assert.AreEqual(0, info.akaze_best_inliers);
            Assert.AreEqual(0, info.consistency_rejected);
        }

        [Test]
        public void VLDebugInfo_OriginalFieldsStillExist()
        {
            // 确保原有字段未被破坏
            var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public;
            var debugType = typeof(VLDebugInfo);

            Assert.IsNotNull(debugType.GetField("orb_keypoints", flags));
            Assert.IsNotNull(debugType.GetField("candidate_keyframes", flags));
            Assert.IsNotNull(debugType.GetField("best_kf_id", flags));
            Assert.IsNotNull(debugType.GetField("best_raw_matches", flags));
            Assert.IsNotNull(debugType.GetField("best_good_matches", flags));
            Assert.IsNotNull(debugType.GetField("best_inliers", flags));
            Assert.IsNotNull(debugType.GetField("best_bow_sim", flags));
        }

        #endregion

        #region FeatureDatabaseReader AKAZE 向后兼容测试 (Requirement 1.2, 1.3, 9.3)

        private string _tempDbPath;

        [TearDown]
        public void TearDown()
        {
            if (_tempDbPath != null && File.Exists(_tempDbPath))
            {
                try { File.Delete(_tempDbPath); } catch { }
                _tempDbPath = null;
            }
        }

        [Test]
        public void HasAkazeFeatures_NoAkazeTable_ReturnsFalse()
        {
            // 创建一个只有 keyframes/features/vocabulary 表的最小数据库（无 akaze_features）
            _tempDbPath = Path.Combine(Path.GetTempPath(), $"no_akaze_{Guid.NewGuid()}.db");
            CreateMinimalDbWithoutAkaze(_tempDbPath);

            var reader = new FeatureDatabaseReader();
            bool loaded = reader.Load(_tempDbPath);

            Assert.IsTrue(loaded, "Load should succeed for DB without akaze_features table");
            Assert.IsFalse(reader.HasAkazeFeatures, "HasAkazeFeatures should be false when table doesn't exist");
            Assert.Greater(reader.KeyframeCount, 0, "Should still load keyframes");

            reader.Dispose();
        }

        [Test]
        public void HasAkazeFeatures_EmptyAkazeTable_ReturnsFalse()
        {
            // 创建一个有 akaze_features 表但为空的数据库
            _tempDbPath = Path.Combine(Path.GetTempPath(), $"empty_akaze_{Guid.NewGuid()}.db");
            CreateMinimalDbWithEmptyAkaze(_tempDbPath);

            var reader = new FeatureDatabaseReader();
            bool loaded = reader.Load(_tempDbPath);

            Assert.IsTrue(loaded, "Load should succeed for DB with empty akaze_features table");
            Assert.IsFalse(reader.HasAkazeFeatures, "HasAkazeFeatures should be false when akaze_features is empty");

            reader.Dispose();
        }

        [Test]
        public void HasAkazeFeatures_DefaultValue_IsFalse()
        {
            var reader = new FeatureDatabaseReader();
            Assert.IsFalse(reader.HasAkazeFeatures, "HasAkazeFeatures should default to false before Load");
        }

        [Test]
        public void KeyframeRecord_AkazeLists_InitializedEmpty()
        {
            // 无 akaze_features 表时，关键帧的 AKAZE 列表应已初始化为空
            _tempDbPath = Path.Combine(Path.GetTempPath(), $"kf_akaze_init_{Guid.NewGuid()}.db");
            CreateMinimalDbWithoutAkaze(_tempDbPath);

            var reader = new FeatureDatabaseReader();
            reader.Load(_tempDbPath);

            foreach (var kf in reader.Keyframes)
            {
                Assert.IsNotNull(kf.AkazeDescriptors, "AkazeDescriptors should be initialized");
                Assert.IsNotNull(kf.AkazeKeypoints2D, "AkazeKeypoints2D should be initialized");
                Assert.IsNotNull(kf.AkazePoints3D, "AkazePoints3D should be initialized");
                Assert.AreEqual(0, kf.AkazeDescriptors.Count, "AkazeDescriptors should be empty");
                Assert.AreEqual(0, kf.AkazeKeypoints2D.Count, "AkazeKeypoints2D should be empty");
                Assert.AreEqual(0, kf.AkazePoints3D.Count, "AkazePoints3D should be empty");
            }

            reader.Dispose();
        }

        /// <summary>
        /// 创建只有 keyframes/features/vocabulary 表的最小数据库（无 akaze_features）。
        /// </summary>
        private static void CreateMinimalDbWithoutAkaze(string dbPath)
        {
            using (var conn = new SQLiteConnection(dbPath, SQLiteOpenFlags.ReadWrite | SQLiteOpenFlags.Create))
            {
                conn.Execute(@"CREATE TABLE keyframes (
                    id INTEGER PRIMARY KEY, pose BLOB, global_descriptor BLOB)");
                conn.Execute(@"CREATE TABLE features (
                    id INTEGER PRIMARY KEY, keyframe_id INTEGER,
                    x REAL, y REAL, x3d REAL, y3d REAL, z3d REAL, descriptor BLOB)");
                conn.Execute(@"CREATE TABLE vocabulary (
                    word_id INTEGER PRIMARY KEY, descriptor BLOB, idf_weight REAL)");

                // 写入一个关键帧（单位矩阵 pose）
                var poseBytes = new byte[128];
                for (int i = 0; i < 16; i++)
                {
                    double val = (i % 5 == 0) ? 1.0 : 0.0;
                    Buffer.BlockCopy(BitConverter.GetBytes(val), 0, poseBytes, i * 8, 8);
                }
                conn.Execute("INSERT INTO keyframes (id, pose) VALUES (?, ?)", 1, poseBytes);
            }
        }

        /// <summary>
        /// 创建有 akaze_features 表但为空的数据库。
        /// </summary>
        private static void CreateMinimalDbWithEmptyAkaze(string dbPath)
        {
            using (var conn = new SQLiteConnection(dbPath, SQLiteOpenFlags.ReadWrite | SQLiteOpenFlags.Create))
            {
                conn.Execute(@"CREATE TABLE keyframes (
                    id INTEGER PRIMARY KEY, pose BLOB, global_descriptor BLOB)");
                conn.Execute(@"CREATE TABLE features (
                    id INTEGER PRIMARY KEY, keyframe_id INTEGER,
                    x REAL, y REAL, x3d REAL, y3d REAL, z3d REAL, descriptor BLOB)");
                conn.Execute(@"CREATE TABLE vocabulary (
                    word_id INTEGER PRIMARY KEY, descriptor BLOB, idf_weight REAL)");
                conn.Execute(@"CREATE TABLE akaze_features (
                    id INTEGER PRIMARY KEY, keyframe_id INTEGER,
                    x REAL, y REAL, x3d REAL, y3d REAL, z3d REAL, descriptor BLOB)");

                var poseBytes = new byte[128];
                for (int i = 0; i < 16; i++)
                {
                    double val = (i % 5 == 0) ? 1.0 : 0.0;
                    Buffer.BlockCopy(BitConverter.GetBytes(val), 0, poseBytes, i * 8, 8);
                }
                conn.Execute("INSERT INTO keyframes (id, pose) VALUES (?, ?)", 1, poseBytes);
            }
        }

        #endregion
    }
}
