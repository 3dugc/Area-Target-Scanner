using System;
using UnityEngine;
using UnityEngine.UI;

namespace VideoPlaybackTestScene
{
    /// <summary>
    /// 视频回放测试场景的调试面板。
    /// 显示帧信息、跟踪状态、图像预览，并提供播放控件。
    /// Validates: Requirements 5.1, 5.2, 5.3, 5.4, 5.5
    /// </summary>
    public class PlaybackDebugPanel : MonoBehaviour
    {
        [Header("状态显示")]
        [SerializeField] private Text statusText;
        [SerializeField] private Text trackingInfoText;
        [SerializeField] private Text frameInfoText;
        [SerializeField] private Text assetInfoText;

        [Header("图像预览")]
        [SerializeField] private RawImage imagePreview;

        [Header("播放控件")]
        [SerializeField] private Button playButton;
        [SerializeField] private Button pauseButton;
        [SerializeField] private Button stepButton;
        [SerializeField] private Slider seekSlider;
        [SerializeField] private Slider speedSlider;
        [SerializeField] private Text speedLabel;

        // 事件回调（由 Manager 订阅）
        public event Action OnPlayClicked;
        public event Action OnPauseClicked;
        public event Action OnStepClicked;
        public event Action<int> OnSeekChanged;
        public event Action<float> OnSpeedChanged;

        private bool _seekSliderDragging;

        void Awake()
        {
            // 绑定按钮事件
            if (playButton != null)
                playButton.onClick.AddListener(() => OnPlayClicked?.Invoke());
            if (pauseButton != null)
                pauseButton.onClick.AddListener(() => OnPauseClicked?.Invoke());
            if (stepButton != null)
                stepButton.onClick.AddListener(() => OnStepClicked?.Invoke());

            // 绑定 seek 滑块
            if (seekSlider != null)
            {
                seekSlider.wholeNumbers = true;
                seekSlider.onValueChanged.AddListener(v =>
                {
                    OnSeekChanged?.Invoke((int)v);
                });
            }

            // 绑定速度滑块（范围 [1, 30]，默认 10）
            if (speedSlider != null)
            {
                speedSlider.minValue = 1f;
                speedSlider.maxValue = 30f;
                speedSlider.value = 10f;
                speedSlider.onValueChanged.AddListener(v =>
                {
                    if (speedLabel != null)
                        speedLabel.text = $"{v:F0} FPS";
                    OnSpeedChanged?.Invoke(v);
                });
            }
        }

        /// <summary>设置状态文字和颜色</summary>
        public void SetStatus(string message, Color color)
        {
            if (statusText == null) return;
            statusText.text = message;
            statusText.color = color;
        }

        /// <summary>显示匹配特征数和置信度</summary>
        public void SetTrackingInfo(int matchedFeatures, float confidence)
        {
            if (trackingInfoText == null) return;
            trackingInfoText.text = $"匹配特征: {matchedFeatures} | 置信度: {confidence:P0}";
        }

        /// <summary>显示帧信息，格式：帧: {current}/{total} | {playbackState}</summary>
        public void SetFrameInfo(int currentFrame, int totalFrames, string playbackState)
        {
            if (frameInfoText == null) return;
            frameInfoText.text = $"帧: {currentFrame}/{totalFrames} | {playbackState}";
        }

        /// <summary>显示资产信息</summary>
        public void SetAssetInfo(string name, string version, int keyframeCount)
        {
            if (assetInfoText == null) return;
            assetInfoText.text = $"资产: {name} v{version} KF:{keyframeCount}";
        }

        /// <summary>设置图像预览纹理</summary>
        public void SetPreviewImage(Texture2D texture)
        {
            if (imagePreview == null) return;
            imagePreview.texture = texture;
        }

        /// <summary>初始化 seek 滑块范围</summary>
        public void SetupSeekSlider(int maxFrames)
        {
            if (seekSlider == null) return;
            seekSlider.minValue = 0;
            seekSlider.maxValue = Mathf.Max(0, maxFrames - 1);
            seekSlider.value = 0;
        }

        /// <summary>更新 seek 滑块当前值（不触发事件）</summary>
        public void UpdateSeekSlider(int currentFrame)
        {
            if (seekSlider == null) return;
            // 临时移除监听器避免循环触发
            seekSlider.onValueChanged.RemoveAllListeners();
            seekSlider.value = currentFrame;
            seekSlider.onValueChanged.AddListener(v => OnSeekChanged?.Invoke((int)v));
        }

        /// <summary>清空所有显示</summary>
        public void Clear()
        {
            if (statusText != null) statusText.text = string.Empty;
            if (trackingInfoText != null) trackingInfoText.text = string.Empty;
            if (frameInfoText != null) frameInfoText.text = string.Empty;
            if (assetInfoText != null) assetInfoText.text = string.Empty;
            if (imagePreview != null) imagePreview.texture = null;
        }
    }
}
