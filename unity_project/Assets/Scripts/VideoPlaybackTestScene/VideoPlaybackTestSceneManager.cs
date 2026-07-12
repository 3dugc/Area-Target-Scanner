using System;
using System.IO;
using System.Threading.Tasks;
using UnityEngine;
using UnityEngine.UI;
using AreaTargetPlugin;
using GLTFast;

namespace VideoPlaybackTestScene
{
    /// <summary>
    /// 视频回放测试场景主控制器。
    /// 协调 ImageSeqFrameSource、PlaybackController、AreaTargetTracker 和 PlaybackDebugPanel。
    /// 不依赖 AR Foundation / XR 子系统，使用标准 Camera。
    /// Validates: Requirements 3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 4.3, 4.4, 5.1, 5.2, 5.3, 6.1, 6.2
    /// </summary>
    public class VideoPlaybackTestSceneManager : MonoBehaviour
    {
        [Header("数据路径")]
        [SerializeField] private string scanDataSubPath = "ScanData";
        [SerializeField] private string assetSubPath = "SLAMTestAssets";

        [Header("场景引用")]
        [SerializeField] private Camera mainCamera;

        [Header("UI")]
        [SerializeField] private PlaybackDebugPanel debugPanel;

        // 内部组件
        private ImageSeqFrameSource _frameSource;
        private PlaybackController _playbackController;
        private AreaTargetTracker _tracker;
        private AssetBundleLoader _loader;
        private TrackingState _previousState = TrackingState.INITIALIZING;
        private GameObject _originCube;
        private GameObject _glbModelObj;
        private GltfImport _gltfImport;
        private bool _initialized;

        // 当前帧的 Texture2D 预览（复用避免频繁 GC）
        private Texture2D _previewTex;

        void Start()
        {
            debugPanel?.SetStatus("初始化中...", Color.yellow);
            _ = InitializeAsync();
        }

        /// <summary>异步初始化：加载扫描数据和资产包</summary>
        private async Task InitializeAsync()
        {
            string scanDataPath = Path.Combine(Application.streamingAssetsPath, scanDataSubPath);
            string assetPath    = Path.Combine(Application.streamingAssetsPath, assetSubPath);

            // Step 1: 加载扫描数据
            _frameSource = new ImageSeqFrameSource();
            if (!_frameSource.Load(scanDataPath))
            {
                debugPanel?.SetStatus($"扫描数据加载失败: {_frameSource.LastError}", Color.red);
                return;
            }

            // Step 2: 初始化播放控制器
            _playbackController = new PlaybackController();
            _playbackController.Setup(_frameSource.FrameCount);

            debugPanel?.SetupSeekSlider(_frameSource.FrameCount);
            debugPanel?.SetFrameInfo(0, _frameSource.FrameCount, "Paused");

            // Step 3: 加载资产包
            _loader = new AssetBundleLoader();
            if (!_loader.Load(assetPath))
            {
                debugPanel?.SetStatus($"资产包加载失败: {_loader.LastError}", Color.red);
                return;
            }

            var m = _loader.Manifest;
            debugPanel?.SetAssetInfo(m.name, m.version, m.keyframeCount);

            // Step 4: 初始化 AreaTargetTracker（后台线程）
            AreaTargetTracker tracker = null;
            string initError = null;

            await Task.Run(() =>
            {
                try
                {
                    tracker = new AreaTargetTracker();
                    if (!tracker.Initialize(assetPath))
                    {
                        initError = "Tracker 初始化失败";
                        tracker.Dispose();
                        tracker = null;
                    }
                }
                catch (Exception ex)
                {
                    initError = ex.Message;
                    tracker?.Dispose();
                    tracker = null;
                }
            });

            if (tracker == null)
            {
                debugPanel?.SetStatus($"Tracker 初始化失败: {initError}", Color.red);
                return;
            }

            _tracker = tracker;

            // Step 5: 订阅调试面板事件
            if (debugPanel != null)
            {
                debugPanel.OnPlayClicked   += () => _playbackController?.Play();
                debugPanel.OnPauseClicked  += () => _playbackController?.Pause();
                debugPanel.OnStepClicked   += () => _playbackController?.StepForward();
                debugPanel.OnSeekChanged   += idx => _playbackController?.SeekTo(idx);
                debugPanel.OnSpeedChanged  += fps => { if (_playbackController != null) _playbackController.PlaybackFPS = fps; };
            }

            // Step 6: 加载 GLB 模型（如果有）
            if (_loader.MeshPath != null && _loader.MeshPath.EndsWith(".glb"))
                _ = LoadGLBAsync(_loader.MeshPath);

            _initialized = true;
            debugPanel?.SetStatus("就绪 — 按 Play 开始", Color.green);
        }

        void Update()
        {
            if (!_initialized || _playbackController == null) return;

            _playbackController.Tick(Time.deltaTime);

            if (!_playbackController.HasNewFrame) return;

            int idx = _playbackController.CurrentFrameIndex;

            // 获取当前帧并送入 Tracker
            CameraFrame frame = _frameSource.GetFrame(idx);
            TrackingResult result = _tracker.ProcessFrame(frame);

            // 获取 camera-to-world 位姿
            Matrix4x4 cameraPose = _frameSource.GetPose(idx);

            HandleTrackingResult(result, cameraPose);

            // 更新调试面板
            string stateStr = _playbackController.CurrentState == PlaybackController.State.Playing ? "Playing" : "Paused";
            debugPanel?.SetFrameInfo(idx, _frameSource.FrameCount, stateStr);
            debugPanel?.SetTrackingInfo(result.MatchedFeatures, result.Confidence);
            debugPanel?.UpdateSeekSlider(idx);

            // 更新图像预览
            UpdatePreviewTexture(frame);
        }

        private void UpdatePreviewTexture(CameraFrame frame)
        {
            if (debugPanel == null || frame.ImageData == null) return;

            int w = frame.Width, h = frame.Height;
            if (_previewTex == null || _previewTex.width != w || _previewTex.height != h)
            {
                if (_previewTex != null) Destroy(_previewTex);
                _previewTex = new Texture2D(w, h, TextureFormat.R8, false);
            }

            _previewTex.LoadRawTextureData(frame.ImageData);
            _previewTex.Apply();
            debugPanel.SetPreviewImage(_previewTex);
        }

        private void HandleTrackingResult(TrackingResult result, Matrix4x4 cameraPose)
        {
            bool toTracking = result.State == TrackingState.TRACKING
                && _previousState != TrackingState.TRACKING;
            bool toLost = result.State == TrackingState.LOST
                && _previousState == TrackingState.TRACKING;

            // 首次进入 TRACKING：创建原点 Cube
            if (toTracking)
            {
                if (_originCube == null) _originCube = CreateOriginCube();
                _originCube.SetActive(true);
                SetCubeColor(Color.green);
            }

            // TRACKING 状态：更新 Cube 和 GLB 位置
            if (result.State == TrackingState.TRACKING && _originCube != null)
            {
                // scanToWorld = cameraPose (camera-to-world) * result.Pose (world-to-camera)
                Matrix4x4 scanToWorld = cameraPose * result.Pose;

                Vector3 pos = new Vector3(scanToWorld.m03, scanToWorld.m13, scanToWorld.m23);
                Quaternion rot = scanToWorld.rotation;
                _originCube.transform.SetPositionAndRotation(pos, rot);

                if (_glbModelObj != null)
                {
                    Vector3 scale = new Vector3(
                        new Vector3(scanToWorld.m00, scanToWorld.m10, scanToWorld.m20).magnitude,
                        new Vector3(scanToWorld.m01, scanToWorld.m11, scanToWorld.m21).magnitude,
                        new Vector3(scanToWorld.m02, scanToWorld.m12, scanToWorld.m22).magnitude);
                    _glbModelObj.transform.SetPositionAndRotation(pos, rot);
                    _glbModelObj.transform.localScale = scale;
                    _glbModelObj.SetActive(true);
                }
            }

            // LOST：Cube 变红，保持最后位置
            if (toLost)
            {
                SetCubeColor(Color.red);
                if (_glbModelObj != null) _glbModelObj.SetActive(false);
            }

            // 更新调试面板状态颜色
            Color statusColor = result.State switch
            {
                TrackingState.TRACKING     => Color.green,
                TrackingState.LOST         => Color.red,
                TrackingState.INITIALIZING => Color.yellow,
                _                          => Color.white
            };
            debugPanel?.SetStatus(result.State.ToString(), statusColor);

            _previousState = result.State;
        }

        private GameObject CreateOriginCube()
        {
            var cube = GameObject.CreatePrimitive(PrimitiveType.Cube);
            cube.name = "TrackingOriginCube";
            cube.transform.localScale = Vector3.one * 0.1f; // 10cm
            return cube;
        }

        private void SetCubeColor(Color color)
        {
            if (_originCube == null) return;
            var r = _originCube.GetComponent<Renderer>();
            if (r == null) return;
            var block = new MaterialPropertyBlock();
            r.GetPropertyBlock(block);
            block.SetColor("_Color", color);
            r.SetPropertyBlock(block);
        }

        private async Task LoadGLBAsync(string glbPath)
        {
            try
            {
                string uri = glbPath.StartsWith("file://") ? glbPath : "file://" + glbPath;
                _gltfImport = new GltfImport();
                bool ok = await _gltfImport.Load(uri);
                if (!ok) { Debug.LogError("[VideoPlayback] GLB 加载失败"); return; }

                _glbModelObj = new GameObject("GLBModel");
                _glbModelObj.SetActive(false);
                await _gltfImport.InstantiateMainSceneAsync(_glbModelObj.transform);
                Debug.Log("[VideoPlayback] GLB 模型已加载");
            }
            catch (Exception ex)
            {
                Debug.LogError($"[VideoPlayback] GLB 异常: {ex.Message}");
            }
        }

        void OnDestroy()
        {
            _tracker?.Dispose();
            _tracker = null;

            if (_glbModelObj != null) Destroy(_glbModelObj);
            _gltfImport?.Dispose();
            _gltfImport = null;

            if (_previewTex != null) Destroy(_previewTex);
        }
    }
}
