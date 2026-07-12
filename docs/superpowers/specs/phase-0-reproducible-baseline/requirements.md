# 阶段 0：可重复构建基线需求

**目标版本：** `v1.2.1`

**基线分支：** `develop`

**基线提交：** `81d815f18eac1a55babd21dbfc2c3a7726942e84`

## 1. 目标

在不改变定位算法、资产格式和公开 Unity API 的前提下，把当前仓库整理成可从干净检出重复构建、验证和安装的内部基线。

阶段 0 完成后，iOS 扫描器、Docker 处理服务、Python 测试、macOS 原生定位器、现有 iOS 原生静态库、Unity EditMode 测试和 UPM 安装验证都必须有明确且可重复执行的入口。

## 2. 用户故事

### US-01：从干净仓库开始验证

作为库维护者，我希望在新的工作目录中执行统一命令，以便确认代码、依赖、Docker、原生库、Unity 和 UPM 包是否满足阶段 0 基线。

### US-02：安装一致的 Unity 包

作为内部 Unity 项目开发者，我希望安装一个版本明确、依赖完整、内容与源码一致的 UPM 包，以便无需修改库源码即可完成编译。

### US-03：识别真实的平台支持范围

作为内部项目负责人，我希望文档只声明经过构建和验证的平台，以便不把空占位文件或理论兼容误认为商业支持。

### US-04：获得可信的验证证据

作为发布负责人，我希望每项检查都有明确的通过、失败或跳过状态，以便设备未连接或 Unity 未授权时不会产生虚假的绿色结果。

## 3. 功能需求

### R0.1：仓库卫生

1. 仓库不得跟踪 Unity 崩溃转储、临时测试 XML、过期备份资产或意外嵌套的测试输出目录。
2. 被自动化测试引用的确定性 fixture 可以保留，但必须在 `unity_project/Assets/StreamingAssets/README.md` 说明用途。
3. `.gitignore` 必须阻止已清理的生成物再次进入版本控制。
4. 删除任何 fixture 前必须使用仓库搜索证明没有活动测试引用它。

### R0.2：统一版本

1. `unity_plugin/AreaTargetPlugin/package.json` 是版本号唯一来源。
2. 阶段 0 版本必须是 `1.2.1`。
3. `package.json` 不得包含重复 JSON 键。
4. `CHANGELOG.md`、生成的包名、验证输出和文档必须报告相同版本。
5. `PackageExporter.cs` 不得维护独立的硬编码版本号。

### R0.3：确定性 Unity 依赖

1. `package.json` 中每个依赖只能声明一次。
2. AR Foundation 固定为当前验证版本 `6.0.0`。
3. SQLite 依赖固定为 `com.gilzoide.sqlite-net` 的当前验证版本 `1.3.2`；干净项目通过固定 Git URL `https://github.com/gilzoide/unity-sqlite-net.git#1.3.2` 解析该包。
4. `AreaTargetPlugin.Runtime.asmdef` 的引用必须与 SQLite 包提供的程序集名称一致。
5. FsCheck、测试程序集和测试 DLL 不得进入运行时 UPM 包。

### R0.4：原生制品契约

1. 必需 C API 符号必须保存在 `tools/phase0/required_native_symbols.txt`。
2. macOS 构建完成后必须验证文件非空、架构有效且所有必需符号存在。
3. 现有 iOS ARM64 静态库必须验证架构和必需符号，但阶段 0 不把静态检查等同于真机定位认证。
4. 空的 Windows/Linux 占位二进制不得进入 UPM 包或被文档声明为支持。
5. 阶段 0 不创建 Android ARM64 原生库。

### R0.5：UPM 打包

1. 打包过程必须读取当前源码和 `package.json` 版本。
2. 生成文件必须命名为 `com.areatarget.tracking-1.2.1.tgz`。
3. 包内必须包含 `AlignmentTransformCalculator.cs`、`ExtendedDebugInfo.cs`、`GLBMeshLoader.cs`、AKAZE 集成代码、许可证和示例元数据。
4. 包内不得包含 `Tests/`、`PropertyTests/`、旧归档、崩溃日志、备份资产或空占位二进制。
5. 包内必须包含阶段 0 支持的 macOS 和 iOS 原生制品。
6. 生成目录为 `dist/`，该目录不进入 Git。

### R0.6：统一验证入口

1. `tools/phase0/verify.sh` 是阶段 0 的统一验证入口。
2. 任一必需检查失败时，脚本必须返回非零状态。
3. 脚本必须逐项输出 `PASS`、`FAIL` 或 `SKIP` 及原因。
4. 默认本地完整模式不得把 Unity 或设备检查静默跳过。
5. CI 模式可以显式跳过需要 Unity 授权或真机的检查，但必须输出 `SKIP`，且这些检查仍保留为发布前本地门禁。

### R0.7：CI 基线

1. CI 必须在 `main` 和 `develop` 使用相同工作流。
2. Linux job 必须执行 `python -m pytest tests/ -v --tb=short`。
3. CI 必须验证 `package.json`、Docker Compose 配置和 UPM 包内容。
4. CI 必须构建 Web Service Docker 镜像。
5. macOS job 必须构建原生定位器并验证符号。
6. Unity 凭据未配置前，`AreaTargetPlugin.Tests` 和 `AreaTargetPlugin.Tests.Property` 是明确记录的本地发布门禁；配置后再迁入 CI。

### R0.8：文档与能力声明

1. README 必须区分“已有源码分支”和“阶段 0 已验证支持”。
2. 阶段 0 只声明 macOS 开发验证和 iOS 静态制品检查，不声明 Rokid、Android ARM64、Windows 或 Linux 商业支持。
3. 文档必须记录 Unity、Xcode、Python、OpenCV、Docker 的验证版本。
4. 文档必须提供扫描器、Docker、Python、原生库、Unity 测试和 UPM 安装命令。
5. 发布说明必须记录回滚基线 `81d815f`。

## 4. 可运行产物

阶段 0 必须产生六个互相独立的可运行结果：

1. iOS Scanner 可以为 generic iOS device 完成编译。
2. Docker Compose 配置有效且 Web Service 镜像构建成功。
3. Python `tests/` 全量通过。
4. macOS 原生定位器构建成功；iOS 静态库通过静态检查。
5. Unity 项目依赖解析成功，两个指定 EditMode 测试程序集通过。
6. 新生成的 UPM 包可以安装到临时 Unity 验证项目并完成编译。

## 5. 验收标准

只有同时满足下列条件才可以勾选阶段 0 完成：

- 从干净检出执行完整验证入口后工作树仍然干净。
- 所有非设备必需检查通过。
- iOS Scanner generic device 编译通过。
- 两个 Unity EditMode 测试程序集通过并保存本次结果。
- 最新阶段 0 提交的全部已配置 CI job 为绿色。
- `dist/com.areatarget.tracking-1.2.1.tgz` 可在临时 Unity 项目中安装和编译。
- macOS 原生库和 iOS 静态库具备全部契约符号。
- 文档没有超出阶段 0 的平台支持声明。
- 验证报告包含提交哈希、工具版本、时间和每项结果。

## 6. 非目标

阶段 0 不包含：

- Rokid SDK 或 UXR/OpenXR 相机适配。
- Android ARM64 原生库。
- PnP 与 ARKit/Rokid 世界坐标对齐修复。
- 后台异步定位。
- 算法阈值调整或精度认证。
- 新的扫描器功能。
- 资产格式迁移。
- Windows/Linux 正式发布。
