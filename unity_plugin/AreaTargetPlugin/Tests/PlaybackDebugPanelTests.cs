using System.Collections.Generic;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.UI;
using VideoPlaybackTestScene;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Unit tests for PlaybackDebugPanel.
    /// Validates: Requirements 5.1, 5.2, 5.3, 5.4, 5.5
    /// </summary>
    [TestFixture]
    public class PlaybackDebugPanelTests
    {
        private GameObject _panelGo;
        private PlaybackDebugPanel _panel;
        private Text _statusText;
        private Text _trackingInfoText;
        private Text _frameInfoText;
        private Text _assetInfoText;
        private RawImage _imagePreview;
        private Slider _seekSlider;
        private Slider _speedSlider;
        private Text _speedLabel;
        private List<GameObject> _created;

        [SetUp]
        public void SetUp()
        {
            _created = new List<GameObject>();

            _panelGo = Create("PlaybackDebugPanel");
            _panel = _panelGo.AddComponent<PlaybackDebugPanel>();

            _statusText       = Create("StatusText").AddComponent<Text>();
            _trackingInfoText = Create("TrackingInfoText").AddComponent<Text>();
            _frameInfoText    = Create("FrameInfoText").AddComponent<Text>();
            _assetInfoText    = Create("AssetInfoText").AddComponent<Text>();
            _imagePreview     = Create("ImagePreview").AddComponent<RawImage>();
            _seekSlider       = Create("SeekSlider").AddComponent<Slider>();
            _speedSlider      = Create("SpeedSlider").AddComponent<Slider>();
            _speedLabel       = Create("SpeedLabel").AddComponent<Text>();

            SetField("statusText",       _statusText);
            SetField("trackingInfoText", _trackingInfoText);
            SetField("frameInfoText",    _frameInfoText);
            SetField("assetInfoText",    _assetInfoText);
            SetField("imagePreview",     _imagePreview);
            SetField("seekSlider",       _seekSlider);
            SetField("speedSlider",      _speedSlider);
            SetField("speedLabel",       _speedLabel);
        }

        [TearDown]
        public void TearDown()
        {
            foreach (var go in _created)
                if (go != null) Object.DestroyImmediate(go);
        }

        private GameObject Create(string name)
        {
            var go = new GameObject(name);
            _created.Add(go);
            return go;
        }

        private void SetField(string fieldName, object value)
        {
            var field = typeof(PlaybackDebugPanel)
                .GetField(fieldName, BindingFlags.NonPublic | BindingFlags.Instance);
            field?.SetValue(_panel, value);
        }

        // --- SetFrameInfo ---

        [Test]
        public void SetFrameInfo_FormatsCorrectly()
        {
            _panel.SetFrameInfo(5, 100, "Playing");
            Assert.AreEqual("帧: 5/100 | Playing", _frameInfoText.text);
        }

        [Test]
        public void SetFrameInfo_PausedState_FormatsCorrectly()
        {
            _panel.SetFrameInfo(0, 64, "Paused");
            Assert.AreEqual("帧: 0/64 | Paused", _frameInfoText.text);
        }

        // --- SetTrackingInfo ---

        [Test]
        public void SetTrackingInfo_FormatsCorrectly()
        {
            _panel.SetTrackingInfo(42, 0.85f);
            StringAssert.Contains("42", _trackingInfoText.text);
            StringAssert.Contains("85", _trackingInfoText.text); // 85%
        }

        // --- SetStatus ---

        [Test]
        public void SetStatus_SetsTextAndColor()
        {
            _panel.SetStatus("跟踪中", Color.green);
            Assert.AreEqual("跟踪中", _statusText.text);
            Assert.AreEqual(Color.green, _statusText.color);
        }

        [Test]
        public void SetStatus_RedColor_SetsRed()
        {
            _panel.SetStatus("丢失", Color.red);
            Assert.AreEqual(Color.red, _statusText.color);
        }

        // --- SetAssetInfo ---

        [Test]
        public void SetAssetInfo_FormatsCorrectly()
        {
            _panel.SetAssetInfo("TestAsset", "2.0", 128);
            StringAssert.Contains("TestAsset", _assetInfoText.text);
            StringAssert.Contains("2.0", _assetInfoText.text);
            StringAssert.Contains("128", _assetInfoText.text);
        }

        // --- Clear ---

        [Test]
        public void Clear_SetsAllTextsEmpty()
        {
            _panel.SetStatus("some status", Color.green);
            _panel.SetFrameInfo(5, 10, "Playing");
            _panel.SetTrackingInfo(10, 0.5f);
            _panel.SetAssetInfo("A", "1.0", 10);

            _panel.Clear();

            Assert.AreEqual(string.Empty, _statusText.text);
            Assert.AreEqual(string.Empty, _trackingInfoText.text);
            Assert.AreEqual(string.Empty, _frameInfoText.text);
            Assert.AreEqual(string.Empty, _assetInfoText.text);
        }

        [Test]
        public void Clear_SetsImagePreviewTextureNull()
        {
            var tex = new Texture2D(4, 4);
            _panel.SetPreviewImage(tex);
            _panel.Clear();
            Assert.IsNull(_imagePreview.texture);
            Object.DestroyImmediate(tex);
        }

        // --- SetPreviewImage ---

        [Test]
        public void SetPreviewImage_SetsRawImageTexture()
        {
            var tex = new Texture2D(8, 8);
            _panel.SetPreviewImage(tex);
            Assert.AreEqual(tex, _imagePreview.texture);
            Object.DestroyImmediate(tex);
        }

        // --- SetupSeekSlider / UpdateSeekSlider ---

        [Test]
        public void SetupSeekSlider_SetsMaxValue()
        {
            _panel.SetupSeekSlider(64);
            Assert.AreEqual(63f, _seekSlider.maxValue);
        }

        [Test]
        public void UpdateSeekSlider_SetsSliderValue()
        {
            _panel.SetupSeekSlider(64);
            _panel.UpdateSeekSlider(10);
            Assert.AreEqual(10f, _seekSlider.value);
        }
    }
}
