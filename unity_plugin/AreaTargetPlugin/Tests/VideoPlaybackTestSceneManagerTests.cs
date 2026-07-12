using System;
using System.Collections.Generic;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.UI;
using UnityEngine.TestTools;
using AreaTargetPlugin;
using VideoPlaybackTestScene;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Unit tests for VideoPlaybackTestSceneManager.
    /// Tests HandleTrackingResult state transitions, OriginCube lifecycle, and OnDestroy.
    /// Validates: Requirements 3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 4.3, 6.1, 6.2
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class VideoPlaybackTestSceneManagerTests
    {
        private GameObject _managerGo;
        private VideoPlaybackTestSceneManager _manager;
        private PlaybackDebugPanel _debugPanel;
        private Text _statusText;
        private Text _trackingInfoText;
        private Text _frameInfoText;
        private Text _assetInfoText;
        private List<GameObject> _created;

        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
            _created = new List<GameObject>();

            _managerGo = Create("VideoPlaybackTestSceneManager");
            _manager = _managerGo.AddComponent<VideoPlaybackTestSceneManager>();

            var panelGo = Create("PlaybackDebugPanel");
            _debugPanel = panelGo.AddComponent<PlaybackDebugPanel>();

            _statusText       = Create("StatusText").AddComponent<Text>();
            _trackingInfoText = Create("TrackingInfoText").AddComponent<Text>();
            _frameInfoText    = Create("FrameInfoText").AddComponent<Text>();
            _assetInfoText    = Create("AssetInfoText").AddComponent<Text>();

            SetField(_debugPanel, "statusText",       _statusText);
            SetField(_debugPanel, "trackingInfoText", _trackingInfoText);
            SetField(_debugPanel, "frameInfoText",    _frameInfoText);
            SetField(_debugPanel, "assetInfoText",    _assetInfoText);

            SetField(_manager, "debugPanel", _debugPanel);
            // 设置初始 _previousState
            SetField(_manager, "_previousState", TrackingState.INITIALIZING);
        }

        [TearDown]
        public void TearDown()
        {
            // 清理 HandleTrackingResult 可能创建的 OriginCube
            var cube = GetField<GameObject>(_manager, "_originCube");
            if (cube != null) _created.Add(cube);

            for (int i = _created.Count - 1; i >= 0; i--)
                if (_created[i] != null) UnityEngine.Object.DestroyImmediate(_created[i]);
            _created.Clear();
        }

        // --- 辅助方法 ---

        private GameObject Create(string name)
        {
            var go = new GameObject(name);
            _created.Add(go);
            return go;
        }

        private static void SetField(object target, string name, object value)
        {
            var t = target.GetType();
            FieldInfo f = null;
            while (t != null && f == null)
            {
                f = t.GetField(name, BindingFlags.NonPublic | BindingFlags.Instance);
                t = t.BaseType;
            }
            if (f == null) throw new InvalidOperationException($"Field '{name}' not found");
            f.SetValue(target, value);
        }

        private static T GetField<T>(object target, string name)
        {
            var t = target.GetType();
            FieldInfo f = null;
            while (t != null && f == null)
            {
                f = t.GetField(name, BindingFlags.NonPublic | BindingFlags.Instance);
                t = t.BaseType;
            }
            if (f == null) throw new InvalidOperationException($"Field '{name}' not found");
            return (T)f.GetValue(target);
        }

        private void InvokeHandleTracking(TrackingResult result, Matrix4x4 cameraPose)
        {
            var m = typeof(VideoPlaybackTestSceneManager).GetMethod(
                "HandleTrackingResult", BindingFlags.NonPublic | BindingFlags.Instance);
            m.Invoke(_manager, new object[] { result, cameraPose });
        }

        private TrackingResult MakeResult(TrackingState state, int matched = 0, float conf = 0f)
            => new TrackingResult { State = state, Pose = Matrix4x4.identity, MatchedFeatures = matched, Confidence = conf };

        private Color GetCubeColor(GameObject cube)
        {
            var r = cube.GetComponent<Renderer>();
            var block = new MaterialPropertyBlock();
            r.GetPropertyBlock(block);
            return block.GetColor("_Color");
        }

        // --- 状态转换测试 ---

        [Test]
        public void HandleTrackingResult_InitializingToTracking_CreatesOriginCube()
        {
            SetField(_manager, "_previousState", TrackingState.INITIALIZING);
            InvokeHandleTracking(MakeResult(TrackingState.TRACKING, 50, 0.9f), Matrix4x4.identity);

            var cube = GetField<GameObject>(_manager, "_originCube");
            Assert.IsNotNull(cube, "OriginCube should be created on first TRACKING");
        }

        [Test]
        public void HandleTrackingResult_Tracking_CubeIsVisible()
        {
            SetField(_manager, "_previousState", TrackingState.INITIALIZING);
            InvokeHandleTracking(MakeResult(TrackingState.TRACKING), Matrix4x4.identity);

            var cube = GetField<GameObject>(_manager, "_originCube");
            Assert.IsTrue(cube.activeSelf, "OriginCube should be active when TRACKING");
        }

        [Test]
        public void HandleTrackingResult_Tracking_CubeIsGreen()
        {
            SetField(_manager, "_previousState", TrackingState.INITIALIZING);
            InvokeHandleTracking(MakeResult(TrackingState.TRACKING), Matrix4x4.identity);

            var cube = GetField<GameObject>(_manager, "_originCube");
            var color = GetCubeColor(cube);
            Assert.AreEqual(Color.green, color, "OriginCube should be green when TRACKING");
        }

        [Test]
        public void HandleTrackingResult_TrackingToLost_CubeIsRed()
        {
            SetField(_manager, "_previousState", TrackingState.INITIALIZING);
            InvokeHandleTracking(MakeResult(TrackingState.TRACKING), Matrix4x4.identity);
            SetField(_manager, "_previousState", TrackingState.TRACKING);
            InvokeHandleTracking(MakeResult(TrackingState.LOST), Matrix4x4.identity);

            var cube = GetField<GameObject>(_manager, "_originCube");
            var color = GetCubeColor(cube);
            Assert.AreEqual(Color.red, color, "OriginCube should be red when LOST");
        }

        [Test]
        public void HandleTrackingResult_TrackingToLost_CubeRemainsVisible()
        {
            SetField(_manager, "_previousState", TrackingState.INITIALIZING);
            InvokeHandleTracking(MakeResult(TrackingState.TRACKING), Matrix4x4.identity);
            SetField(_manager, "_previousState", TrackingState.TRACKING);
            InvokeHandleTracking(MakeResult(TrackingState.LOST), Matrix4x4.identity);

            var cube = GetField<GameObject>(_manager, "_originCube");
            Assert.IsTrue(cube.activeSelf, "OriginCube should remain visible after LOST");
        }

        [Test]
        public void HandleTrackingResult_LostToTracking_CubeBecomesGreenAgain()
        {
            // INIT → TRACKING → LOST → TRACKING
            SetField(_manager, "_previousState", TrackingState.INITIALIZING);
            InvokeHandleTracking(MakeResult(TrackingState.TRACKING), Matrix4x4.identity);
            SetField(_manager, "_previousState", TrackingState.TRACKING);
            InvokeHandleTracking(MakeResult(TrackingState.LOST), Matrix4x4.identity);
            SetField(_manager, "_previousState", TrackingState.LOST);
            InvokeHandleTracking(MakeResult(TrackingState.TRACKING), Matrix4x4.identity);

            var cube = GetField<GameObject>(_manager, "_originCube");
            var color = GetCubeColor(cube);
            Assert.AreEqual(Color.green, color, "OriginCube should be green again after re-tracking");
        }

        [Test]
        public void HandleTrackingResult_Tracking_StatusPanelIsGreen()
        {
            SetField(_manager, "_previousState", TrackingState.INITIALIZING);
            InvokeHandleTracking(MakeResult(TrackingState.TRACKING), Matrix4x4.identity);
            Assert.AreEqual(Color.green, _statusText.color);
        }

        [Test]
        public void HandleTrackingResult_Lost_StatusPanelIsRed()
        {
            SetField(_manager, "_previousState", TrackingState.TRACKING);
            InvokeHandleTracking(MakeResult(TrackingState.LOST), Matrix4x4.identity);
            Assert.AreEqual(Color.red, _statusText.color);
        }

        [Test]
        public void HandleTrackingResult_Initializing_StatusPanelIsYellow()
        {
            SetField(_manager, "_previousState", TrackingState.INITIALIZING);
            InvokeHandleTracking(MakeResult(TrackingState.INITIALIZING), Matrix4x4.identity);
            Assert.AreEqual(Color.yellow, _statusText.color);
        }

        // --- OriginCube 尺寸 ---

        [Test]
        public void OriginCube_Scale_Is10cm()
        {
            SetField(_manager, "_previousState", TrackingState.INITIALIZING);
            InvokeHandleTracking(MakeResult(TrackingState.TRACKING), Matrix4x4.identity);

            var cube = GetField<GameObject>(_manager, "_originCube");
            Assert.That(cube.transform.localScale.x, Is.EqualTo(0.1f).Within(1e-6f));
            Assert.That(cube.transform.localScale.y, Is.EqualTo(0.1f).Within(1e-6f));
            Assert.That(cube.transform.localScale.z, Is.EqualTo(0.1f).Within(1e-6f));
        }

        // --- OnDestroy ---

        [Test]
        public void OnDestroy_DisposesTracker()
        {
            var tracker = new AreaTargetTracker();
            SetField(_manager, "_tracker", tracker);
            SetField(_manager, "_initialized", true);

            var onDestroy = typeof(VideoPlaybackTestSceneManager).GetMethod(
                "OnDestroy", BindingFlags.NonPublic | BindingFlags.Instance);
            onDestroy.Invoke(_manager, null);

            var disposed = (bool)typeof(AreaTargetTracker)
                .GetField("_disposed", BindingFlags.NonPublic | BindingFlags.Instance)
                .GetValue(tracker);
            Assert.IsTrue(disposed, "Tracker should be disposed on OnDestroy");
        }

        [Test]
        public void OnDestroy_SetsTrackerToNull()
        {
            var tracker = new AreaTargetTracker();
            SetField(_manager, "_tracker", tracker);

            var onDestroy = typeof(VideoPlaybackTestSceneManager).GetMethod(
                "OnDestroy", BindingFlags.NonPublic | BindingFlags.Instance);
            onDestroy.Invoke(_manager, null);

            var trackerField = GetField<AreaTargetTracker>(_manager, "_tracker");
            Assert.IsNull(trackerField, "Tracker field should be null after OnDestroy");
        }
    }
}
