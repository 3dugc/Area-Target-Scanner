using UnityEngine;

/// <summary>
/// 在运行时将 RectTransform 调整到设备 Safe Area 内，
/// 避免 Dynamic Island / 刘海 / Home Indicator 遮挡 UI。
/// 挂载到 Canvas 下的一个全屏 Panel 上，所有 UI 元素作为其子物体。
/// </summary>
[RequireComponent(typeof(RectTransform))]
public class SafeAreaHelper : MonoBehaviour
{
    private RectTransform _rect;
    private Rect _lastSafeArea;
    private ScreenOrientation _lastOrientation;

    void Awake()
    {
        _rect = GetComponent<RectTransform>();
        _lastOrientation = Screen.orientation;
        ApplySafeArea();
    }

    void Update()
    {
        if (_lastSafeArea != Screen.safeArea || _lastOrientation != Screen.orientation)
        {
            _lastOrientation = Screen.orientation;
            ApplySafeArea();
        }
    }

    void ApplySafeArea()
    {
        Rect safeArea = Screen.safeArea;
        _lastSafeArea = safeArea;

        // 计算 anchor
        Vector2 anchorMin = safeArea.position;
        Vector2 anchorMax = safeArea.position + safeArea.size;

        int w = Screen.width;
        int h = Screen.height;

        if (w > 0 && h > 0)
        {
            anchorMin.x /= w;
            anchorMin.y /= h;
            anchorMax.x /= w;
            anchorMax.y /= h;
        }
        else
        {
            anchorMin = Vector2.zero;
            anchorMax = Vector2.one;
        }

        // 确保至少有合理的顶部边距（针对 Dynamic Island 设备）
        // iPhone 17 Pro: safeArea top inset ~59pt / 932pt ≈ 0.063
        float minTopInset = 0.06f;
        if ((1f - anchorMax.y) < minTopInset)
        {
            anchorMax.y = 1f - minTopInset;
        }

        // 底部也保留一点给 Home Indicator
        float minBottomInset = 0.035f;
        if (anchorMin.y < minBottomInset)
        {
            anchorMin.y = minBottomInset;
        }

        _rect.anchorMin = anchorMin;
        _rect.anchorMax = anchorMax;

        // 清除 offset，完全由 anchor 控制
        _rect.offsetMin = Vector2.zero;
        _rect.offsetMax = Vector2.zero;

        Debug.Log($"[SafeArea] screen={w}x{h} safeArea={safeArea} anchor=({anchorMin.x:F3},{anchorMin.y:F3})-({anchorMax.x:F3},{anchorMax.y:F3})");
    }
}
