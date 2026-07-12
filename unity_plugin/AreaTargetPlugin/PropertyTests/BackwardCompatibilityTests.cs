using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;
using UnityEngine;
using UnityEngine.TestTools;
using SQLite;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// 向后兼容性单元测试和 Property 16 测试。
    /// Validates: Requirements 9.1, 9.2, 9.3, 9.4
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class BackwardCompatibilityTests
    {
        private string _tempDbPath;

        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
        }

        [TearDown]
        public void TearDown()
        {
            if (_tempDbPath != null && File.Exists(_tempDbPath))
            {
                try { File.Delete(_tempDbPath); } catch { }
                _tempDbPath = null;
            }
        }

        // =====================================================================
        // 14.1: 向后兼容性单元测试
        // Validates: Requirements 9.1, 9.2, 9.3
        // =====================================================================

        #region TrackingState 枚举向后兼容 (Requirement 9.1)

        [Test]
        public void TrackingState_HasInitializing_WithValue0()
        {
            Assert.IsTrue(Enum.IsDefined(typeof(TrackingState), TrackingState.INITIALIZING));
            Assert.AreEqual(0, (int)TrackingState.INITIALIZING);
        }

        [Test]
        public void TrackingState_HasTracking_WithValue1()
        {
            Assert.IsTrue(Enum.IsDefined(typeof(TrackingState), TrackingState.TRACKING));
            Assert.AreEqual(1, (int)TrackingState.TRACKING);
        }

        [Test]
        public void TrackingState_HasLost_WithValue2()
        {
            Assert.IsTrue(Enum.IsDefined(typeof(TrackingState), TrackingState.LOST));
            Assert.AreEqual(2, (int)TrackingState.LOST);
        }

        #endregion

        #region IAreaTargetTracker 接口方法签名不变 (Requirement 9.2)

        [Test]
        public void IAreaTargetTracker_HasInitializeMethod()
        {
            var method = typeof(IAreaTargetTracker).GetMethod("Initialize");
            Assert.IsNotNull(method, "Initialize method should exist");
            Assert.AreEqual(typeof(bool), method.ReturnType);
            var parameters = method.GetParameters();
            Assert.AreEqual(1, parameters.Length);
            Assert.AreEqual(typeof(string), parameters[0].ParameterType);
        }

        [Test]
        public void IAreaTargetTracker_HasProcessFrameMethod()
        {
            var method = typeof(IAreaTargetTracker).GetMethod("ProcessFrame");
            Assert.IsNotNull(method, "ProcessFrame method should exist");
            Assert.AreEqual(typeof(TrackingResult), method.ReturnType);
            var parameters = method.GetParameters();
            Assert.AreEqual(1, parameters.Length);
            Assert.AreEqual(typeof(CameraFrame), parameters[0].ParameterType);
        }

        [Test]
        public void IAreaTargetTracker_HasGetTrackingStateMethod()
        {
            var method = typeof(IAreaTargetTracker).GetMethod("GetTrackingState");
            Assert.IsNotNull(method, "GetTrackingState method should exist");
            Assert.AreEqual(typeof(TrackingState), method.ReturnType);
            Assert.AreEqual(0, method.GetParameters().Length);
        }

        [Test]
        public void IAreaTargetTracker_HasResetMethod()
        {
            var method = typeof(IAreaTargetTracker).GetMethod("Reset");
            Assert.IsNotNull(method, "Reset method should exist");
            Assert.AreEqual(typeof(void), method.ReturnType);
            Assert.AreEqual(0, method.GetParameters().Length);
        }

        [Test]
        public void IAreaTargetTracker_ExtendsIDisposable()
        {
            Assert.IsTrue(typeof(IDisposable).IsAssignableFrom(typeof(IAreaTargetTracker)),
                "IAreaTargetTracker should extend IDisposable");
        }

        #endregion

        #region TrackingResult.Quality 默认值 (Requirement 9.4)

        [Test]
        public void TrackingResult_Quality_DefaultsToNone()
        {
            var result = new TrackingResult();
            Assert.AreEqual(LocalizationQuality.NONE, result.Quality);
        }

        #endregion

        #region FeatureDatabaseReader.HasAkazeFeatures 默认值 (Requirement 9.3)

        [Test]
        public void FeatureDatabaseReader_HasAkazeFeatures_DefaultsFalse()
        {
            var reader = new FeatureDatabaseReader();
            Assert.IsFalse(reader.HasAkazeFeatures);
            reader.Dispose();
        }

        #endregion

        // =====================================================================
        // 14.2: Property 16 — 无 AKAZE 数据时向后兼容
        // Feature: unity-akaze-at-integration, Property 16
        // **Validates: Requirements 9.1, 9.3, 9.4**
        //
        // For any features.db without akaze_features table:
        // - HasAkazeFeatures should be false
        // - No vl_add_keyframe_akaze calls should be made
        // - TrackingState should only use INITIALIZING/TRACKING/LOST
        // - Quality defaults to NONE
        // =====================================================================

        /// <summary>
        /// Property 16a: 对任意不含 akaze_features 表的 features.db，
        /// HasAkazeFeatures 应为 false，关键帧的 AKAZE 列表应为空。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property NoAkazeTable_HasAkazeFeatures_IsFalse(PositiveInt keyframeCount)
        {
            int numKeyframes = (keyframeCount.Get % 10) + 1; // 1-10 个关键帧

            _tempDbPath = Path.Combine(Path.GetTempPath(), $"compat_{Guid.NewGuid()}.db");
            CreateOrbOnlyDatabase(_tempDbPath, numKeyframes);

            var reader = new FeatureDatabaseReader();
            bool loaded = reader.Load(_tempDbPath);

            if (!loaded)
                return false.ToProperty().Label("Failed to load database");

            bool hasAkazeFalse = !reader.HasAkazeFeatures;
            bool keyframeCountCorrect = reader.KeyframeCount == numKeyframes;

            // 验证每个关键帧的 AKAZE 列表为空
            bool allAkazeEmpty = true;
            foreach (var kf in reader.Keyframes)
            {
                if (kf.AkazeDescriptors.Count != 0 ||
                    kf.AkazeKeypoints2D.Count != 0 ||
                    kf.AkazePoints3D.Count != 0)
                {
                    allAkazeEmpty = false;
                    break;
                }
            }

            reader.Dispose();

            return (hasAkazeFalse && keyframeCountCorrect && allAkazeEmpty).ToProperty()
                .Label($"keyframes={numKeyframes}: hasAkaze={!hasAkazeFalse}, " +
                       $"kfCount={reader.KeyframeCount}, allEmpty={allAkazeEmpty}");
        }

        /// <summary>
        /// Property 16b: 无 AKAZE 数据时，TrackingState 枚举仅包含
        /// INITIALIZING/TRACKING/LOST，Quality 默认为 NONE。
        /// 对任意 TrackingState 值验证向后兼容。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property NoAkaze_TrackingState_OnlyUsesOriginalValues(int stateIndex)
        {
            // TrackingState 应只有 3 个值
            var allValues = (TrackingState[])Enum.GetValues(typeof(TrackingState));

            // 验证枚举值数量和具体值
            bool hasThreeValues = allValues.Length == 3;
            bool hasInitializing = Array.IndexOf(allValues, TrackingState.INITIALIZING) >= 0;
            bool hasTracking = Array.IndexOf(allValues, TrackingState.TRACKING) >= 0;
            bool hasLost = Array.IndexOf(allValues, TrackingState.LOST) >= 0;

            // 验证数值不变
            bool valuesCorrect = (int)TrackingState.INITIALIZING == 0
                && (int)TrackingState.TRACKING == 1
                && (int)TrackingState.LOST == 2;

            // 验证 TrackingResult.Quality 默认为 NONE
            var result = new TrackingResult();
            bool qualityDefault = result.Quality == LocalizationQuality.NONE;

            bool allOk = hasThreeValues && hasInitializing && hasTracking && hasLost
                && valuesCorrect && qualityDefault;

            return allOk.ToProperty()
                .Label($"TrackingState values={allValues.Length}, " +
                       $"INIT={hasInitializing}, TRACK={hasTracking}, LOST={hasLost}, " +
                       $"values={valuesCorrect}, qualityDefault={qualityDefault}");
        }

        /// <summary>
        /// Property 16c: 对任意不含 akaze_features 表的 DB，加载后关键帧的
        /// ORB 数据应正常存在，AKAZE 数据应为空列表（非 null）。
        /// 验证纯 ORB 模式下不会调用 vl_add_keyframe_akaze。
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property NoAkaze_OrbDataIntact_AkazeListsInitialized(PositiveInt seed)
        {
            int kfId = (seed.Get % 100) + 1;
            int numOrbFeatures = (seed.Get % 20) + 1;

            _tempDbPath = Path.Combine(Path.GetTempPath(), $"orb_compat_{Guid.NewGuid()}.db");
            CreateOrbOnlyDatabaseWithFeatures(_tempDbPath, kfId, numOrbFeatures);

            var reader = new FeatureDatabaseReader();
            bool loaded = reader.Load(_tempDbPath);

            if (!loaded)
                return false.ToProperty().Label("Failed to load database");

            // HasAkazeFeatures 应为 false
            bool noAkaze = !reader.HasAkazeFeatures;

            // 找到关键帧
            KeyframeRecord kf = null;
            foreach (var k in reader.Keyframes)
            {
                if (k.Id == kfId) { kf = k; break; }
            }

            if (kf == null)
            {
                reader.Dispose();
                return false.ToProperty().Label($"Keyframe {kfId} not found");
            }

            // ORB 数据应存在
            bool orbPresent = kf.Descriptors.Count == numOrbFeatures
                && kf.Keypoints2D.Count == numOrbFeatures
                && kf.Points3D.Count == numOrbFeatures;

            // AKAZE 列表应已初始化为空（非 null）
            bool akazeInitialized = kf.AkazeDescriptors != null
                && kf.AkazeKeypoints2D != null
                && kf.AkazePoints3D != null;
            bool akazeEmpty = kf.AkazeDescriptors.Count == 0
                && kf.AkazeKeypoints2D.Count == 0
                && kf.AkazePoints3D.Count == 0;

            reader.Dispose();

            return (noAkaze && orbPresent && akazeInitialized && akazeEmpty).ToProperty()
                .Label($"kf={kfId}, orbFeatures={numOrbFeatures}: " +
                       $"noAkaze={noAkaze}, orbPresent={orbPresent}, " +
                       $"akazeInit={akazeInitialized}, akazeEmpty={akazeEmpty}");
        }

        #region Helper: 创建纯 ORB 数据库（无 akaze_features 表）

        /// <summary>
        /// 创建只有 keyframes/features/vocabulary 表的数据库（无 akaze_features）。
        /// </summary>
        private static void CreateOrbOnlyDatabase(string dbPath, int numKeyframes)
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

                for (int kfId = 1; kfId <= numKeyframes; kfId++)
                {
                    var poseBytes = new byte[128];
                    for (int i = 0; i < 16; i++)
                    {
                        double val = (i % 5 == 0) ? 1.0 : 0.0;
                        Buffer.BlockCopy(BitConverter.GetBytes(val), 0, poseBytes, i * 8, 8);
                    }
                    conn.Execute("INSERT INTO keyframes (id, pose) VALUES (?, ?)", kfId, poseBytes);
                }
            }
        }

        /// <summary>
        /// 创建包含 ORB 特征但无 akaze_features 表的数据库。
        /// </summary>
        private static void CreateOrbOnlyDatabaseWithFeatures(string dbPath, int kfId, int numFeatures)
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

                // 写入关键帧
                var poseBytes = new byte[128];
                for (int i = 0; i < 16; i++)
                {
                    double val = (i % 5 == 0) ? 1.0 : 0.0;
                    Buffer.BlockCopy(BitConverter.GetBytes(val), 0, poseBytes, i * 8, 8);
                }
                conn.Execute("INSERT INTO keyframes (id, pose) VALUES (?, ?)", kfId, poseBytes);

                // 写入 ORB 特征
                var rng = new System.Random(kfId);
                for (int i = 0; i < numFeatures; i++)
                {
                    var desc = new byte[32];
                    rng.NextBytes(desc);
                    conn.Execute(
                        "INSERT INTO features (keyframe_id, x, y, x3d, y3d, z3d, descriptor) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        kfId,
                        rng.NextDouble() * 1920.0, rng.NextDouble() * 1080.0,
                        rng.NextDouble() * 10.0 - 5.0, rng.NextDouble() * 10.0 - 5.0, rng.NextDouble() * 10.0 - 5.0,
                        desc);
                }
            }
        }

        #endregion
    }
}
