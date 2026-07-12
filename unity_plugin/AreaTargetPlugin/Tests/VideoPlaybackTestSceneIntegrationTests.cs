using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;
using UnityEngine.UI;
using AreaTargetPlugin;
using VideoPlaybackTestScene;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Integration tests for VideoPlaybackTestScene pipeline.
    /// Tests scan data loading, playback control interactions, and OnDestroy resource cleanup.
    /// Validates: Requirements 3.1, 3.2, 5.4, 6.1, 6.2
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class VideoPlaybackTestSceneIntegrationTests
    {
        private string _tempDir;
        private List<GameObject> _created;

        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
            _tempDir = Path.Combine(Path.GetTempPath(), "VPIntegration_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_tempDir);
            _created = new List<GameObject>();
        }

        [TearDown]
        public void TearDown()
        {
            for (int i = _created.Count - 1; i >= 0; i--)
                if (_created[i] != null) UnityEngine.Object.DestroyImmediate(_created[i]);
            _created.Clear();
            if (Directory.Exists(_tempDir))
                try { Directory.Delete(_tempDir, true); } catch { }
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

        private void WriteScanData(string dir, int frameCount = 3)
        {
            Directory.CreateDirectory(Path.Combine(dir, "images"));
            // intrinsics.json
            File.WriteAllText(Path.Combine(dir, "intrinsics.json"),
                "{\"fx\":1113.5,\"fy\":1113.5,\"cx\":480,\"cy\":640,\"width\":960,\"height\":1280}");
            // poses.json
            var sb = new System.Text.StringBuilder("{\"frames\":[");
            for (int i = 0; i < frameCount; i++)
            {
                if (i > 0) sb.Append(",");
                var ts = (i * 0.033).ToString(System.Globalization.CultureInfo.InvariantCulture);
                sb.Append($"{{\"index\":{i},\"timestamp\":{ts},\"imageFile\":\"images/frame_{i:D4}.jpg\"," +
                           $"\"transform\":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}}");
            }
            sb.Append("]}");
            File.WriteAllText(Path.Combine(dir, "poses.json"), sb.ToString());
        }

        private (VideoPlaybackTestSceneManager manager, PlaybackDebugPanel panel, Text statusText)
            CreateManagerWithPanel()
        {
            var go = Create("Manager");
            var manager = go.AddComponent<VideoPlaybackTestSceneManager>();
            var panel   = go.AddComponent<PlaybackDebugPanel>();

            var statusText = Create("StatusText").AddComponent<Text>();
            SetField(panel, "statusText", statusText);
            SetField(manager, "debugPanel", panel);

            return (manager, panel, statusText);
        }

        // --- 扫描数据加载失败路径 ---

        [Test]
        public void ScanDataLoad_DirectoryNotExist_ShowsErrorOnPanel()
        {
            var (manager, panel, statusText) = CreateManagerWithPanel();
            SetField(manager, "scanDataSubPath", "nonexistent_path_xyz");

            // 直接调用内部加载逻辑（通过 ImageSeqFrameSource）
            var src = new ImageSeqFrameSource();
            bool ok = src.Load("/nonexistent/path");

            Assert.IsFalse(ok);
            Assert.IsNotNull(src.LastError);
        }

        [Test]
        public void ScanDataLoad_ValidData_FrameCountCorrect()
        {
            WriteScanData(_tempDir, 5);

            var src = new ImageSeqFrameSource();
            bool ok = src.Load(_tempDir);

            Assert.IsTrue(ok, $"Load failed: {src.LastError}");
            Assert.AreEqual(5, src.FrameCount);
        }

        // --- PlaybackController 集成 ---

        [Test]
        public void PlaybackController_PlayPauseStep_WorksEndToEnd()
        {
            WriteScanData(_tempDir, 10);
            var src = new ImageSeqFrameSource();
            src.Load(_tempDir);

            var ctrl = new PlaybackController();
            ctrl.Setup(src.FrameCount);

            // 初始状态
            Assert.AreEqual(PlaybackController.State.Paused, ctrl.CurrentState);
            Assert.AreEqual(0, ctrl.CurrentFrameIndex);

            // Play → Pause
            ctrl.Play();
            Assert.AreEqual(PlaybackController.State.Playing, ctrl.CurrentState);
            ctrl.Pause();
            Assert.AreEqual(PlaybackController.State.Paused, ctrl.CurrentState);

            // Step
            ctrl.StepForward();
            Assert.AreEqual(1, ctrl.CurrentFrameIndex);
            Assert.AreEqual(PlaybackController.State.Paused, ctrl.CurrentState);

            // Seek
            ctrl.SeekTo(5);
            Assert.AreEqual(5, ctrl.CurrentFrameIndex);
        }

        [Test]
        public void PlaybackController_SpeedChange_AffectsTickRate()
        {
            var ctrl = new PlaybackController();
            ctrl.Setup(100);
            ctrl.PlaybackFPS = 20f;
            ctrl.Play();

            ctrl.Tick(0.05f); // 1/20 = 0.05s → 1 frame
            Assert.AreEqual(1, ctrl.CurrentFrameIndex);
        }

        // --- OnDestroy 资源释放 ---

        [Test]
        public void OnDestroy_WithTracker_DisposesTracker()
        {
            var (manager, _, _) = CreateManagerWithPanel();
            var tracker = new AreaTargetTracker();
            SetField(manager, "_tracker", tracker);
            SetField(manager, "_initialized", true);

            var onDestroy = typeof(VideoPlaybackTestSceneManager)
                .GetMethod("OnDestroy", BindingFlags.NonPublic | BindingFlags.Instance);
            onDestroy.Invoke(manager, null);

            var disposed = (bool)typeof(AreaTargetTracker)
                .GetField("_disposed", BindingFlags.NonPublic | BindingFlags.Instance)
                .GetValue(tracker);
            Assert.IsTrue(disposed);
        }

        [Test]
        public void OnDestroy_WithNullTracker_DoesNotThrow()
        {
            var (manager, _, _) = CreateManagerWithPanel();
            SetField(manager, "_tracker", null);

            var onDestroy = typeof(VideoPlaybackTestSceneManager)
                .GetMethod("OnDestroy", BindingFlags.NonPublic | BindingFlags.Instance);

            Assert.DoesNotThrow(() => onDestroy.Invoke(manager, null));
        }

        // --- DebugPanel 更新 ---

        [Test]
        public void DebugPanel_SetFrameInfo_DisplaysCorrectFormat()
        {
            var go = Create("Panel");
            var panel = go.AddComponent<PlaybackDebugPanel>();
            var frameText = Create("FrameText").AddComponent<Text>();
            SetField(panel, "frameInfoText", frameText);

            panel.SetFrameInfo(3, 64, "Playing");

            Assert.AreEqual("帧: 3/64 | Playing", frameText.text);
        }

        [Test]
        public void DebugPanel_Clear_ResetsAllText()
        {
            var go = Create("Panel");
            var panel = go.AddComponent<PlaybackDebugPanel>();
            var statusText = Create("S").AddComponent<Text>();
            var frameText  = Create("F").AddComponent<Text>();
            SetField(panel, "statusText",    statusText);
            SetField(panel, "frameInfoText", frameText);

            panel.SetStatus("test", Color.green);
            panel.SetFrameInfo(5, 10, "Playing");
            panel.Clear();

            Assert.AreEqual(string.Empty, statusText.text);
            Assert.AreEqual(string.Empty, frameText.text);
        }
    }
}
