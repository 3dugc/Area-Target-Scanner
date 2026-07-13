# 阶段 1：iOS 完整扫描与定位工作流需求

**目标版本：** `v1.3.0`

**基线分支：** `develop`

**基线提交：** `d656f09b7d62ad663f02cbd65deb7d299b85650a`

## 1. 目标

将当前已可重复构建的基线提升为可在 LiDAR iPhone 和 LiDAR iPad 上真实运行的 iOS Area Target 工作流：设备扫描空间、处理扫描数据、加载生成地图、定位并稳定显示 Unity 内容。

阶段 1 的重点是把坐标语义、运行时线程边界、iOS 安装包依赖和现场诊断做成可验证的库能力。它不扩展 Rokid、Android 或跨平台 API 范围。

## 2. 术语与坐标契约

本阶段所有实现、测试、日志和文档必须使用下列符号；不得在场景脚本中另行推导或以未标注的 `Pose`、`AT` 表示不同空间的变换。

| 符号 | 含义 | 方向 |
|---|---|---|
| `S` | 扫描地图坐标系 | 扫描器导出的 mesh、关键帧和 3D 点坐标系 |
| `C` | 当前相机坐标系 | 当前 AR Foundation 相机坐标系 |
| `U` | Unity AR 世界坐标系 | 当前运行时可渲染内容所在坐标系 |
| `T_U_C` | 当前相机在 Unity 世界中的位姿 | `C → U`，由 AR Foundation 当前帧采集 |
| `T_C_S` | native PnP 返回的扫描地图到当前相机变换 | `S → C`，即 world-to-camera PnP 结果 |
| `T_U_S` | 内容根节点应使用的最终地图变换 | `S → U`，`T_U_C × T_C_S` |

矩阵均表示列向量左乘的 4×4 齐次变换；Unity/C# 与 native 交换时使用明确的 row-major `float[16]` 序列。Swift 扫描导出的 ARKit column-major 数组在进入 Python 前只能由一个显式转换函数转换。任何图像旋转、镜像或内参变换必须和对应帧一起保存并验证。

## 3. 用户故事

### US-01：扫描并复现同一空间

作为现场采集人员，我希望在 LiDAR iPhone 或 LiDAR iPad 上获得具有明确姿态、图像方向和内参语义的扫描 ZIP，以便后续处理和定位能使用同一坐标合同。

### US-02：在 iOS 上定位并显示内容

作为内部应用开发者，我希望安装独立 UPM 包后能导出和编译 iOS 应用，使扫描地图中的内容在当前 AR 世界正确出现，而不是依赖测试场景中的手写坐标换算。

### US-03：保持 AR 体验流畅

作为设备用户，我希望视觉定位不会阻塞 Unity 主线程，旧帧结果不会覆盖新帧状态，失去定位后能安全恢复。

### US-04：诊断现场问题

作为测试人员，我希望导出不含采集图像的结构化诊断记录，以便判断是地图、相机、native 初始化、定位、队列延迟还是坐标契约导致问题。

### US-05：进行真机验收

作为发布负责人，我希望 iPhone 与 iPad 都在三个真实场地完成完整工作流和连续运行验证，以便阶段 2 的 Rokid 适配建立在可信 iOS 基础上。

## 4. 功能需求

### R1.1：跨语言坐标与帧数据契约

1. Runtime 必须定义不可变的定位帧载荷，至少包含：`frameId`、单调递增 `captureTimestampNs`、灰度图像、宽高、`fx/fy/cx/cy`、图像方向、`T_U_C` 和地图标识。
2. `ICameraData`、`CameraFrame`、`AreaTargetTracker` 和 `VisualLocalizationEngine` 必须能够将当前帧 `T_U_C` 传递到 native 调用；不得再以“上一帧 PnP 结果”代替当前 AR 相机位姿。
3. native 返回的 PnP 矩阵必须在 Runtime 中标注为 `T_C_S`，并仅由一个坐标转换组件计算 `T_U_S = T_U_C × T_C_S`。
4. `AlignmentTransformCalculator` 的输入、输出和 native `vl_set_alignment_transform` 的空间方向与乘法顺序必须被固定文档化，并用固定样本测试；场景管理器不得自行计算或覆盖 alignment。
5. Swift 扫描器必须为每一张保留的关键帧记录实际图像方向和对应内参；若相机内参在本次扫描中恒定，导出仍必须声明其适用帧范围。
6. Python 处理管线、SQLite 存储、C++ 头文件和 C# bridge 必须对矩阵布局和单位（米、弧度/角度）有一致、可测试的声明。
7. 提供一套不含真实图片的跨语言 fixture，覆盖 Swift JSON → Python 处理输入 → SQLite pose blob → native row-major 数组 → Unity `Matrix4x4` 的矩阵、方向和内参往返验证。

### R1.2：单工作线程的异步定位

1. UPM Runtime 必须提供一个异步定位运行器，唯一负责调用同一个 native localizer handle 的 `ProcessFrame`、`Reset` 和 `Dispose`。
2. 主线程提交帧时必须深拷贝图像和矩阵数据；运行器只保留最新待处理帧，覆盖较旧待处理帧，不建立无界队列。
3. 每个结果必须携带输入 `frameId`、采集时间、开始与结束时间、处理耗时和定位状态。
4. 主线程只可消费仍属于当前地图且未超过配置最大年龄的结果；过期、乱序、来自 reset 前世代或失败的结果不得移动内容根节点。
5. `Reset` 与 `Dispose` 必须先停止接收新帧、唤醒 worker、等待 worker 完成 native 调用，再调用 native reset/destroy；不得让 Unity 主线程与 worker 并发访问 native handle。
6. 初始化期间加载 vocabulary、keyframe 和 AKAZE 数据必须完成后才启动 worker；运行期间不得并发调用 native 数据加载接口。
7. 运行器应提供显式 `Start`、`Submit`、`TryDequeueLatest`、`ResetAsync` 和 `DisposeAsync` 生命周期入口，且重复调用的行为可预测、可测试。

### R1.3：iOS 独立 UPM 安装与 Xcode 链接

1. 生成的 UPM 包必须包含 iOS 必需的 `libvisual_localizer.a`、iOS 后处理代码和其所需元数据，不得依赖 `unity_project/Assets/Editor/` 中的源文件。
2. iOS 后处理必须从 UPM 安装路径解析 OpenCV framework 或等价可链接制品，并向导出的 Xcode 工程添加正确的 framework、搜索路径和系统库；缺失依赖时构建必须失败并给出明确原因。
3. `com.gilzoide.sqlite-net` 必须仅通过 `package.json` 中的固定依赖解析；干净安装验证不得通过临时修改目标项目 manifest 补充依赖。
4. 从空 Unity 项目安装当次生成的 `.tgz` 后，必须能够执行 iOS Development 导出，并使用 `xcodebuild` 对 generic iOS device 编译成功。
5. 运行时从生成地图加载 `features.db` 的 iOS 真机 smoke test 必须证明 SQLite 与 native 定位器均可初始化；静态符号检查和源码字符串检查不能替代此验证。

### R1.4：结构化诊断与隐私边界

1. Runtime 必须收集并导出版本化诊断记录，至少包含：应用构建、包版本、地图 ID/版本/哈希、设备型号、iOS 版本、帧 ID、队列覆盖次数、结果年龄、处理耗时、tracking state、quality、置信度、ORB/AKAZE/candidate/match/inlier/consistency 指标以及 `T_U_S` 是否被应用。
2. 默认诊断不得包含原始相机图像、JPEG、关键帧像素、扫描 ZIP 或绝对用户路径。
3. 诊断导出必须是有界的；达到记录上限时丢弃最旧的记录并记录丢弃计数。
4. 诊断失败、地图加载失败、native 初始化失败、SQLite 失败、定位失败、过期结果和不支持设备必须有稳定的错误类别与可读原因。
5. 示例场景可展示实时摘要，但不得使用反射访问内部状态，也不得在每帧打印完整矩阵。

### R1.5：可复现的 iOS 闭环

1. 扫描器导出的 ZIP、处理命令、处理输出、地图部署位置、应用构建版本和运行日志必须能够关联到同一个 map manifest。
2. 阶段 1 允许扫描 ZIP 经人工触发的本地/Docker 处理和人工地图部署；不引入账号、云上传、远程地图分发或后台同步。
3. 每个真实场地必须保存不含原始图像的验收记录：场地代号、面积、扫描设备、运行设备、系统版本、应用/包版本、map manifest 哈希、首次定位时间、失锁与恢复事件、30 分钟摘要及诊断导出路径。

### R1.6：自动化和设备验证

1. Python 测试必须覆盖导出 pose 的布局、方向、内参范围和处理输入的读取方向。
2. Unity EditMode 测试必须覆盖 `T_U_S` 计算、row-major 序列化、错误方向拒绝、alignment 乘法顺序、过期/乱序结果拒绝和诊断 schema。
3. Unity PlayMode 或等价生命周期测试必须覆盖 latest-frame 覆盖、worker 独占 native 调用、reset 与 dispose 等待、重复生命周期调用以及主线程不直接处理 native 帧。
4. iOS 构建门禁必须包含：UPM 干净安装、Unity iOS Development 导出、generic-device `xcodebuild`；真机安装、加载数据库和相机权限使用为本地发布门禁。
5. `tools/phase1/verify.sh` 必须提供 `ci`、`local` 和 `device` 三种显式模式，并对每项检查输出 `PASS`、`FAIL` 或 `SKIP` 及理由；`device` 模式不得把缺设备视为通过。

### R1.7：版本、文档与支持声明

1. `package.json` 版本更新为 `1.3.0`，变更日志、生成包名、诊断 schema 和验收报告引用相同版本。
2. README、UPM README、iOS 指南和发布说明必须只声明已经通过阶段 1 门禁的 iOS 支持；Rokid、Android ARM64、Windows 和 Linux 不得因本阶段改动被声明为已支持。
3. 每个阶段 1 子里程碑必须可独立构建、测试和演示，不依赖尚未实现的 Rokid 代码。

## 5. 可运行产物

阶段 1 必须按以下顺序提供五个可独立运行的产物：

1. **坐标契约样本：** Swift/Python/C++/Unity 对同一 fixture 输出相同的矩阵、方向和内参结果。
2. **异步 Runtime：** Unity 示例能以 latest-frame 策略运行定位，且 reset/dispose 没有 native 并发访问。
3. **独立 iOS 包：** 空 Unity 工程安装 `.tgz` 后可导出并通过 generic-device Xcode 编译。
4. **单地图真机闭环：** 一张真实地图可在 iPhone 和 iPad 上扫描、处理、加载、定位并导出诊断。
5. **三场地验收：** iPhone 和 iPad 分别在三个 20–100 m² 场地完成完整流程和 30 分钟稳定运行。

## 6. 验收标准

只有同时满足以下条件，阶段 1 才能标记为完成：

- 自动化坐标 fixture 覆盖 Swift 导出、Python 读取、SQLite row-major blob、native bridge 与 Unity 内容根变换，并全部通过。
- 所有 Runtime native 调用都由单一异步运行器拥有；没有场景脚本直接调用、重置或销毁 native handle。
- 扫描数据的图像方向、每帧/适用范围内参和矩阵布局在导出时可验证，错误数据被拒绝而不是静默修正。
- 独立 UPM `.tgz` 在干净 Unity 项目中安装后可完成 iOS Development 导出和 generic-device Xcode 编译。
- LiDAR iPhone 与 LiDAR iPad 各在三个 20–100 m² 真实场地完成：扫描、处理、加载、至少一次定位成功、失锁后恢复尝试、定位后连续运行 30 分钟。
- 六次设备-场地运行均保留版本化诊断与验收记录，且默认导出不含图像数据。
- 本阶段新增/修改的全部本地验证、Unity 测试、iOS 构建门禁及三分支 CI 全部通过。
- 文档中没有超出 iOS 阶段 1 的平台支持声明。

## 7. 非目标

阶段 1 不包含：

- Rokid AR Studio、Rokid UXR/OpenXR、Android ARM64 或 Rokid 相机/头显位姿适配。
- 云端扫描上传、账号、远程地图分发、后台同步或多租户服务。
- 重新设计扫描 ZIP、资产 bundle、ORB/AKAZE/BoW/PnP 算法或阈值调优。
- 阶段 3 的跨设备精度、帧率、内存或两小时稳定性发布指标。
- Windows/Linux 正式发布、Web 运行时定位或公开 SDK API 冻结。
- 未经阶段 1 验证的 iOS 设备、非 LiDAR 设备或平台支持声明。
