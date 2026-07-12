# Area Target Tracking Plugin for Unity

开源区域目标扫描与 AR 跟踪 Unity 插件。通过 ORB 特征匹配和 PnP 姿态估计实现 6DoF 视觉定位。

## 功能特性

- 6DoF 视觉定位（ORB 特征 + BoW 检索 + PnP RANSAC）
- Kalman 滤波姿态平滑
- 原生 C++ 引擎，无 OpenCV C# 依赖
- 阶段 0 验证 macOS 开发构建和 iOS 基线；其他平台见下方支持范围
- AR Foundation 集成
- SQLite 特征数据库
- 完整的测试套件（100+ 单元测试 + 属性测试）

## 系统要求

- Unity 6000.4.6f1（阶段 0 验证版本）
- AR Foundation 6.0.0+
- iOS 16.0+

## 阶段 0 支持范围

| 目标平台 | 阶段 0 状态 |
|---|---|
| macOS 开发构建 | 已验证基线 |
| iOS 扫描器通用设备构建 | 已验证基线 |
| iOS 定位器归档 | 仅完成 arm64 架构和静态符号验证 |
| Rokid AR Studio | 计划在阶段 2 实施；阶段 0 不支持 |
| Android ARM64 | 计划在阶段 2 实施；阶段 0 不支持 |
| Windows/Linux 运行时 | 不支持；已移除空占位文件 |

阶段 0 使用 Python 3.11.12、OpenCV 4.13.0、Unity 6000.4.6f1 和 Xcode 26.2 完成本地验证。回滚基线为 `81d815f`。
- 支持 ARKit 或 ARCore 的设备

## 安装

### 方式一：本地路径引用（开发阶段）

编辑 `Packages/manifest.json`：
```json
{
  "dependencies": {
    "com.areatarget.tracking": "file:../../unity_plugin/AreaTargetPlugin"
  }
}
```

### 方式二：阶段 0 UPM 包

在仓库根目录运行 `python3 tools/phase0/build_upm_package.py`，然后通过 Unity Package Manager 安装 `dist/com.areatarget.tracking-1.2.1.tgz`。

## 快速开始

### 1. 准备资产包

使用 Python 后处理管线生成资产包：
```bash
python3 -m processing_pipeline.cli --input scan_data/ --output AreaTargetAssets/my_room/
```

生成的目录结构：
```
AreaTargetAssets/my_room/
├── manifest.json        # 资产清单
├── mesh.obj             # 3D 网格
├── mesh.mtl             # 材质
├── texture_atlas.png    # 纹理图集
└── features.db          # ORB 特征数据库
```

将此目录放入 `Assets/StreamingAssets/` 下。

### 2. 基本用法

```csharp
using AreaTargetPlugin;

public class MyARManager : MonoBehaviour
{
    private AreaTargetTracker _tracker;

    void Start()
    {
        _tracker = new AreaTargetTracker();
        
        string path = Path.Combine(Application.streamingAssetsPath, "AreaTargetAssets/my_room");
        if (!_tracker.Initialize(path))
        {
            Debug.LogError("资产包加载失败");
            return;
        }
    }

    // 每帧调用（通常在 ARCameraManager.frameReceived 回调中）
    void ProcessCameraFrame(byte[] grayscaleImage, int width, int height,
                            float fx, float fy, float cx, float cy)
    {
        var frame = new CameraFrame
        {
            ImageData = grayscaleImage,
            Width = width,
            Height = height,
            Fx = fx, Fy = fy, Cx = cx, Cy = cy
        };

        TrackingResult result = _tracker.ProcessFrame(frame);

        switch (result.State)
        {
            case TrackingState.TRACKING:
                // result.Pose 是 4x4 变换矩阵
                transform.SetPositionAndRotation(
                    result.Pose.GetPosition(),
                    result.Pose.rotation);
                break;
            case TrackingState.LOST:
                // 显示重定位提示
                break;
        }
    }

    void OnDestroy()
    {
        _tracker?.Dispose();
    }
}
```

### 3. AR Foundation 集成

```csharp
using UnityEngine.XR.ARFoundation;
using AreaTargetPlugin;

public class ARAreaTarget : MonoBehaviour
{
    [SerializeField] private ARCameraManager arCameraManager;
    private AreaTargetTracker _tracker;

    void Start()
    {
        _tracker = new AreaTargetTracker();
        _tracker.Initialize(Path.Combine(Application.streamingAssetsPath, "AreaTargetAssets/my_room"));
        arCameraManager.frameReceived += OnCameraFrame;
    }

    void OnCameraFrame(ARCameraFrameEventArgs args)
    {
        if (!arCameraManager.TryAcquireLatestCpuImage(out var cpuImage))
            return;

        // 转换为灰度数据
        byte[] grayscale = ConvertToGrayscale(cpuImage);
        var intrinsics = args.projectionMatrix; // 提取内参

        var frame = new CameraFrame
        {
            ImageData = grayscale,
            Width = cpuImage.width,
            Height = cpuImage.height,
            Fx = intrinsics.m00, Fy = intrinsics.m11,
            Cx = intrinsics.m02, Cy = intrinsics.m12
        };

        TrackingResult result = _tracker.ProcessFrame(frame);
        // 处理结果...

        cpuImage.Dispose();
    }
}
```

## API 参考

### AreaTargetTracker

| 方法 | 说明 |
|------|------|
| `Initialize(string path)` | 加载资产包，返回是否成功 |
| `ProcessFrame(CameraFrame)` | 处理一帧，返回 TrackingResult |
| `GetTrackingState()` | 获取当前跟踪状态 |
| `Reset()` | 重置跟踪（清除 Kalman 滤波器） |
| `Dispose()` | 释放所有资源 |

### TrackingResult

| 字段 | 类型 | 说明 |
|------|------|------|
| `State` | TrackingState | INITIALIZING / TRACKING / LOST |
| `Pose` | Matrix4x4 | 4x4 变换矩阵（行主序） |
| `Confidence` | float | 置信度 [0, 1] |
| `MatchedFeatures` | int | 匹配的特征点数量 |

### CameraFrame

| 字段 | 类型 | 说明 |
|------|------|------|
| `ImageData` | byte[] | 灰度图像数据 |
| `Width` | int | 图像宽度 |
| `Height` | int | 图像高度 |
| `Fx, Fy` | float | 焦距（像素） |
| `Cx, Cy` | float | 主点坐标（像素） |

### TrackingState

| 值 | 说明 |
|----|------|
| `INITIALIZING` | 资产包已加载，等待首次定位 |
| `TRACKING` | 定位成功，持续跟踪中 |
| `LOST` | 跟踪丢失，正在重定位 |

## 原生库

插件使用 C++ 原生库 `libvisual_localizer` 进行视觉定位计算：

| 平台 | 文件 | 位置 |
|------|------|------|
| macOS | libvisual_localizer.dylib | Plugins/macOS/ |
| iOS | libvisual_localizer.a（静态检查基线） | Plugins/iOS/ |

阶段 0 不提供 Android ARM64、Rokid、Windows 或 Linux 运行时原生库。

### 从源码编译原生库

```bash
# macOS (arm64)
cd native_visual_localizer
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DOpenCV_DIR=/path/to/opencv
make -j$(sysctl -n hw.ncpu)
```

### 阶段 0 验证

```bash
tools/phase0/verify.sh local
python3 tools/phase0/build_upm_package.py
tools/phase0/validate_unity_package.sh
```

## 目录结构

```
com.areatarget.tracking/
├── Runtime/                    # 核心运行时代码
│   ├── AreaTargetTracker.cs    # 主跟踪器
│   ├── VisualLocalizationEngine.cs  # 视觉定位引擎
│   ├── NativeLocalizerBridge.cs     # P/Invoke 桥接
│   ├── KalmanPoseFilter.cs    # Kalman 姿态平滑
│   ├── AssetBundleLoader.cs   # 资产包加载
│   ├── FeatureDatabaseReader.cs     # SQLite 特征库
│   ├── LocalizationPipeline.cs      # 端到端管线
│   ├── Interfaces/             # 接口定义
│   ├── Models/                 # 数据模型
│   └── Platforms/              # 平台适配
├── Tests/                      # 单元测试 (18 个文件, 100+ 用例)
├── Editor/                     # 编辑器工具
├── Samples~/AreaTargetExample/ # 示例代码
├── package.json
├── CHANGELOG.md
├── LICENSE.md
├── README.md
└── TEST_GUIDE.md
```

## 许可证

Apache License 2.0
