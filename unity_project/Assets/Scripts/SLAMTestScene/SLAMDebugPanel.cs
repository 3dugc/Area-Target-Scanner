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
        if (trackingInfoText != null)
            trackingInfoText.text = $"匹配特征: {matchedFeatures} | 置信度: {Mathf.RoundToInt(confidence * 100f)}%";
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
        if (trackingInfoText != null)
            trackingInfoText.text = detail;
    }

    public void Clear()
    {
        if (statusText != null) statusText.text = string.Empty;
        if (trackingInfoText != null) trackingInfoText.text = string.Empty;
        if (fpsText != null) fpsText.text = string.Empty;
        if (assetInfoText != null) assetInfoText.text = string.Empty;
    }
}
