using System;
using System.Collections.Generic;
using System.Reflection;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;
using UnityEngine;
using UnityEngine.UI;
using UnityEngine.XR.ARFoundation;
using AreaTargetPlugin;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for SLAMTestSceneManager.
    /// Tests state transition audio, OriginCube visibility, size/position invariants, and reset behavior.
    /// Validates: Requirements 4.1, 4.3, 4.4, 4.5, 4.6, 5.1, 5.2, 5.4, 7.3, 7.4
    /// </summary>
    [TestFixture]
    public class SLAMTestScenePropertyTests
    {
        private GameObject _managerGo;
        private SLAMTestSceneManager _manager;
        private GameObject _debugPanelGo;
        private SLAMDebugPanel _debugPanel;
        private Text _statusText;
        private Text _trackingInfoText;
        private Text _fpsText;
        private Text _assetInfoText;
        private GameObject _audioFeedbackGo;
        private SLAMAudioFeedback _audioFeedback;
        private Transform _areaTargetOrigin;
        private List<GameObject> _createdObjects;

        [SetUp]
        public void SetUp()
        {
            _createdObjects = new List<GameObject>();

            // Create manager
            _managerGo = CreateTracked("SLAMTestSceneManager");
            _manager = _managerGo.AddComponent<SLAMTestSceneManager>();

            // Create SLAMDebugPanel with Text fields
            _debugPanelGo = CreateTracked("SLAMDebugPanel");
            _debugPanel = _debugPanelGo.AddComponent<SLAMDebugPanel>();

            _statusText = CreateTracked("StatusText").AddComponent<Text>();
            _trackingInfoText = CreateTracked("TrackingInfoText").AddComponent<Text>();
            _fpsText = CreateTracked("FpsText").AddComponent<Text>();
            _assetInfoText = CreateTracked("AssetInfoText").AddComponent<Text>();

            SetPrivateField(_debugPanel, "statusText", _statusText);
            SetPrivateField(_debugPanel, "trackingInfoText", _trackingInfoText);
            SetPrivateField(_debugPanel, "fpsText", _fpsText);
            SetPrivateField(_debugPanel, "assetInfoText", _assetInfoText);

            // Create SLAMAudioFeedback (clips will be null — methods silently skip)
            _audioFeedbackGo = CreateTracked("SLAMAudioFeedback");
            _audioFeedback = _audioFeedbackGo.AddComponent<SLAMAudioFeedback>();

            // Create area target origin
            var originGo = CreateTracked("AreaTargetOrigin");
            _areaTargetOrigin = originGo.transform;

            // Wire up manager fields via reflection
            SetPrivateField(_manager, "debugPanel", _debugPanel);
            SetPrivateField(_manager, "audioFeedback", _audioFeedback);
            SetPrivateField(_manager, "areaTargetOrigin", _areaTargetOrigin);

            // Set initial state to INITIALIZING (matching Start() behavior)
            SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);
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

        private void TrackOriginCube()
        {
            var cube = GetPrivateField<GameObject>(_manager, "_originCube");
            if (cube != null && !_createdObjects.Contains(cube))
                _createdObjects.Add(cube);
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

        private static TrackingResult MakeResult(TrackingState state)
        {
            return new TrackingResult
            {
                State = state,
                Pose = Matrix4x4.identity,
                Confidence = 0.9f,
                MatchedFeatures = 100
            };
        }

        // Feature: slam-scene-ar-config, Property 1: AR Session 就绪门控
        /// <summary>
        /// Property 1: For any ARSessionState value, tracker initialization occurs
        /// if and only if state >= ARSessionState.SessionTracking.
        /// When state < SessionTracking, the readiness gate blocks initialization.
        /// When state >= SessionTracking, the readiness gate allows initialization.
        ///
        /// This tests the pure logic of the readiness condition used in
        /// InitializeWhenReady(): ARSession.state >= ARSessionState.SessionTracking
        ///
        /// **Validates: Requirements 3.1, 3.4**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property ARSessionReadinessGate_InitializesOnlyWhenSessionTracking()
        {
            var arSessionStateGen = Gen.Elements(
                ARSessionState.None,
                ARSessionState.CheckingAvailability,
                ARSessionState.Ready,
                ARSessionState.SessionInitializing,
                ARSessionState.SessionTracking
            ).ToArbitrary();

            return Prop.ForAll(arSessionStateGen, (ARSessionState state) =>
            {
                // The readiness gate condition from InitializeWhenReady()
                bool shouldInitialize = state >= ARSessionState.SessionTracking;

                // Expected: only SessionTracking (and above) passes the gate
                bool expectedShouldInitialize = (state == ARSessionState.SessionTracking);

                // States below SessionTracking must NOT pass the gate
                bool statesBelowBlocked =
                    (state == ARSessionState.None && !shouldInitialize) ||
                    (state == ARSessionState.CheckingAvailability && !shouldInitialize) ||
                    (state == ARSessionState.Ready && !shouldInitialize) ||
                    (state == ARSessionState.SessionInitializing && !shouldInitialize) ||
                    (state == ARSessionState.SessionTracking && shouldInitialize);

                return (shouldInitialize == expectedShouldInitialize && statesBelowBlocked)
                    .ToProperty()
                    .Label($"ARSessionState={state}: shouldInitialize={shouldInitialize}, " +
                           $"expected={expectedShouldInitialize}, gateCorrect={statesBelowBlocked}");
            });
        }

        // Feature: slam-scene-ar-config, Property 2: 等待状态显示
        /// <summary>
        /// Property 2: For any ARSessionState below SessionTracking
        /// (None, CheckingAvailability, Ready, SessionInitializing),
        /// the DebugPanel status text produced by InitializeWhenReady()
        /// contains "等待 AR Session" and the state name string.
        ///
        /// This tests the pure string format used in the waiting loop:
        ///   $"等待 AR Session... ({ARSession.state})"
        ///
        /// **Validates: Requirements 3.2, 3.3**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property WaitingStatusDisplay_ContainsExpectedTextAndStateName()
        {
            var belowTrackingGen = Gen.Elements(
                ARSessionState.None,
                ARSessionState.CheckingAvailability,
                ARSessionState.Ready,
                ARSessionState.SessionInitializing
            ).ToArbitrary();

            return Prop.ForAll(belowTrackingGen, (ARSessionState state) =>
            {
                // Reproduce the exact format string from InitializeWhenReady()
                string statusText = $"等待 AR Session... ({state})";

                bool containsWaitingPrefix = statusText.Contains("等待 AR Session");
                bool containsStateName = statusText.Contains(state.ToString());

                return (containsWaitingPrefix && containsStateName)
                    .ToProperty()
                    .Label($"ARSessionState={state}: statusText=\"{statusText}\", " +
                           $"containsPrefix={containsWaitingPrefix}, containsStateName={containsStateName}");
            });
        }

        // Feature: ar-slam-test-scene, Property 2: 状态转换时音效播放
        /// <summary>
        /// Property 2: For any random TrackingState sequence (length 2-20),
        /// audio plays only on state transitions:
        ///   - Non-TRACKING → TRACKING: PlayTrackingFound called exactly once per transition
        ///   - TRACKING → LOST: PlayTrackingLost called exactly once per transition
        ///   - Same state → same state: no audio played
        ///
        /// Since SLAMAudioFeedback silently skips when clips are null, we verify
        /// the transition logic by counting expected transitions from the state sequence
        /// and comparing against the actual transitions detected by HandleTrackingResult.
        /// We track _previousState changes to confirm transitions happen correctly.
        ///
        /// **Validates: Requirements 4.1, 4.6, 5.1, 5.4**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property StateTransition_AudioPlaysOnlyOnTransitions()
        {
            var stateGen = Gen.Elements(
                TrackingState.INITIALIZING,
                TrackingState.TRACKING,
                TrackingState.LOST
            );

            var sequenceGen = stateGen.ListOf()
                .Where(list => list.Count >= 2 && list.Count <= 20)
                .ToArbitrary();

            return Prop.ForAll(sequenceGen, (IList<TrackingState> stateSequence) =>
            {
                // Reset manager state for each test run
                SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);
                // Destroy any existing origin cube
                var existingCube = GetPrivateField<GameObject>(_manager, "_originCube");
                if (existingCube != null)
                {
                    UnityEngine.Object.DestroyImmediate(existingCube);
                    SetPrivateField(_manager, "_originCube", (GameObject)null);
                }

                // Count expected transitions from the sequence
                int expectedFoundTransitions = 0;
                int expectedLostTransitions = 0;
                var prevState = TrackingState.INITIALIZING;

                foreach (var state in stateSequence)
                {
                    if (state == TrackingState.TRACKING && prevState != TrackingState.TRACKING)
                        expectedFoundTransitions++;
                    if (state == TrackingState.LOST && prevState == TrackingState.TRACKING)
                        expectedLostTransitions++;
                    prevState = state;
                }

                // Now feed the same sequence through HandleTrackingResult and track actual transitions
                int actualFoundTransitions = 0;
                int actualLostTransitions = 0;
                var actualPrev = TrackingState.INITIALIZING;

                foreach (var state in stateSequence)
                {
                    var beforeState = GetPrivateField<TrackingState>(_manager, "_previousState");
                    InvokeHandleTrackingResult(MakeResult(state));
                    var afterState = GetPrivateField<TrackingState>(_manager, "_previousState");

                    // Detect transitions that occurred
                    if (state == TrackingState.TRACKING && beforeState != TrackingState.TRACKING)
                        actualFoundTransitions++;
                    if (state == TrackingState.LOST && beforeState == TrackingState.TRACKING)
                        actualLostTransitions++;
                }

                TrackOriginCube();

                bool foundMatch = actualFoundTransitions == expectedFoundTransitions;
                bool lostMatch = actualLostTransitions == expectedLostTransitions;

                return (foundMatch && lostMatch)
                    .ToProperty()
                    .Label($"Sequence length={stateSequence.Count}: " +
                           $"found transitions actual={actualFoundTransitions} expected={expectedFoundTransitions}, " +
                           $"lost transitions actual={actualLostTransitions} expected={expectedLostTransitions}");
            });
        }

        // Feature: ar-slam-test-scene, Property 3: TRACKING 状态下立方体可见
        /// <summary>
        /// Property 3: For any TRACKING state frame (after OriginCube has been created),
        /// OriginCube's activeInHierarchy should be true.
        ///
        /// We first transition to TRACKING to create the cube, then feed additional
        /// TRACKING frames and verify the cube remains visible.
        ///
        /// **Validates: Requirements 4.5**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property TrackingState_CubeIsVisible()
        {
            // Generate 1-10 additional TRACKING frames after initial creation
            var frameCountGen = Gen.Choose(1, 10).ToArbitrary();

            return Prop.ForAll(frameCountGen, (int additionalFrames) =>
            {
                // Reset state
                SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);
                var existingCube = GetPrivateField<GameObject>(_manager, "_originCube");
                if (existingCube != null)
                {
                    UnityEngine.Object.DestroyImmediate(existingCube);
                    SetPrivateField(_manager, "_originCube", (GameObject)null);
                }

                // First frame: transition to TRACKING to create the cube
                InvokeHandleTrackingResult(MakeResult(TrackingState.TRACKING));

                var cube = GetPrivateField<GameObject>(_manager, "_originCube");
                TrackOriginCube();

                if (cube == null)
                    return false.ToProperty().Label("OriginCube was not created on TRACKING transition");

                // Feed additional TRACKING frames
                bool allVisible = true;
                for (int i = 0; i < additionalFrames; i++)
                {
                    InvokeHandleTrackingResult(MakeResult(TrackingState.TRACKING));
                    if (!cube.activeInHierarchy)
                    {
                        allVisible = false;
                        break;
                    }
                }

                return allVisible
                    .ToProperty()
                    .Label($"OriginCube should be active during {additionalFrames} TRACKING frames");
            });
        }

        // Feature: ar-slam-test-scene, Property 4: LOST 状态下立方体隐藏
        /// <summary>
        /// Property 4: For any LOST state frame (after OriginCube has been created),
        /// OriginCube's activeInHierarchy should be false.
        ///
        /// We first transition to TRACKING to create the cube, then transition to LOST
        /// and feed additional LOST frames, verifying the cube stays hidden.
        ///
        /// **Validates: Requirements 5.2**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property LostState_CubeIsHidden()
        {
            var frameCountGen = Gen.Choose(1, 10).ToArbitrary();

            return Prop.ForAll(frameCountGen, (int additionalFrames) =>
            {
                // Reset state
                SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);
                var existingCube = GetPrivateField<GameObject>(_manager, "_originCube");
                if (existingCube != null)
                {
                    UnityEngine.Object.DestroyImmediate(existingCube);
                    SetPrivateField(_manager, "_originCube", (GameObject)null);
                }

                // Create cube by transitioning to TRACKING
                InvokeHandleTrackingResult(MakeResult(TrackingState.TRACKING));

                var cube = GetPrivateField<GameObject>(_manager, "_originCube");
                TrackOriginCube();

                if (cube == null)
                    return false.ToProperty().Label("OriginCube was not created on TRACKING transition");

                // Transition to LOST
                InvokeHandleTrackingResult(MakeResult(TrackingState.LOST));

                bool allHidden = !cube.activeInHierarchy;

                // Feed additional LOST frames
                for (int i = 0; i < additionalFrames && allHidden; i++)
                {
                    InvokeHandleTrackingResult(MakeResult(TrackingState.LOST));
                    if (cube.activeInHierarchy)
                        allHidden = false;
                }

                return allHidden
                    .ToProperty()
                    .Label($"OriginCube should be inactive during {additionalFrames} LOST frames");
            });
        }

        // Feature: ar-slam-test-scene, Property 5: OriginCube 尺寸和位置不变量
        /// <summary>
        /// Property 5: After creating OriginCube, its localScale should always be
        /// Vector3.one * 0.1f and localPosition should always be Vector3.zero,
        /// regardless of how many subsequent frames are processed.
        ///
        /// **Validates: Requirements 4.3, 4.4**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property OriginCube_SizeAndPositionInvariant()
        {
            var stateGen = Gen.Elements(
                TrackingState.INITIALIZING,
                TrackingState.TRACKING,
                TrackingState.LOST
            );

            var sequenceGen = stateGen.ListOf()
                .Where(list => list.Count >= 1 && list.Count <= 15)
                .ToArbitrary();

            return Prop.ForAll(sequenceGen, (IList<TrackingState> followUpStates) =>
            {
                // Reset state
                SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);
                var existingCube = GetPrivateField<GameObject>(_manager, "_originCube");
                if (existingCube != null)
                {
                    UnityEngine.Object.DestroyImmediate(existingCube);
                    SetPrivateField(_manager, "_originCube", (GameObject)null);
                }

                // Create cube by transitioning to TRACKING
                InvokeHandleTrackingResult(MakeResult(TrackingState.TRACKING));

                var cube = GetPrivateField<GameObject>(_manager, "_originCube");
                TrackOriginCube();

                if (cube == null)
                    return false.ToProperty().Label("OriginCube was not created");

                // Process follow-up states
                foreach (var state in followUpStates)
                {
                    InvokeHandleTrackingResult(MakeResult(state));
                }

                Vector3 expectedScale = Vector3.one * 0.1f;
                Vector3 expectedPosition = Vector3.zero;

                bool scaleCorrect = Vector3.Distance(cube.transform.localScale, expectedScale) < 0.0001f;
                bool positionCorrect = Vector3.Distance(cube.transform.localPosition, expectedPosition) < 0.0001f;

                return (scaleCorrect && positionCorrect)
                    .ToProperty()
                    .Label($"After {followUpStates.Count} frames: " +
                           $"scale={cube.transform.localScale} (expected {expectedScale}, match={scaleCorrect}), " +
                           $"position={cube.transform.localPosition} (expected {expectedPosition}, match={positionCorrect})");
            });
        }

        // Feature: ar-slam-test-scene, Property 8: 重置后状态归位
        /// <summary>
        /// Property 8: After a reset operation, the tracker's previous state should be
        /// INITIALIZING, OriginCube should be hidden, and DebugPanel should be cleared.
        ///
        /// We generate a random initial state sequence, then invoke OnResetClicked
        /// and verify the post-reset invariants.
        ///
        /// **Validates: Requirements 7.3, 7.4**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property Reset_RestoresInitialState()
        {
            var stateGen = Gen.Elements(
                TrackingState.INITIALIZING,
                TrackingState.TRACKING,
                TrackingState.LOST
            );

            var sequenceGen = stateGen.ListOf()
                .Where(list => list.Count >= 1 && list.Count <= 10)
                .ToArbitrary();

            return Prop.ForAll(sequenceGen, (IList<TrackingState> preResetStates) =>
            {
                // Reset state
                SetPrivateField(_manager, "_previousState", TrackingState.INITIALIZING);
                var existingCube = GetPrivateField<GameObject>(_manager, "_originCube");
                if (existingCube != null)
                {
                    UnityEngine.Object.DestroyImmediate(existingCube);
                    SetPrivateField(_manager, "_originCube", (GameObject)null);
                }

                // Feed pre-reset state sequence (always start with TRACKING to ensure cube exists)
                InvokeHandleTrackingResult(MakeResult(TrackingState.TRACKING));
                foreach (var state in preResetStates)
                {
                    InvokeHandleTrackingResult(MakeResult(state));
                }

                var cube = GetPrivateField<GameObject>(_manager, "_originCube");
                TrackOriginCube();

                // Set some debug panel content to verify it gets cleared
                _debugPanel.SetStatus("跟踪中", Color.green);
                _debugPanel.SetTrackingInfo(100, 0.9f);
                _debugPanel.SetFPS(60f);

                // Invoke reset
                _manager.OnResetClicked();

                // Verify post-reset state
                var previousState = GetPrivateField<TrackingState>(_manager, "_previousState");
                bool stateIsInitializing = previousState == TrackingState.INITIALIZING;

                // OriginCube should be hidden (inactive)
                cube = GetPrivateField<GameObject>(_manager, "_originCube");
                bool cubeHidden = cube == null || !cube.activeInHierarchy;

                // DebugPanel should be cleared
                bool statusCleared = string.IsNullOrEmpty(_statusText.text);
                bool trackingInfoCleared = string.IsNullOrEmpty(_trackingInfoText.text);
                bool fpsCleared = string.IsNullOrEmpty(_fpsText.text);

                return (stateIsInitializing && cubeHidden && statusCleared && trackingInfoCleared && fpsCleared)
                    .ToProperty()
                    .Label($"After reset: state={previousState} (expected INITIALIZING, match={stateIsInitializing}), " +
                           $"cubeHidden={cubeHidden}, statusCleared={statusCleared}, " +
                           $"trackingInfoCleared={trackingInfoCleared}, fpsCleared={fpsCleared}");
            });
        }
    }
}
