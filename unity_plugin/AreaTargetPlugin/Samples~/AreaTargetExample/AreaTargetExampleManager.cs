using System;
using UnityEngine;
using UnityEngine.UI;
using UnityEngine.XR.ARFoundation;
using AreaTargetPlugin;

/// <summary>
/// 示例场景管理器：演示如何使用 AreaTargetPlugin 进行 AR 区域定位。
///
/// 使用方法：
/// 1. 将此脚本挂载到场景中的空 GameObject 上
/// 2. 在 Inspector 中设置 assetBundlePath 为 Python 管线输出的资产包路径
/// 3. 将 AR Camera 的 ARCameraManager 拖入 arCameraManager 字段
/// 4. 将需要锚定到 Area Target 坐标系的内容放在 areaTargetOrigin 下
/// </summary>
public class AreaTargetExampleManager : MonoBehaviour
{
    [Header("Area Target 配置")]
    [Tooltip("资产包路径（Python 管线输出目录，包含 manifest.json）")]
    [SerializeField] private string assetBundlePath = "AreaTargetAssets/my_room";

    [Header("AR 组件")]
    [Tooltip("AR Camera Manager，用于获取相机图像")]
    [SerializeField] private ARCameraManager arCameraManager;

    [Header("场景引用")]
    [Tooltip("Area Target 坐标系原点，跟踪成功后此物体会对齐到真实世界")]
    [SerializeField] private Transform areaTargetOrigin;

    [Tooltip("可选：跟踪丢失时显示的提示 UI")]
    [SerializeField] private GameObject lostIndicatorUI;

    [Header("调试")]
    [Tooltip("状态文本（可选）")]
    [SerializeField] private Text statusText;

    private AreaTargetTracker _tracker;
    private bool _initialized;
    private Texture2D _cameraTexture;

    void Start()
    {
        _tracker = new AreaTargetTracker();

        // 解析资产包路径（支持 StreamingAssets 相对路径）
        string fullPath = System.IO.Path.IsPathRooted(assetBundlePath)
            ? assetBundlePath
            : System.IO.Path.Combine(Application.streamingAssetsPath, assetBundlePath);

        bool ok = _tracker.Initialize(fullPath);
        if (!ok)
        {
            Debug.LogError($"[AreaTargetExample] 资产包加载失败: {fullPath}");
            UpdateStatus("初始化失败", Color.red);
            return;
        }

        _initialized = true;
        UpdateStatus("初始化完成，正在定位...", Color.yellow);
        Debug.Log($"[AreaTargetExample] 资产包加载成功: {fullPath}");

        // 订阅 AR 相机帧事件
        if (arCameraManager != null)
        {
            arCameraManager.frameReceived += OnCameraFrameReceived;
        }
        else
        {
            Debug.LogWarning("[AreaTargetExample] 未设置 ARCameraManager，请手动调用 ProcessFrame");
        }

        // 初始隐藏 Area Target 内容
        if (areaTargetOrigin != null)
            areaTargetOrigin.gameObject.SetActive(false);

        if (lostIndicatorUI != null)
            lostIndicatorUI.SetActive(true);
    }

    /// <summary>
    /// AR 相机每帧回调：获取灰度图像，送入跟踪器处理。
    /// </summary>
    private void OnCameraFrameReceived(ARCameraFrameEventArgs args)
    {
        if (!_initialized) return;

        // 尝试获取 CPU 端的相机图像
        if (!arCameraManager.TryAcquireLatestCpuImage(out XRCpuImage cpuImage))
            return;

        // 转换为灰度
        var conversionParams = new XRCpuImage.ConversionParams
        {
            inputRect = new RectInt(0, 0, cpuImage.width, cpuImage.height),
            outputDimensions = new Vector2Int(cpuImage.width, cpuImage.height),
            outputFormat = TextureFormat.R8, // 单通道灰度
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

        // 构建相机内参矩阵
        Matrix4x4 intrinsics = BuildIntrinsicsMatrix(width, height);

        // 构建 CameraFrame 并处理
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
    /// 根据跟踪结果更新场景。
    /// </summary>
    private void HandleTrackingResult(TrackingResult result)
    {
        switch (result.State)
        {
            case TrackingState.TRACKING:
                // 跟踪成功：将 Area Target 原点对齐到真实世界
                if (areaTargetOrigin != null)
                {
                    areaTargetOrigin.gameObject.SetActive(true);

                    // result.Pose 是 world-to-camera 变换（PnP 输出经 flip 后）。
                    // 要把模型放到 ARKit 世界中，需要：
                    //   T_model→ARKit = T_camera→ARKit * T_model→camera
                    // 其中 T_camera→ARKit = AR 相机的 localToWorldMatrix，
                    //       T_model→camera = result.Pose (w2c)。
                    Matrix4x4 cameraPose = arCameraManager != null
                        ? arCameraManager.transform.localToWorldMatrix
                        : Matrix4x4.identity;
                    Matrix4x4 modelToWorld = cameraPose * result.Pose;

                    Vector3 position = new Vector3(
                        modelToWorld.m03,
                        modelToWorld.m13,
                        modelToWorld.m23
                    );
                    Quaternion rotation = modelToWorld.rotation;

                    // 平滑插值（避免跳变）
                    areaTargetOrigin.position = Vector3.Lerp(
                        areaTargetOrigin.position, position, 0.3f);
                    areaTargetOrigin.rotation = Quaternion.Slerp(
                        areaTargetOrigin.rotation, rotation, 0.3f);
                }

                if (lostIndicatorUI != null)
                    lostIndicatorUI.SetActive(false);

                UpdateStatus(
                    $"跟踪中 | 置信度: {result.Confidence:P0} | 特征: {result.MatchedFeatures}",
                    Color.green);
                break;

            case TrackingState.LOST:
                if (lostIndicatorUI != null)
                    lostIndicatorUI.SetActive(true);

                UpdateStatus("跟踪丢失，请对准扫描区域", Color.red);
                break;

            case TrackingState.INITIALIZING:
                UpdateStatus("正在初始化...", Color.yellow);
                break;
        }
    }

    /// <summary>
    /// 从 AR Foundation 的投影矩阵估算相机内参。
    /// 实际项目中建议从 ARCameraManager.TryGetIntrinsics 获取精确值。
    /// </summary>
    private Matrix4x4 BuildIntrinsicsMatrix(int width, int height)
    {
        // 尝试从 AR Foundation 获取精确内参
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

        // 降级：使用经验估算值
        float fx = Mathf.Max(width, height) * 0.8f;
        float fy = fx;
        float cx = width / 2f;
        float cy = height / 2f;

        var fallback = Matrix4x4.zero;
        fallback.m00 = fx;
        fallback.m11 = fy;
        fallback.m02 = cx;
        fallback.m12 = cy;
        fallback.m22 = 1f;
        return fallback;
    }

    private void UpdateStatus(string message, Color color)
    {
        if (statusText != null)
        {
            statusText.text = message;
            statusText.color = color;
        }
    }

    /// <summary>
    /// 公开方法：重置跟踪（可绑定到 UI 按钮）。
    /// </summary>
    public void ResetTracking()
    {
        if (_tracker == null) return;

        _tracker.Reset();
        UpdateStatus("已重置，正在重新定位...", Color.yellow);

        if (areaTargetOrigin != null)
            areaTargetOrigin.gameObject.SetActive(false);
        if (lostIndicatorUI != null)
            lostIndicatorUI.SetActive(true);

        Debug.Log("[AreaTargetExample] 跟踪已重置");
    }

    void OnDestroy()
    {
        if (arCameraManager != null)
            arCameraManager.frameReceived -= OnCameraFrameReceived;

        _tracker?.Dispose();
        _tracker = null;
    }
}
