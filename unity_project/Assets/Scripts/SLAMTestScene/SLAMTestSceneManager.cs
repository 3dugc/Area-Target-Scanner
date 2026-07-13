using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using UnityEngine;
using UnityEngine.UI;
using UnityEngine.XR.ARFoundation;
using UnityEngine.XR.ARSubsystems;
using AreaTargetPlugin;
using GLTFast;

public class SLAMTestSceneManager : MonoBehaviour
{
    [Header("AR")]
    [SerializeField] private ARCameraManager arCameraManager;
    [SerializeField] private ARSession arSession;

    [Header("Area Target")]
    [SerializeField] private string assetSubPath = "SLAMTestAssets";

    [Header("场景引用")]
    [SerializeField] private Transform areaTargetOrigin;

    [Header("UI")]
    [SerializeField] private SLAMDebugPanel debugPanel;
    [SerializeField] private Button resetButton;

    [Header("音效")]
    [SerializeField] private SLAMAudioFeedback audioFeedback;

    private AreaTargetTracker _tracker;
    private AssetBundleLoader _loader;
    private AreaTargetPlugin.TrackingState _previousState;
    private GameObject _originCube;
    private GameObject _glbModelObj;   // GLB 模型 GameObject (glTFast)
    private GltfImport _gltfImport;    // glTFast import handle
    private bool _glbLoaded;
    private Material _wireMaterial;    // 线框材质引用，用于 TRACKING/LOST 颜色切换
    private bool _initialized;

    private float _fpsTimer;
    private int _fpsFrameCount;
    private int _totalFramesProcessed;
    private int _framesWithImage;
    private int _framesNoImage;
    private int _framesSkipped;
    private string _lastTrackingDetail = "";
    private float _lastIntrinsicsFx;
    private int _lastImageW, _lastImageH;
    private int _lastGrayscaleNonZero;
    private long _lastCaptureTimestampNs = -1;

    private const long MaxLocalizationResultAgeNs = 1_000_000_000L;

    // --- 原点稳定性验证 ---
    private Vector3 _lastOriginPos;
    private bool _hasLastOriginPos;
    private int _originSampleCount;
    private Vector3 _originSum;       // 累计位置之和
    private Vector3 _originSumSq;     // 累计位置平方之和
    private float _maxFrameDrift;     // 最大帧间位移
    private string _stabilityInfo = "";

    // --- 增强调试信息（显示在屏幕上） ---
    private string _poseDebugInfo = "";
    private string _glbDebugInfo = "";
    private string _scanToARDebugInfo = "";

    void Start()
    {
        debugPanel?.SetStatus("脚本已加载", Color.cyan);
        if (resetButton != null) resetButton.onClick.AddListener(OnResetClicked);
        StartCoroutine(InitializeWhenReady());
    }

    private IEnumerator InitializeWhenReady()
    {
        float t = 0;
        while (ARSession.state < ARSessionState.SessionTracking)
        {
            t += Time.deltaTime;
            debugPanel?.SetStatus($"等AR {t:F0}s state={ARSession.state}", Color.yellow);
            yield return null;
        }
        debugPanel?.SetStatus($"AR就绪 state={ARSession.state}", Color.green);
        yield return new WaitForSeconds(0.3f);
        // 异步初始化，不阻塞主线程
        _ = InitializeTrackingAsync();
    }

    /// <summary>
    /// 异步初始化：耗时的 IO/计算在后台线程执行，UI 更新回主线程。
    /// </summary>
    private async Task InitializeTrackingAsync()
    {
        string assetPath = Path.Combine(Application.streamingAssetsPath, assetSubPath);
        var log = new List<string>();

        debugPanel?.SetStatus("初始化中...", Color.yellow);

        // Step 1: 检查路径（快，主线程）
        log.Add($"路径: {assetPath}");
        bool pathExists = Directory.Exists(assetPath);
        log.Add($"存在: {pathExists}");

        if (pathExists)
        {
            var files = Directory.GetFiles(assetPath);
            log.Add($"文件数: {files.Length}");
            foreach (var f in files)
                log.Add($"  {Path.GetFileName(f)} ({new FileInfo(f).Length}B)");
        }
        else
        {
            log.Add("路径不存在!");
            if (Directory.Exists(Application.streamingAssetsPath))
            {
                foreach (var d in Directory.GetDirectories(Application.streamingAssetsPath))
                    log.Add($"  D:{Path.GetFileName(d)}");
                foreach (var f in Directory.GetFiles(Application.streamingAssetsPath))
                    log.Add($"  F:{Path.GetFileName(f)}");
            }
            debugPanel?.SetStatus(string.Join("\n", log), Color.red);
            return;
        }

        // Step 2: 加载资产包 manifest（快，主线程）
        _loader = new AssetBundleLoader();
        bool loadOk = _loader.Load(assetPath);
        log.Add($"资产包: {(loadOk ? "OK" : "FAIL")}");
        if (!loadOk)
        {
            log.Add($"错误: {_loader.LastError}");
            debugPanel?.SetStatus(string.Join("\n", log), Color.red);
            return;
        }
        var m = _loader.Manifest;
        log.Add($"  {m.name} v{m.version} KF:{m.keyframeCount}");
        debugPanel?.SetAssetInfo(m.name, m.version, m.keyframeCount);
        debugPanel?.SetStatus("加载特征数据库...", Color.yellow);

        // Step 3: 后台线程执行耗时初始化（FeatureDB + native localizer）
        string trackerAssetPath = assetPath;
        AreaTargetTracker tracker = null;
        string initError = null;
        var bgLog = new List<string>();

        await Task.Run(() =>
        {
            try
            {
                tracker = new AreaTargetTracker();
                bool initOk = tracker.Initialize(trackerAssetPath);
                bgLog.Add($"Tracker.Init: {(initOk ? "OK" : "FAIL")}");
                if (!initOk)
                {
                    initError = "Tracker 初始化失败";
                    tracker.Dispose();
                    tracker = null;
                }
            }
            catch (Exception ex)
            {
                bgLog.Add($"Tracker.Init异常: {ex.GetType().Name}");
                bgLog.Add($"  {ex.Message}");
                initError = ex.Message;
                tracker?.Dispose();
                tracker = null;
            }
        });

        // 回到主线程
        log.AddRange(bgLog);

        if (tracker == null)
        {
            log.Add(initError ?? "未知错误");
            debugPanel?.SetStatus(string.Join("\n", log), Color.red);
            return;
        }

        _tracker = tracker;

        // Step 6: 订阅帧
        if (arCameraManager != null)
        {
            arCameraManager.frameReceived += OnCameraFrameReceived;
            log.Add("帧订阅: OK");
        }
        else
        {
            log.Add("arCameraManager=NULL!");
        }

        _initialized = true;
        _previousState = AreaTargetPlugin.TrackingState.INITIALIZING;
        log.Add("初始化完成!");

        // 加载 GLB 模型用于 AR 可视化 (glTFast 异步加载)
        if (_loader.MeshPath != null && _loader.MeshPath.EndsWith(".glb"))
        {
            log.Add($"GLB路径: {_loader.MeshPath}");
            _ = LoadGLBModelAsync(_loader.MeshPath);
        }

        log.Add("定位运行器: 已启动");

        debugPanel?.SetStatus(string.Join("\n", log), Color.green);
    }

    private void OnCameraFrameReceived(ARCameraFrameEventArgs args)
    {
        if (!_initialized || _tracker == null) return;
        _totalFramesProcessed++;

        if (!arCameraManager.TryAcquireLatestCpuImage(out XRCpuImage cpuImage))
        {
            _framesNoImage++;
            return;
        }
        _framesWithImage++;

        var convParams = new XRCpuImage.ConversionParams
        {
            inputRect = new RectInt(0, 0, cpuImage.width, cpuImage.height),
            outputDimensions = new Vector2Int(cpuImage.width, cpuImage.height),
            outputFormat = TextureFormat.R8,
            transformation = XRCpuImage.Transformation.None
        };

        int bufSize = cpuImage.GetConvertedDataSize(convParams);
        byte[] gray = new byte[bufSize];
        unsafe
        {
            fixed (byte* ptr = gray)
                cpuImage.Convert(convParams, (IntPtr)ptr, bufSize);
        }

        _lastImageW = cpuImage.width;
        _lastImageH = cpuImage.height;
        cpuImage.Dispose();

        int nonZero = 0;
        for (int i = 0; i < Mathf.Min(gray.Length, 1000); i++)
            if (gray[i] > 0) nonZero++;
        _lastGrayscaleNonZero = nonZero;

        Matrix4x4 intrinsics = BuildIntrinsicsMatrix(_lastImageW, _lastImageH);
        _lastIntrinsicsFx = intrinsics.m00;

        Camera arCamera = Camera.main;
        if (arCamera == null)
        {
            _framesSkipped++;
            Debug.LogWarning("[SLAM] 本帧缺少 AR 相机位姿，跳过定位");
            return;
        }

        var frame = new CameraFrame
        {
            ImageData = gray,
            Width = _lastImageW,
            Height = _lastImageH,
            Intrinsics = intrinsics,
            FrameId = _totalFramesProcessed,
            CaptureTimestampNs = GetMonotonicCaptureTimestampNs(args),
            Orientation = ImageOrientation.LandscapeRight,
            UnityWorldFromCamera = arCamera.transform.localToWorldMatrix,
            MapId = _tracker.MapId
        };

        if (!_tracker.SubmitFrame(frame))
            _framesSkipped++;
    }

    private long GetMonotonicCaptureTimestampNs(ARCameraFrameEventArgs args)
    {
        long candidate = args.timestampNs ?? ((long)_totalFramesProcessed * 1_000_000L);
        if (candidate <= _lastCaptureTimestampNs)
            candidate = _lastCaptureTimestampNs + 1;

        _lastCaptureTimestampNs = candidate;
        return candidate;
    }

    /// <summary>
    /// Main-thread result consumption. Native work has already completed inside
    /// AreaTargetTracker's single runner worker.
    /// </summary>
    private void ConsumeLatestTrackingResult()
    {
        if (!_initialized || _tracker == null || _lastCaptureTimestampNs < 0)
            return;

        if (!_tracker.TryGetLatestTrackingResult(
            _lastCaptureTimestampNs,
            MaxLocalizationResultAgeNs,
            out TrackingResult result))
        {
            return;
        }

        ExtendedDebugInfo debug = _tracker.GetExtendedDebugInfo();
        VLDebugInfo native = debug.NativeDebugInfo;
        debugPanel?.SetDiagnosticSummary(
            debug.LastDiagnosticFrameId,
            debug.LastResultAgeNs,
            debug.LastDiagnosticState,
            debug.LastDiagnosticQuality,
            native.best_inliers,
            debug.LastWorkerProcessingTimeNs);
        _lastTrackingDetail =
            $"S={result.State} M={result.MatchedFeatures} C={result.Confidence:F3}";
        if (native.orb_keypoints > 0 || native.candidate_keyframes > 0 || native.best_kf_id >= 0)
        {
            _lastTrackingDetail +=
                $"\nORB:{native.orb_keypoints} Cand:{native.candidate_keyframes} BoW:{native.best_bow_sim:F3}" +
                $"\nRaw:{native.best_raw_matches} Good:{native.best_good_matches} In:{native.best_inliers} KF:{native.best_kf_id}";
        }

        HandleTrackingResult(result);
    }

    private void HandleTrackingResult(TrackingResult result)
    {
        switch (result.State)
        {
            case AreaTargetPlugin.TrackingState.TRACKING:
                debugPanel?.SetStatus("跟踪中", Color.green);
                debugPanel?.SetTrackingInfo(result.MatchedFeatures, result.Confidence);
                break;
            case AreaTargetPlugin.TrackingState.LOST:
                debugPanel?.SetStatus("跟踪丢失", Color.red);
                break;
            default:
                debugPanel?.SetStatus("正在初始化", Color.yellow);
                break;
        }

        bool toTracking = result.State == AreaTargetPlugin.TrackingState.TRACKING
            && _previousState != AreaTargetPlugin.TrackingState.TRACKING;
        bool toLost = result.State == AreaTargetPlugin.TrackingState.LOST
            && _previousState == AreaTargetPlugin.TrackingState.TRACKING;

        // 首次识别到：播放音效，创建原点标记 + GLB 模型
        if (toTracking)
        {
            audioFeedback?.PlayTrackingFound();
            if (_originCube == null) _originCube = CreateOriginCube();
        }

        // TrackingResult.Pose is already T_U_S. Scene code only consumes this
        // completed Unity-world pose; all camera/native composition lives in Runtime.
        if (result.State == AreaTargetPlugin.TrackingState.TRACKING && _originCube != null)
        {
            Matrix4x4 unityWorldFromScan = result.Pose;
            Vector3 scanOriginInUnity = new Vector3(
                unityWorldFromScan.m03,
                unityWorldFromScan.m13,
                unityWorldFromScan.m23);
            Quaternion scanRotationInUnity = unityWorldFromScan.rotation;

            _poseDebugInfo = $"T_U_S t=({scanOriginInUnity.x:F2},{scanOriginInUnity.y:F2},{scanOriginInUnity.z:F2})";
            _scanToARDebugInfo =
                "T_U_S = T_U_C × T_C_S (Runtime)\n" +
                $"scan→Unity=({scanOriginInUnity.x:F3},{scanOriginInUnity.y:F3},{scanOriginInUnity.z:F3})";
            Debug.Log($"[T_U_S] pos=({scanOriginInUnity.x:F3},{scanOriginInUnity.y:F3},{scanOriginInUnity.z:F3})");

            // 更新原点 cube
            _originCube.transform.SetPositionAndRotation(scanOriginInUnity, scanRotationInUnity);
            _originCube.SetActive(true);
            SetCubeColor(Color.green);

            // 更新 GLB 模型位置 — 直接使用 Runtime 输出的 T_U_S。
            if (_glbModelObj != null)
            {
                Vector3 pos = scanOriginInUnity;
                Quaternion rot = scanRotationInUnity;
                Vector3 scale = new Vector3(
                    new Vector3(unityWorldFromScan.m00, unityWorldFromScan.m10, unityWorldFromScan.m20).magnitude,
                    new Vector3(unityWorldFromScan.m01, unityWorldFromScan.m11, unityWorldFromScan.m21).magnitude,
                    new Vector3(unityWorldFromScan.m02, unityWorldFromScan.m12, unityWorldFromScan.m22).magnitude);

                _glbModelObj.transform.SetPositionAndRotation(pos, rot);
                _glbModelObj.transform.localScale = scale;
                _glbModelObj.SetActive(true);

                // TRACKING 时线框绿色
                if (_wireMaterial != null)
                    _wireMaterial.color = new Color(0f, 1f, 0f, 0.8f);

                // 诊断: 模型世界空间 bounds
                var renderers = _glbModelObj.GetComponentsInChildren<Renderer>();
                string boundsInfo = "";
                if (renderers.Length > 0)
                {
                    Bounds combinedBounds = renderers[0].bounds;
                    for (int i = 1; i < renderers.Length; i++)
                        combinedBounds.Encapsulate(renderers[i].bounds);
                    Vector3 modelCenterWorld = combinedBounds.center;
                    float distToCam = Vector3.Distance(modelCenterWorld, Camera.main?.transform.position ?? Vector3.zero);
                    boundsInfo = $"center=({modelCenterWorld.x:F1},{modelCenterWorld.y:F1},{modelCenterWorld.z:F1}) d={distToCam:F1}m";
                    Debug.Log($"[GLB] {boundsInfo} size={combinedBounds.size}");
                }

                _glbDebugInfo = $"GLB pos=({pos.x:F2},{pos.y:F2},{pos.z:F2}) sc=({scale.x:F2},{scale.y:F2},{scale.z:F2})\n{boundsInfo}";

                Debug.Log($"[GLB] T_U_S pos=({pos.x:F3},{pos.y:F3},{pos.z:F3}) scale=({scale.x:F3},{scale.y:F3},{scale.z:F3})");
            }

            // 稳定性统计
            float frameDrift = 0f;
            if (_hasLastOriginPos)
            {
                frameDrift = Vector3.Distance(scanOriginInUnity, _lastOriginPos);
                if (frameDrift > _maxFrameDrift) _maxFrameDrift = frameDrift;
            }
            _lastOriginPos = scanOriginInUnity;
            _hasLastOriginPos = true;
            _originSampleCount++;
            _originSum += scanOriginInUnity;
            _originSumSq += new Vector3(
                scanOriginInUnity.x * scanOriginInUnity.x,
                scanOriginInUnity.y * scanOriginInUnity.y,
                scanOriginInUnity.z * scanOriginInUnity.z);

            Vector3 mean = _originSum / _originSampleCount;
            Vector3 variance = _originSumSq / _originSampleCount - new Vector3(
                mean.x * mean.x, mean.y * mean.y, mean.z * mean.z);
            float stdDev = Mathf.Sqrt(Mathf.Max(0, variance.x) +
                                       Mathf.Max(0, variance.y) +
                                       Mathf.Max(0, variance.z));

            _stabilityInfo = $"漂移:{frameDrift:F3}m 最大:{_maxFrameDrift:F3}m σ:{stdDev:F3}m N:{_originSampleCount}";
            Debug.Log($"[STABILITY] {_stabilityInfo}");
        }

        // 丢失：播放音效，线框变红（保留在最后已知位置，靠 ARKit SLAM 锚定）
        if (toLost)
        {
            audioFeedback?.PlayTrackingLost();
            SetCubeColor(Color.red);
            if (_originCube != null)
                _originCube.SetActive(false);
            if (_wireMaterial != null)
                _wireMaterial.color = new Color(1f, 0f, 0f, 0.8f);
        }

        _previousState = result.State;
    }

    private void SetCubeColor(Color color)
    {
        if (_originCube == null) return;
        var renderer = _originCube.GetComponent<Renderer>();
        if (renderer != null)
        {
            renderer.sharedMaterial.color = color;
        }
    }

    private GameObject CreateOriginCube()
    {
        var cube = GameObject.CreatePrimitive(PrimitiveType.Cube);
        cube.name = "TrackingOriginCube";
        if (areaTargetOrigin != null)
            cube.transform.SetParent(areaTargetOrigin, false);
        cube.transform.localScale = Vector3.one * 0.1f; // 10cm
        return cube;
    }

    /// <summary>
    /// 用 glTFast 异步加载 GLB 模型，创建半透明叠加层。
    /// </summary>
    private async Task LoadGLBModelAsync(string glbPath)
    {
        try
        {
            // iOS 上路径需要 file:// 前缀
            string uri = glbPath;
            if (!uri.StartsWith("file://"))
                uri = "file://" + uri;

            Debug.Log($"[GLB] Loading via glTFast: {uri}");

            _gltfImport = new GltfImport();
            bool success = await _gltfImport.Load(uri);

            if (!success)
            {
                Debug.LogError("[GLB] glTFast load failed");
                return;
            }

            // 创建容器 GameObject
            _glbModelObj = new GameObject("GLBModel");
            _glbModelObj.SetActive(false); // 等 tracking 时再显示

            // 实例化场景到容器下
            await _gltfImport.InstantiateMainSceneAsync(_glbModelObj.transform);

            // === glTFast 资产坐标修正 ===
            // glTFast 已将顶点转换到 Unity 约定；这里仅保留 GLB 子节点的
            // 静态资产修正。根节点的运行时位姿始终直接使用 Runtime 的 T_U_S，
            // 不在场景中再组合相机或 native 矩阵。
            foreach (Transform child in _glbModelObj.transform)
            {
                child.localScale = new Vector3(-1f, 1f, -1f);
                Debug.Log($"[GLB_DIAG] XZ-flip applied to child='{child.name}'");
            }

            // 诊断: 输出 glTFast 创建的子节点层级
            foreach (Transform child in _glbModelObj.transform)
            {
                Debug.Log($"[GLB_DIAG] child='{child.name}' localPos={child.localPosition} localRot={child.localEulerAngles} localScale={child.localScale}");
            }

            // 诊断: 输出每个 mesh 的本地空间 bounds 和顶点范围
            var meshFilters = _glbModelObj.GetComponentsInChildren<MeshFilter>();
            int totalVerts = 0, totalTris = 0;
            foreach (var mf in meshFilters)
            {
                if (mf.sharedMesh != null)
                {
                    var m = mf.sharedMesh;
                    totalVerts += m.vertexCount;
                    totalTris += m.triangles.Length / 3;
                    var b = m.bounds;
                    Debug.Log($"[GLB_DIAG] mesh='{mf.gameObject.name}' verts={m.vertexCount} tris={m.triangles.Length / 3} bounds_center=({b.center.x:F3},{b.center.y:F3},{b.center.z:F3}) bounds_size=({b.size.x:F3},{b.size.y:F3},{b.size.z:F3})");

                    // 输出前3个顶点的实际坐标（glTFast 翻转后的值）
                    var verts = m.vertices;
                    for (int i = 0; i < Mathf.Min(3, verts.Length); i++)
                    {
                        Debug.Log($"[GLB_DIAG] vert[{i}]=({verts[i].x:F4},{verts[i].y:F4},{verts[i].z:F4})");
                    }
                }
            }

            // 红色线框模式：把三角形 mesh 转成线段，用内置 shader 避免 URP 兼容问题
            var meshFiltersForWire = _glbModelObj.GetComponentsInChildren<MeshFilter>();
            foreach (var mf in meshFiltersForWire)
            {
                if (mf.sharedMesh == null) continue;
                var srcMesh = mf.sharedMesh;
                var tris = srcMesh.triangles;
                var verts = srcMesh.vertices;

                // 构建线段索引：每个三角形 3 条边
                var lineIndices = new List<int>(tris.Length * 2);
                for (int ti = 0; ti < tris.Length; ti += 3)
                {
                    lineIndices.Add(tris[ti]);     lineIndices.Add(tris[ti + 1]);
                    lineIndices.Add(tris[ti + 1]); lineIndices.Add(tris[ti + 2]);
                    lineIndices.Add(tris[ti + 2]); lineIndices.Add(tris[ti]);
                }

                var wireMesh = new Mesh();
                wireMesh.name = srcMesh.name + "_wire";
                wireMesh.vertices = verts;
                wireMesh.SetIndices(lineIndices.ToArray(), MeshTopology.Lines, 0);
                mf.sharedMesh = wireMesh;

                Debug.Log($"[GLB_WIRE] '{mf.gameObject.name}' → {verts.Length} verts, {lineIndices.Count / 2} lines");
            }

            // 红色线框材质（Sprites/Default 内置 shader，不依赖 URP）
            var wireShader = Shader.Find("Sprites/Default");
            if (wireShader == null) wireShader = Shader.Find("UI/Default");
            var wireMat = new Material(wireShader);
            wireMat.color = new Color(0f, 1f, 0f, 0.8f); // 初始绿色（首次显示即 TRACKING）
            _wireMaterial = wireMat;

            var renderers = _glbModelObj.GetComponentsInChildren<Renderer>();
            foreach (var r in renderers)
            {
                r.materials = new Material[] { wireMat };
            }

            _glbLoaded = true;
            Debug.Log($"[GLB_DIAG] Loaded: {totalVerts} verts, {totalTris} tris, {renderers.Length} renderers — X-flip applied, material unchanged");
        }
        catch (Exception ex)
        {
            Debug.LogError($"[GLB] glTFast exception: {ex.Message}\n{ex.StackTrace}");
        }
    }

    void Update()
    {
        ConsumeLatestTrackingResult();

        _fpsFrameCount++;
        _fpsTimer += Time.unscaledDeltaTime;
        if (_fpsTimer >= 1f)
        {
            debugPanel?.SetFPS(_fpsFrameCount / _fpsTimer);
            _fpsTimer = 0;
            _fpsFrameCount = 0;

            if (_initialized)
            {
                string detail = _lastTrackingDetail;
                string cubeInfo = _originCube != null && _originCube.activeSelf
                    ? $"\n原点:{_originCube.transform.position.x:F2},{_originCube.transform.position.y:F2},{_originCube.transform.position.z:F2}"
                    : "";
                string glbInfo = _glbModelObj != null && _glbModelObj.activeSelf
                    ? $"\nGLB:已加载" : (_glbLoaded ? "\nGLB:待显示" : "");
                string stabilityLine = !string.IsNullOrEmpty(_stabilityInfo) ? $"\n{_stabilityInfo}" : "";
                debugPanel?.SetDetailedTracking(
                    $"帧:{_totalFramesProcessed} 图:{_framesWithImage} 无:{_framesNoImage} 跳:{_framesSkipped}\n" +
                    $"图像:{_lastImageW}x{_lastImageH} nz:{_lastGrayscaleNonZero}/1000\n" +
                    $"fx:{_lastIntrinsicsFx:F1} {detail}\n" +
                    $"状态:{_previousState} [异步]{cubeInfo}{glbInfo}{stabilityLine}");
            }
        }
    }

    public void OnResetClicked()
    {
        if (_tracker != null)
            _ = _tracker.ResetAsync();
        _lastTrackingDetail = "";
        if (_originCube != null) _originCube.SetActive(false);
        if (_glbModelObj != null) _glbModelObj.SetActive(false);
        // 重置稳定性统计
        _hasLastOriginPos = false;
        _originSampleCount = 0;
        _originSum = Vector3.zero;
        _originSumSq = Vector3.zero;
        _maxFrameDrift = 0f;
        _stabilityInfo = "";
        debugPanel?.Clear();
        _previousState = AreaTargetPlugin.TrackingState.INITIALIZING;
        Debug.Log("[RESET] Tracker and stats reset");
    }

    void OnDestroy()
    {
        if (arCameraManager != null) arCameraManager.frameReceived -= OnCameraFrameReceived;
        if (_tracker != null)
            _ = _tracker.DisposeAsync();
        _tracker = null;

        if (_glbModelObj != null) Destroy(_glbModelObj);
        _gltfImport?.Dispose();
        _gltfImport = null;
    }

    // --- 屏幕箭头指示器 ---
    private static Texture2D _arrowTex;

    void OnGUI()
    {
        // === 调试 HUD：在屏幕右下角显示关键数值 ===
        if (_previousState == AreaTargetPlugin.TrackingState.TRACKING)
        {
            float sw = Screen.width;
            float sh = Screen.height;
            var hudStyle = new GUIStyle(GUI.skin.label)
            {
                fontSize = 20,
                alignment = TextAnchor.LowerLeft
            };
            hudStyle.normal.textColor = Color.yellow;

            // 背景半透明黑色
            float hudW = 500f, hudH = 180f;
            float hudX = 10f, hudY = sh - hudH - 10f;
            GUI.color = new Color(0, 0, 0, 0.7f);
            GUI.DrawTexture(new Rect(hudX, hudY, hudW, hudH), Texture2D.whiteTexture);
            GUI.color = Color.white;

            string hudText = "";
            if (!string.IsNullOrEmpty(_poseDebugInfo))
                hudText += _poseDebugInfo + "\n";
            if (!string.IsNullOrEmpty(_scanToARDebugInfo))
                hudText += _scanToARDebugInfo + "\n";
            if (!string.IsNullOrEmpty(_glbDebugInfo))
                hudText += _glbDebugInfo + "\n";
            if (!string.IsNullOrEmpty(_stabilityInfo))
                hudText += _stabilityInfo;

            hudStyle.normal.textColor = Color.yellow;
            GUI.Label(new Rect(hudX + 5, hudY + 5, hudW - 10, hudH - 10), hudText, hudStyle);
        }

        if (_originCube == null || !_originCube.activeSelf) return;
        var cam = Camera.main;
        if (cam == null) return;

        Vector3 worldPos = _originCube.transform.position;
        Vector3 vp = cam.WorldToViewportPoint(worldPos);

        // vp.z < 0 表示在相机后面
        bool behind = vp.z < 0;
        bool onScreen = !behind && vp.x > 0.05f && vp.x < 0.95f && vp.y > 0.05f && vp.y < 0.95f;

        float sw2 = Screen.width;
        float sh2 = Screen.height;

        if (_arrowTex == null)
        {
            _arrowTex = new Texture2D(1, 1);
            _arrowTex.SetPixel(0, 0, Color.white);
            _arrowTex.Apply();
        }

        Color arrowColor = _previousState == AreaTargetPlugin.TrackingState.TRACKING
            ? Color.green : Color.red;

        if (onScreen)
        {
            // 立方体在屏幕内：在它上方画一个向下的三角箭头
            float sx = vp.x * sw2;
            float sy = (1f - vp.y) * sh2; // GUI Y 轴反转
            DrawArrowAt(sx, sy - 60f, 0f, 40f, arrowColor); // 箭头朝下，在立方体上方
            // 距离标签
            float dist = Vector3.Distance(cam.transform.position, worldPos);
            var style = new GUIStyle(GUI.skin.label)
            {
                fontSize = 28,
                fontStyle = FontStyle.Bold,
                alignment = TextAnchor.MiddleCenter
            };
            style.normal.textColor = arrowColor;
            GUI.Label(new Rect(sx - 80, sy - 100, 160, 36), $"{dist:F2}m", style);
        }
        else
        {
            // 立方体在屏幕外或后面：箭头贴在屏幕边缘
            float cx = sw2 / 2f;
            float cy = sh2 / 2f;

            // 如果在后面，翻转方向
            float dx = vp.x - 0.5f;
            float dy = vp.y - 0.5f;
            if (behind) { dx = -dx; dy = -dy; }

            float angle = Mathf.Atan2(dy, dx);
            float margin = 60f;

            // 沿方向射线与屏幕边缘求交
            float ex = cx + Mathf.Cos(angle) * sw2;
            float ey = cy - Mathf.Sin(angle) * sh2; // GUI Y反转
            // 裁剪到屏幕边缘
            ex = Mathf.Clamp(ex, margin, sw2 - margin);
            ey = Mathf.Clamp(ey, margin, sh2 - margin);

            float guiAngle = -angle * Mathf.Rad2Deg;
            DrawArrowAt(ex, ey, guiAngle, 50f, arrowColor);
        }
    }

    /// <summary>
    /// 在屏幕 (x,y) 处画一个三角箭头。angle=0 表示朝下。
    /// </summary>
    private void DrawArrowAt(float x, float y, float angle, float size, Color color)
    {
        var prevMatrix = GUI.matrix;
        var prevColor = GUI.color;
        GUI.color = color;

        // 旋转绕 (x,y)
        GUIUtility.RotateAroundPivot(angle, new Vector2(x, y));

        // 画三角形：用3个旋转过的矩形近似一个箭头
        float h = size;
        float w = size * 0.6f;
        // 箭头主体（向下的三角）
        for (int i = 0; i < (int)h; i++)
        {
            float t = (float)i / h;
            float lineW = w * (1f - t);
            GUI.DrawTexture(new Rect(x - lineW / 2f, y + i, lineW, 1.5f), _arrowTex);
        }

        GUI.matrix = prevMatrix;
        GUI.color = prevColor;
    }

    private Matrix4x4 BuildIntrinsicsMatrix(int width, int height)
    {
        if (arCameraManager != null &&
            arCameraManager.TryGetIntrinsics(out XRCameraIntrinsics arIntrinsics))
        {
            var mat = Matrix4x4.zero;
            mat.m00 = arIntrinsics.focalLength.x;
            mat.m11 = arIntrinsics.focalLength.y;
            mat.m02 = arIntrinsics.principalPoint.x;
            mat.m12 = arIntrinsics.principalPoint.y;
            mat.m22 = 1f;
            return mat;
        }
        float fx = Mathf.Max(width, height) * 0.8f;
        var fb = Matrix4x4.zero;
        fb.m00 = fx; fb.m11 = fx;
        fb.m02 = width / 2f; fb.m12 = height / 2f;
        fb.m22 = 1f;
        return fb;
    }
}
