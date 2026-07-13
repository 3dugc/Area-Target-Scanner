# 阶段 1：iOS 完整扫描与定位工作流设计

## 1. 设计原则

阶段 1 采用“坐标合同先于现场调参”的最小扩展策略。保留现有 Swift 扫描器、Python 处理管线、C++ native localizer、Unity UPM 包和现有地图格式；只把其中已经存在但语义断裂的链路收敛到一个可测、可打包、可诊断的 iOS Runtime。

本阶段不为 Rokid 预埋平台分支、不引入网络服务、不修改 ORB/AKAZE/BoW/PnP 算法的选择或阈值。所有新接口必须由 iOS Runtime 的真实需要驱动，并保持可在 Unity Editor 测试中替换。

## 2. 目标架构

```text
iOS Scanner
  ARKit frame C2W + image orientation + intrinsics
  → scan ZIP (明确 column-major 与帧元数据)
  → Python processing pipeline
  → map bundle + features.db + map manifest
  → Unity UPM runtime
      AR Foundation adapter
        → LocalizationFrame (T_U_C, image, intrinsics, frameId)
        → AsyncLocalizationRunner (single native owner)
        → VisualLocalizationEngine/native PnP (T_C_S)
        → CoordinateTransform (T_U_S = T_U_C × T_C_S)
        → SceneUpdater (apply validated content root pose)
        → bounded DiagnosticRecorder/export
```

`ARTestSceneManager` 和 `SLAMTestSceneManager` 只负责采集/展示/生命周期接入；它们不得再承担矩阵换算、worker 线程、native 反射访问或诊断存储逻辑。

## 3. 坐标与数据合同

### 3.1 唯一的运行时帧载荷

新增 `LocalizationFrame`，以值对象承载一次定位所需的所有数据：

```csharp
public readonly struct LocalizationFrame
{
    public long FrameId { get; }
    public long CaptureTimestampNs { get; }
    public byte[] GrayscaleImage { get; }
    public int Width { get; }
    public int Height { get; }
    public Vector4 Intrinsics { get; }
    public ImageOrientation Orientation { get; }
    public Matrix4x4 UnityWorldFromCamera { get; }
    public string MapId { get; }
}
```

构造函数复制数组并验证：图像长度等于 `width × height`、尺寸与内参均为正、`frameId` 非负、矩阵为有限的刚体变换。图像旋转只在 `ARFoundationPlatformSupport` 内规范化；内参在同一处按旋转后的宽高同步变换。进入 `AsyncLocalizationRunner` 的图像永远为 single-channel、row-major、方向已规范化的灰度像素。

### 3.2 矩阵转换边界

新增内部 `CoordinateTransform`，它是唯一允许组合空间变换的 Runtime 类型：

```text
native PnP result       = T_C_S
AR Foundation frame pose = T_U_C
content root pose        = T_U_S = T_U_C × T_C_S
```

`VisualLocalizationEngine` 只负责把 row-major native `VLResult.pose` 解码为 `T_C_S`，不得再将其保存为“last AR pose”。`AreaTargetTracker` 缓存完整成功帧对 `(T_U_C, T_C_S)`，并把它们交给改造后的 `AlignmentTransformCalculator`。alignment 的空间、是否求逆、乘法顺序和传给 `vl_set_alignment_transform` 的序列化方式由 `CoordinateTransform` 明确命名并通过 fixture 断言；native API 注释和 C# bridge 必须使用同一名称。

跨语言 fixture 使用合成矩阵和纯元数据，不携带真实 JPEG。它至少包含：ARKit column-major pose、规范化图像方向、每帧内参、处理管线输入矩阵、SQLite row-major blob、预期 `T_C_S`、预期 `T_U_S`。Swift tests、Python tests、C# EditMode tests 分别读取同一个版本化 fixture 并比对容差。

### 3.3 扫描导出调整

`CameraPose.swift` 和 `ScanDataExporter.swift` 继续输出兼容的 `poses.json`，但每个 keyframe 增加显式 `imageOrientation` 与 `intrinsics` 或 `intrinsicsRef`。顶层 manifest 声明：坐标系为 ARKit world、矩阵布局为 column-major、长度单位为米、图像规范化规则和 schema 版本。`processing_pipeline` 只接受声明的 schema；缺失/未知方向、非 16 元矩阵、非有限内参或图像尺寸不匹配时快速失败。

## 4. 异步定位运行器

### 4.1 所有权与生命周期

新增 `AsyncLocalizationRunner`，创建时接收一个已经初始化的 `VisualLocalizationEngine`。它拥有该 engine 直到 `DisposeAsync` 返回；因此 native handle 的 `vl_process_frame[_out]`、`vl_reset` 和 `vl_destroy` 永远在 worker 生命周期序列内发生。

```text
Created
  → Start
  → Running
  → Resetting (停止接收，worker 空闲后 reset)
  → Running
  → Disposing (停止接收，worker 退出并 join)
  → Disposed
```

违反状态机的调用返回明确错误：未启动提交、已处置提交、mapId 不匹配的结果和重复启动均不触发 native 调用。`AreaTargetTracker` 只向 runner 提交帧和读取结果，不再直接同步调用 `VisualLocalizationEngine.ProcessFrame`。

### 4.2 latest-frame 策略

主线程调用 `Submit(frame)` 时，在输入锁中替换尚未被 worker 取走的帧并增加 `overwrittenPendingFrames`。worker 醒来后取出一个完整的 frame 值，清空 pending 槽，再在锁外处理。输出槽只保留最新完成的结果。

结果 `LocalizationFrameResult` 至少含输入 frame ID、capture timestamp、worker start/end timestamp、`T_C_S`、`T_U_S`、tracking state、quality、debug info 和 failure category。主线程按 map generation、frame ID 与最大年龄过滤；失败、旧 generation、乱序或超龄结果只写诊断，不更新场景。

`ResetAsync` 先递增 generation 并清空输入/输出，随后请求 worker 进入同步点，完成 native reset 后再接受新帧。`DisposeAsync` 使用相同路径，然后等待 worker 退出并销毁 engine；无法在限定等待时间内退出时报告错误且不释放仍可能被使用的 handle。

### 4.3 线程边界

- AR Foundation、Unity `Transform`、`SceneUpdater`、UI 和日志摘要仅在主线程访问。
- native localizer、其 debug info 与 alignment 设置仅由 worker 访问。
- native 初始化和地图数据加载发生在 worker 开始前；native 数据加载不与定位并发。
- `DiagnosticRecorder` 接受不可变记录，可从 worker 写入、主线程导出；不保存图像数组。

## 5. iOS 包闭环

### 5.1 UPM 内容

将当前只存在于 `unity_project/Assets/Editor/iOSPostProcess.cs` 的可复用后处理迁移到 `unity_plugin/AreaTargetPlugin/Editor/`。后处理从 `PackageInfo.FindForAssembly` 或包内固定相对路径定位 OpenCV iOS framework，复制/引用到导出的 Xcode 工程，并添加系统 framework 和 linker flags。

原生 `libvisual_localizer.a` 与 OpenCV iOS framework 的来源、架构和许可证在 UPM 包内可追溯。生成器将检查它们均存在且为 arm64 iOS 制品；缺一项即停止打包。

`package.json` 保留 SQLite 的固定 package 依赖，并通过干净项目的原始 manifest 解析。`validate_unity_package.sh` 不再向临时项目注入 SQLite Git URL；如果包元数据无法解析，它必须失败。

### 5.2 iOS 门禁

新增验证会在新建临时 Unity 工程中：安装当前 `.tgz`、导入最小 iOS sample、执行 `BuildiOS.BuildDevelopment`、再用 `xcodebuild -destination 'generic/platform=iOS'` 编译。该检查验证真实链接路径，取代只检查源文本或 static archive 符号的做法。

真机门禁仍在本地执行：以开发签名安装应用、加载带 `features.db` 的地图、打开相机并产生一份诊断记录。它不上传 scan 或用户画面。

## 6. 诊断模型

新增版本化 `LocalizationDiagnosticRecord` 和 `LocalizationDiagnosticExporter`。每条记录可序列化为 JSON Lines，字段分为：

- **身份：** schema、UTC 时间、build、UPM 版本、map ID/version/hash、设备和 iOS 版本。
- **帧：** frame ID、capture timestamp、map generation、队列覆盖次数、结果年龄、worker 耗时。
- **定位：** state、quality、confidence、是否应用 `T_U_S`、failure category。
- **算法：** ORB、AKAZE、candidate、raw/good match、inlier、BoW similarity、consistency。

`BoundedDiagnosticBuffer` 按固定条数保存记录，达到上限时删最旧记录并累计丢弃数。导出器拒绝包含图像/扫描路径的字段，输出到应用可共享的诊断目录。所有现场验收记录引用导出的文件哈希，而不是把数据塞入 Git。

## 7. 文件结构

### 新建

```text
docs/superpowers/specs/phase-1-ios-workflow/
tools/phase1/verify.sh
tools/phase1/validate_ios_upm_build.sh
tools/phase1/validate_scan_contract.py
tests/phase1/test_scan_contract.py
tests/fixtures/phase1/coordinate-contract-v1.json
unity_plugin/AreaTargetPlugin/Runtime/LocalizationFrame.cs
unity_plugin/AreaTargetPlugin/Runtime/LocalizationFrameResult.cs
unity_plugin/AreaTargetPlugin/Runtime/CoordinateTransform.cs
unity_plugin/AreaTargetPlugin/Runtime/AsyncLocalizationRunner.cs
unity_plugin/AreaTargetPlugin/Runtime/LocalizationDiagnosticRecord.cs
unity_plugin/AreaTargetPlugin/Runtime/BoundedDiagnosticBuffer.cs
unity_plugin/AreaTargetPlugin/Runtime/LocalizationDiagnosticExporter.cs
unity_plugin/AreaTargetPlugin/Editor/iOSPostProcess.cs
unity_plugin/AreaTargetPlugin/Tests/CoordinateTransformTests.cs
unity_plugin/AreaTargetPlugin/Tests/AsyncLocalizationRunnerTests.cs
unity_plugin/AreaTargetPlugin/Tests/LocalizationDiagnosticTests.cs
unity_plugin/AreaTargetPlugin/Tests/UPMiOSBuildIntegrationTests.cs
docs/phase-1-ios-validation.md
docs/phase-1-device-acceptance-template.md
```

### 修改

```text
ios_scanner/AreaTargetScanner/Models/CameraPose.swift
ios_scanner/AreaTargetScanner/Services/ARKitScannerService.swift
ios_scanner/AreaTargetScanner/Services/ScanDataExporter.swift
ios_scanner/AreaTargetScannerTests/ScanDataExporterTests.swift
processing_pipeline/optimized_pipeline.py
processing_pipeline/feature_extraction.py
processing_pipeline/feature_db.py
tests/test_feature_db.py
tests/test_feature_extraction.py
native_visual_localizer/include/visual_localizer.h
native_visual_localizer/src/visual_localizer_impl.cpp
unity_plugin/AreaTargetPlugin/Runtime/CameraFrame.cs
unity_plugin/AreaTargetPlugin/Runtime/CameraDataAdapter.cs
unity_plugin/AreaTargetPlugin/Runtime/VisualLocalizationEngine.cs
unity_plugin/AreaTargetPlugin/Runtime/AreaTargetTracker.cs
unity_plugin/AreaTargetPlugin/Runtime/AlignmentTransformCalculator.cs
unity_plugin/AreaTargetPlugin/Runtime/NativeLocalizerBridge.cs
unity_plugin/AreaTargetPlugin/Runtime/Platforms/ARFoundationPlatformSupport.cs
unity_plugin/AreaTargetPlugin/Runtime/IAreaTargetTracker.cs
unity_plugin/AreaTargetPlugin/Runtime/Interfaces/ICameraData.cs
unity_plugin/AreaTargetPlugin/package.json
unity_plugin/AreaTargetPlugin/CHANGELOG.md
unity_plugin/AreaTargetPlugin/README.md
tools/phase0/build_upm_package.py
tools/phase0/validate_unity_package.sh
unity_project/Assets/Editor/BuildiOS.cs
unity_project/Assets/Editor/iOSPostProcess.cs
unity_project/Assets/Scripts/ARTestSceneManager.cs
unity_project/Assets/Scripts/SLAMTestScene/SLAMTestSceneManager.cs
README.md
TEST_PLAN.md
docs/ios-device-test-guide.md
.github/workflows/ci.yml
```

## 8. 错误处理与恢复

| 类别 | 行为 | 场景影响 |
|---|---|---|
| `UnsupportedDevice` | 启动前拒绝并记录 LiDAR/AR 要求 | 不创建 tracker 或 native handle |
| `InvalidFrame` | 拒绝图像、内参、方向或矩阵无效的 frame | 不提交 worker，不移动内容 |
| `MapLoadFailed` | 记录地图/SQLite/native 初始化错误 | 显示可恢复错误，不开始相机定位 |
| `LocalizationFailed` | 保存算法统计 | 保持最后已验证内容根位姿 |
| `StaleResult` | 丢弃并记录原因 | 不覆盖较新 AR 世界状态 |
| `LifecycleFailure` | 停止接受帧、报告 worker/handle 状态 | 不调用不安全的 destroy |
| `PackageBuildFailed` | 立即退出 UPM/iOS 导出验证 | 不生成可发布包 |

内容根节点只在 `LocalizationFrameResult` 同时满足：当前 map generation、tracking 成功、坐标转换有效、结果未超龄时更新。失锁不会把内容移到 identity 或未验证位姿。

## 9. 测试与发布策略

自动化按由内向外的层次执行：

1. Swift/Python fixture 与 schema 单元测试。
2. C++/C# row-major、PnP 和 `T_U_S` 坐标测试。
3. Unity EditMode 生命周期、latest-frame、过期结果、诊断 schema 测试。
4. Unity PlayMode/runtime sample 测试。
5. 干净 UPM 安装、Unity iOS 导出和 generic-device Xcode 编译。
6. iPhone/iPad 真机 smoke test。
7. 三场地、双设备、连续 30 分钟的阶段验收。

`tools/phase1/verify.sh ci` 只运行无需签名/设备的检查；`local` 额外要求 Unity、Xcode 和 generic-device build；`device` 要求通过 USB 可见的指定 iPhone/iPad 并生成验收记录。阶段发布前，三种模式均必须有明确结果；CI 不把设备缺失报告为通过。

版本升级到 `1.3.0` 后，先在 `develop` 运行 CI，再按 `develop → main → publish` 门禁提升。阶段 1 的回滚目标为阶段 0 发布提交 `d656f09`，并保留其 `1.2.1` UPM 制品引用。
