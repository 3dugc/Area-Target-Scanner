using System;
using System.Collections;
using System.Collections.Generic;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.UI;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for DownloadTestSceneManager.
    /// Uses NUnit TestCaseSource with programmatic data generation to verify
    /// properties across many inputs (following the PnPPropertyTests pattern).
    ///
    /// Properties tested:
    ///   1: Download button interactable matches scene state
    ///   2: Empty/whitespace URL rejection
    ///   9: OriginCube active during TRACKING
    ///  10: OriginCube position frozen during LOST
    ///  11: Old tracker disposed on re-download
    /// </summary>
    [TestFixture]
    public class DownloadTestSceneManagerPropertyTests
    {
        private GameObject _managerGo;
        private DownloadTestSceneManager _manager;
        private Button _downloadButton;
        private InputField _urlInputField;
        private DebugPanel _debugPanel;
        private Text _statusText;
        private Transform _areaTargetOrigin;
        private List<GameObject> _createdObjects;

        [SetUp]
        public void SetUp()
        {
            _createdObjects = new List<GameObject>();

            _managerGo = CreateTracked("DownloadTestSceneManager");
            _manager = _managerGo.AddComponent<DownloadTestSceneManager>();

            var buttonGo = CreateTracked("DownloadButton");
            _downloadButton = buttonGo.AddComponent<Button>();

            var inputGo = CreateTracked("UrlInputField");
            _urlInputField = inputGo.AddComponent<InputField>();
            var inputTextGo = CreateTracked("InputText");
            inputTextGo.transform.SetParent(inputGo.transform);
            var inputText = inputTextGo.AddComponent<Text>();
            _urlInputField.textComponent = inputText;

            var panelGo = CreateTracked("DebugPanel");
            _debugPanel = panelGo.AddComponent<DebugPanel>();
            var statusGo = CreateTracked("StatusText");
            _statusText = statusGo.AddComponent<Text>();
            SetPrivateField(_debugPanel, "statusText", _statusText);

            var originGo = CreateTracked("AreaTargetOrigin");
            _areaTargetOrigin = originGo.transform;

            SetPrivateField(_manager, "urlInputField", _urlInputField);
            SetPrivateField(_manager, "downloadButton", _downloadButton);
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

        private void InvokeUpdateButtonStates()
        {
            var method = typeof(DownloadTestSceneManager).GetMethod("UpdateButtonStates",
                BindingFlags.NonPublic | BindingFlags.Instance);
            method.Invoke(_manager, null);
        }

        private void InvokeHandleTrackingResult(TrackingResult result)
        {
            var method = typeof(DownloadTestSceneManager).GetMethod("HandleTrackingResult",
                BindingFlags.NonPublic | BindingFlags.Instance);
            method.Invoke(_manager, new object[] { result });
        }

        private static bool IsTrackerDisposed(AreaTargetTracker tracker)
        {
            var field = typeof(AreaTargetTracker).GetField("_disposed",
                BindingFlags.NonPublic | BindingFlags.Instance);
            return (bool)field.GetValue(tracker);
        }


        // =================================================================
        // Property 1: 下载按钮状态与场景状态一致
        // Feature: ar-download-test-scene, Property 1
        // =================================================================

        /// <summary>
        /// Generates test cases for all SceneState enum values.
        /// </summary>
        private static IEnumerable<TestCaseData> AllSceneStateCases()
        {
            foreach (SceneState state in Enum.GetValues(typeof(SceneState)))
            {
                bool expected = (state == SceneState.Idle || state == SceneState.Error);
                yield return new TestCaseData(state, expected)
                    .SetName($"P1_ButtonState_{state}_Interactable{expected}");
            }
        }

        /// <summary>
        /// Property 1: For any SceneState value, the download button's interactable
        /// property equals (state == Idle || state == Error).
        /// Button is only clickable in Idle or Error; disabled during
        /// Downloading, Extracting, Loading, and Tracking.
        ///
        /// **Validates: Requirements 1.4, 1.5**
        /// </summary>
        [Test, TestCaseSource(nameof(AllSceneStateCases))]
        public void P1_DownloadButton_InteractableMatchesSceneState(SceneState state, bool expectedInteractable)
        {
            SetCurrentState(state);
            InvokeUpdateButtonStates();

            Assert.AreEqual(expectedInteractable, _downloadButton.interactable,
                $"State={state}: button.interactable should be {expectedInteractable}");
        }


        // =================================================================
        // Property 2: 空 URL 拒绝
        // Feature: ar-download-test-scene, Property 2
        // =================================================================

        /// <summary>
        /// Generates random whitespace-only strings (spaces, tabs, newlines)
        /// of varying lengths, including empty string.
        /// </summary>
        private static IEnumerable<TestCaseData> WhitespaceUrlCases()
        {
            var rng = new System.Random(42);
            char[] wsChars = { ' ', '\t', '\n', '\r' };

            // Empty string
            yield return new TestCaseData("").SetName("P2_EmptyUrl_Empty");

            // Generate 100 random whitespace strings
            for (int i = 0; i < 100; i++)
            {
                int len = rng.Next(1, 21);
                char[] chars = new char[len];
                for (int j = 0; j < len; j++)
                    chars[j] = wsChars[rng.Next(wsChars.Length)];
                string ws = new string(chars);
                yield return new TestCaseData(ws)
                    .SetName($"P2_WhitespaceUrl_Len{len}_Case{i}");
            }
        }

        /// <summary>
        /// Property 2: For any whitespace-only string used as URL input,
        /// OnDownloadClicked should reject the download, keep state as Idle,
        /// and display "请输入有效的 URL" in the DebugPanel.
        ///
        /// **Validates: Requirements 2.4**
        /// </summary>
        [Test, TestCaseSource(nameof(WhitespaceUrlCases))]
        public void P2_EmptyUrl_RejectedAndStateUnchanged(string whitespaceUrl)
        {
            SetCurrentState(SceneState.Idle);
            _statusText.text = string.Empty;
            _urlInputField.text = whitespaceUrl;

            _manager.OnDownloadClicked();

            Assert.AreEqual(SceneState.Idle, _manager.CurrentState,
                "State should remain Idle after whitespace URL");
            Assert.IsTrue(_statusText.text.Contains("请输入有效的 URL"),
                $"Status text should contain error message, got: '{_statusText.text}'");
        }


        // =================================================================
        // Property 9: 跟踪状态下立方体可见
        // Feature: ar-download-test-scene, Property 9
        // =================================================================

        /// <summary>
        /// Generates random TRACKING frame parameters (matchedFeatures, confidence).
        /// </summary>
        private static IEnumerable<TestCaseData> TrackingFrameCases()
        {
            var rng = new System.Random(99);
            for (int i = 0; i < 100; i++)
            {
                int features = rng.Next(1, 501);
                float confidence = (float)(rng.NextDouble());
                yield return new TestCaseData(features, confidence)
                    .SetName($"P9_TrackingCube_Features{features}_Conf{confidence:F2}");
            }
        }

        /// <summary>
        /// Property 9: When HandleTrackingResult is called with a TRACKING result,
        /// the OriginCube should be active (activeInHierarchy == true).
        ///
        /// **Validates: Requirements 6.4**
        /// </summary>
        [Test, TestCaseSource(nameof(TrackingFrameCases))]
        public void P9_TrackingState_OriginCubeIsActive(int matchedFeatures, float confidence)
        {
            SetCurrentState(SceneState.Tracking);

            var result = new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = confidence,
                MatchedFeatures = matchedFeatures
            };

            InvokeHandleTrackingResult(result);

            var originCube = GetPrivateField<GameObject>(_manager, "_originCube");
            Assert.IsNotNull(originCube, "OriginCube should be created after TRACKING frame");
            Assert.IsTrue(originCube.activeInHierarchy,
                "OriginCube should be active during TRACKING state");

            // Track for cleanup
            if (!_createdObjects.Contains(originCube))
                _createdObjects.Add(originCube);
        }


        // =================================================================
        // Property 10: 丢失状态下立方体位置冻结
        // Feature: ar-download-test-scene, Property 10
        // =================================================================

        /// <summary>
        /// Generates random initial positions and LOST frame sequence lengths.
        /// </summary>
        private static IEnumerable<TestCaseData> LostFrameFreezeCases()
        {
            var rng = new System.Random(77);
            for (int i = 0; i < 100; i++)
            {
                float px = (float)((rng.NextDouble() - 0.5) * 20.0);
                float py = (float)((rng.NextDouble() - 0.5) * 20.0);
                float pz = (float)((rng.NextDouble() - 0.5) * 20.0);
                int lostFrames = rng.Next(1, 11);
                yield return new TestCaseData(px, py, pz, lostFrames)
                    .SetName($"P10_LostFreeze_Pos({px:F1},{py:F1},{pz:F1})_Frames{lostFrames}");
            }
        }

        /// <summary>
        /// Property 10: For any random initial position and a sequence of LOST frames,
        /// the OriginCube's localPosition and localRotation remain unchanged
        /// (frozen at the last known value before LOST).
        ///
        /// **Validates: Requirements 6.5**
        /// </summary>
        [Test, TestCaseSource(nameof(LostFrameFreezeCases))]
        public void P10_LostState_OriginCubePositionFrozen(float px, float py, float pz, int lostFrameCount)
        {
            SetCurrentState(SceneState.Tracking);

            // First simulate a TRACKING frame to create the OriginCube
            var trackingResult = new TrackingResult
            {
                State = TrackingState.TRACKING,
                Pose = Matrix4x4.identity,
                Confidence = 0.9f,
                MatchedFeatures = 100
            };
            InvokeHandleTrackingResult(trackingResult);

            var originCube = GetPrivateField<GameObject>(_manager, "_originCube");
            Assert.IsNotNull(originCube, "OriginCube should exist after TRACKING frame");
            if (!_createdObjects.Contains(originCube))
                _createdObjects.Add(originCube);

            // Set a known initial position and rotation
            Vector3 initialPos = new Vector3(px, py, pz);
            Quaternion initialRot = Quaternion.Euler(px * 10f, py * 10f, pz * 10f);
            originCube.transform.localPosition = initialPos;
            originCube.transform.localRotation = initialRot;

            // Simulate multiple LOST frames
            var lostResult = new TrackingResult
            {
                State = TrackingState.LOST,
                Pose = Matrix4x4.identity,
                Confidence = 0f,
                MatchedFeatures = 0
            };

            for (int i = 0; i < lostFrameCount; i++)
            {
                InvokeHandleTrackingResult(lostResult);

                Vector3 currentPos = originCube.transform.localPosition;
                Quaternion currentRot = originCube.transform.localRotation;

                Assert.That(Vector3.Distance(currentPos, initialPos), Is.LessThan(0.0001f),
                    $"Position changed after LOST frame {i}: expected {initialPos}, got {currentPos}");
                Assert.That(Quaternion.Angle(currentRot, initialRot), Is.LessThan(0.01f),
                    $"Rotation changed after LOST frame {i}");
            }
        }


        // =================================================================
        // Property 11: 重新下载前释放旧资源
        // Feature: ar-download-test-scene, Property 11
        // =================================================================

        /// <summary>
        /// Generates random re-download sequence counts (2 to 5).
        /// </summary>
        private static IEnumerable<TestCaseData> ReDownloadSequenceCases()
        {
            for (int count = 2; count <= 5; count++)
            {
                // Multiple iterations per count for broader coverage
                for (int trial = 0; trial < 25; trial++)
                {
                    yield return new TestCaseData(count)
                        .SetName($"P11_ReDownload_Count{count}_Trial{trial}");
                }
            }
        }

        /// <summary>
        /// Property 11: When a new download is triggered while a tracker is active,
        /// the old tracker must be Disposed before the new download starts.
        /// At any point in time, there should be at most one active tracker.
        ///
        /// We inject real (uninitialized) AreaTargetTracker instances and verify
        /// each is disposed when OnDownloadClicked is called with a valid URL.
        ///
        /// **Validates: Requirements 7.4**
        /// </summary>
        [Test, TestCaseSource(nameof(ReDownloadSequenceCases))]
        public void P11_ReDownload_DisposesOldTracker(int sequenceCount)
        {
            // Ensure _downloadManager is initialized
            var existingDm = GetPrivateField<DownloadManager>(_manager, "_downloadManager");
            if (existingDm == null)
            {
                var dm = new DownloadManager(_manager);
                SetPrivateField(_manager, "_downloadManager", dm);
            }

            var oldTrackers = new List<AreaTargetTracker>();

            for (int i = 0; i < sequenceCount; i++)
            {
                // Create a real (uninitialized) tracker and inject it
                var oldTracker = new AreaTargetTracker();
                oldTrackers.Add(oldTracker);
                SetPrivateField(_manager, "_tracker", oldTracker);

                SetCurrentState(SceneState.Tracking);
                _urlInputField.text = "https://example.com/test.zip";

                // Trigger new download — should dispose old tracker first
                _manager.OnDownloadClicked();

                Assert.IsTrue(IsTrackerDisposed(oldTracker),
                    $"Old tracker {i} should be disposed after OnDownloadClicked");
            }

            // Verify all old trackers are disposed
            for (int i = 0; i < oldTrackers.Count; i++)
            {
                Assert.IsTrue(IsTrackerDisposed(oldTrackers[i]),
                    $"Tracker {i} should be disposed");
            }

            // Clean up
            SetPrivateField(_manager, "_tracker", null);
            var downloadDir = GetPrivateField<string>(_manager, "_currentDownloadDir");
            if (!string.IsNullOrEmpty(downloadDir) && System.IO.Directory.Exists(downloadDir))
            {
                try { System.IO.Directory.Delete(downloadDir, true); }
                catch { /* ignore cleanup errors */ }
            }
        }
    }
}
