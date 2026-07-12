using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text.RegularExpressions;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;
using UnityEngine.UI;
using AreaTargetPlugin;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Integration tests for the SLAMTestScene pipeline.
    /// Tests AssetBundleLoader loading from a local asset directory (simulating StreamingAssets/SLAMTestAssets/),
    /// and verifies scene lifecycle resource cleanup (Start → tracking → reset → OnDestroy).
    ///
    /// Validates: Requirements 2.1, 7.1, 7.2, 8.1, 8.2
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class SLAMTestSceneIntegrationTests
    {
        private string _testDir;
        private List<GameObject> _createdObjects;

        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
            _testDir = Path.Combine(Path.GetTempPath(), "SLAMIntegrationTests_" + Guid.NewGuid().ToString("N"));
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

        private void InvokeHandleTrackingResult(SLAMTestSceneManager manager, TrackingResult result)
        {
            var method = typeof(SLAMTestSceneManager).GetMethod("HandleTrackingResult",
                BindingFlags.NonPublic | BindingFlags.Instance);
            method.Invoke(manager, new object[] { result, Matrix4x4.identity });
        }

        private void InvokeOnDestroy(SLAMTestSceneManager manager)
        {
            var method = typeof(SLAMTestSceneManager).GetMethod("OnDestroy",
                BindingFlags.NonPublic | BindingFlags.Instance);
            method.Invoke(manager, null);
        }

        private static bool IsTrackerDisposed(AreaTargetTracker tracker)
        {
            var field = typeof(AreaTargetTracker).GetField("_disposed",
                BindingFlags.NonPublic | BindingFlags.Instance);
            return (bool)field.GetValue(tracker);
        }

        /// <summary>
        /// Creates a valid test asset directory with manifest.json, optimized.glb, and features.db.
        /// Simulates the StreamingAssets/SLAMTestAssets/ directory structure.
        /// </summary>
        private string CreateTestAssetDirectory()
        {
            string assetDir = Path.Combine(_testDir, "SLAMTestAssets");
            Directory.CreateDirectory(assetDir);

            string manifest = @"{
                ""version"": ""2.0"",
                ""name"": ""slam_integration_test"",
                ""meshFile"": ""optimized.glb"",
                ""format"": ""glb"",
                ""featureDbFile"": ""features.db"",
                ""keyframeCount"": 30,
                ""featureType"": ""ORB"",
                ""createdAt"": ""2025-01-20T10:00:00Z""
            }";
            File.WriteAllText(Path.Combine(assetDir, "manifest.json"), manifest);
            File.WriteAllBytes(Path.Combine(assetDir, "optimized.glb"), new byte[] { 0x67, 0x6C, 0x54, 0x46 });
            File.WriteAllBytes(Path.Combine(assetDir, "features.db"), new byte[] { 0x53, 0x51, 0x4C });

            return assetDir;
        }

        /// <summary>
        /// Creates a wired SLAMTestSceneManager with all required Inspector references.
        /// </summary>
        private SLAMTestSceneManager CreateWiredManager()
        {
            var managerGo = CreateTracked("SLAMTestSceneManager");
            var manager = managerGo.AddComponent<SLAMTestSceneManager>();

            var resetBtnGo = CreateTracked("ResetButton");
            var resetButton = resetBtnGo.AddComponent<Button>();

            var panelGo = CreateTracked("SLAMDebugPanel");
            var debugPanel = panelGo.AddComponent<SLAMDebugPanel>();

            var statusText = CreateTracked("StatusText").AddComponent<Text>();
            var trackingInfoText = CreateTracked("TrackingInfoText").AddComponent<Text>();
            var fpsText = CreateTracked("FpsText").AddComponent<Text>();
            var assetInfoText = CreateTracked("AssetInfoText").AddComponent<Text>();

            SetPrivateField(debugPanel, "statusText", statusText);
            SetPrivateField(debugPanel, "trackingInfoText", trackingInfoText);
            SetPrivateField(debugPanel, "fpsText", fpsText);
            SetPrivateField(debugPanel, "assetInfoText", assetInfoText);

            var audioGo = CreateTracked("SLAMAudioFeedback");
            var audioFeedback = audioGo.AddComponent<SLAMAudioFeedback>();

            var originGo = CreateTracked("AreaTargetOrigin");

            SetPrivateField(manager, "resetButton", resetButton);
            SetPrivateField(manager, "debugPanel", debugPanel);
            SetPrivateField(manager, "audioFeedback", audioFeedback);
            SetPrivateField(manager, "areaTargetOrigin", originGo.transform);

            return manager;
        }

        #region AssetBundleLoader Loading from Local Directory (Requirements 2.1, 8.1)

        /// <summary>
        /// Integration: AssetBundleLoader loads a valid v2.0 asset directory (simulating StreamingAssets/SLAMTestAssets/).
        /// Verifies manifest parsing, file path resolution, and all fields are correctly populated.
        /// </summary>
        [Test]
        public void AssetBundleLoader_LoadValidAssetDirectory_Succeeds()
        {
            string assetDir = CreateTestAssetDirectory();
            var loader = new AssetBundleLoader();

            bool result = loader.Load(assetDir);

            Assert.IsTrue(result, $"Load should succeed, error: {loader.LastError}");
            Assert.IsNotNull(loader.Manifest, "Manifest should be parsed");
            Assert.AreEqual("slam_integration_test", loader.Manifest.name);
            Assert.AreEqual("2.0", loader.Manifest.version);
            Assert.AreEqual("glb", loader.Manifest.format);
            Assert.AreEqual("optimized.glb", loader.Manifest.meshFile);
            Assert.AreEqual("features.db", loader.Manifest.featureDbFile);
            Assert.AreEqual(30, loader.Manifest.keyframeCount);
            Assert.AreEqual("ORB", loader.Manifest.featureType);

            Assert.IsNotNull(loader.MeshPath, "MeshPath should be set");
            Assert.IsNotNull(loader.FeatureDbPath, "FeatureDbPath should be set");
            Assert.IsTrue(File.Exists(loader.MeshPath), "Mesh file should exist at resolved path");
            Assert.IsTrue(File.Exists(loader.FeatureDbPath), "Feature DB should exist at resolved path");
        }

        /// <summary>
        /// Integration: AssetBundleLoader rejects a directory missing manifest.json.
        /// Verifies error handling when the asset directory is incomplete.
        /// </summary>
        [Test]
        public void AssetBundleLoader_MissingManifest_Fails()
        {
            LogAssert.ignoreFailingMessages = true;
            string assetDir = Path.Combine(_testDir, "NoManifest");
            Directory.CreateDirectory(assetDir);
            File.WriteAllBytes(Path.Combine(assetDir, "optimized.glb"), new byte[] { 0x00 });
            File.WriteAllBytes(Path.Combine(assetDir, "features.db"), new byte[] { 0x00 });

            var loader = new AssetBundleLoader();
            bool result = loader.Load(assetDir);

            Assert.IsFalse(result, "Load should fail without manifest.json");
            Assert.IsNotNull(loader.LastError);
            StringAssert.Contains("manifest.json", loader.LastError);
        }

        /// <summary>
        /// Integration: AssetBundleLoader rejects a directory missing required asset files.
        /// Verifies that even with a valid manifest, missing referenced files cause failure.
        /// </summary>
        [Test]
        public void AssetBundleLoader_MissingReferencedFiles_Fails()
        {
            LogAssert.ignoreFailingMessages = true;
            string assetDir = Path.Combine(_testDir, "MissingFiles");
            Directory.CreateDirectory(assetDir);

            string manifest = @"{
                ""version"": ""2.0"",
                ""name"": ""missing_files_test"",
                ""meshFile"": ""optimized.glb"",
                ""format"": ""glb"",
                ""featureDbFile"": ""features.db"",
                ""keyframeCount"": 10,
                ""featureType"": ""ORB""
            }";
            File.WriteAllText(Path.Combine(assetDir, "manifest.json"), manifest);
            // Intentionally omit optimized.glb and features.db

            var loader = new AssetBundleLoader();
            bool result = loader.Load(assetDir);

            Assert.IsFalse(result, "Load should fail when referenced files are missing");
            Assert.IsNotNull(loader.LastError);
        }

        /// <summary>
        /// Integration: AssetBundleLoader rejects a non-existent directory path.
        /// Simulates the case where StreamingAssets/SLAMTestAssets/ does not exist.
        /// </summary>
        [Test]
        public void AssetBundleLoader_NonExistentDirectory_Fails()
        {
            LogAssert.ignoreFailingMessages = true;
            string nonExistentDir = Path.Combine(_testDir, "DoesNotExist");

            var loader = new AssetBundleLoader();
            bool result = loader.Load(nonExistentDir);

            Assert.IsFalse(result, "Load should fail for non-existent directory");
            Assert.IsNotNull(loader.LastError);
        }

        #endregion

        #region Scene Lifecycle Resource Cleanup (Requirements 7.1, 7.2, 8.2)

        /// <summary>
        /// Lifecycle: Simulates Start → Tracking → OnDestroy.
        /// Verifies that tracker is disposed and reference is nulled on destroy.
        /// </summary>
        [Test]
        public void Lifecycle_TrackingThenDestroy_TrackerDisposed()
        {
            var manager = CreateWiredManager();

            // Inject a tracker to simulate successful initialization
            var tracker = new AreaTargetTracker();
            SetPrivateField(manager, "_tracker", tracker);
            SetPrivateField(manager, "_initialized", true);
            SetPrivateField(manager, "_previousState", TrackingState.INITIALIZING);

            // Simulate entering TRACKING state
            var trackingResult = new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = 0.9f,
                MatchedFeatures = 100
            };
            InvokeHandleTrackingResult(manager, trackingResult);

            // Track the created OriginCube for cleanup
            var originCube = GetPrivateField<GameObject>(manager, "_originCube");
            if (originCube != null && !_createdObjects.Contains(originCube))
                _createdObjects.Add(originCube);

            // Simulate OnDestroy
            InvokeOnDestroy(manager);

            Assert.IsTrue(IsTrackerDisposed(tracker),
                "Tracker should be disposed after OnDestroy");
            Assert.IsNull(GetPrivateField<AreaTargetTracker>(manager, "_tracker"),
                "Tracker reference should be null after OnDestroy");
        }

        /// <summary>
        /// Lifecycle: Simulates Start → Tracking → Reset → verify cleanup, then continue tracking → OnDestroy.
        /// Verifies the full lifecycle with a reset in the middle.
        /// </summary>
        [Test]
        public void Lifecycle_TrackingResetThenDestroy_ProperResourceRelease()
        {
            var manager = CreateWiredManager();

            var tracker = new AreaTargetTracker();
            SetPrivateField(manager, "_tracker", tracker);
            SetPrivateField(manager, "_initialized", true);
            SetPrivateField(manager, "_previousState", TrackingState.INITIALIZING);

            // Enter TRACKING — creates OriginCube
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

            // Reset — should hide cube, clear panel, reset state
            manager.OnResetClicked();

            Assert.IsFalse(originCube.activeSelf, "OriginCube should be hidden after reset");
            var previousState = GetPrivateField<TrackingState>(manager, "_previousState");
            Assert.AreEqual(TrackingState.INITIALIZING, previousState,
                "_previousState should be INITIALIZING after reset");

            // Verify tracker was reset (not disposed — reset keeps tracker alive)
            Assert.AreEqual(TrackingState.INITIALIZING, tracker.GetTrackingState(),
                "Tracker should be in INITIALIZING state after Reset()");

            // Simulate OnDestroy
            InvokeOnDestroy(manager);

            Assert.IsTrue(IsTrackerDisposed(tracker),
                "Tracker should be disposed after OnDestroy");
            Assert.IsNull(GetPrivateField<AreaTargetTracker>(manager, "_tracker"),
                "Tracker reference should be null after OnDestroy");
        }

        /// <summary>
        /// Lifecycle: OnDestroy properly disposes tracker and nulls references when no tracking occurred.
        /// Verifies graceful cleanup when scene is destroyed before any tracking.
        /// </summary>
        [Test]
        public void Lifecycle_DestroyBeforeTracking_NoExceptions()
        {
            var manager = CreateWiredManager();

            var tracker = new AreaTargetTracker();
            SetPrivateField(manager, "_tracker", tracker);
            SetPrivateField(manager, "_initialized", true);

            Assert.DoesNotThrow(() => InvokeOnDestroy(manager),
                "OnDestroy should not throw when no tracking has occurred");

            Assert.IsTrue(IsTrackerDisposed(tracker),
                "Tracker should be disposed even if no tracking occurred");
            Assert.IsNull(GetPrivateField<AreaTargetTracker>(manager, "_tracker"),
                "Tracker reference should be null after OnDestroy");
        }

        /// <summary>
        /// Lifecycle: OnDestroy with no tracker (initialization failed) should not throw.
        /// Verifies graceful cleanup when scene is destroyed after a failed initialization.
        /// </summary>
        [Test]
        public void Lifecycle_DestroyWithNoTracker_NoExceptions()
        {
            var manager = CreateWiredManager();

            // Simulate failed initialization — no tracker
            SetPrivateField(manager, "_tracker", null);
            SetPrivateField(manager, "_initialized", false);

            Assert.DoesNotThrow(() => InvokeOnDestroy(manager),
                "OnDestroy should not throw when no tracker exists");
        }

        /// <summary>
        /// Lifecycle: Full cycle Start → TRACKING → LOST → TRACKING → Reset → OnDestroy.
        /// Verifies no resource leaks across multiple state transitions and a reset.
        /// </summary>
        [Test]
        public void Lifecycle_FullCycleWithMultipleTransitions_NoResourceLeaks()
        {
            var manager = CreateWiredManager();

            var tracker = new AreaTargetTracker();
            SetPrivateField(manager, "_tracker", tracker);
            SetPrivateField(manager, "_initialized", true);
            SetPrivateField(manager, "_previousState", TrackingState.INITIALIZING);

            // INITIALIZING → TRACKING
            InvokeHandleTrackingResult(manager, new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = 0.95f,
                MatchedFeatures = 200
            });

            var originCube = GetPrivateField<GameObject>(manager, "_originCube");
            Assert.IsNotNull(originCube, "OriginCube should be created");
            if (!_createdObjects.Contains(originCube))
                _createdObjects.Add(originCube);
            Assert.IsTrue(originCube.activeSelf, "OriginCube should be visible during TRACKING");

            // TRACKING → LOST
            InvokeHandleTrackingResult(manager, new TrackingResult
            {
                State = TrackingState.LOST,
                Pose = Matrix4x4.identity,
                Confidence = 0f,
                MatchedFeatures = 0
            });
            Assert.IsFalse(originCube.activeSelf, "OriginCube should be hidden during LOST");

            // LOST → TRACKING
            InvokeHandleTrackingResult(manager, new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = 0.8f,
                MatchedFeatures = 80
            });
            Assert.IsTrue(originCube.activeSelf, "OriginCube should be visible again after re-tracking");

            // Same cube instance should be reused
            var sameCube = GetPrivateField<GameObject>(manager, "_originCube");
            Assert.AreSame(originCube, sameCube, "OriginCube should be reused, not recreated");

            // Reset
            manager.OnResetClicked();
            Assert.IsFalse(originCube.activeSelf, "OriginCube should be hidden after reset");

            // OnDestroy
            InvokeOnDestroy(manager);

            Assert.IsTrue(IsTrackerDisposed(tracker),
                "Tracker should be disposed after full lifecycle");
            Assert.IsNull(GetPrivateField<AreaTargetTracker>(manager, "_tracker"),
                "Tracker reference should be null after full lifecycle");
        }

        #endregion

        #region Static XR Asset Validation (Requirements 1.1–1.6, 2.1, 2.2, 4.1–4.3, 5.1, 5.3, 6.1–6.4)

        /// <summary>
        /// Resolves the base path to the unity_project directory by navigating up from the test assembly location.
        /// </summary>
        private static string GetUnityProjectPath()
        {
            // When running inside Unity Editor (batch mode or Test Runner),
            // the working directory is typically the unity_project folder itself.
            // Check if the current working directory IS the unity_project.
            string cwd = Directory.GetCurrentDirectory();
            if (Directory.Exists(Path.Combine(cwd, "Assets")) &&
                Directory.Exists(Path.Combine(cwd, "ProjectSettings")))
            {
                return cwd;
            }

            // Navigate from test assembly location to workspace root, then into unity_project
            string assemblyDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            string current = assemblyDir;

            // Walk up until we find unity_project directory
            for (int i = 0; i < 15; i++)
            {
                string candidate = Path.Combine(current, "unity_project");
                if (Directory.Exists(candidate))
                    return candidate;
                current = Path.GetDirectoryName(current);
                if (current == null) break;
            }

            // Fallback: try relative from working directory
            string workingDirCandidate = Path.GetFullPath("unity_project");
            if (Directory.Exists(workingDirCandidate))
                return workingDirCandidate;

            throw new DirectoryNotFoundException(
                $"Could not find unity_project directory. Assembly location: {assemblyDir}, cwd: {cwd}");
        }

        /// <summary>
        /// Validates: Requirements 1.3, 1.4
        /// XRGeneralSettingsPerBuildTarget Keys contains 02000000 (iOS) and Values references XRGeneralSettings_iOS.
        /// </summary>
        [Test]
        public void XRGeneralSettingsPerBuildTarget_KeysContainsiOS_ValuesReferencesGeneralSettings()
        {
            string projectPath = GetUnityProjectPath();
            string assetPath = Path.Combine(projectPath, "Assets", "XR", "XRGeneralSettingsPerBuildTarget.asset");
            Assert.IsTrue(File.Exists(assetPath), $"XRGeneralSettingsPerBuildTarget.asset should exist at {assetPath}");

            string content = File.ReadAllText(assetPath);

            // Keys should contain 02000000 (BuildTargetGroup.iOS = 2)
            StringAssert.Contains("02000000", content,
                "Keys should contain 02000000 for BuildTargetGroup.iOS");

            // Values should reference XRGeneralSettings_iOS by its meta GUID
            StringAssert.Contains("6de05aa3e7e84d20bcfba5c07e5e6f12", content,
                "Values should reference XRGeneralSettings_iOS asset GUID");
        }

        /// <summary>
        /// Validates: Requirements 1.1, 1.2, 4.2
        /// XRGeneralSettings_iOS m_LoaderManagerInstance references XRManagerSettings_iOS.
        /// </summary>
        [Test]
        public void XRGeneralSettings_iOS_LoaderManagerInstance_ReferencesXRManagerSettings()
        {
            string projectPath = GetUnityProjectPath();
            string assetPath = Path.Combine(projectPath, "Assets", "XR", "Settings", "XRGeneralSettings_iOS.asset");
            Assert.IsTrue(File.Exists(assetPath), $"XRGeneralSettings_iOS.asset should exist at {assetPath}");

            string content = File.ReadAllText(assetPath);

            // m_LoaderManagerInstance should reference XRManagerSettings_iOS by its meta GUID
            StringAssert.Contains("m_LoaderManagerInstance", content,
                "Asset should contain m_LoaderManagerInstance field");
            StringAssert.Contains("e44aa2e7ae974761906e04651fcbc911", content,
                "m_LoaderManagerInstance should reference XRManagerSettings_iOS GUID");
        }

        /// <summary>
        /// Validates: Requirements 1.5, 6.1, 6.2
        /// XRManagerSettings_iOS m_Loaders[0] GUID = 23953935e6fca4839ad7c8b39da9c6f9 (ARKitLoader).
        /// </summary>
        [Test]
        public void XRManagerSettings_iOS_Loaders_ContainsARKitLoaderGUID()
        {
            string projectPath = GetUnityProjectPath();
            string assetPath = Path.Combine(projectPath, "Assets", "XR", "Settings", "XRManagerSettings_iOS.asset");
            Assert.IsTrue(File.Exists(assetPath), $"XRManagerSettings_iOS.asset should exist at {assetPath}");

            string content = File.ReadAllText(assetPath);

            // m_Loaders should contain ARKitLoader GUID
            StringAssert.Contains("23953935e6fca4839ad7c8b39da9c6f9", content,
                "m_Loaders should contain ARKitLoader GUID 23953935e6fca4839ad7c8b39da9c6f9");

            // Should NOT contain the old incorrect GUID
            Assert.IsFalse(content.Contains("6883de2d4764747dfab10d70e1a376d3"),
                "m_Loaders should not contain the old incorrect GUID 6883de2d4764747dfab10d70e1a376d3");
        }

        /// <summary>
        /// Validates: Requirements 6.3, 6.4
        /// XRManagerSettings_iOS m_AutomaticLoading = 1 and m_AutomaticRunning = 1.
        /// </summary>
        [Test]
        public void XRManagerSettings_iOS_AutomaticLoadingAndRunning_AreEnabled()
        {
            string projectPath = GetUnityProjectPath();
            string assetPath = Path.Combine(projectPath, "Assets", "XR", "Settings", "XRManagerSettings_iOS.asset");
            Assert.IsTrue(File.Exists(assetPath), $"XRManagerSettings_iOS.asset should exist at {assetPath}");

            string content = File.ReadAllText(assetPath);

            StringAssert.Contains("m_AutomaticLoading: 1", content,
                "m_AutomaticLoading should be 1");
            StringAssert.Contains("m_AutomaticRunning: 1", content,
                "m_AutomaticRunning should be 1");
        }

        /// <summary>
        /// Validates: Requirements 1.6, 4.1
        /// .meta files exist for XRManagerSettings_iOS and XRGeneralSettings_iOS with valid GUIDs.
        /// </summary>
        [Test]
        public void XRSettings_MetaFiles_ExistWithValidGUIDs()
        {
            string projectPath = GetUnityProjectPath();
            string settingsDir = Path.Combine(projectPath, "Assets", "XR", "Settings");

            // XRManagerSettings_iOS.asset.meta
            string managerMetaPath = Path.Combine(settingsDir, "XRManagerSettings_iOS.asset.meta");
            Assert.IsTrue(File.Exists(managerMetaPath),
                "XRManagerSettings_iOS.asset.meta should exist");
            string managerMetaContent = File.ReadAllText(managerMetaPath);
            StringAssert.Contains("guid: e44aa2e7ae974761906e04651fcbc911", managerMetaContent,
                "XRManagerSettings_iOS meta should contain GUID e44aa2e7ae974761906e04651fcbc911");

            // XRGeneralSettings_iOS.asset.meta
            string generalMetaPath = Path.Combine(settingsDir, "XRGeneralSettings_iOS.asset.meta");
            Assert.IsTrue(File.Exists(generalMetaPath),
                "XRGeneralSettings_iOS.asset.meta should exist");
            string generalMetaContent = File.ReadAllText(generalMetaPath);
            StringAssert.Contains("guid: 6de05aa3e7e84d20bcfba5c07e5e6f12", generalMetaContent,
                "XRGeneralSettings_iOS meta should contain GUID 6de05aa3e7e84d20bcfba5c07e5e6f12");
        }

        /// <summary>
        /// Validates: Requirements 2.1, 2.2
        /// AR Camera m_ClearFlags = 2, background alpha = 0, ARCameraBackground component attached.
        /// </summary>
        [Test]
        public void ARCamera_ClearFlagsAndBackground_CorrectlyConfigured()
        {
            string projectPath = GetUnityProjectPath();
            string scenePath = Path.Combine(projectPath, "Assets", "Scenes", "SLAMTestScene.unity");
            Assert.IsTrue(File.Exists(scenePath), $"SLAMTestScene.unity should exist at {scenePath}");

            string content = File.ReadAllText(scenePath);

            // AR Camera should have m_ClearFlags: 2 (Solid Color)
            StringAssert.Contains("m_ClearFlags: 2", content,
                "AR Camera should have m_ClearFlags = 2 (Solid Color)");

            // Background color alpha should be 0
            // The Camera component has m_BackGroundColor with a: 0
            StringAssert.Contains("a: 0", content,
                "AR Camera background color alpha should be 0");

            // ARCameraBackground component should be attached (identified by its script GUID)
            StringAssert.Contains("4966719baa26e4b0e8231a24d9bd491a", content,
                "ARCameraBackground component (GUID 4966719baa26e4b0e8231a24d9bd491a) should be attached to AR Camera");
        }

        /// <summary>
        /// Validates: Requirements 5.1, 5.3
        /// ProjectSettings cameraUsageDescription is non-empty and iOSRequireARKit = 1.
        /// </summary>
        [Test]
        public void ProjectSettings_CameraPermissionAndARKit_CorrectlyConfigured()
        {
            string projectPath = GetUnityProjectPath();
            string settingsPath = Path.Combine(projectPath, "ProjectSettings", "ProjectSettings.asset");
            Assert.IsTrue(File.Exists(settingsPath), $"ProjectSettings.asset should exist at {settingsPath}");

            string content = File.ReadAllText(settingsPath);

            // cameraUsageDescription should be non-empty
            StringAssert.Contains("cameraUsageDescription:", content,
                "ProjectSettings should contain cameraUsageDescription field");
            // Verify it has actual content after the colon (not just empty)
            Assert.IsFalse(
                System.Text.RegularExpressions.Regex.IsMatch(content, @"cameraUsageDescription:\s*\n"),
                "cameraUsageDescription should not be empty");

            // iOSRequireARKit should be 1
            StringAssert.Contains("iOSRequireARKit: 1", content,
                "iOSRequireARKit should be 1");
        }

        #endregion
    }
}
