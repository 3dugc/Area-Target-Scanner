using System;
using System.Collections.Generic;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.UI;
using AreaTargetPlugin;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Unit tests for DownloadTestSceneManager.
    /// Tests state transitions, reset behavior, OnDestroy lifecycle, and OriginCube creation.
    /// Validates: Requirements 1.4, 1.5, 6.1, 6.2, 6.3, 7.1, 7.2, 7.3
    /// </summary>
    [TestFixture]
    public class DownloadTestSceneManagerTests
    {
        private GameObject _managerGo;
        private DownloadTestSceneManager _manager;
        private Button _downloadButton;
        private Button _resetButton;
        private InputField _urlInputField;
        private DebugPanel _debugPanel;
        private Text _statusText;
        private Text _progressText;
        private Text _trackingInfoText;
        private Text _fpsText;
        private Text _assetInfoText;
        private Transform _areaTargetOrigin;
        private List<GameObject> _createdObjects;

        [SetUp]
        public void SetUp()
        {
            _createdObjects = new List<GameObject>();

            _managerGo = CreateTracked("DownloadTestSceneManager");
            _manager = _managerGo.AddComponent<DownloadTestSceneManager>();

            // Download button
            var downloadBtnGo = CreateTracked("DownloadButton");
            _downloadButton = downloadBtnGo.AddComponent<Button>();

            // Reset button
            var resetBtnGo = CreateTracked("ResetButton");
            _resetButton = resetBtnGo.AddComponent<Button>();

            // URL input field
            var inputGo = CreateTracked("UrlInputField");
            _urlInputField = inputGo.AddComponent<InputField>();
            var inputTextGo = CreateTracked("InputText");
            inputTextGo.transform.SetParent(inputGo.transform);
            var inputText = inputTextGo.AddComponent<Text>();
            _urlInputField.textComponent = inputText;

            // DebugPanel with all text fields
            var panelGo = CreateTracked("DebugPanel");
            _debugPanel = panelGo.AddComponent<DebugPanel>();

            _statusText = CreateTracked("StatusText").AddComponent<Text>();
            _progressText = CreateTracked("ProgressText").AddComponent<Text>();
            _trackingInfoText = CreateTracked("TrackingInfoText").AddComponent<Text>();
            _fpsText = CreateTracked("FpsText").AddComponent<Text>();
            _assetInfoText = CreateTracked("AssetInfoText").AddComponent<Text>();

            SetPrivateField(_debugPanel, "statusText", _statusText);
            SetPrivateField(_debugPanel, "progressText", _progressText);
            SetPrivateField(_debugPanel, "trackingInfoText", _trackingInfoText);
            SetPrivateField(_debugPanel, "fpsText", _fpsText);
            SetPrivateField(_debugPanel, "assetInfoText", _assetInfoText);

            // Area target origin
            var originGo = CreateTracked("AreaTargetOrigin");
            _areaTargetOrigin = originGo.transform;

            // Wire up manager fields via reflection
            SetPrivateField(_manager, "urlInputField", _urlInputField);
            SetPrivateField(_manager, "downloadButton", _downloadButton);
            SetPrivateField(_manager, "resetButton", _resetButton);
            SetPrivateField(_manager, "debugPanel", _debugPanel);
            SetPrivateField(_manager, "areaTargetOrigin", _areaTargetOrigin);
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

        private void SetCurrentState(SceneState state)
        {
            var backingField = typeof(DownloadTestSceneManager).GetField("<CurrentState>k__BackingField",
                BindingFlags.NonPublic | BindingFlags.Instance);
            if (backingField != null)
            {
                backingField.SetValue(_manager, state);
                return;
            }
            var prop = typeof(DownloadTestSceneManager).GetProperty("CurrentState");
            if (prop != null && prop.CanWrite)
            {
                prop.SetValue(_manager, state);
                return;
            }
            throw new InvalidOperationException("Cannot set CurrentState via reflection");
        }

        private void InvokeHandleTrackingResult(TrackingResult result)
        {
            var method = typeof(DownloadTestSceneManager).GetMethod("HandleTrackingResult",
                BindingFlags.NonPublic | BindingFlags.Instance);
            method.Invoke(_manager, new object[] { result });
        }

        private void InvokeUpdateButtonStates()
        {
            var method = typeof(DownloadTestSceneManager).GetMethod("UpdateButtonStates",
                BindingFlags.NonPublic | BindingFlags.Instance);
            method.Invoke(_manager, null);
        }

        private static bool IsTrackerDisposed(AreaTargetTracker tracker)
        {
            var field = typeof(AreaTargetTracker).GetField("_disposed",
                BindingFlags.NonPublic | BindingFlags.Instance);
            return (bool)field.GetValue(tracker);
        }

        #region State Transition Tests (Requirements 1.4, 1.5)

        /// <summary>
        /// Tests the complete state transition sequence:
        /// Idle → Downloading → Extracting → Loading → Tracking.
        /// Simulates each state and verifies button interactable matches expectations.
        /// </summary>
        [Test]
        public void StateTransition_IdleToTracking_ButtonStatesCorrect()
        {
            // Idle: button should be interactable
            SetCurrentState(SceneState.Idle);
            InvokeUpdateButtonStates();
            Assert.AreEqual(SceneState.Idle, _manager.CurrentState);
            Assert.IsTrue(_downloadButton.interactable, "Button should be interactable in Idle");

            // Downloading: button should be disabled
            SetCurrentState(SceneState.Downloading);
            InvokeUpdateButtonStates();
            Assert.AreEqual(SceneState.Downloading, _manager.CurrentState);
            Assert.IsFalse(_downloadButton.interactable, "Button should be disabled in Downloading");

            // Extracting: button should be disabled
            SetCurrentState(SceneState.Extracting);
            InvokeUpdateButtonStates();
            Assert.AreEqual(SceneState.Extracting, _manager.CurrentState);
            Assert.IsFalse(_downloadButton.interactable, "Button should be disabled in Extracting");

            // Loading: button should be disabled
            SetCurrentState(SceneState.Loading);
            InvokeUpdateButtonStates();
            Assert.AreEqual(SceneState.Loading, _manager.CurrentState);
            Assert.IsFalse(_downloadButton.interactable, "Button should be disabled in Loading");

            // Tracking: button should be disabled
            SetCurrentState(SceneState.Tracking);
            InvokeUpdateButtonStates();
            Assert.AreEqual(SceneState.Tracking, _manager.CurrentState);
            Assert.IsFalse(_downloadButton.interactable, "Button should be disabled in Tracking");
        }

        [Test]
        public void StateTransition_ErrorState_ButtonReEnabled()
        {
            SetCurrentState(SceneState.Error);
            InvokeUpdateButtonStates();

            Assert.AreEqual(SceneState.Error, _manager.CurrentState);
            Assert.IsTrue(_downloadButton.interactable, "Button should be interactable in Error state");
        }

        #endregion

        #region OnResetClicked Tests (Requirements 7.1, 7.2, 7.3)

        [Test]
        public void OnResetClicked_StateReturnsToIdle()
        {
            // Put manager in Tracking state with a tracker
            SetCurrentState(SceneState.Tracking);
            var tracker = new AreaTargetTracker();
            SetPrivateField(_manager, "_tracker", tracker);

            _manager.OnResetClicked();

            Assert.AreEqual(SceneState.Idle, _manager.CurrentState,
                "State should return to Idle after reset");
        }

        [Test]
        public void OnResetClicked_DebugPanelCleared()
        {
            // Set some debug panel content
            _debugPanel.SetStatus("跟踪中", Color.green);
            _debugPanel.SetProgress(0.75f);
            _debugPanel.SetTrackingInfo(100, 0.9f);
            _debugPanel.SetFPS(60f);
            _debugPanel.SetAssetInfo("test", "2.0", 50);

            SetCurrentState(SceneState.Tracking);
            _manager.OnResetClicked();

            Assert.AreEqual(string.Empty, _statusText.text, "Status text should be cleared");
            Assert.AreEqual(string.Empty, _progressText.text, "Progress text should be cleared");
            Assert.AreEqual(string.Empty, _trackingInfoText.text, "Tracking info text should be cleared");
            Assert.AreEqual(string.Empty, _fpsText.text, "FPS text should be cleared");
            Assert.AreEqual(string.Empty, _assetInfoText.text, "Asset info text should be cleared");
        }

        [Test]
        public void OnResetClicked_TrackerDisposed()
        {
            SetCurrentState(SceneState.Tracking);
            var tracker = new AreaTargetTracker();
            SetPrivateField(_manager, "_tracker", tracker);

            _manager.OnResetClicked();

            Assert.IsTrue(IsTrackerDisposed(tracker), "Tracker should be disposed after reset");
            Assert.IsNull(GetPrivateField<AreaTargetTracker>(_manager, "_tracker"),
                "Tracker reference should be null after reset");
        }

        [Test]
        public void OnResetClicked_DownloadButtonReEnabled()
        {
            SetCurrentState(SceneState.Tracking);
            _downloadButton.interactable = false;

            _manager.OnResetClicked();

            Assert.IsTrue(_downloadButton.interactable,
                "Download button should be re-enabled after reset");
        }

        [Test]
        public void OnResetClicked_OriginCubeDestroyed()
        {
            SetCurrentState(SceneState.Tracking);

            // Create an OriginCube via a TRACKING result
            var trackingResult = new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = 0.9f,
                MatchedFeatures = 100
            };
            InvokeHandleTrackingResult(trackingResult);

            var originCube = GetPrivateField<GameObject>(_manager, "_originCube");
            Assert.IsNotNull(originCube, "OriginCube should exist before reset");
            if (!_createdObjects.Contains(originCube))
                _createdObjects.Add(originCube);

            _manager.OnResetClicked();

            // After reset, the _originCube field should be null
            var cubeAfterReset = GetPrivateField<GameObject>(_manager, "_originCube");
            Assert.IsNull(cubeAfterReset, "OriginCube reference should be null after reset");
        }

        [Test]
        public void OnResetClicked_FromErrorState_ReturnsToIdle()
        {
            SetCurrentState(SceneState.Error);

            _manager.OnResetClicked();

            Assert.AreEqual(SceneState.Idle, _manager.CurrentState,
                "State should return to Idle after reset from Error");
        }

        #endregion

        #region OnDestroy Tests (Requirements 7.1, 7.2)

        [Test]
        public void OnDestroy_DisposesTracker()
        {
            SetCurrentState(SceneState.Tracking);
            var tracker = new AreaTargetTracker();
            SetPrivateField(_manager, "_tracker", tracker);

            // Initialize DownloadManager so OnDestroy can dispose it
            var dm = new DownloadManager(_manager);
            SetPrivateField(_manager, "_downloadManager", dm);

            // Simulate OnDestroy via reflection
            var onDestroy = typeof(DownloadTestSceneManager).GetMethod("OnDestroy",
                BindingFlags.NonPublic | BindingFlags.Instance);
            onDestroy.Invoke(_manager, null);

            Assert.IsTrue(IsTrackerDisposed(tracker), "Tracker should be disposed in OnDestroy");
        }

        [Test]
        public void OnDestroy_DisposesDownloadManager()
        {
            var dm = new DownloadManager(_manager);
            SetPrivateField(_manager, "_downloadManager", dm);

            var onDestroy = typeof(DownloadTestSceneManager).GetMethod("OnDestroy",
                BindingFlags.NonPublic | BindingFlags.Instance);
            onDestroy.Invoke(_manager, null);

            // After OnDestroy, _downloadManager should be null
            var dmAfter = GetPrivateField<DownloadManager>(_manager, "_downloadManager");
            Assert.IsNull(dmAfter, "DownloadManager should be null after OnDestroy");
        }

        [Test]
        public void OnDestroy_NoTracker_DoesNotThrow()
        {
            SetPrivateField(_manager, "_tracker", null);
            var dm = new DownloadManager(_manager);
            SetPrivateField(_manager, "_downloadManager", dm);

            var onDestroy = typeof(DownloadTestSceneManager).GetMethod("OnDestroy",
                BindingFlags.NonPublic | BindingFlags.Instance);

            Assert.DoesNotThrow(() => onDestroy.Invoke(_manager, null),
                "OnDestroy should not throw when no tracker exists");
        }

        #endregion

        #region OriginCube Creation Tests (Requirements 6.1, 6.2, 6.3)

        [Test]
        public void FirstTracking_CreatesOriginCube()
        {
            SetCurrentState(SceneState.Tracking);

            var result = new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = 0.95f,
                MatchedFeatures = 200
            };

            InvokeHandleTrackingResult(result);

            var originCube = GetPrivateField<GameObject>(_manager, "_originCube");
            Assert.IsNotNull(originCube, "OriginCube should be created on first TRACKING");
            if (!_createdObjects.Contains(originCube))
                _createdObjects.Add(originCube);
        }

        [Test]
        public void FirstTracking_CubeSize_Is01Meters()
        {
            SetCurrentState(SceneState.Tracking);

            var result = new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = 0.9f,
                MatchedFeatures = 150
            };

            InvokeHandleTrackingResult(result);

            var originCube = GetPrivateField<GameObject>(_manager, "_originCube");
            Assert.IsNotNull(originCube);
            if (!_createdObjects.Contains(originCube))
                _createdObjects.Add(originCube);

            Vector3 expectedScale = Vector3.one * 0.1f;
            Assert.That(Vector3.Distance(originCube.transform.localScale, expectedScale), Is.LessThan(0.0001f),
                $"Cube scale should be (0.1, 0.1, 0.1), got {originCube.transform.localScale}");
        }

        [Test]
        public void FirstTracking_CubePosition_IsVectorZero()
        {
            SetCurrentState(SceneState.Tracking);

            var result = new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = 0.9f,
                MatchedFeatures = 150
            };

            InvokeHandleTrackingResult(result);

            var originCube = GetPrivateField<GameObject>(_manager, "_originCube");
            Assert.IsNotNull(originCube);
            if (!_createdObjects.Contains(originCube))
                _createdObjects.Add(originCube);

            Assert.That(Vector3.Distance(originCube.transform.localPosition, Vector3.zero), Is.LessThan(0.0001f),
                $"Cube localPosition should be Vector3.zero, got {originCube.transform.localPosition}");
        }

        [Test]
        public void FirstTracking_CubeParentedToAreaTargetOrigin()
        {
            SetCurrentState(SceneState.Tracking);

            var result = new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = 0.9f,
                MatchedFeatures = 150
            };

            InvokeHandleTrackingResult(result);

            var originCube = GetPrivateField<GameObject>(_manager, "_originCube");
            Assert.IsNotNull(originCube);
            if (!_createdObjects.Contains(originCube))
                _createdObjects.Add(originCube);

            Assert.AreEqual(_areaTargetOrigin, originCube.transform.parent,
                "OriginCube should be parented to areaTargetOrigin");
        }

        [Test]
        public void SecondTracking_DoesNotCreateDuplicateCube()
        {
            SetCurrentState(SceneState.Tracking);

            var result = new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = 0.9f,
                MatchedFeatures = 150
            };

            // First TRACKING frame
            InvokeHandleTrackingResult(result);
            var firstCube = GetPrivateField<GameObject>(_manager, "_originCube");
            if (!_createdObjects.Contains(firstCube))
                _createdObjects.Add(firstCube);

            // Second TRACKING frame
            InvokeHandleTrackingResult(result);
            var secondCube = GetPrivateField<GameObject>(_manager, "_originCube");

            Assert.AreSame(firstCube, secondCube,
                "Second TRACKING frame should not create a new cube");
        }

        #endregion
    }
}
