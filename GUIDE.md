# Area Target Scanner — 测试与运行指南

本项目包含三个模块：**Python 后处理管线**、**iOS 扫描端**、**Unity AR 定位插件**。以下是各模块的环境搭建、测试和运行方法。

---

## 1. Python 后处理管线

### 1.1 环境准备

```bash
# 推荐 Python 3.9+
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
# 额外安装 Pillow（纹理映射需要）
pip install Pillow
```

### 1.2 运行测试

```bash
# 运行全部测试（122 个）
python3 -m pytest tests/ -v

# 只运行属性测试（P1-P4）
python3 -m pytest tests/test_point_cloud_properties.py tests/test_mesh_properties.py tests/test_feature_properties.py -v

# 只运行单元测试
python3 -m pytest tests/test_point_cloud.py tests/test_mesh_reconstruction.py tests/test_texture.py tests/test_feature_extraction.py tests/test_feature_db.py tests/test_asset_export.py -v

# 运行端到端集成测试
python3 -m pytest tests/test_pipeline_run.py -v
```

### 1.3 运行管线（CLI）

管线接受 iOS 扫描端导出的数据包作为输入，输出 Area Target 资产包。

**输入目录结构**（由 iOS 扫描端导出）：

```
scan_data/
├── pointcloud.ply          # 点云文件（XYZ + 颜色 + 法线）
├── poses.json              # 相机位姿列表
├── intrinsics.json         # 相机内参
└── images/                 # 关键帧 RGB 图像
    ├── frame_0000.jpg
    ├── frame_0001.jpg
    └── ...
```

**poses.json 格式**：

```json
{
  "frames": [
    {
      "index": 0,
      "timestamp": 0.0,
      "imageFile": "images/frame_0000.jpg",
      "transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
    }
  ]
}
```

> `transform` 是 4×4 变换矩阵，按列优先（column-major）展开为 16 个浮点数。

**运行命令**：

```bash
python3 -m processing_pipeline.cli --input ./scan_data --output ./asset_bundle --verbose
```

**输出资产包结构**：

```
asset_bundle/
├── manifest.json           # 资产包清单（版本、包围盒、关键帧数等）
├── mesh.obj                # 简化后的三角网格
├── mesh.mtl                # 材质文件
├── texture_atlas.png       # 纹理贴图
└── features.db             # SQLite 特征数据库（ORB 特征 + BoW 词汇表）
```

> 注意：资产包中**不包含**原始 RGB 图像，仅包含处理后的网格、纹理和特征数据。

### 1.4 已知问题

- **Open3D Poisson 重建在 macOS 上可能 segfault**：如果在同一进程中多次调用 `reconstruct_mesh()`，Open3D 可能崩溃。测试中已通过懒加载缓存（`tests/conftest.py`）规避此问题。
- **MVS-Texturing（texrecon）**：如果系统未安装 `texrecon`，纹理映射会自动降级为基于顶点颜色的简单投影。安装 texrecon 可获得更好的纹理质量。

---

## 2. iOS 扫描端（Swift）

### 2.1 环境要求

- macOS + Xcode 15+
- 配备 LiDAR 的 iPhone/iPad（iPhone 12 Pro 及以上）
- iOS 16.0+

### 2.2 打开项目

```bash
# 在 Xcode 中打开项目目录
open ios_scanner/
# 或直接在 Xcode 中 File → Open → 选择 ios_scanner/AreaTargetScanner/
```

> 项目目前没有 `.xcodeproj` 文件，你需要在 Xcode 中创建一个新的 iOS App 项目，
> 然后将 `ios_scanner/AreaTargetScanner/` 下的所有源文件拖入项目中。

### 2.3 配置

1. 在 Xcode 中设置 Bundle Identifier
2. 选择你的开发者签名证书
3. 确保 Target 的 Deployment Target 设为 iOS 16.0+
4. 在 Capabilities 中启用 ARKit

### 2.4 运行测试

```bash
# 在 Xcode 中：Product → Test (⌘U)
# 测试文件位于 ios_scanner/AreaTargetScannerTests/ScanDataExporterTests.swift
```

### 2.5 使用流程

1. 在真机上运行 App
2. 点击「开始扫描」，缓慢移动设备扫描目标区域
3. 界面会实时显示点云点数、覆盖面积和 3D 预览
4. 扫描完成后点击「停止扫描」
5. 点击「导出」，数据将保存到设备本地
6. 通过 AirDrop 或 Files 将导出的数据包传输到电脑
7. 使用 Python 管线处理导出的数据包

---

## 3. Unity AR 定位插件（C#）

### 3.1 环境要求

- Unity 6000.0+、AR Foundation 6.0+
- 固定 OpenCV 5.0.0 + contrib 的原生定位库与 iOS framework，按[打包说明](unity_plugin/AreaTargetPlugin/BUILD_PACKAGE.md)构建
- SQLite-net 和 ARKit 依赖由 UPM 包管理；启用 OpenUPM 的 `com.gilzoide` scope

### 3.2 导入插件

1. 按打包说明构建并部署匹配的 OpenCV 5 原生依赖
2. 运行 `python tools/phase0/build_upm_package.py`，生成包含原生库、framework 和许可的 `dist/com.areatarget.tracking-<version>.tgz`
3. 打开 Unity 项目，在 Package Manager 中选择「Add package from tarball」，选择生成的包

### 3.3 运行测试

```
# 在 Unity 中：Window → General → Test Runner
# 选择 EditMode 标签页
# 点击 Run All 运行所有测试
```

测试文件位于 `unity_plugin/AreaTargetPlugin/Tests/`：

| 测试文件 | 覆盖内容 |
|---------|---------|
| `AssetBundleLoaderTests.cs` | 资产包加载与验证 |
| `AreaTargetTrackerInitTests.cs` | 跟踪器初始化 |
| `VisualLocalizationTests.cs` | PnP 求解、特征匹配 |
| `PnPPropertyTests.cs` | 属性 P5：PnP 结果有效性 |
| `KalmanPoseFilterTests.cs` | 卡尔曼滤波平滑 |
| `PoseSmoothingPropertyTests.cs` | 属性 P6：平滑偏差约束 |
| `TrackingStateTests.cs` | 状态转换、Reset、Dispose |

### 3.4 在代码中使用

```csharp
using AreaTargetPlugin;

// 创建跟踪器
var tracker = new AreaTargetTracker();

// 加载资产包（Python 管线的输出目录）
bool ok = tracker.Initialize("/path/to/asset_bundle");
if (!ok) {
    Debug.LogError("加载失败");
    return;
}

// 每帧处理
void Update() {
    // 从 AR Camera 获取灰度图像和内参
    var frame = new CameraFrame {
        ImageData = grayscaleBytes,
        Width = 640,
        Height = 480,
        Intrinsics = cameraIntrinsicMatrix  // 3x3 Matrix4x4
    };

    TrackingResult result = tracker.ProcessFrame(frame);

    if (result.State == TrackingState.TRACKING) {
        // result.Pose 是相对于 Area Target 坐标系的 4x4 位姿矩阵
        // result.Confidence 是置信度 [0.0, 1.0]
        transform.SetPositionAndRotation(
            result.Pose.GetPosition(),
            result.Pose.rotation
        );
    }
}

// 重置跟踪（重新定位）
tracker.Reset();

// 释放资源
tracker.Dispose();
```

---

## 4. 端到端工作流

完整的使用流程如下：

```
┌─────────────────┐     导出数据包     ┌──────────────────┐     资产包     ┌─────────────────┐
│   iOS 扫描端     │ ──────────────→  │  Python 后处理    │ ──────────→  │  Unity AR 插件   │
│  (iPhone/iPad)  │   PLY + 图像 +    │    管线           │  mesh.obj +  │  (AR 应用)       │
│                 │   poses.json      │                  │  features.db │                 │
└─────────────────┘                   └──────────────────┘              └─────────────────┘
```

1. **扫描**：使用 iOS App 在目标区域进行 LiDAR 扫描，采集点云和关键帧图像
2. **传输**：将导出的扫描数据包传输到电脑
3. **处理**：运行 Python 管线生成资产包
   ```bash
   python3 -m processing_pipeline.cli --input ./scan_data --output ./asset_bundle --verbose
   ```
4. **部署**：将资产包放入 Unity 项目，使用 `AreaTargetTracker` 进行 AR 定位

---

## 5. 项目结构速查

```
.
├── processing_pipeline/        # Python 后处理管线
│   ├── pipeline.py             #   核心管线（6 步处理流程）
│   ├── models.py               #   数据模型定义
│   ├── feature_db.py           #   SQLite 特征数据库读写
│   ├── cli.py                  #   命令行入口
│   └── utils.py                #   工具函数
├── tests/                      # Python 测试（122 个）
│   ├── conftest.py             #   共享 fixture（懒加载网格缓存）
│   ├── test_point_cloud*.py    #   点云预处理测试 + 属性 P1
│   ├── test_mesh_*.py          #   网格重建/简化测试 + 属性 P2/P3
│   ├── test_feature_*.py       #   特征提取测试 + 属性 P4
│   ├── test_texture*.py        #   纹理映射测试
│   ├── test_asset_export.py    #   资产包导出测试
│   └── test_pipeline_run.py    #   端到端集成测试
├── ios_scanner/                # iOS 扫描端（Swift）
│   ├── AreaTargetScanner/
│   │   ├── Services/           #   ARKit 扫描服务 + 数据导出
│   │   ├── Models/             #   数据模型
│   │   └── Views/              #   扫描进度 UI + 3D 预览
│   └── AreaTargetScannerTests/ #   单元测试
├── unity_plugin/               # Unity AR 定位插件（C#）
│   └── AreaTargetPlugin/
│       ├── Runtime/            #   运行时代码
│       │   ├── AreaTargetTracker.cs          # 主跟踪器
│       │   ├── VisualLocalizationEngine.cs   # 视觉定位引擎
│       │   ├── KalmanPoseFilter.cs           # 卡尔曼滤波
│       │   ├── FeatureDatabaseReader.cs      # 特征数据库读取
│       │   └── AssetBundleLoader.cs          # 资产包加载
│       └── Tests/              #   NUnit 测试（含属性测试 P5/P6）
├── requirements.txt            # Python 依赖
└── pyproject.toml              # pytest 配置
```
