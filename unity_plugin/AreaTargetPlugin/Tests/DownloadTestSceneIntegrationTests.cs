using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;
using UnityEngine.UI;
using AreaTargetPlugin;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Integration tests for the DownloadTestScene pipeline.
    /// Tests the complete chain: ZIP extraction → file validation → AssetBundleLoader loading,
    /// and verifies scene lifecycle resource cleanup (Start → download → tracking → OnDestroy).
    ///
    /// Validates: Requirements 4.1, 7.1, 7.2
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class DownloadTestSceneIntegrationTests
    {
        private string _testDir;
        private List<GameObject> _createdObjects;

        [SetUp]
        public void SetUp()
        {
            _testDir = Path.Combine(Path.GetTempPath(), "IntegrationTests_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_testDir);
            _createdObjects = new List<GameObject>();
        }

        [TearDown]
        public void TearDown()
        {
            for (int i = _createdObjects.Count - 1; i >= 0; i--)
            {
                if (_createdObjects[i] != null)
                    UnityEngine.Object.DestroyImmediate(_createdObjects[i]);
            }
            _createdObjects.Clear();

            if (Directory.Exists(_testDir))
            {
                try { Directory.Delete(_testDir, true); }
                catch { /* ignore cleanup errors in tests */ }
            }
        }

        private GameObject CreateTracked(string name)
        {
            var go = new GameObject(name);
            _createdObjects.Add(go);
            return go;
        }

        private static void SetPrivateField(object target, string fieldName, object value)
        {
            var type = target.GetType();
            FieldInfo field = null;
            while (type != null && field == null)
            {
                field = type.GetField(fieldName, BindingFlags.NonPublic | BindingFlags.Instance);
                type = type.BaseType;
            }
            if (field == null)
                throw new InvalidOperationException($"Field '{fieldName}' not found on {target.GetType().Name}");
            field.SetValue(target, value);
        }

        private static T GetPrivateField<T>(object target, string fieldName)
        {
            var type = target.GetType();
            FieldInfo field = null;
            while (type != null && field == null)
            {
                field = type.GetField(fieldName, BindingFlags.NonPublic | BindingFlags.Instance);
                type = type.BaseType;
            }
            if (field == null)
                throw new InvalidOperationException($"Field '{fieldName}' not found on {target.GetType().Name}");
            return (T)field.GetValue(target);
        }

        /// <summary>
        /// Creates a valid test ZIP file containing manifest.json, optimized.glb, and features.db.
        /// The manifest.json has valid v2.0 content; glb and db files are minimal placeholders.
        /// </summary>
        private string CreateTestZip(string zipName = "test_bundle.zip")
        {
            string sourceDir = Path.Combine(_testDir, "zip_source_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(sourceDir);

            string manifest = @"{
                ""version"": ""2.0"",
                ""name"": ""integration_test_asset"",
                ""meshFile"": ""optimized.glb"",
                ""format"": ""glb"",
                ""featureDbFile"": ""features.db"",
                ""keyframeCount"": 25,
                ""featureType"": ""ORB"",
                ""createdAt"": ""2025-01-15T12:00:00Z""
            }";
            File.WriteAllText(Path.Combine(sourceDir, "manifest.json"), manifest);
            File.WriteAllBytes(Path.Combine(sourceDir, "optimized.glb"), new byte[] { 0x67, 0x6C, 0x54, 0x46 });
            File.WriteAllBytes(Path.Combine(sourceDir, "features.db"), new byte[] { 0x53, 0x51, 0x4C });

            string zipPath = Path.Combine(_testDir, zipName);
            ZipFile.CreateFromDirectory(sourceDir, zipPath);
            return zipPath;
        }

        /// <summary>
        /// Creates a test ZIP missing one or more required files.
        /// </summary>
        private string CreateIncompleteTestZip(bool includeGlb, bool includeDb, bool includeManifest)
        {
            string sourceDir = Path.Combine(_testDir, "incomplete_source_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(sourceDir);

            if (includeManifest)
            {
                string manifest = @"{
                    ""version"": ""2.0"",
                    ""name"": ""incomplete_asset"",
                    ""meshFile"": ""optimized.glb"",
                    ""format"": ""glb"",
                    ""featureDbFile"": ""features.db"",
                    ""keyframeCount"": 5,
                    ""featureType"": ""ORB"",
                    ""createdAt"": ""2025-01-15T12:00:00Z""
                }";
                File.WriteAllText(Path.Combine(sourceDir, "manifest.json"), manifest);
            }
            if (includeGlb)
                File.WriteAllBytes(Path.Combine(sourceDir, "optimized.glb"), new byte[] { 0x00 });
            if (includeDb)
                File.WriteAllBytes(Path.Combine(sourceDir, "features.db"), new byte[] { 0x00 });

            string zipPath = Path.Combine(_testDir, "incomplete_bundle.zip");
            if (File.Exists(zipPath)) File.Delete(zipPath);
            ZipFile.CreateFromDirectory(sourceDir, zipPath);
            return zipPath;
        }

        private DownloadTestSceneManager CreateWiredManager()
        {
            var managerGo = CreateTracked("DownloadTestSceneManager");
            var manager = managerGo.AddComponent<DownloadTestSceneManager>();

            var downloadBtnGo = CreateTracked("DownloadButton");
            var downloadButton = downloadBtnGo.AddComponent<Button>();

            var resetBtnGo = CreateTracked("ResetButton");
            var resetButton = resetBtnGo.AddComponent<Button>();

            var inputGo = CreateTracked("UrlInputField");
            var urlInputField = inputGo.AddComponent<InputField>();
            var inputTextGo = CreateTracked("InputText");
            inputTextGo.transform.SetParent(inputGo.transform);
            urlInputField.textComponent = inputTextGo.AddComponent<Text>();

            var panelGo = CreateTracked("DebugPanel");
            var debugPanel = panelGo.AddComponent<DebugPanel>();

            var statusText = CreateTracked("StatusText").AddComponent<Text>();
            var progressText = CreateTracked("ProgressText").AddComponent<Text>();
            var trackingInfoText = CreateTracked("TrackingInfoText").AddComponent<Text>();
            var fpsText = CreateTracked("FpsText").AddComponent<Text>();
            var assetInfoText = CreateTracked("AssetInfoText").AddComponent<Text>();

            SetPrivateField(debugPanel, "statusText", statusText);
            SetPrivateField(debugPanel, "progressText", progressText);
            SetPrivateField(debugPanel, "trackingInfoText", trackingInfoText);
            SetPrivateField(debugPanel, "fpsText", fpsText);
            SetPrivateField(debugPanel, "assetInfoText", assetInfoText);

            var originGo = CreateTracked("AreaTargetOrigin");

            SetPrivateField(manager, "urlInputField", urlInputField);
            SetPrivateField(manager, "downloadButton", downloadButton);
            SetPrivateField(manager, "resetButton", resetButton);
            SetPrivateField(manager, "debugPanel", debugPanel);
            SetPrivateField(manager, "areaTargetOrigin", originGo.transform);

            return manager;
        }

        private void SetCurrentState(DownloadTestSceneManager manager, SceneState state)
        {
            var backingField = typeof(DownloadTestSceneManager).GetField("<CurrentState>k__BackingField",
                BindingFlags.NonPublic | BindingFlags.Instance);
            if (backingField != null)
            {
                backingField.SetValue(manager, state);
                return;
            }
            var prop = typeof(DownloadTestSceneManager).GetProperty("CurrentState");
            if (prop != null && prop.CanWrite)
            {
                prop.SetValue(manager, state);
                return;
            }
            throw new InvalidOperationException("Cannot set CurrentState via reflection");
        }

        private void InvokeOnDestroy(DownloadTestSceneManager manager)
        {
            var method = typeof(DownloadTestSceneManager).GetMethod("OnDestroy",
                BindingFlags.NonPublic | BindingFlags.Instance);
            method.Invoke(manager, null);
        }

        private void InvokeHandleTrackingResult(DownloadTestSceneManager manager, TrackingResult result)
        {
            var method = typeof(DownloadTestSceneManager).GetMethod("HandleTrackingResult",
                BindingFlags.NonPublic | BindingFlags.Instance);
            method.Invoke(manager, new object[] { result });
        }

        private static bool IsTrackerDisposed(AreaTargetTracker tracker)
        {
            var field = typeof(AreaTargetTracker).GetField("_disposed",
                BindingFlags.NonPublic | BindingFlags.Instance);
            return (bool)field.GetValue(tracker);
        }

        #region Extract → Validate → Load Chain (Requirement 4.1)

        /// <summary>
        /// Integration: Valid ZIP → ZipExtractor.Extract → ValidateRequiredFiles → AssetBundleLoader.Load
        /// Verifies the complete chain from extraction to asset loading succeeds with valid data.
        /// </summary>
        [Test]
        public void ExtractValidateLoad_ValidZip_CompletePipelineSucceeds()
        {
            string zipPath = CreateTestZip();
            string extractDir = Path.Combine(_testDir, "extracted");

            var extractor = new ZipExtractor();
            var loader = new AssetBundleLoader();

            // Step 1: Extract
            bool extractResult = extractor.Extract(zipPath, extractDir);
            Assert.IsTrue(extractResult, $"Extract should succeed, error: {extractor.LastError}");

            // Step 2: Validate required files
            var (isValid, missingFiles) = extractor.ValidateRequiredFiles(extractDir);
            Assert.IsTrue(isValid, $"Validation should pass, missing: {string.Join(", ", missingFiles)}");
            Assert.IsEmpty(missingFiles, "No files should be missing");

            // Step 3: Load via AssetBundleLoader
            bool loadResult = loader.Load(extractDir);
            Assert.IsTrue(loadResult, $"Load should succeed, error: {loader.LastError}");

            // Verify manifest was parsed correctly
            Assert.IsNotNull(loader.Manifest);
            Assert.AreEqual("integration_test_asset", loader.Manifest.name);
            Assert.AreEqual("2.0", loader.Manifest.version);
            Assert.AreEqual(25, loader.Manifest.keyframeCount);
            Assert.AreEqual("glb", loader.Manifest.format);
            Assert.AreEqual("optimized.glb", loader.Manifest.meshFile);
            Assert.AreEqual("features.db", loader.Manifest.featureDbFile);

            // Verify file paths are set
            Assert.IsNotNull(loader.MeshPath);
            Assert.IsNotNull(loader.FeatureDbPath);
            Assert.IsTrue(File.Exists(loader.MeshPath), "Mesh file should exist at resolved path");
            Assert.IsTrue(File.Exists(loader.FeatureDbPath), "Feature DB should exist at resolved path");
        }

        /// <summary>
        /// Integration: Incomplete ZIP → Extract → Validate fails with correct missing files.
        /// Verifies the pipeline correctly rejects incomplete asset bundles.
        /// </summary>
        [Test]
        public void ExtractValidateLoad_IncompleteZip_ValidationFailsWithMissingFiles()
        {
            // ZIP with only manifest.json (missing glb and db)
            string zipPath = CreateIncompleteTestZip(includeGlb: false, includeDb: false, includeManifest: true);
            string extractDir = Path.Combine(_testDir, "extracted_incomplete");

            var extractor = new ZipExtractor();

            bool extractResult = extractor.Extract(zipPath, extractDir);
            Assert.IsTrue(extractResult, "Extract should succeed even for incomplete bundles");

            var (isValid, missingFiles) = extractor.ValidateRequiredFiles(extractDir);
            Assert.IsFalse(isValid, "Validation should fail for incomplete bundle");
            Assert.Contains("optimized.glb", missingFiles);
            Assert.Contains("features.db", missingFiles);
        }

        /// <summary>
        /// Integration: Valid extract + validate but AssetBundleLoader rejects bad manifest content.
        /// Verifies the loader catches format issues even when files are present.
        /// </summary>
        [Test]
        public void ExtractValidateLoad_BadManifestFormat_LoaderRejects()
        {
            // Create a ZIP with all files present but manifest has wrong format field
            string sourceDir = Path.Combine(_testDir, "bad_format_source");
            Directory.CreateDirectory(sourceDir);

            string manifest = @"{
                ""version"": ""2.0"",
                ""name"": ""bad_format_asset"",
                ""meshFile"": ""optimized.glb"",
                ""format"": ""obj"",
                ""featureDbFile"": ""features.db"",
                ""keyframeCount"": 10,
                ""featureType"": ""ORB""
            }";
            File.WriteAllText(Path.Combine(sourceDir, "manifest.json"), manifest);
            File.WriteAllBytes(Path.Combine(sourceDir, "optimized.glb"), new byte[] { 0x00 });
            File.WriteAllBytes(Path.Combine(sourceDir, "features.db"), new byte[] { 0x00 });

            string zipPath = Path.Combine(_testDir, "bad_format.zip");
            ZipFile.CreateFromDirectory(sourceDir, zipPath);
            string extractDir = Path.Combine(_testDir, "extracted_bad_format");

            var extractor = new ZipExtractor();
            var loader = new AssetBundleLoader();

            bool extractResult = extractor.Extract(zipPath, extractDir);
            Assert.IsTrue(extractResult);

            var (isValid, _) = extractor.ValidateRequiredFiles(extractDir);
            Assert.IsTrue(isValid, "All files present, validation should pass");

            LogAssert.Expect(LogType.Error,
                "[AreaTargetPlugin] Unsupported asset format: 'obj' (expected: 'glb').");
            bool loadResult = loader.Load(extractDir);
            Assert.IsFalse(loadResult, "Loader should reject unsupported format");
            Assert.IsNotNull(loader.LastError);
            StringAssert.Contains("format", loader.LastError.ToLower());
        }

        /// <summary>
        /// Integration: Extract overwrites existing directory, then validate + load succeeds.
        /// Verifies that re-extraction cleans up stale files.
        /// </summary>
        [Test]
        public void ExtractValidateLoad_ReExtraction_CleansOldFilesAndSucceeds()
        {
            string extractDir = Path.Combine(_testDir, "extracted_reuse");

            // First extraction: incomplete bundle
            string incompleteZip = CreateIncompleteTestZip(includeGlb: true, includeDb: false, includeManifest: true);
            var extractor = new ZipExtractor();
            extractor.Extract(incompleteZip, extractDir);

            // Verify incomplete
            var (isValid1, _) = extractor.ValidateRequiredFiles(extractDir);
            Assert.IsFalse(isValid1, "First extraction should be incomplete");

            // Second extraction: valid bundle overwrites
            string validZip = CreateTestZip("valid_reextract.zip");
            bool extractResult = extractor.Extract(validZip, extractDir);
            Assert.IsTrue(extractResult);

            var (isValid2, missingFiles) = extractor.ValidateRequiredFiles(extractDir);
            Assert.IsTrue(isValid2, $"Re-extraction should produce valid bundle, missing: {string.Join(", ", missingFiles)}");

            var loader = new AssetBundleLoader();
            bool loadResult = loader.Load(extractDir);
            Assert.IsTrue(loadResult, $"Load should succeed after re-extraction, error: {loader.LastError}");
        }

        #endregion

        #region Scene Lifecycle Resource Cleanup (Requirements 7.1, 7.2)

        /// <summary>
        /// Lifecycle: Simulates Start → Tracking → OnDestroy.
        /// Verifies that tracker is disposed and download manager is cleaned up on destroy.
        /// </summary>
        [Test]
        public void Lifecycle_TrackingThenDestroy_TrackerDisposed()
        {
            var manager = CreateWiredManager();

            // Simulate Start() having run by injecting a DownloadManager
            var dm = new DownloadManager(manager);
            SetPrivateField(manager, "_downloadManager", dm);

            // Simulate reaching Tracking state with an active tracker
            var tracker = new AreaTargetTracker();
            SetPrivateField(manager, "_tracker", tracker);
            SetCurrentState(manager, SceneState.Tracking);

            // Simulate OnDestroy
            InvokeOnDestroy(manager);

            Assert.IsTrue(IsTrackerDisposed(tracker),
                "Tracker should be disposed after OnDestroy");
            Assert.IsNull(GetPrivateField<AreaTargetTracker>(manager, "_tracker"),
                "Tracker reference should be null after OnDestroy");
            Assert.IsNull(GetPrivateField<DownloadManager>(manager, "_downloadManager"),
                "DownloadManager should be null after OnDestroy");
        }

        /// <summary>
        /// Lifecycle: Simulates Start → Tracking → OnDestroy with temp files.
        /// Verifies that temporary download directory is cleaned up on destroy.
        /// </summary>
        [Test]
        public void Lifecycle_TrackingThenDestroy_TempFilesCleanedUp()
        {
            var manager = CreateWiredManager();

            var dm = new DownloadManager(manager);
            SetPrivateField(manager, "_downloadManager", dm);

            // Create a temp download directory to simulate downloaded files
            string tempDownloadDir = Path.Combine(_testDir, "temp_download");
            Directory.CreateDirectory(tempDownloadDir);
            File.WriteAllText(Path.Combine(tempDownloadDir, "test.zip"), "fake");
            SetPrivateField(manager, "_currentDownloadDir", tempDownloadDir);

            SetCurrentState(manager, SceneState.Tracking);

            InvokeOnDestroy(manager);

            Assert.IsFalse(Directory.Exists(tempDownloadDir),
                "Temporary download directory should be deleted after OnDestroy");
        }

        /// <summary>
        /// Lifecycle: Simulates Start → Tracking (with OriginCube) → Reset → verify cleanup.
        /// Verifies that reset properly cleans up all resources and returns to Idle.
        /// </summary>
        [Test]
        public void Lifecycle_TrackingThenReset_AllResourcesCleanedUp()
        {
            var manager = CreateWiredManager();

            var dm = new DownloadManager(manager);
            SetPrivateField(manager, "_downloadManager", dm);

            var tracker = new AreaTargetTracker();
            SetPrivateField(manager, "_tracker", tracker);
            SetCurrentState(manager, SceneState.Tracking);

            // Create OriginCube via HandleTrackingResult
            var trackingResult = new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = 0.9f,
                MatchedFeatures = 100
            };
            InvokeHandleTrackingResult(manager, trackingResult);

            var originCube = GetPrivateField<GameObject>(manager, "_originCube");
            Assert.IsNotNull(originCube, "OriginCube should exist before reset");
            if (!_createdObjects.Contains(originCube))
                _createdObjects.Add(originCube);

            // Create temp download dir
            string tempDir = Path.Combine(_testDir, "reset_temp");
            Directory.CreateDirectory(tempDir);
            SetPrivateField(manager, "_currentDownloadDir", tempDir);

            // Reset
            manager.OnResetClicked();

            Assert.AreEqual(SceneState.Idle, manager.CurrentState, "State should be Idle after reset");
            Assert.IsTrue(IsTrackerDisposed(tracker), "Tracker should be disposed after reset");
            Assert.IsNull(GetPrivateField<AreaTargetTracker>(manager, "_tracker"),
                "Tracker reference should be null after reset");
            Assert.IsNull(GetPrivateField<GameObject>(manager, "_originCube"),
                "OriginCube reference should be null after reset");
            Assert.IsFalse(Directory.Exists(tempDir),
                "Temp directory should be cleaned up after reset");
        }

        /// <summary>
        /// Lifecycle: Simulates multiple download cycles (Tracking → re-download → Tracking → OnDestroy).
        /// Verifies that old trackers are disposed before new ones are created,
        /// and final OnDestroy cleans up the last tracker.
        /// </summary>
        [Test]
        public void Lifecycle_MultipleDownloadCycles_OldTrackersDisposed()
        {
            var manager = CreateWiredManager();

            var dm = new DownloadManager(manager);
            SetPrivateField(manager, "_downloadManager", dm);

            var trackers = new List<AreaTargetTracker>();

            // Simulate 3 download cycles
            for (int i = 0; i < 3; i++)
            {
                var tracker = new AreaTargetTracker();
                trackers.Add(tracker);
                SetPrivateField(manager, "_tracker", tracker);
                SetCurrentState(manager, SceneState.Tracking);

                // Trigger re-download (which should dispose old tracker)
                var urlField = GetPrivateField<InputField>(manager, "urlInputField");
                urlField.text = "https://example.com/test.zip";
                manager.OnDownloadClicked();

                Assert.IsTrue(IsTrackerDisposed(tracker),
                    $"Tracker {i} should be disposed after re-download");
            }

            // All old trackers should be disposed
            for (int i = 0; i < trackers.Count; i++)
            {
                Assert.IsTrue(IsTrackerDisposed(trackers[i]),
                    $"Tracker {i} should remain disposed");
            }

            // Clean up download dir created by OnDownloadClicked
            var downloadDir = GetPrivateField<string>(manager, "_currentDownloadDir");
            if (!string.IsNullOrEmpty(downloadDir) && Directory.Exists(downloadDir))
            {
                try { Directory.Delete(downloadDir, true); }
                catch { /* ignore */ }
            }
        }

        /// <summary>
        /// Lifecycle: OnDestroy with no tracker or download manager should not throw.
        /// Verifies graceful cleanup when scene is destroyed in Idle state.
        /// </summary>
        [Test]
        public void Lifecycle_DestroyInIdleState_NoExceptions()
        {
            var manager = CreateWiredManager();

            // Manager is in Idle state with no tracker, no download manager initialized via Start()
            // Inject a DownloadManager so OnDestroy has something to clean
            var dm = new DownloadManager(manager);
            SetPrivateField(manager, "_downloadManager", dm);

            Assert.DoesNotThrow(() => InvokeOnDestroy(manager),
                "OnDestroy should not throw when no tracker exists");
        }

        #endregion
    }
}
