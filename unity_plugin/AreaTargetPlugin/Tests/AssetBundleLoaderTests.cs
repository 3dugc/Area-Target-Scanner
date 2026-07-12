using System;
using System.IO;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace AreaTargetPlugin.Tests
{
    [TestFixture]
    [IgnoreLogErrors]
    public class AssetBundleLoaderTests
    {
        private string _testDir;
        private AssetBundleLoader _loader;

        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
            _testDir = Path.Combine(Path.GetTempPath(), "AreaTargetPluginTests_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_testDir);
            _loader = new AssetBundleLoader();
        }

        [TearDown]
        public void TearDown()
        {
            if (Directory.Exists(_testDir))
            {
                Directory.Delete(_testDir, true);
            }
        }

        #region Helper Methods

        private string CreateValidAssetBundle(string subDir = null)
        {
            string dir = subDir != null ? Path.Combine(_testDir, subDir) : _testDir;
            Directory.CreateDirectory(dir);

            string manifest = @"{
                ""version"": ""2.0"",
                ""name"": ""test_asset"",
                ""meshFile"": ""optimized.glb"",
                ""format"": ""glb"",
                ""featureDbFile"": ""features.db"",
                ""keyframeCount"": 10,
                ""featureType"": ""ORB"",
                ""createdAt"": ""2024-01-01T00:00:00Z""
            }";
            File.WriteAllText(Path.Combine(dir, "manifest.json"), manifest);
            File.WriteAllText(Path.Combine(dir, "optimized.glb"), "GLB_DATA");
            File.WriteAllText(Path.Combine(dir, "features.db"), "SQLITE_DB");

            return dir;
        }

        #endregion

        #region Valid Asset Bundle Tests

        [Test]
        public void Load_ValidAssetBundle_ReturnsTrue()
        {
            string assetDir = CreateValidAssetBundle("valid_bundle");

            bool result = _loader.Load(assetDir);

            Assert.IsTrue(result);
            Assert.IsNull(_loader.LastError);
        }

        [Test]
        public void Load_ValidAssetBundle_ParsesManifestCorrectly()
        {
            string assetDir = CreateValidAssetBundle("valid_bundle");

            _loader.Load(assetDir);

            Assert.IsNotNull(_loader.Manifest);
            Assert.AreEqual("2.0", _loader.Manifest.version);
            Assert.AreEqual("test_asset", _loader.Manifest.name);
            Assert.AreEqual("optimized.glb", _loader.Manifest.meshFile);
            Assert.AreEqual("glb", _loader.Manifest.format);
            Assert.AreEqual("features.db", _loader.Manifest.featureDbFile);
            Assert.AreEqual(10, _loader.Manifest.keyframeCount);
            Assert.AreEqual("ORB", _loader.Manifest.featureType);
        }

        [Test]
        public void Load_ValidAssetBundle_SetsFilePaths()
        {
            string assetDir = CreateValidAssetBundle("valid_bundle");

            _loader.Load(assetDir);

            Assert.IsNotNull(_loader.MeshPath);
            Assert.IsNotNull(_loader.FeatureDbPath);
            Assert.IsTrue(File.Exists(_loader.MeshPath));
            Assert.IsTrue(File.Exists(_loader.FeatureDbPath));
        }

        #endregion

        #region Missing/Invalid Path Tests

        [Test]
        public void Load_NullPath_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            bool result = _loader.Load(null);

            Assert.IsFalse(result);
            Assert.IsNotNull(_loader.LastError);
            StringAssert.Contains("null or empty", _loader.LastError);
        }

        [Test]
        public void Load_EmptyPath_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            bool result = _loader.Load("");

            Assert.IsFalse(result);
            Assert.IsNotNull(_loader.LastError);
            StringAssert.Contains("null or empty", _loader.LastError);
        }

        [Test]
        public void Load_NonExistentDirectory_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            bool result = _loader.Load("/nonexistent/path/to/asset");

            Assert.IsFalse(result);
            Assert.IsNotNull(_loader.LastError);
            StringAssert.Contains("does not exist", _loader.LastError);
        }

        #endregion

        #region Missing Manifest Tests

        [Test]
        public void Load_MissingManifest_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = Path.Combine(_testDir, "no_manifest");
            Directory.CreateDirectory(dir);

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
            StringAssert.Contains("manifest.json not found", _loader.LastError);
        }

        #endregion

        #region Corrupt/Invalid Manifest Tests

        [Test]
        public void Load_InvalidJsonManifest_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = Path.Combine(_testDir, "bad_json");
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, "manifest.json"), "NOT VALID JSON {{{");

            bool result = _loader.Load(dir);

            // JsonUtility.FromJson may not throw on invalid JSON but returns empty object
            // The validation of required fields will catch this
            Assert.IsFalse(result);
            Assert.IsNotNull(_loader.LastError);
        }

        [Test]
        public void Load_ManifestMissingVersion_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = Path.Combine(_testDir, "no_version");
            Directory.CreateDirectory(dir);
            string manifest = @"{
                ""name"": ""test"",
                ""meshFile"": ""optimized.glb"",
                ""format"": ""glb"",
                ""featureDbFile"": ""features.db""
            }";
            File.WriteAllText(Path.Combine(dir, "manifest.json"), manifest);

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
            StringAssert.Contains("version", _loader.LastError);
        }

        [Test]
        public void Load_IncompatibleVersion_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = Path.Combine(_testDir, "bad_version");
            Directory.CreateDirectory(dir);
            string manifest = @"{
                ""version"": ""1.0"",
                ""name"": ""test"",
                ""meshFile"": ""mesh.obj"",
                ""format"": ""glb"",
                ""featureDbFile"": ""features.db""
            }";
            File.WriteAllText(Path.Combine(dir, "manifest.json"), manifest);
            File.WriteAllText(Path.Combine(dir, "mesh.obj"), "data");
            File.WriteAllText(Path.Combine(dir, "features.db"), "data");

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
            StringAssert.Contains("Incompatible", _loader.LastError);
        }

        #endregion

        #region Missing Asset File Tests

        [Test]
        public void Load_MissingMeshFile_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = Path.Combine(_testDir, "no_mesh");
            Directory.CreateDirectory(dir);
            string manifest = @"{
                ""version"": ""2.0"",
                ""name"": ""test"",
                ""meshFile"": ""optimized.glb"",
                ""format"": ""glb"",
                ""featureDbFile"": ""features.db""
            }";
            File.WriteAllText(Path.Combine(dir, "manifest.json"), manifest);
            // optimized.glb intentionally missing
            File.WriteAllText(Path.Combine(dir, "features.db"), "data");

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
            StringAssert.Contains("Mesh file not found", _loader.LastError);
        }

        [Test]
        public void Load_MissingFeatureDb_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = Path.Combine(_testDir, "no_features");
            Directory.CreateDirectory(dir);
            string manifest = @"{
                ""version"": ""2.0"",
                ""name"": ""test"",
                ""meshFile"": ""optimized.glb"",
                ""format"": ""glb"",
                ""featureDbFile"": ""features.db""
            }";
            File.WriteAllText(Path.Combine(dir, "manifest.json"), manifest);
            File.WriteAllText(Path.Combine(dir, "optimized.glb"), "data");
            // features.db intentionally missing

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
            StringAssert.Contains("Feature database not found", _loader.LastError);
        }

        #endregion

        #region Missing Manifest Field Tests

        [Test]
        public void Load_ManifestMissingMeshFile_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = Path.Combine(_testDir, "no_mesh_field");
            Directory.CreateDirectory(dir);
            string manifest = @"{
                ""version"": ""2.0"",
                ""name"": ""test"",
                ""format"": ""glb"",
                ""featureDbFile"": ""features.db""
            }";
            File.WriteAllText(Path.Combine(dir, "manifest.json"), manifest);

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
            StringAssert.Contains("meshFile", _loader.LastError);
        }

        [Test]
        public void Load_ManifestMissingFeatureDbFile_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = Path.Combine(_testDir, "no_featuredb_field");
            Directory.CreateDirectory(dir);
            string manifest = @"{
                ""version"": ""2.0"",
                ""name"": ""test"",
                ""meshFile"": ""optimized.glb"",
                ""format"": ""glb""
            }";
            File.WriteAllText(Path.Combine(dir, "manifest.json"), manifest);

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
            StringAssert.Contains("featureDbFile", _loader.LastError);
        }

        #endregion

        #region Reload/State Reset Tests

        [Test]
        public void Load_AfterFailedLoad_ClearsState()
        {
            LogAssert.ignoreFailingMessages = true;
            // First load fails
            _loader.Load("/nonexistent");
            Assert.IsFalse(string.IsNullOrEmpty(_loader.LastError));

            // Second load succeeds
            string assetDir = CreateValidAssetBundle("reload_test");
            bool result = _loader.Load(assetDir);

            Assert.IsTrue(result);
            Assert.IsNull(_loader.LastError);
            Assert.IsNotNull(_loader.Manifest);
        }

        #endregion
    }
}
