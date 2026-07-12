using System;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.UI;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Unit tests for SLAMDebugPanel.
    /// Tests tracking info display, Clear behavior, and FPS display.
    /// Validates: Requirements 3.4, 3.5
    /// </summary>
    [TestFixture]
    public class SLAMDebugPanelTests
    {
        private GameObject _panelGo;
        private SLAMDebugPanel _debugPanel;
        private Text _statusText;
        private Text _trackingInfoText;
        private Text _fpsText;
        private Text _assetInfoText;

        [SetUp]
        public void SetUp()
        {
            _panelGo = new GameObject("SLAMDebugPanel");
            _debugPanel = _panelGo.AddComponent<SLAMDebugPanel>();

            var statusGo = new GameObject("StatusText");
            _statusText = statusGo.AddComponent<Text>();

            var trackingInfoGo = new GameObject("TrackingInfoText");
            _trackingInfoText = trackingInfoGo.AddComponent<Text>();

            var fpsGo = new GameObject("FpsText");
            _fpsText = fpsGo.AddComponent<Text>();

            var assetInfoGo = new GameObject("AssetInfoText");
            _assetInfoText = assetInfoGo.AddComponent<Text>();

            SetPrivateField(_debugPanel, "statusText", _statusText);
            SetPrivateField(_debugPanel, "trackingInfoText", _trackingInfoText);
            SetPrivateField(_debugPanel, "fpsText", _fpsText);
            SetPrivateField(_debugPanel, "assetInfoText", _assetInfoText);
        }

        [TearDown]
        public void TearDown()
        {
            if (_panelGo != null) UnityEngine.Object.DestroyImmediate(_panelGo);
            if (_statusText != null) UnityEngine.Object.DestroyImmediate(_statusText.gameObject);
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

        #region SetTrackingInfo Tests (Requirement 3.4)

        [Test]
        public void SetTrackingInfo_42Features_85Percent_DisplaysCorrectValues()
        {
            _debugPanel.SetTrackingInfo(42, 0.85f);

            string text = _trackingInfoText.text;
            Assert.IsTrue(text.Contains("42"), $"Expected text to contain '42', got: '{text}'");
            Assert.IsTrue(text.Contains("85%"), $"Expected text to contain '85%', got: '{text}'");
        }

        #endregion

        #region Clear Tests (Requirement 3.4, 3.5)

        [Test]
        public void Clear_AfterSettingValues_AllTextFieldsAreEmpty()
        {
            _debugPanel.SetStatus("跟踪中", Color.green);
            _debugPanel.SetTrackingInfo(42, 0.85f);
            _debugPanel.SetFPS(60f);
            _debugPanel.SetAssetInfo("test", "2.0", 50);

            _debugPanel.Clear();

            Assert.AreEqual(string.Empty, _statusText.text);
            Assert.AreEqual(string.Empty, _trackingInfoText.text);
            Assert.AreEqual(string.Empty, _fpsText.text);
            Assert.AreEqual(string.Empty, _assetInfoText.text);
        }

        #endregion

        #region SetFPS Tests (Requirement 3.5)

        [Test]
        public void SetFPS_60_DisplaysFPS60()
        {
            _debugPanel.SetFPS(60.0f);

            Assert.AreEqual("FPS: 60.0", _fpsText.text);
        }

        #endregion
    }
}
