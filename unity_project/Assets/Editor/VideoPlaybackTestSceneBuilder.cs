using UnityEngine;
using UnityEngine.UI;
using UnityEditor;
using UnityEditor.SceneManagement;
using VideoPlaybackTestScene;

/// <summary>
/// Editor 工具：一键创建 VideoPlaybackTestScene 场景并连接所有 Inspector 引用。
/// 菜单：Tools → VideoPlayback → Build Test Scene
/// </summary>
public static class VideoPlaybackTestSceneBuilder
{
    [MenuItem("Tools/VideoPlayback/Build Test Scene")]
    public static void BuildScene()
    {
        // 创建新场景
        var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);

        // --- 标准 Camera ---
        var cameraGo = new GameObject("Main Camera");
        cameraGo.tag = "MainCamera";
        var cam = cameraGo.AddComponent<Camera>();
        cam.clearFlags = CameraClearFlags.Skybox;
        cam.fieldOfView = 60f;
        cameraGo.AddComponent<AudioListener>();
        cameraGo.transform.position = new Vector3(0, 1, -5);

        // --- Canvas ---
        var canvasGo = new GameObject("Canvas");
        var canvas = canvasGo.AddComponent<Canvas>();
        canvas.renderMode = RenderMode.ScreenSpaceOverlay;
        canvasGo.AddComponent<CanvasScaler>();
        canvasGo.AddComponent<GraphicRaycaster>();

        // --- UI 元素 ---
        var statusText       = CreateText(canvasGo, "StatusText",       new Vector2(0, 1), new Vector2(0, 1), new Vector2(10, -10), new Vector2(400, 60), "初始化中...");
        var trackingInfoText = CreateText(canvasGo, "TrackingInfoText", new Vector2(0, 1), new Vector2(0, 1), new Vector2(10, -80), new Vector2(400, 40), "跟踪信息");
        var frameInfoText    = CreateText(canvasGo, "FrameInfoText",    new Vector2(0, 1), new Vector2(0, 1), new Vector2(10, -130), new Vector2(400, 40), "帧: 0/0 | Paused");
        var assetInfoText    = CreateText(canvasGo, "AssetInfoText",    new Vector2(0, 1), new Vector2(0, 1), new Vector2(10, -180), new Vector2(400, 40), "资产: -");

        // 图像预览（右上角）
        var previewGo = new GameObject("ImagePreview");
        previewGo.transform.SetParent(canvasGo.transform, false);
        var previewRect = previewGo.AddComponent<RectTransform>();
        previewRect.anchorMin = new Vector2(1, 1);
        previewRect.anchorMax = new Vector2(1, 1);
        previewRect.anchoredPosition = new Vector2(-170, -170);
        previewRect.sizeDelta = new Vector2(320, 240);
        var rawImage = previewGo.AddComponent<RawImage>();

        // 播放控件（底部）
        var playBtn  = CreateButton(canvasGo, "PlayButton",  new Vector2(0.1f, 0), new Vector2(0.1f, 0), new Vector2(0, 40), new Vector2(80, 40), "▶ Play");
        var pauseBtn = CreateButton(canvasGo, "PauseButton", new Vector2(0.3f, 0), new Vector2(0.3f, 0), new Vector2(0, 40), new Vector2(80, 40), "⏸ Pause");
        var stepBtn  = CreateButton(canvasGo, "StepButton",  new Vector2(0.5f, 0), new Vector2(0.5f, 0), new Vector2(0, 40), new Vector2(80, 40), "⏭ Step");

        // Seek 滑块
        var seekGo = new GameObject("SeekSlider");
        seekGo.transform.SetParent(canvasGo.transform, false);
        var seekRect = seekGo.AddComponent<RectTransform>();
        seekRect.anchorMin = new Vector2(0, 0);
        seekRect.anchorMax = new Vector2(1, 0);
        seekRect.anchoredPosition = new Vector2(0, 90);
        seekRect.sizeDelta = new Vector2(-20, 30);
        var seekSlider = seekGo.AddComponent<Slider>();

        // Speed 슬라이더 + 라벨
        var speedGo = new GameObject("SpeedSlider");
        speedGo.transform.SetParent(canvasGo.transform, false);
        var speedRect = speedGo.AddComponent<RectTransform>();
        speedRect.anchorMin = new Vector2(0, 0);
        speedRect.anchorMax = new Vector2(0.5f, 0);
        speedRect.anchoredPosition = new Vector2(0, 130);
        speedRect.sizeDelta = new Vector2(-10, 30);
        var speedSlider = speedGo.AddComponent<Slider>();
        speedSlider.minValue = 1f;
        speedSlider.maxValue = 30f;
        speedSlider.value = 10f;

        var speedLabel = CreateText(canvasGo, "SpeedLabel", new Vector2(0.5f, 0), new Vector2(0.5f, 0), new Vector2(50, 130), new Vector2(100, 30), "10 FPS");

        // --- EventSystem ---
        var esGo = new GameObject("EventSystem");
        esGo.AddComponent<UnityEngine.EventSystems.EventSystem>();
        esGo.AddComponent<UnityEngine.EventSystems.StandaloneInputModule>();

        // --- Manager GameObject ---
        var managerGo = new GameObject("VideoPlaybackTestSceneManager");
        var manager = managerGo.AddComponent<VideoPlaybackTestSceneManager>();
        var panel   = managerGo.AddComponent<PlaybackDebugPanel>();

        // 通过反射连接 Manager 的 Inspector 引用
        SetField(manager, "mainCamera",      cam);
        SetField(manager, "debugPanel",      panel);
        SetField(manager, "scanDataSubPath", "ScanData");
        SetField(manager, "assetSubPath",    "SLAMTestAssets");

        // 连接 Panel 的 Inspector 引用
        SetField(panel, "statusText",       statusText);
        SetField(panel, "trackingInfoText", trackingInfoText);
        SetField(panel, "frameInfoText",    frameInfoText);
        SetField(panel, "assetInfoText",    assetInfoText);
        SetField(panel, "imagePreview",     rawImage);
        SetField(panel, "playButton",       playBtn);
        SetField(panel, "pauseButton",      pauseBtn);
        SetField(panel, "stepButton",       stepBtn);
        SetField(panel, "seekSlider",       seekSlider);
        SetField(panel, "speedSlider",      speedSlider);
        SetField(panel, "speedLabel",       speedLabel);

        // 保存场景
        string scenePath = "Assets/Scenes/VideoPlaybackTestScene.unity";
        EditorSceneManager.SaveScene(scene, scenePath);
        AssetDatabase.Refresh();

        Debug.Log($"[VideoPlaybackTestSceneBuilder] 场景已创建: {scenePath}");
        EditorUtility.DisplayDialog("完成", $"VideoPlaybackTestScene 已创建并保存到:\n{scenePath}", "OK");
    }

    private static Text CreateText(GameObject parent, string name,
        Vector2 anchorMin, Vector2 anchorMax, Vector2 pos, Vector2 size, string content)
    {
        var go = new GameObject(name);
        go.transform.SetParent(parent.transform, false);
        var rect = go.AddComponent<RectTransform>();
        rect.anchorMin = anchorMin;
        rect.anchorMax = anchorMax;
        rect.anchoredPosition = pos;
        rect.sizeDelta = size;
        var text = go.AddComponent<Text>();
        text.text = content;
        text.fontSize = 24;
        text.color = Color.white;
        text.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
        return text;
    }

    private static Button CreateButton(GameObject parent, string name,
        Vector2 anchorMin, Vector2 anchorMax, Vector2 pos, Vector2 size, string label)
    {
        var go = new GameObject(name);
        go.transform.SetParent(parent.transform, false);
        var rect = go.AddComponent<RectTransform>();
        rect.anchorMin = anchorMin;
        rect.anchorMax = anchorMax;
        rect.anchoredPosition = pos;
        rect.sizeDelta = size;
        var img = go.AddComponent<Image>();
        img.color = new Color(0.2f, 0.2f, 0.2f, 0.8f);
        var btn = go.AddComponent<Button>();

        var labelGo = new GameObject("Label");
        labelGo.transform.SetParent(go.transform, false);
        var labelRect = labelGo.AddComponent<RectTransform>();
        labelRect.anchorMin = Vector2.zero;
        labelRect.anchorMax = Vector2.one;
        labelRect.sizeDelta = Vector2.zero;
        var text = labelGo.AddComponent<Text>();
        text.text = label;
        text.fontSize = 18;
        text.color = Color.white;
        text.alignment = TextAnchor.MiddleCenter;
        text.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");

        return btn;
    }

    private static void SetField(object target, string fieldName, object value)
    {
        var type = target.GetType();
        System.Reflection.FieldInfo field = null;
        while (type != null && field == null)
        {
            field = type.GetField(fieldName,
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
            type = type.BaseType;
        }
        field?.SetValue(target, value);
    }
}
