# Changelog

## [1.3.0] - 2026-07-13

### Added
- UPM 包内置 iOS Xcode 后处理、OpenCV framework 与固定的 SQLite `1.3.2` 依赖（经 OpenUPM 解析），支持干净工程独立导出验证。
- 增加 generic iOS device Xcode 链接门禁，验证 UPM 安装路径而非测试工程的 Editor 文件。

### Changed
- iOS 原生定位器链接配置只从已安装 UPM 包解析所需制品；缺少静态库或 framework 时构建立刻失败并报告包内路径。

### Support
- iOS 支持仍以阶段 1 本地 UPM 导出、generic-device Xcode 和真机门禁为准；不声明 Rokid AR Studio、Android ARM64、Windows 或 Linux 支持。

## [1.2.1] - 2026-07-12

### Changed
- 统一由 `package.json` 提供包版本，并固定阶段 0 的 Unity 依赖版本。
- 增加可重复 UPM 打包、统一验证入口和阶段 0 CI 基线。
- 清理生成的测试输出、崩溃转储、备份资产和不受支持的空平台占位文件。

### Added
- 增加包元数据、仓库卫生、原生符号契约和 UPM 内容自动检查。
- 增加 iOS 扫描器与 Unity 干净安装本地发布门禁。

### Support
- 本版本不声明 Rokid AR Studio 或 Android ARM64 支持。

## [1.2.0] - 2026-03-19

### Changed
- 后端移除 v1 旧管线 (pipeline.py)，统一使用 OptimizedPipeline (v2)
- 特征提取逻辑独立为 feature_extraction.py 模块
- BoW 向量测试更新为 TF-IDF + L2 归一化断言

### Added
- GitHub Actions CI/CD (Python 3.10-3.12 测试 + ruff lint)

## [1.1.0] - 2026-03-18

### Changed
- 视觉定位引擎从 OpenCvSharp 迁移到原生 C++ 库 (libvisual_localizer)
- 移除 OpenCvSharp4 依赖，减少包体积约 40MB
- 所有平台（Editor/iOS/Android/Standalone）使用统一的原生库接口

### Added
- `NativeLocalizerBridge.cs` — P/Invoke 桥接层
- 原生库支持 macOS (.dylib)、Windows (.dll)、Linux (.so)、iOS (静态链接)
- `NativeLocalizerBridgeTests.cs` — 原生桥接层单元测试（句柄生命周期、NULL 安全、结构体编组）
- `PerformanceBenchmarkTests.cs` — 性能基准测试（帧处理延迟、吞吐量、内存稳定性）

### Fixed
- iOS 平台使用 `__Internal` 静态链接，避免动态库加载问题

## [1.0.0] - 2026-03-17

### Added
- 初始版本
- AreaTargetTracker 核心跟踪器
- VisualLocalizationEngine（ORB 特征提取 + BoW 检索 + PnP 定位）
- KalmanPoseFilter 姿态平滑
- AssetBundleLoader 资产包加载
- FeatureDatabaseReader SQLite 特征数据库读取
- LocalizationPipeline 端到端定位管线
- AR Foundation 平台支持
- 完整单元测试和属性测试套件
