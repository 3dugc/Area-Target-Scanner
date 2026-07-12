using System;
using System.Collections;
using UnityEngine;
using UnityEngine.UI;
using UnityEngine.XR.ARFoundation;
using UnityEngine.XR.ARSubsystems;
using AreaTargetPlugin;

/// <summary>
/// 场景状态枚举，表示下载测试场景的当前阶段。
/// </summary>
public enum SceneState
{
    Idle,           // 等待用户输入
    Downloading,    // 正在下载
    Extracting,     // 正在解压
    Loading,        // 正在加载资产包
    Tracking,       // AR 跟踪中
    Error           // 发生错误
}

/// <summary>
/// 下载测试场景主控制器，协调 UI、下载、解压、加载、跟踪的完整流程。
/// 参考 ARTestSceneManager 的 MonoBehaviour 模式。
/// </summary>
public class DownloadTestSceneManager : MonoBehaviour
{
    [Header("UI 组件")]
    [SerializeField] private InputField urlInputField;
    [SerializeField] private Button downloadButton;
    [SerializeField] private Button resetButton;
    [SerializeField] private DebugPanel debugPanel;

    [Header("AR 组件")]
    [SerializeField] private ARCameraManager arCameraManager;
    [SerializeField] private Transform areaTargetOrigin;

    // 内部组件
    private DownloadManager _downloadManager;
    private ZipExtractor _zipExtractor;
    private AssetBundleLoader _assetBundleLoader;
    private AreaTargetTracker _tracker;

    // 当前下载目录路径，用于后续清理
    private string _currentDownloadDir;

    // FPS 计算
    private float _fpsTimer;
    private int _fpsFrameCount;

    // OriginCube — 将在 task 5.4 中创建，此处仅声明引用
    private GameObject _originCube;

    // 最后已知跟踪位姿，用于 LOST 状态下保持 OriginCube 位置
    private Matrix4x4 _lastTrackingPose;

    // 场景状态
    public SceneState CurrentState { get; private set; }

    void Start()
    {
        CurrentState = SceneState.Idle;

        _downloadManager = new DownloadManager(this);
        _zipExtractor = new ZipExtractor();
        _assetBundleLoader = new AssetBundleLoader();

        if (downloadButton != null)
            downloadButton.onClick.AddListener(OnDownloadClicked);

        if (resetButton != null)
            resetButton.onClick.AddListener(OnResetClicked);

        // 在模拟器/编辑器中预填默认 URL，方便测试
#if UNITY_EDITOR || UNITY_IOS
        if (urlInputField != null && string.IsNullOrEmpty(urlInputField.text))
        {
            // 优先级: 环境变量 > 命令行参数 > 硬编码默认值
            string defaultUrl = System.Environment.GetEnvironmentVariable("DOWNLOAD_TEST_URL");

            if (string.IsNullOrEmpty(defaultUrl))
            {
                // 检查命令行参数 -url
                var args = System.Environment.GetCommandLineArgs();
                for (int i = 0; i < args.Length - 1; i++)
                {
                    if (args[i] == "-url")
                    {
                        defaultUrl = args[i + 1];
                        break;
                    }
                }
            }

            if (string.IsNullOrEmpty(defaultUrl))
            {
                // 本地 HTTP 服务器提供 asset bundle（模拟器可通过 localhost 访问 Mac）
                defaultUrl = "http://localhost:8888/asset_bundle_ede87ec5.zip";
            }

            urlInputField.text = defaultUrl;
            Debug.Log($"[DownloadTestScene] 预填 URL: {defaultUrl}");
        }
#endif

        UpdateButtonStates();

        Debug.Log("[DownloadTestScene] 场景初始化完成，等待用户输入 URL");

        // 模拟器/设备上自动触发下载（绕过 UI 点击无响应的问题）
        // 使用运行时检查而非编译时条件，确保在 IL2CPP 构建中也能工作
        if (!Application.isEditor)
        {
            StartCoroutine(AutoStartDownload());
        }
    }

    /// <summary>
    /// 在 iOS 模拟器/设备上自动触发下载，延迟 2 秒等待场景完全加载。
    /// </summary>
    private IEnumerator AutoStartDownload()
    {
        Debug.Log("[DownloadTestScene] 自动下载模式：等待 2 秒后开始...");
        debugPanel?.SetStatus("自动下载：等待 2 秒...", Color.cyan);
        yield return new WaitForSeconds(2f);

        if (CurrentState == SceneState.Idle && urlInputField != null && !string.IsNullOrEmpty(urlInputField.text))
        {
            Debug.Log($"[DownloadTestScene] 自动触发下载: {urlInputField.text}");
            debugPanel?.SetStatus($"自动下载: {urlInputField.text}", Color.cyan);
            OnDownloadClicked();
        }
        else
        {
            string reason = CurrentState != SceneState.Idle ? $"状态={CurrentState}" :
                            urlInputField == null ? "urlInputField=null" :
                            $"URL为空";
            Debug.LogWarning($"[DownloadTestScene] 自动下载跳过：{reason}");
            debugPanel?.SetStatus($"自动下载跳过: {reason}", Color.yellow);
        }
    }

    /// <summary>
    /// 验证 URL → 下载 → 解压 → 加载 → 初始化跟踪。
    /// </summary>
    public void OnDownloadClicked()
    {
        // 1. Validate URL is non-empty
        string url = urlInputField != null ? urlInputField.text : string.Empty;
        if (string.IsNullOrWhiteSpace(url))
        {
            debugPanel?.SetStatus("请输入有效的 URL", Color.red);
            return;
        }

        // 2. If there's an active tracker, dispose old resources first
        if (_tracker != null)
        {
            _tracker.Dispose();
            _tracker = null;
        }

        // 3. Disable download button, set state to Downloading
        CurrentState = SceneState.Downloading;
        UpdateButtonStates();

        // Build download paths using timestamp for isolation
        string timestamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        _currentDownloadDir = System.IO.Path.Combine(Application.persistentDataPath, "DownloadedAreaTargets", timestamp);
        System.IO.Directory.CreateDirectory(_currentDownloadDir);

        string zipPath = System.IO.Path.Combine(_currentDownloadDir, "asset_bundle.zip");
        string extractedDir = System.IO.Path.Combine(_currentDownloadDir, "extracted");

        debugPanel?.SetStatus("正在下载...", Color.white);

        // 4. Start download with progress callback
        _downloadManager.StartDownload(url, zipPath,
            onProgress: (progress) =>
            {
                debugPanel?.SetProgress(progress);
            },
            onComplete: (filePath) =>
            {
                debugPanel?.SetStatus("下载完成", Color.white);
                OnDownloadComplete(filePath, extractedDir);
            },
            onError: (error) =>
            {
                debugPanel?.SetStatus(error, Color.red);
                CurrentState = SceneState.Error;
                UpdateButtonStates();
            }
        );
    }

    /// <summary>
    /// 下载完成后的处理：解压 → 验证 → 加载 → 初始化跟踪。
    /// </summary>
    private void OnDownloadComplete(string zipFilePath, string extractedDir)
    {
        // 5. Set state to Extracting, call ZipExtractor.Extract
        CurrentState = SceneState.Extracting;
        UpdateButtonStates();
        debugPanel?.SetStatus("正在解压...", Color.white);

        bool extractSuccess = _zipExtractor.Extract(zipFilePath, extractedDir);
        if (!extractSuccess)
        {
            debugPanel?.SetStatus($"解压失败: {_zipExtractor.LastError}", Color.red);
            CurrentState = SceneState.Error;
            UpdateButtonStates();
            return;
        }

        // 6. Validate required files
        var (isValid, missingFiles) = _zipExtractor.ValidateRequiredFiles(extractedDir);
        if (!isValid)
        {
            string missing = string.Join(", ", missingFiles);
            debugPanel?.SetStatus($"缺少文件: {missing}", Color.red);
            CurrentState = SceneState.Error;
            UpdateButtonStates();
            return;
        }

        // 7. Set state to Loading, call AssetBundleLoader.Load
        CurrentState = SceneState.Loading;
        UpdateButtonStates();
        debugPanel?.SetStatus("正在加载资产包...", Color.white);

        bool loadSuccess = _assetBundleLoader.Load(extractedDir);
        if (!loadSuccess)
        {
            debugPanel?.SetStatus($"加载失败: {_assetBundleLoader.LastError}", Color.red);
            CurrentState = SceneState.Error;
            UpdateButtonStates();
            return;
        }

        // 8. Show asset info
        var manifest = _assetBundleLoader.Manifest;
        debugPanel?.SetAssetInfo(manifest.name, manifest.version, manifest.keyframeCount);

        // Initialize AreaTargetTracker
        _tracker = new AreaTargetTracker();
        bool initSuccess = _tracker.Initialize(extractedDir);
        if (!initSuccess)
        {
            debugPanel?.SetStatus("跟踪器初始化失败", Color.red);
            _tracker.Dispose();
            _tracker = null;
            CurrentState = SceneState.Error;
            UpdateButtonStates();
            return;
        }

        // Success — set state to Tracking
        CurrentState = SceneState.Tracking;
        UpdateButtonStates();
        debugPanel?.SetStatus("正在初始化...", Color.yellow);

        // Subscribe to AR camera frame events for tracking
        if (arCameraManager != null)
            arCameraManager.frameReceived += OnCameraFrameReceived;

        Debug.Log("[DownloadTestScene] 资产加载完成，跟踪器已初始化");
    }

    /// <summary>
    /// 释放跟踪器 → 清理临时文件 → 重置 UI → 销毁 OriginCube → 取消帧订阅。
    /// </summary>
    public void OnResetClicked()
    {
        // 1. Unsubscribe from camera frame events
        if (arCameraManager != null)
            arCameraManager.frameReceived -= OnCameraFrameReceived;

        // 2. Release tracker
        if (_tracker != null)
        {
            _tracker.Dispose();
            _tracker = null;
        }

        // 3. Clean up temporary files
        if (!string.IsNullOrEmpty(_currentDownloadDir) && System.IO.Directory.Exists(_currentDownloadDir))
        {
            try
            {
                System.IO.Directory.Delete(_currentDownloadDir, true);
            }
            catch (Exception ex)
            {
                Debug.LogWarning($"[DownloadTestScene] 清理临时文件失败: {ex.Message}");
            }
            _currentDownloadDir = null;
        }

        // 4. Reset DebugPanel
        debugPanel?.Clear();

        // 5. Destroy OriginCube if it exists
        if (_originCube != null)
        {
            if (Application.isPlaying)
                Destroy(_originCube);
            else
                DestroyImmediate(_originCube);
            _originCube = null;
        }

        // 6. Re-enable download button, set state back to Idle
        CurrentState = SceneState.Idle;
        UpdateButtonStates();

        Debug.Log("[DownloadTestScene] 场景已重置");
    }

    /// <summary>
    /// 场景销毁时释放所有资源，防止内存泄漏。
    /// </summary>
    void OnDestroy()
    {
        // 1. Unsubscribe from camera frame events
        if (arCameraManager != null)
            arCameraManager.frameReceived -= OnCameraFrameReceived;

        // 2. Dispose AreaTargetTracker
        if (_tracker != null)
        {
            _tracker.Dispose();
            _tracker = null;
        }

        // 3. Clean up downloaded temporary files
        if (!string.IsNullOrEmpty(_currentDownloadDir) && System.IO.Directory.Exists(_currentDownloadDir))
        {
            try
            {
                System.IO.Directory.Delete(_currentDownloadDir, true);
            }
            catch (Exception ex)
            {
                Debug.LogWarning($"[DownloadTestScene] OnDestroy 清理临时文件失败: {ex.Message}");
            }
        }

        // 4. Dispose DownloadManager
        if (_downloadManager != null)
        {
            _downloadManager.Dispose();
            _downloadManager = null;
        }
    }


    /// <summary>
    /// 每帧更新：计算 FPS 并在 Tracking 状态下处理 AR 跟踪。
    /// </summary>
    void Update()
    {
        // FPS 计算（持续运行，不受状态限制）
        _fpsFrameCount++;
        _fpsTimer += Time.unscaledDeltaTime;
        if (_fpsTimer >= 1f)
        {
            float fps = _fpsFrameCount / _fpsTimer;
            _fpsTimer = 0;
            _fpsFrameCount = 0;
            debugPanel?.SetFPS(fps);
        }
    }

    /// <summary>
    /// AR 相机帧接收回调，在 Tracking 状态下处理每帧相机数据。
    /// </summary>
    private void OnCameraFrameReceived(ARCameraFrameEventArgs args)
    {
        if (CurrentState != SceneState.Tracking || _tracker == null)
            return;

        if (!arCameraManager.TryAcquireLatestCpuImage(out XRCpuImage cpuImage))
            return;

        var conversionParams = new XRCpuImage.ConversionParams
        {
            inputRect = new RectInt(0, 0, cpuImage.width, cpuImage.height),
            outputDimensions = new Vector2Int(cpuImage.width, cpuImage.height),
            outputFormat = TextureFormat.R8,
            transformation = XRCpuImage.Transformation.None
        };

        int bufferSize = cpuImage.GetConvertedDataSize(conversionParams);
        byte[] grayscaleData = new byte[bufferSize];

        unsafe
        {
            fixed (byte* ptr = grayscaleData)
            {
                cpuImage.Convert(conversionParams, (IntPtr)ptr, bufferSize);
            }
        }

        int width = cpuImage.width;
        int height = cpuImage.height;
        cpuImage.Dispose();

        Matrix4x4 intrinsics = BuildIntrinsicsMatrix(width, height);

        var frame = new CameraFrame
        {
            ImageData = grayscaleData,
            Width = width,
            Height = height,
            Intrinsics = intrinsics
        };

        TrackingResult result = _tracker.ProcessFrame(frame);
        HandleTrackingResult(result);
    }

    /// <summary>
    /// 处理跟踪结果，更新 DebugPanel 状态和 OriginCube。
    /// </summary>
    private void HandleTrackingResult(TrackingResult result)
    {
        switch (result.State)
        {
            case AreaTargetPlugin.TrackingState.INITIALIZING:
                debugPanel?.SetStatus("正在初始化...", Color.yellow);
                break;

            case AreaTargetPlugin.TrackingState.TRACKING:
                debugPanel?.SetStatus("跟踪中", Color.green);
                debugPanel?.SetTrackingInfo(result.MatchedFeatures, result.Confidence);

                // 保存最后已知位姿
                _lastTrackingPose = result.Pose;

                // 首次进入 TRACKING 时创建 OriginCube
                if (_originCube == null)
                {
                    _originCube = CreateOriginCube();
                }

                _originCube.SetActive(true);
                break;

            case AreaTargetPlugin.TrackingState.LOST:
                debugPanel?.SetStatus("跟踪丢失", Color.red);

                // LOST 时保持 OriginCube 在最后已知位置，不更新位姿
                // _originCube 保持当前位置不变
                break;
        }
    }
    /// <summary>
    /// 在 areaTargetOrigin 下创建 10cm 立方体作为 OriginCube。
    /// </summary>
    private GameObject CreateOriginCube()
    {
        var cube = GameObject.CreatePrimitive(PrimitiveType.Cube);
        cube.name = "OriginCube";

        if (areaTargetOrigin != null)
        {
            cube.transform.SetParent(areaTargetOrigin, false);
        }

        cube.transform.localPosition = Vector3.zero;
        cube.transform.localScale = Vector3.one * 0.1f;

        return cube;
    }

    /// <summary>
    /// 构建相机内参矩阵。优先使用 AR Foundation 提供的真实内参，
    /// 回退到基于图像尺寸的估算值。
    /// </summary>
    private Matrix4x4 BuildIntrinsicsMatrix(int width, int height)
    {
        if (arCameraManager != null &&
            arCameraManager.TryGetIntrinsics(out XRCameraIntrinsics arIntrinsics))
        {
            var m = Matrix4x4.zero;
            m.m00 = arIntrinsics.focalLength.x;
            m.m11 = arIntrinsics.focalLength.y;
            m.m02 = arIntrinsics.principalPoint.x;
            m.m12 = arIntrinsics.principalPoint.y;
            m.m22 = 1f;
            return m;
        }

        // 回退：使用图像尺寸估算内参
        float fx = Mathf.Max(width, height) * 0.8f;
        var fallback = Matrix4x4.zero;
        fallback.m00 = fx;
        fallback.m11 = fx;
        fallback.m02 = width / 2f;
        fallback.m12 = height / 2f;
        fallback.m22 = 1f;
        return fallback;
    }

    /// <summary>
    /// 根据当前场景状态更新下载按钮的可交互性。
    /// 仅在 Idle 或 Error 状态下按钮可点击。
    /// </summary>
    private void UpdateButtonStates()
    {
        if (downloadButton != null)
            downloadButton.interactable = (CurrentState == SceneState.Idle || CurrentState == SceneState.Error);
    }
}
