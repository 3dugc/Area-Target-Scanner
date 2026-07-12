using System;
using System.IO;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for AssetBundleLoader v2.0 manifest format validation.
    /// Feature: pointcloud-localization, Property 4: v2.0 Manifest 格式验证
    /// **Validates: Requirements 4.2, 4.9**
    /// </summary>
    [TestFixture]
    public class AssetBundleLoaderPropertyTests
    {
        private string _testDir;
        private AssetBundleLoader _loader;

        [SetUp]
        public void SetUp()
        {
            _testDir = Path.Combine(Path.GetTempPath(), "ABLPropTests_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_testDir);
            _loader = new AssetBundleLoader();
        }

        [TearDown]
        public void TearDown()
        {
            if (Directory.Exists(_testDir))
                Directory.Delete(_testDir, true);
        }

        /// <summary>
        /// Creates a bundle directory with the given manifest fields and optionally creates referenced files.
        /// </summary>
        private string CreateBundleDir(string version, string format,
            string meshFile = "optimized.glb", string featureDbFile = "features.db",
            bool createFiles = true)
        {
            string dir = Path.Combine(_testDir, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);

            string manifest = $@"{{
                ""version"": ""{version}"",
                ""name"": ""test"",
                ""meshFile"": ""{meshFile}"",
                ""format"": ""{format}"",
                ""featureDbFile"": ""{featureDbFile}"",
                ""keyframeCount"": 10,
                ""featureType"": ""ORB""
            }}";
            File.WriteAllText(Path.Combine(dir, "manifest.json"), manifest);

            if (createFiles)
            {
                File.WriteAllText(Path.Combine(dir, meshFile), "GLB_DATA");
                File.WriteAllText(Path.Combine(dir, featureDbFile), "SQLITE_DB");
            }

            return dir;
        }

        /// <summary>
        /// Property 4a: For any version string that does NOT start with "2.0",
        /// AssetBundleLoader.Load() should return false.
        /// **Validates: Requirements 4.9**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property InvalidVersion_LoadFails(NonEmptyString versionSuffix)
        {
            string version = versionSuffix.Get;
            // Ensure version does not start with "2.0"
            if (version.StartsWith("2.0"))
                version = "1." + version;

            string dir = CreateBundleDir(version, "glb");
            bool result = _loader.Load(dir);

            return (!result).ToProperty()
                .Label($"Version '{version}' should cause Load to fail");
        }

        /// <summary>
        /// Property 4b: For any format string that is NOT "glb",
        /// AssetBundleLoader.Load() should return false.
        /// **Validates: Requirements 4.2**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property InvalidFormat_LoadFails(NonEmptyString formatStr)
        {
            string format = formatStr.Get;
            // Ensure format is not "glb"
            if (format == "glb")
                format = "obj";

            string dir = CreateBundleDir("2.0", format);
            bool result = _loader.Load(dir);

            return (!result).ToProperty()
                .Label($"Format '{format}' should cause Load to fail");
        }

        /// <summary>
        /// Property 4c: When version is "2.0", format is "glb", and all referenced files exist,
        /// AssetBundleLoader.Load() should return true with correct manifest fields.
        /// **Validates: Requirements 4.2, 4.9**
        /// </summary>
        [Test]
        public void ValidV2Bundle_LoadSucceeds()
        {
            string dir = CreateBundleDir("2.0", "glb");
            bool result = _loader.Load(dir);

            Assert.IsTrue(result, $"Load should succeed for valid v2.0 bundle. LastError: {_loader.LastError}");
            Assert.IsNull(_loader.LastError);
            Assert.IsNotNull(_loader.Manifest);
            Assert.AreEqual("2.0", _loader.Manifest.version);
            Assert.AreEqual("glb", _loader.Manifest.format);
            Assert.IsNotNull(_loader.MeshPath);
            Assert.IsNotNull(_loader.FeatureDbPath);
        }
    }
}
