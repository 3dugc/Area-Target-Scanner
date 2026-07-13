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
    /// Unit tests for SLAMTestSceneManager.
    /// Tests HandleTrackingResult state transitions, OnResetClicked behavior,
    /// OnDestroy lifecycle, and OriginCube creation.
    /// Validates: Requirements 2.1, 2.4, 2.5, 4.2, 4.3, 4.4, 7.1, 7.2, 7.3, 7.4
    /// </summary>
    [TestFixture]
    public class SLAMTestSceneManagerTests
    {
        private GameObject _managerGo;
        private SLAMTestSceneManager _manager;
        private Button _resetButton;
        private SLAMDebugPanel _debugPanel;
        private SLAMAudioFeedback _audioFeedback;
        private Text _statusText;
        private Text _trackingInfoText;
        private Text _fpsText;
        private Text _assetInfoText;
        private Transform _areaTargetOrigin;
        private List<GameObject> _createdObjects;

        [SetUp]
        public void SetUp()
        {
            _createdObjects = new List<GameObject>();

            _managerGo = CreateTracked("SLAMTestSceneManager");
            _manager = _managerGo.AddComponent<SLAMTestSceneManager>();

            // Reset button
            var resetBtnGo = CreateTracked("ResetButton");
            _resetButton = resetBtnGo.AddComponent<Button>();

            // SLAMDebugPanel with all text fields
            var panelGo = CreateTracked("SLAMDebugPanel");
            _debugPanel = panelGo.AddComponent<SLAMDebugPanel>();

            _statusText = CreateTracked("StatusText").AddComponent<Text>();
            _trackingInfoText = CreateTracked("TrackingInfoText").AddComponent<Text>();
            _fpsText = CreateTracked("FpsText").AddComponent<Text>();
            _assetInfoText = CreateTracked("AssetInfoText").AddComponent<Text>();

            SetPrivateField(_debugPanel, "statusText", _statusText);
            SetPrivateField(_debugPanel, "trackingInfoText", _trackingInfoText);
            SetPrivateField(_debugPanel, "fpsText", _fpsText);
            SetPrivateField(_debugPanel, "assetInfoText", _assetInfoText);

            // SLAMAudioFeedback
            var audioGo = CreateTracked("SLAMAudioFeedback");
            _audioFeedback = audioGo.AddComponent<SLAMAudioFeedback>();

            // Area target origin
            var originGo = CreateTracked("AreaTargetOrigin");
            _areaTargetOrigin = originGo.transform;

            // Wire up manager fields via reflection
            SetPrivateField(_manager, "resetButton", _resetButton);
            SetPrivateField(_manager, "debugPanel", _debugPanel);
            SetPrivateField(_manager, "audioFeedback", _audioFeedback);
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

        private void InvokeHandleTrackingResult(TrackingResult result)
        {
            var method = typeof(SLAMTestSceneManager).GetMethod("HandleTrackingResult",
                BindingFlags.NonPublic | BindingFlags.Instance);
            method.Invoke(_manager, new object[] { result });
        }

        private void InvokeOnDestroy()
        {
            var method = typeof(SLAMTestSceneManager).GetMethod("OnDestroy",
                BindingFlags.NonPublic | BindingFlags.Instance);
            method.Invoke(_manager, null);
        }

        private static bool IsTrackerDisposed(AreaTargetTracker tracker)
        {
            var field = typeof(AreaTargetTracker).GetField("_disposed",
                BindingFlags.NonPublic | BindingFlags.Instance);
            return (bool)field.GetValue(tracker);
        }

        #region State Transition Tests (Requirements 2.1, 2.4, 2.5)

        /// <summary>
        /// Tests the complete state transition cycle:
        /// INITIALIZING → TRACKING → LOST → TRACKING.
        /// Verifies DebugPanel status text and color update correctly at each transition.
        /// </summary>
        [Test]
        public void StateTransition_InitializingToTrackingToLostToTracking_DebugPanelUpdatesCorrectly()
        {
            // Start in INITIALIZING (default _previousState)
            SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);

            // INITIALIZING → TRACKING
            var trackingResult = new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = 0.9f,
                MatchedFeatures = 100
            };
            InvokeHandleTrackingResult(trackingResult);

            Assert.AreEqual("跟踪中", _statusText.text, "Status should show TRACKING text");
            Assert.AreEqual(Color.green, _statusText.color, "Status color should be green for TRACKING");

            // Track the created cube for cleanup
            var originCube = GetPrivateField<GameObject>(_manager, "_originCube");
            if (originCube != null && !_createdObjects.Contains(originCube))
                _createdObjects.Add(originCube);

            // TRACKING → LOST
            var lostResult = new TrackingResult
            {
                State = TrackingState.LOST,
                Pose = Matrix4x4.identity,
                Confidence = 0f,
                MatchedFeatures = 0
            };
            InvokeHandleTrackingResult(lostResult);

            Assert.AreEqual("跟踪丢失", _statusText.text, "Status should show LOST text");
            Assert.AreEqual(Color.red, _statusText.color, "Status color should be red for LOST");

            // LOST → TRACKING
            InvokeHandleTrackingResult(trackingResult);

            Assert.AreEqual("跟踪中", _statusText.text, "Status should show TRACKING text after re-tracking");
            Assert.AreEqual(Color.green, _statusText.color, "Status color should be green after re-tracking");
        }

        /// <summary>
        /// Tests that INITIALIZING state shows correct status.
        /// </summary>
        [Test]
        public void HandleTrackingResult_Initializing_ShowsYellowStatus()
        {
            SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);

            var result = new TrackingResult
            {
                State = TrackingState.INITIALIZING,
                Pose = Matrix4x4.identity,
                Confidence = 0f,
                MatchedFeatures = 0
            };
            InvokeHandleTrackingResult(result);

            Assert.AreEqual("正在初始化", _statusText.text);
            Assert.AreEqual(Color.yellow, _statusText.color);
        }

        /// <summary>
        /// Tests that TRACKING state shows tracking info (matched features and confidence).
        /// </summary>
        [Test]
        public void HandleTrackingResult_Tracking_ShowsTrackingInfo()
        {
            SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);

            var result = new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = 0.85f,
                MatchedFeatures = 42
            };
            InvokeHandleTrackingResult(result);

            // Track cube for cleanup
            var originCube = GetPrivateField<GameObject>(_manager, "_originCube");
            if (originCube != null && !_createdObjects.Contains(originCube))
                _createdObjects.Add(originCube);

            Assert.That(_trackingInfoText.text, Does.Contain("42"), "Should display matched features count");
            Assert.That(_trackingInfoText.text, Does.Contain("85"), "Should display confidence percentage");
        }

        /// <summary>
        /// Tests that _previousState is updated after each HandleTrackingResult call.
        /// </summary>
        [Test]
        public void HandleTrackingResult_UpdatesPreviousState()
        {
            SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);

            var result = new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = 0.9f,
                MatchedFeatures = 100
            };
            InvokeHandleTrackingResult(result);

            // Track cube for cleanup
            var originCube = GetPrivateField<GameObject>(_manager, "_originCube");
            if (originCube != null && !_createdObjects.Contains(originCube))
                _createdObjects.Add(originCube);

            var previousState = GetPrivateField<TrackingState>(_manager, "_previousState");
            Assert.AreEqual(TrackingState.TRACKING, previousState,
                "_previousState should be updated to TRACKING");
        }

        #endregion

        #region OnResetClicked Tests (Requirements 7.1, 7.2, 7.3, 7.4)

        /// <summary>
        /// Tests that OnResetClicked calls tracker.Reset().
        /// </summary>
        [Test]
        public void OnResetClicked_CallsTrackerReset()
        {
            var tracker = new AreaTargetTracker();
            SetPrivateField(_manager, "_tracker", tracker);

            // Put into TRACKING state first
            SetPrivateField(_manager, "_previousState", TrackingState.TRACKING);

            _manager.OnResetClicked();

            // After Reset(), tracker state should be INITIALIZING
            Assert.AreEqual(TrackingState.INITIALIZING, tracker.GetTrackingState(),
                "Tracker should be in INITIALIZING state after Reset()");
        }

        /// <summary>
        /// Tests that OnResetClicked hides the OriginCube.
        /// </summary>
        [Test]
        public void OnResetClicked_HidesOriginCube()
        {
            SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);

            // Create OriginCube via TRACKING result
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

            Assert.IsTrue(originCube.activeSelf, "OriginCube should be active before reset");

            _manager.OnResetClicked();

            Assert.IsFalse(originCube.activeSelf, "OriginCube should be hidden after reset");
        }

        /// <summary>
        /// Tests that OnResetClicked clears the DebugPanel.
        /// </summary>
        [Test]
        public void OnResetClicked_ClearsDebugPanel()
        {
            // Set some debug panel content
            _debugPanel.SetStatus("跟踪中", Color.green);
            _debugPanel.SetTrackingInfo(100, 0.9f);
            _debugPanel.SetFPS(60f);
            _debugPanel.SetAssetInfo("test", "2.0", 50);

            _manager.OnResetClicked();

            Assert.AreEqual(string.Empty, _statusText.text, "Status text should be cleared");
            Assert.AreEqual(string.Empty, _trackingInfoText.text, "Tracking info text should be cleared");
            Assert.AreEqual(string.Empty, _fpsText.text, "FPS text should be cleared");
            Assert.AreEqual(string.Empty, _assetInfoText.text, "Asset info text should be cleared");
        }

        /// <summary>
        /// Tests that OnResetClicked sets _previousState back to INITIALIZING.
        /// </summary>
        [Test]
        public void OnResetClicked_ResetsPreviousStateToInitializing()
        {
            SetPrivateField(_manager, "_previousState", TrackingState.TRACKING);

            _manager.OnResetClicked();

            var previousState = GetPrivateField<TrackingState>(_manager, "_previousState");
            Assert.AreEqual(TrackingState.INITIALIZING, previousState,
                "_previousState should be INITIALIZING after reset");
        }

        /// <summary>
        /// Tests that OnResetClicked with no tracker does not throw.
        /// </summary>
        [Test]
        public void OnResetClicked_NoTracker_DoesNotThrow()
        {
            SetPrivateField(_manager, "_tracker", null);

            Assert.DoesNotThrow(() => _manager.OnResetClicked(),
                "OnResetClicked should not throw when no tracker exists");
        }

        #endregion

        #region OnDestroy Tests (Requirements 7.1, 7.2)

        /// <summary>
        /// Tests that OnDestroy disposes the tracker.
        /// </summary>
        [Test]
        public void OnDestroy_DisposesTracker()
        {
            var tracker = new AreaTargetTracker();
            SetPrivateField(_manager, "_tracker", tracker);

            InvokeOnDestroy();

            Assert.IsTrue(IsTrackerDisposed(tracker), "Tracker should be disposed in OnDestroy");
        }

        /// <summary>
        /// Tests that OnDestroy sets tracker reference to null.
        /// </summary>
        [Test]
        public void OnDestroy_NullsTrackerReference()
        {
            var tracker = new AreaTargetTracker();
            SetPrivateField(_manager, "_tracker", tracker);

            InvokeOnDestroy();

            var trackerAfter = GetPrivateField<AreaTargetTracker>(_manager, "_tracker");
            Assert.IsNull(trackerAfter, "Tracker reference should be null after OnDestroy");
        }

        /// <summary>
        /// Tests that OnDestroy with no tracker does not throw.
        /// </summary>
        [Test]
        public void OnDestroy_NoTracker_DoesNotThrow()
        {
            SetPrivateField(_manager, "_tracker", null);

            Assert.DoesNotThrow(() => InvokeOnDestroy(),
                "OnDestroy should not throw when no tracker exists");
        }

        #endregion

        #region OriginCube Creation Tests (Requirements 4.2, 4.3, 4.4)

        /// <summary>
        /// Tests that first TRACKING state creates an OriginCube.
        /// </summary>
        [Test]
        public void FirstTracking_CreatesOriginCube()
        {
            SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);

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

        /// <summary>
        /// Tests that OriginCube has 0.1m scale (10cm cube).
        /// </summary>
        [Test]
        public void FirstTracking_CubeSize_Is01Meters()
        {
            SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);

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

        /// <summary>
        /// Tests that OriginCube localPosition is Vector3.zero.
        /// </summary>
        [Test]
        public void FirstTracking_CubePosition_IsVectorZero()
        {
            SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);

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

        /// <summary>
        /// Tests that OriginCube is parented to areaTargetOrigin.
        /// </summary>
        [Test]
        public void FirstTracking_CubeParentedToAreaTargetOrigin()
        {
            SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);

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

        /// <summary>
        /// Tests that second TRACKING frame does not create a duplicate cube.
        /// </summary>
        [Test]
        public void SecondTracking_DoesNotCreateDuplicateCube()
        {
            SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);

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

        /// <summary>
        /// Tests that OriginCube is visible during TRACKING and hidden during LOST.
        /// </summary>
        [Test]
        public void OriginCube_VisibleDuringTracking_HiddenDuringLost()
        {
            SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);

            // Enter TRACKING — cube should be created and visible
            var trackingResult = new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = 0.9f,
                MatchedFeatures = 100
            };
            InvokeHandleTrackingResult(trackingResult);

            var originCube = GetPrivateField<GameObject>(_manager, "_originCube");
            Assert.IsNotNull(originCube);
            if (!_createdObjects.Contains(originCube))
                _createdObjects.Add(originCube);

            Assert.IsTrue(originCube.activeSelf, "OriginCube should be visible during TRACKING");

            // Transition to LOST — cube should be hidden
            var lostResult = new TrackingResult
            {
                State = TrackingState.LOST,
                Pose = Matrix4x4.identity,
                Confidence = 0f,
                MatchedFeatures = 0
            };
            InvokeHandleTrackingResult(lostResult);

            Assert.IsFalse(originCube.activeSelf, "OriginCube should be hidden during LOST");

            // Re-enter TRACKING — cube should be visible again
            InvokeHandleTrackingResult(trackingResult);

            Assert.IsTrue(originCube.activeSelf, "OriginCube should be visible again after re-tracking");
        }

        #endregion
    }
}
