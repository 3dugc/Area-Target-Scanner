using System;
using System.IO;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// ARTestSceneManager 资产路径相关单元测试。
    /// 验证默认路径、路径解析逻辑、资产目录预检查。
    /// Validates: Requirements 2.1, 2.2, 2.4
    /// </summary>
    [TestFixture]
    public class ARTestSceneAssetPathTests
    {
        private string _tempDir;

        [SetUp]
        public void SetUp()
        {
            _tempDir = Path.Combine(Path.GetTempPath(), "AssetPathTests_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_tempDir);
        }

        [TearDown]
        public void TearDown()
        {
            if (Directory.Exists(_tempDir))
                Directory.Delete(_tempDir, true);
        }

        #region Default Value Tests (Requirement 2.1)

        [Test]
        public void AssetBundlePath_DefaultValue_IsSLAMTestAssets()
        {
            // 通过反射读取新实例的 assetBundlePath 私有字段默认值
            var go = new GameObject("TestARManager");
            try
            {
                var manager = go.AddComponent<ARTestSceneManager>();
                var field = typeof(ARTestSceneManager).GetField("assetBundlePath",
                    BindingFlags.NonPublic | BindingFlags.Instance);
                Assert.IsNotNull(field, "assetBundlePath field should exist");

                string defaultValue = (string)field.GetValue(manager);
                Assert.AreEqual("SLAMTestAssets", defaultValue,
                    "assetBundlePath default should be 'SLAMTestAssets'");
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(go);
            }
        }

        #endregion

        #region ResolveAssetPath Tests (Requirements 2.2, 2.4)

        [Test]
        public void ResolveAssetPath_AbsolutePath_ReturnsUnchanged()
        {
            string absolutePath = "/absolute/path/to/assets";
            string result = ARTestSceneManager.ResolveAssetPath(absolutePath, "/some/streaming");

            Assert.AreEqual(absolutePath, result,
                "Absolute path should be returned unchanged");
        }

        [Test]
        public void ResolveAssetPath_RelativePath_CombinesWithStreamingAssets()
        {
            string relativePath = "SLAMTestAssets";
            string streamingAssets = "/app/StreamingAssets";
            string expected = Path.Combine(streamingAssets, relativePath);

            string result = ARTestSceneManager.ResolveAssetPath(relativePath, streamingAssets);

            Assert.AreEqual(expected, result,
                "Relative path should be combined with streamingAssetsPath");
        }

        #endregion

        #region ValidateAssetDirectory Tests (Requirements 2.2, 2.3, 2.4)

        [Test]
        public void ValidateAssetDirectory_NonExistentDirectory_ReturnsError()
        {
            string nonExistent = Path.Combine(_tempDir, "does_not_exist");

            string error = ARTestSceneManager.ValidateAssetDirectory(nonExistent, "TestAssets");

            Assert.IsNotNull(error, "Should return error for non-existent directory");
            Assert.That(error, Does.Contain("TestAssets"),
                "Error should mention the asset bundle path");
        }

        [Test]
        public void ValidateAssetDirectory_MissingFeaturesDb_ReturnsErrorMentioningFeaturesDb()
        {
            // 目录存在但缺少 features.db
            string error = ARTestSceneManager.ValidateAssetDirectory(_tempDir, "TestAssets");

            Assert.IsNotNull(error, "Should return error when features.db is missing");
            Assert.That(error, Does.Contain("features.db"),
                "Error should mention 'features.db'");
        }

        [Test]
        public void ValidateAssetDirectory_MissingManifestJson_ReturnsErrorMentioningManifestJson()
        {
            // features.db 存在但缺少 manifest.json
            File.WriteAllText(Path.Combine(_tempDir, "features.db"), "DB");

            string error = ARTestSceneManager.ValidateAssetDirectory(_tempDir, "TestAssets");

            Assert.IsNotNull(error, "Should return error when manifest.json is missing");
            Assert.That(error, Does.Contain("manifest.json"),
                "Error should mention 'manifest.json'");
        }

        [Test]
        public void ValidateAssetDirectory_AllFilesPresent_ReturnsNull()
        {
            File.WriteAllText(Path.Combine(_tempDir, "features.db"), "DB");
            File.WriteAllText(Path.Combine(_tempDir, "manifest.json"), "{}");

            string error = ARTestSceneManager.ValidateAssetDirectory(_tempDir, "TestAssets");

            Assert.IsNull(error, "Should return null when all required files are present");
        }

        #endregion
    }
}
