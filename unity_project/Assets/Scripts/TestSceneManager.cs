using UnityEngine;
using UnityEngine.UI;
using AreaTargetPlugin;
using AreaTargetPlugin.PointCloudLocalization;

/// <summary>
/// 编辑器测试场景管理器：验证 AreaTargetPlugin 全链路功能。
/// 不依赖 AR 硬件，使用模拟数据在 Editor 和 iOS 设备上均可运行。
/// </summary>
public class TestSceneManager : MonoBehaviour
{
    [Header("配置")]
    [SerializeField] private string assetBundlePath = "AreaTargetAssets/test_room";
    [SerializeField] private int simulatedWidth = 640;
    [SerializeField] private int simulatedHeight = 480;

    [Header("UI 引用")]
    [SerializeField] private Text statusText;
    [SerializeField] private Text fpsText;
    [SerializeField] private Text detailText;

    [Header("场景引用")]
    [SerializeField] private Transform targetOrigin;
    [SerializeField] private GameObject testCube;

    private AreaTargetTracker _tracker;
    private bool _initialized;
    private int _frameCount;
    private float _fpsTimer;
    private int _fpsFrameCount;
    private float _currentFps;

    // 测试结果
    private int _totalTests;
    private int _passedTests;

    void Start()
    {
        Log("=== AreaTarget Plugin 测试场景 ===");
        Log($"平台: {Application.platform}");
        Log($"设备: {SystemInfo.deviceModel}");
        Log($"Unity: {Application.unityVersion}");

        RunAllTests();
    }

    void Update()
    {
        // FPS 计算
        _fpsFrameCount++;
        _fpsTimer += Time.unscaledDeltaTime;
        if (_fpsTimer >= 1f)
        {
            _currentFps = _fpsFrameCount / _fpsTimer;
            _fpsTimer = 0;
            _fpsFrameCount = 0;
            if (fpsText != null)
                fpsText.text = $"FPS: {_currentFps:F1}";
        }

        // 模拟帧处理
        if (_initialized)
        {
            _frameCount++;
            ProcessSimulatedFrame();
        }
    }

    private void RunAllTests()
    {
        _totalTests = 0;
        _passedTests = 0;

        TestTrackerLifecycle();
        TestMapManager();
        TestLocalizationResult();
        TestCameraDataAdapter();
        TestSceneUpdater();
        TestLocalizationPipeline();

        string summary = $"测试完成: {_passedTests}/{_totalTests} 通过";
        Log(summary);
        SetStatus(summary, _passedTests == _totalTests ? Color.green : Color.red);
    }

    #region 测试用例

    private void TestTrackerLifecycle()
    {
        Log("--- 测试: Tracker 生命周期 ---");

        // 1. 创建
        var tracker = new AreaTargetTracker();
        Assert("创建 Tracker", tracker != null);

        // 2. 初始状态
        Assert("初始状态为 INITIALIZING", tracker.GetTrackingState() == TrackingState.INITIALIZING);

        // 3. 未初始化时 ProcessFrame
        var frame = new CameraFrame
        {
            ImageData = new byte[100],
            Width = 10,
            Height = 10,
            Intrinsics = Matrix4x4.identity
        };
        var result = tracker.ProcessFrame(frame);
        Assert("未初始化 ProcessFrame 返回 LOST", result.State == TrackingState.LOST);

        // 4. Reset 不抛异常
        bool resetOk = true;
        try { tracker.Reset(); } catch { resetOk = false; }
        Assert("Reset 不抛异常", resetOk);

        // 5. Dispose
        tracker.Dispose();
        Assert("Dispose 后状态为 LOST", tracker.GetTrackingState() == TrackingState.LOST);

        // 6. 多次 Dispose 不抛异常
        bool multiDisposeOk = true;
        try { tracker.Dispose(); tracker.Dispose(); } catch { multiDisposeOk = false; }
        Assert("多次 Dispose 不抛异常", multiDisposeOk);

        // 7. Dispose 后 Initialize 返回 false
        Assert("Dispose 后 Initialize 返回 false", !tracker.Initialize("/fake"));
    }

    private void TestMapManager()
    {
        Log("--- 测试: MapManager ---");

        MapManager.Clear();

        // 1. 注册和查找
        var entry = new MapEntry { MapId = 42 };
        MapManager.RegisterMap(42, entry);
        bool found = MapManager.TryGetMapEntry(42, out var result);
        Assert("注册后可查找", found && result.MapId == 42);

        // 2. 未注册的 ID
        bool notFound = MapManager.TryGetMapEntry(999, out _);
        Assert("未注册 ID 返回 false", !notFound);

        // 3. 覆盖注册
        var entry2 = new MapEntry { MapId = 42 };
        MapManager.RegisterMap(42, entry2);
        MapManager.TryGetMapEntry(42, out var result2);
        Assert("覆盖注册生效", result2 == entry2);

        // 4. 注销
        MapManager.UnregisterMap(42);
        Assert("注销后查找失败", !MapManager.TryGetMapEntry(42, out _));

        // 5. Clear
        MapManager.RegisterMap(1, new MapEntry { MapId = 1 });
        MapManager.RegisterMap(2, new MapEntry { MapId = 2 });
        MapManager.Clear();
        Assert("Clear 后全部清空", !MapManager.TryGetMapEntry(1, out _) && !MapManager.TryGetMapEntry(2, out _));
    }

    private void TestLocalizationResult()
    {
        Log("--- 测试: LocalizationResult ---");

        // 1. Failed 工厂方法
        var failed = LocalizationResult.Failed();
        Assert("Failed() Success=false", !failed.Success);
        Assert("Failed() MapId=-1", failed.MapId == -1);
        Assert("Failed() Pose=identity", failed.Pose == Matrix4x4.identity);

        // 2. 成功结果
        var pose = Matrix4x4.TRS(new Vector3(1, 2, 3), Quaternion.identity, Vector3.one);
        var success = new LocalizationResult { Success = true, MapId = 5, Pose = pose };
        Assert("成功结果 Success=true", success.Success);
        Assert("成功结果 MapId=5", success.MapId == 5);
        Assert("成功结果 Pose 正确", success.Pose == pose);
    }

    private void TestCameraDataAdapter()
    {
        Log("--- 测试: CameraDataAdapter ---");

        var cameraData = new TestCameraData(640, 480, new Vector4(500, 500, 320, 240));
        var cameraFrame = CameraDataAdapter.ToCameraFrame(cameraData);

        Assert("Width 保持一致", cameraFrame.Width == 640);
        Assert("Height 保持一致", cameraFrame.Height == 480);
        Assert("fx 映射到 m00", Mathf.Approximately(cameraFrame.Intrinsics.m00, 500f));
        Assert("fy 映射到 m11", Mathf.Approximately(cameraFrame.Intrinsics.m11, 500f));
        Assert("cx 映射到 m02", Mathf.Approximately(cameraFrame.Intrinsics.m02, 320f));
        Assert("cy 映射到 m12", Mathf.Approximately(cameraFrame.Intrinsics.m12, 240f));
    }

    private void TestSceneUpdater()
    {
        Log("--- 测试: SceneUpdater ---");

        var updater = new SceneUpdater();
        Assert("SceneUpdater 创建成功", updater != null);
    }

    private void TestLocalizationPipeline()
    {
        Log("--- 测试: LocalizationPipeline ---");

        var platform = new TestPlatformSupport();
        var localizer = new TestLocalizer();
        var sceneUpdater = new SceneUpdater();

        var pipeline = new LocalizationPipeline(platform, localizer, sceneUpdater);
        Assert("Pipeline 创建成功", pipeline != null);
        Assert("默认阈值为 50", pipeline.TrackingQualityThreshold == 50);

        // 测试 null 参数
        bool threw = false;
        try { new LocalizationPipeline(null, localizer, sceneUpdater); }
        catch (System.ArgumentNullException) { threw = true; }
        Assert("null platform 抛 ArgumentNullException", threw);
    }

    #endregion

    #region 模拟帧处理

    private void ProcessSimulatedFrame()
    {
        if (_tracker == null) return;

        byte[] fakeImage = new byte[simulatedWidth * simulatedHeight];
        for (int i = 0; i < fakeImage.Length; i++)
            fakeImage[i] = (byte)((_frameCount + i) % 256);

        float fx = Mathf.Max(simulatedWidth, simulatedHeight) * 0.8f;
        var intrinsics = Matrix4x4.zero;
        intrinsics.m00 = fx;
        intrinsics.m11 = fx;
        intrinsics.m02 = simulatedWidth / 2f;
        intrinsics.m12 = simulatedHeight / 2f;
        intrinsics.m22 = 1f;

        var frame = new CameraFrame
        {
            ImageData = fakeImage,
            Width = simulatedWidth,
            Height = simulatedHeight,
            Intrinsics = intrinsics
        };

        var result = _tracker.ProcessFrame(frame);

        if (_frameCount % 120 == 0 && detailText != null)
        {
            detailText.text = $"帧: {_frameCount}\n状态: {result.State}\n" +
                              $"置信度: {result.Confidence:P0}\n特征: {result.MatchedFeatures}";
        }
    }

    #endregion

    #region 辅助方法

    private void Assert(string name, bool condition)
    {
        _totalTests++;
        if (condition)
        {
            _passedTests++;
            Log($"  ✓ {name}");
        }
        else
        {
            Log($"  ✗ {name}");
            Debug.LogError($"[TestScene] FAIL: {name}");
        }
    }

    private void Log(string msg)
    {
        Debug.Log($"[TestScene] {msg}");
    }

    private void SetStatus(string msg, Color color)
    {
        if (statusText != null)
        {
            statusText.text = msg;
            statusText.color = color;
        }
    }

    void OnDestroy()
    {
        _tracker?.Dispose();
        MapManager.Clear();
    }

    #endregion

    #region 测试用 Stub 类

    private class TestCameraData : ICameraData
    {
        private readonly int _w, _h;
        private readonly Vector4 _intr;

        public TestCameraData(int w, int h, Vector4 intrinsics)
        {
            _w = w; _h = h; _intr = intrinsics;
        }

        public byte[] GetBytes() => new byte[_w * _h];
        public int Width => _w;
        public int Height => _h;
        public int Channels => 1;
        public Vector4 Intrinsics => _intr;
        public Vector3 CameraPositionOnCapture => Vector3.zero;
        public Quaternion CameraRotationOnCapture => Quaternion.identity;
        public long FrameId => 0;
        public long CaptureTimestampNs => 0;
        public ImageOrientation Orientation => ImageOrientation.LandscapeRight;
        public string MapId => "test-scene-map";
    }

    private class TestPlatformSupport : IPlatformSupport
    {
        public System.Threading.Tasks.Task<IPlatformUpdateResult> UpdatePlatform()
        {
            var result = new PlatformUpdateResult
            {
                Success = true,
                TrackingQuality = 80,
                CameraData = new TestCameraData(640, 480, new Vector4(500, 500, 320, 240))
            };
            return System.Threading.Tasks.Task.FromResult<IPlatformUpdateResult>(result);
        }

        public System.Threading.Tasks.Task ConfigurePlatform()
            => System.Threading.Tasks.Task.CompletedTask;

        public System.Threading.Tasks.Task StopAndCleanUp()
            => System.Threading.Tasks.Task.CompletedTask;
    }

    private class TestLocalizer : ILocalizer
    {
        public event System.Action<int[]> OnSuccessfulLocalizations;

        public System.Threading.Tasks.Task<ILocalizationResult> Localize(ICameraData cameraData)
            => System.Threading.Tasks.Task.FromResult<ILocalizationResult>(LocalizationResult.Failed());

        public System.Threading.Tasks.Task StopAndCleanUp()
            => System.Threading.Tasks.Task.CompletedTask;
    }

    #endregion
}
