using System;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.UI;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Unit tests for DebugPanel.
    /// Tests progress display formatting, Clear behavior, and tracking info display.
    /// Validates: Requirements 2.2, 5.4, 5.5
    /// </summary>
    [TestFixture]
    public class DebugPanelTests
    {
        private GameObject _panelGo;
        private DebugPanel _debugPanel;
        private Text _statusText;
        private Text _progressText;
        private Text _trackingInfoText;
        private Text _fpsText;
        private Text _assetInfoText;

        [SetUp]
        public void SetUp()
        {
            _panelGo = new GameObject("DebugPanel");
            _debugPanel = _panelGo.AddComponent<DebugPanel>();

            var statusGo = new GameObject("StatusText");
            _statusText = statusGo.AddComponent<Text>();

            var progressGo = new GameObject("ProgressText");
            _progressText = progressGo.AddComponent<Text>();

            var trackingInfoGo = new GameObject("TrackingInfoText");
            _trackingInfoText = trackingInfoGo.AddComponent<Text>();

            var fpsGo = new GameObject("FpsText");
            _fpsText = fpsGo.AddComponent<Text>();

            var assetInfoGo = new GameObject("AssetInfoText");
            _assetInfoText = assetInfoGo.AddComponent<Text>();

            SetPrivateField(_debugPanel, "statusText", _statusText);
            SetPrivateField(_debugPanel, "progressText", _progressText);
            SetPrivateField(_debugPanel, "trackingInfoText", _trackingInfoText);
            SetPrivateField(_debugPanel, "fpsText", _fpsText);
            SetPrivateField(_debugPanel, "assetInfoText", _assetInfoText);
        }

        [TearDown]
        public void TearDown()
        {
            if (_panelGo != null) UnityEngine.Object.DestroyImmediate(_panelGo);
            if (_statusText != null) UnityEngine.Object.DestroyImmediate(_statusText.gameObject);
            if (_progressText != null) UnityEngine.Object.DestroyImmediate(_progressText.gameObject);
            if (_trackingInfoText != null) UnityEngine.Object.DestroyImmediate(_trackingInfoText.gameObject);
            if (_fpsText != null) UnityEngine.Object.DestroyImmediate(_fpsText.gameObject);
            if (_assetInfoText != null) UnityEngine.Object.DestroyImmediate(_assetInfoText.gameObject);
        }

        private static void SetPrivateField(object target, string fieldName, object value)
        {
            var field = target.GetType().GetField(fieldName,
                BindingFlags.NonPublic | BindingFlags.Instance);
            if (field == null)
                throw new InvalidOperationException($"Field '{fieldName}' not found on {target.GetType().Name}");
            field.SetValue(target, value);
        }

        #region SetProgress Tests (Requirement 2.2)

        [Test]
        public void SetProgress_075_DisplaysSeventyFivePercent()
        {
            _debugPanel.SetProgress(0.75f);

            Assert.AreEqual("下载进度: 75%", _progressText.text);
        }

        [Test]
        public void SetProgress_Zero_DisplaysZeroPercent()
        {
            _debugPanel.SetProgress(0f);

            Assert.AreEqual("下载进度: 0%", _progressText.text);
        }

        [Test]
        public void SetProgress_One_DisplaysHundredPercent()
        {
            _debugPanel.SetProgress(1.0f);

            Assert.AreEqual("下载进度: 100%", _progressText.text);
        }

        #endregion

        #region Clear Tests (Requirement 2.2, 5.4, 5.5)

        [Test]
        public void Clear_AllTextFieldsAreEmpty()
        {
            // Set some values first
            _debugPanel.SetStatus("测试状态", Color.green);
            _debugPanel.SetProgress(0.5f);
            _debugPanel.SetTrackingInfo(42, 0.85f);
            _debugPanel.SetFPS(60f);
            _debugPanel.SetAssetInfo("test", "1.0", 100);

            _debugPanel.Clear();

            Assert.AreEqual(string.Empty, _statusText.text);
            Assert.AreEqual(string.Empty, _progressText.text);
            Assert.AreEqual(string.Empty, _trackingInfoText.text);
            Assert.AreEqual(string.Empty, _fpsText.text);
            Assert.AreEqual(string.Empty, _assetInfoText.text);
        }

        #endregion

        #region SetTrackingInfo Tests (Requirement 5.4, 5.5)

        [Test]
        public void SetTrackingInfo_DisplaysFeatureCountAndConfidence()
        {
            _debugPanel.SetTrackingInfo(150, 0.92f);

            string text = _trackingInfoText.text;
            Assert.IsTrue(text.Contains("150"), $"Expected text to contain '150', got: '{text}'");
            Assert.IsTrue(text.Contains("92"), $"Expected text to contain confidence '92', got: '{text}'");
        }

        [Test]
        public void SetTrackingInfo_ZeroFeatures_DisplaysZero()
        {
            _debugPanel.SetTrackingInfo(0, 0f);

            string text = _trackingInfoText.text;
            Assert.IsTrue(text.Contains("0"), $"Expected text to contain '0', got: '{text}'");
        }

        #endregion
    }
}
