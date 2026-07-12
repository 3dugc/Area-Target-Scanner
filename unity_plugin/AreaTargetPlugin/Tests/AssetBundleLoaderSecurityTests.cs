using System;
using System.IO;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Security-focused tests for AssetBundleLoader.
    /// Covers path traversal detection, malformed manifests, and edge cases
    /// not covered by existing AssetBundleLoaderTests / PropertyTests.
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class AssetBundleLoaderSecurityTests
    {
        private string _testDir;
        private AssetBundleLoader _loader;

        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
            _testDir = Path.Combine(Path.GetTempPath(), "ABLSecTests_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_testDir);
            _loader = new AssetBundleLoader();
        }

        [TearDown]
        public void TearDown()
        {
            if (Directory.Exists(_testDir))
                Directory.Delete(_testDir, true);
        }

        private string CreateManifest(string meshFile, string featureDbFile,
            string version = "2.0", string format = "glb")
        {
            string dir = Path.Combine(_testDir, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);

            string manifest = $@"{{
                ""version"": ""{version}"",
                ""name"": ""test"",
                ""meshFile"": ""{meshFile}"",
                ""format"": ""{format}"",
                ""featureDbFile"": ""{featureDbFile}"",
                ""keyframeCount"": 5,
                ""featureType"": ""ORB""
            }}";
            File.WriteAllText(Path.Combine(dir, "manifest.json"), manifest);
            return dir;
        }

        #region Path Traversal Detection

        [Test]
        public void Load_MeshFilePathTraversal_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = CreateManifest("../../../etc/passwd", "features.db");
            // Create the feature db file so it doesn't fail on that check first
            File.WriteAllText(Path.Combine(dir, "features.db"), "DB");

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
            Assert.IsTrue(_loader.LastError.Contains("Path traversal"));
        }

        [Test]
        public void Load_FeatureDbPathTraversal_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = CreateManifest("optimized.glb", "../../secret.db");
            File.WriteAllText(Path.Combine(dir, "optimized.glb"), "GLB");

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
            Assert.IsTrue(_loader.LastError.Contains("Path traversal"));
        }

        [Test]
        public void Load_DotDotSlashInMeshFile_Blocked()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = CreateManifest("subdir/../../../outside.glb", "features.db");
            File.WriteAllText(Path.Combine(dir, "features.db"), "DB");

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
        }

        [Test]
        public void Load_AbsolutePathInMeshFile_Blocked()
        {
            LogAssert.ignoreFailingMessages = true;
            // Absolute path should resolve outside the asset directory
            string dir = CreateManifest("/tmp/evil.glb", "features.db");
            File.WriteAllText(Path.Combine(dir, "features.db"), "DB");

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
        }

        #endregion

        #region Manifest Field Validation

        [Test]
        public void Load_EmptyMeshFile_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = CreateManifest("", "features.db");

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
            Assert.IsTrue(_loader.LastError.Contains("meshFile"));
        }

        [Test]
        public void Load_EmptyFeatureDbFile_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = CreateManifest("optimized.glb", "");

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
            Assert.IsTrue(_loader.LastError.Contains("featureDbFile"));
        }

        [Test]
        public void Load_WrongFormat_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = CreateManifest("model.obj", "features.db", format: "obj");
            File.WriteAllText(Path.Combine(dir, "model.obj"), "OBJ");
            File.WriteAllText(Path.Combine(dir, "features.db"), "DB");

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
            Assert.IsTrue(_loader.LastError.Contains("Unsupported asset format"));
        }

        [Test]
        public void Load_MissingVersion_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = Path.Combine(_testDir, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            string manifest = @"{
                ""name"": ""test"",
                ""meshFile"": ""optimized.glb"",
                ""format"": ""glb"",
                ""featureDbFile"": ""features.db""
            }";
            File.WriteAllText(Path.Combine(dir, "manifest.json"), manifest);
            File.WriteAllText(Path.Combine(dir, "optimized.glb"), "GLB");
            File.WriteAllText(Path.Combine(dir, "features.db"), "DB");

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
        }

        [Test]
        public void Load_MeshFileNotFound_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = CreateManifest("optimized.glb", "features.db");
            // Only create features.db, not the mesh file
            File.WriteAllText(Path.Combine(dir, "features.db"), "DB");

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
            Assert.IsTrue(_loader.LastError.Contains("Mesh file not found"));
        }

        [Test]
        public void Load_FeatureDbNotFound_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            string dir = CreateManifest("optimized.glb", "features.db");
            // Only create mesh file, not features.db
            File.WriteAllText(Path.Combine(dir, "optimized.glb"), "GLB");

            bool result = _loader.Load(dir);

            Assert.IsFalse(result);
            Assert.IsTrue(_loader.LastError.Contains("Feature database not found"));
        }

        #endregion

        #region Valid Load Verification

        [Test]
        public void Load_ValidBundle_SetsAllProperties()
        {
            string dir = CreateManifest("optimized.glb", "features.db");
            File.WriteAllText(Path.Combine(dir, "optimized.glb"), "GLB_DATA");
            File.WriteAllText(Path.Combine(dir, "features.db"), "SQLITE_DB");

            bool result = _loader.Load(dir);

            Assert.IsTrue(result);
            Assert.IsNull(_loader.LastError);
            Assert.IsNotNull(_loader.Manifest);
            Assert.AreEqual("2.0", _loader.Manifest.version);
            Assert.AreEqual("glb", _loader.Manifest.format);
            Assert.IsTrue(_loader.MeshPath.EndsWith("optimized.glb"));
            Assert.IsTrue(_loader.FeatureDbPath.EndsWith("features.db"));
        }

        [Test]
        public void Load_SubdirectoryMeshFile_Works()
        {
            string dir = Path.Combine(_testDir, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            Directory.CreateDirectory(Path.Combine(dir, "models"));

            string manifest = @"{
                ""version"": ""2.0"",
                ""name"": ""test"",
                ""meshFile"": ""models/optimized.glb"",
                ""format"": ""glb"",
                ""featureDbFile"": ""features.db"",
                ""keyframeCount"": 5,
                ""featureType"": ""ORB""
            }";
            File.WriteAllText(Path.Combine(dir, "manifest.json"), manifest);
            File.WriteAllText(Path.Combine(dir, "models", "optimized.glb"), "GLB");
            File.WriteAllText(Path.Combine(dir, "features.db"), "DB");

            bool result = _loader.Load(dir);

            Assert.IsTrue(result);
        }

        [Test]
        public void Load_ResetsPreviousState()
        {
            LogAssert.ignoreFailingMessages = true;
            // First load fails
            _loader.Load("/nonexistent");
            Assert.IsNotNull(_loader.LastError);

            // Second load succeeds
            string dir = CreateManifest("optimized.glb", "features.db");
            File.WriteAllText(Path.Combine(dir, "optimized.glb"), "GLB");
            File.WriteAllText(Path.Combine(dir, "features.db"), "DB");

            bool result = _loader.Load(dir);

            Assert.IsTrue(result);
            Assert.IsNull(_loader.LastError);
        }

        #endregion
    }
}
