using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// 在屏幕上显示调试信息，根据跟踪状态切换文字颜色。
/// 包含下载进度、加载状态、跟踪状态、匹配特征数、置信度、FPS 等信息。
/// </summary>
public class DebugPanel : MonoBehaviour
{
    [SerializeField] private Text statusText;
    [SerializeField] private Text progressText;
    [SerializeField] private Text trackingInfoText;
    [SerializeField] private Text fpsText;
    [SerializeField] private Text assetInfoText;

    /// <summary>
    /// 设置状态文字和颜色。
    /// 颜色映射: INITIALIZING → 黄色, TRACKING → 绿色, LOST → 红色
    /// </summary>
    public void SetStatus(string message, Color color)
    {
        if (statusText != null)
        {
            statusText.text = message;
            statusText.color = color;
        }
    }

    /// <summary>
    /// 显示下载进度百分比（如 "下载进度: 75%"）。
    /// </summary>
    /// <param name="progress">进度值 0.0~1.0</param>
    public void SetProgress(float progress)
    {
        if (progressText != null)
        {
            int percent = Mathf.RoundToInt(progress * 100f);
            progressText.text = $"下载进度: {percent}%";
        }
    }

    /// <summary>
    /// 显示匹配特征数和置信度。
    /// </summary>
    public void SetTrackingInfo(int matchedFeatures, float confidence)
    {
        if (trackingInfoText != null)
        {
            trackingInfoText.text = $"匹配特征: {matchedFeatures} | 置信度: {confidence:P0}";
        }
    }

    /// <summary>
    /// 显示资产包名称、版本号和关键帧数量。
    /// </summary>
    public void SetAssetInfo(string name, string version, int keyframeCount)
    {
        if (assetInfoText != null)
        {
            assetInfoText.text = $"资产: {name} | 版本: {version} | 关键帧: {keyframeCount}";
        }
    }

    /// <summary>
    /// 显示帧率。
    /// </summary>
    public void SetFPS(float fps)
    {
        if (fpsText != null)
        {
            fpsText.text = $"FPS: {fps:F1}";
        }
    }

    /// <summary>
    /// 清空所有文字。
    /// </summary>
    public void Clear()
    {
        if (statusText != null) statusText.text = string.Empty;
        if (progressText != null) progressText.text = string.Empty;
        if (trackingInfoText != null) trackingInfoText.text = string.Empty;
        if (fpsText != null) fpsText.text = string.Empty;
        if (assetInfoText != null) assetInfoText.text = string.Empty;
    }
}
