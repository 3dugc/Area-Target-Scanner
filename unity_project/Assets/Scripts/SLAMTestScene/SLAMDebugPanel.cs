using System.Globalization;
using AreaTargetPlugin;
using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// SLAM 测试场景的调试面板。
/// Awake 时自动给每个 Text 加半透明黑色背景，方便截图阅读。
/// </summary>
public class SLAMDebugPanel : MonoBehaviour
{
    [SerializeField] private Text statusText;
    [SerializeField] private Text trackingInfoText;
    [SerializeField] private Text fpsText;
    [SerializeField] private Text assetInfoText;

    private string _trackingDetail;
    private string _diagnosticSummary;

    void Awake()
    {
        AddBackground(statusText);
        AddBackground(trackingInfoText);
        AddBackground(fpsText);
        AddBackground(assetInfoText);
    }

    private void AddBackground(Text txt)
    {
        if (txt == null || txt.gameObject == null) return;
        var go = txt.gameObject;
        var img = go.GetComponent<Image>();
        if (img == null)
        {
            // Canvas 下才能添加 Image，先检查
            if (go.GetComponentInParent<Canvas>() == null) return;
            img = go.AddComponent<Image>();
        }
        if (img != null) img.color = new Color(0, 0, 0, 0.75f);
        // 确保文字字号足够大
        if (txt.fontSize < 28) txt.fontSize = 28;
    }

    public void SetStatus(string message, Color color)
    {
        if (statusText != null)
        {
            statusText.text = message;
            statusText.color = color;
        }
    }

    public void SetTrackingInfo(int matchedFeatures, float confidence)
    {
        _trackingDetail = $"匹配特征: {matchedFeatures} | 置信度: {Mathf.RoundToInt(confidence * 100f)}%";
        RefreshTrackingText();
    }

    public void SetAssetInfo(string name, string version, int keyframeCount)
    {
        if (assetInfoText != null)
            assetInfoText.text = $"资产: {name} v{version} KF:{keyframeCount}";
    }

    public void SetFPS(float fps)
    {
        if (fpsText != null)
            fpsText.text = $"FPS: {fps:F1}";
    }

    public void SetDetailedTracking(string detail)
    {
        _trackingDetail = detail ?? string.Empty;
        RefreshTrackingText();
    }

    /// <summary>
    /// Shows only the latest operational diagnostic summary. Full pose matrices,
    /// images, and capture payloads are deliberately never rendered here.
    /// </summary>
    public void SetDiagnosticSummary(
        long frameId,
        long resultAgeNs,
        TrackingState state,
        LocalizationQuality quality,
        int inliers,
        long workerProcessingTimeNs)
    {
        _diagnosticSummary =
            $"诊断帧: {frameId} | 结果年龄: {FormatMilliseconds(resultAgeNs)} ms\n" +
            $"状态: {state} | 质量: {quality} | 内点: {inliers} | worker: {FormatMilliseconds(workerProcessingTimeNs)} ms";
        RefreshTrackingText();
    }

    public void Clear()
    {
        _trackingDetail = string.Empty;
        _diagnosticSummary = string.Empty;
        if (statusText != null) statusText.text = string.Empty;
        if (trackingInfoText != null) trackingInfoText.text = string.Empty;
        if (fpsText != null) fpsText.text = string.Empty;
        if (assetInfoText != null) assetInfoText.text = string.Empty;
    }

    private void RefreshTrackingText()
    {
        if (trackingInfoText == null)
            return;

        if (string.IsNullOrEmpty(_trackingDetail))
        {
            trackingInfoText.text = _diagnosticSummary ?? string.Empty;
            return;
        }

        trackingInfoText.text = string.IsNullOrEmpty(_diagnosticSummary)
            ? _trackingDetail
            : _trackingDetail + "\n" + _diagnosticSummary;
    }

    private static string FormatMilliseconds(long nanoseconds)
    {
        double milliseconds = Mathf.Max(0f, nanoseconds / 1_000_000f);
        return milliseconds.ToString("F1", CultureInfo.InvariantCulture);
    }
}
