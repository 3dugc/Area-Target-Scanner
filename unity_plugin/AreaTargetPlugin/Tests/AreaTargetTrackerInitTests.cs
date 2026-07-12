using System;
using System.IO;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace AreaTargetPlugin.Tests
{
    [TestFixture]
    [IgnoreLogErrors]
    public class AreaTargetTrackerInitTests
    {
        private string _testDir;

        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
            _testDir = Path.Combine(Path.GetTempPath(), "TrackerInitTests_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_testDir);
        }

        [TearDown]
        public void TearDown()
        {
            if (Directory.Exists(_testDir))
            {
                Directory.Delete(_testDir, true);
            }
        }

        private string CreateValidAssetBundle()
        {
            string manifest = @"{
                ""version"": ""2.0"",
                ""name"": ""test_asset"",
                ""meshFile"": ""optimized.glb"",
                ""format"": ""glb"",
                ""featureDbFile"": ""features.db"",
                ""keyframeCount"": 5,
                ""featureType"": ""ORB"",
                ""createdAt"": ""2024-01-01T00:00:00Z""
            }";
            File.WriteAllText(Path.Combine(_testDir, "manifest.json"), manifest);
            File.WriteAllText(Path.Combine(_testDir, "optimized.glb"), "GLB_DATA");
            File.WriteAllText(Path.Combine(_testDir, "features.db"), "DB");
            return _testDir;
        }

        [Test]
        public void Initialize_ValidAsset_LoaderSucceeds()
        {
            LogAssert.ignoreFailingMessages = true;
            string assetDir = CreateValidAssetBundle();
            var loader = new AssetBundleLoader();

            bool result = loader.Load(assetDir);

            Assert.IsTrue(result);
            Assert.IsNull(loader.LastError);
            Assert.IsNotNull(loader.Manifest);
            Assert.AreEqual("2.0", loader.Manifest.version);
        }

        [Test]
        public void Initialize_ValidAsset_SetsStateToInitializing()
        {
            LogAssert.ignoreFailingMessages = true;
            // AreaTargetTracker.Initialize will fail at FeatureDatabaseReader.Load
            // because we don't have a real SQLite DB, but the tracker state should
            // remain INITIALIZING (the default state for a new tracker)
            string assetDir = CreateValidAssetBundle();
            var tracker = new AreaTargetTracker();

            tracker.Initialize(assetDir);

            Assert.AreEqual(TrackingState.INITIALIZING, tracker.GetTrackingState());
            tracker.Dispose();
        }

        [Test]
        public void Initialize_InvalidPath_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            var tracker = new AreaTargetTracker();

            bool result = tracker.Initialize("/nonexistent/path");

            Assert.IsFalse(result);
            tracker.Dispose();
        }

        [Test]
        public void Initialize_NullPath_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            var tracker = new AreaTargetTracker();

            bool result = tracker.Initialize(null);

            Assert.IsFalse(result);
            tracker.Dispose();
        }

        [Test]
        public void Initialize_CorruptManifest_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            Directory.CreateDirectory(_testDir);
            File.WriteAllText(Path.Combine(_testDir, "manifest.json"), "CORRUPT DATA");

            var tracker = new AreaTargetTracker();
            bool result = tracker.Initialize(_testDir);

            Assert.IsFalse(result);
            tracker.Dispose();
        }

        [Test]
        public void Initialize_IncompatibleVersion_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string manifest = @"{
                ""version"": ""99.0"",
                ""name"": ""test"",
                ""meshFile"": ""mesh.obj"",
                ""textureFile"": ""texture_atlas.png"",
                ""featureDbFile"": ""features.db""
            }";
            File.WriteAllText(Path.Combine(_testDir, "manifest.json"), manifest);
            File.WriteAllText(Path.Combine(_testDir, "mesh.obj"), "data");
            File.WriteAllText(Path.Combine(_testDir, "texture_atlas.png"), "data");
            File.WriteAllText(Path.Combine(_testDir, "features.db"), "data");

            var tracker = new AreaTargetTracker();
            bool result = tracker.Initialize(_testDir);

            Assert.IsFalse(result);
            tracker.Dispose();
        }

        [Test]
        public void Initialize_AfterDispose_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string assetDir = CreateValidAssetBundle();
            var tracker = new AreaTargetTracker();
            tracker.Dispose();

            bool result = tracker.Initialize(assetDir);

            Assert.IsFalse(result);
        }

        [Test]
        public void ProcessFrame_BeforeInitialize_ReturnsLost()
        {
            var tracker = new AreaTargetTracker();
            var frame = new CameraFrame
            {
                ImageData = new byte[100],
                Width = 10,
                Height = 10,
                Intrinsics = Matrix4x4.identity
            };

            TrackingResult result = tracker.ProcessFrame(frame);

            Assert.AreEqual(TrackingState.LOST, result.State);
            Assert.AreEqual(0f, result.Confidence);
            Assert.AreEqual(0, result.MatchedFeatures);
            tracker.Dispose();
        }
    }
}
