# iOS 真机验收：Tracker 主线程创建修复设计

## 背景和根因

阶段 1、任务 9 的 iPhone 验收工程已确认 ARKit provider、ARWorldTracking 和地图资产加载均正常。运行时界面随后显示：`Tracker.Init异常: UnityException: get_version can only be called from the main thread`。

`AreaTargetTracker` 构造函数读取 `Application.version`、`SystemInfo.deviceModel` 和 `SystemInfo.operatingSystem` 以生成隐私安全诊断元数据；而验收场景在 `Task.Run` 内构造该对象。这违反了 Unity 主线程约束，导致 SQLite/native 初始化尚未开始就失败。

## 目标

- 在 Unity 主线程创建 `AreaTargetTracker`，使诊断元数据安全采集。
- 保留现有后台 SQLite 读取、native 索引构建与异步帧定位路线。
- 让失败清理回到 Unity 主线程，避免在后台线程调用含 Unity 日志的释放路径。
- 为任务 9 的 iPhone 复测提供清晰的 `Tracker.Init` 成功或失败证据。

## 非目标

- 不修改地图格式、SQLite schema、native localizer、定位算法、坐标变换或公开 API。
- 不把整个初始化改回主线程，也不调整定位阈值。
- 不将真机路径、设备标识、扫描数据或图像写入 Git。

## 实现

`SLAMTestSceneManager.InitializeTrackingAsync` 在主线程、进入 `Task.Run` 前创建 tracker。工作线程只调用既有的 `tracker.Initialize(assetPath)`，并返回初始化结果及异常摘要；`await` 返回后，主线程决定是否将 tracker 赋给 `_tracker`，并在失败时释放临时 tracker。

该变更使 Unity 运行时元数据读取与 UI 更新都停留在主线程，同时不改变 `AreaTargetTracker.Initialize`、`AsyncLocalizationRunner` 或首帧定位管道的合同。

## 验证

1. 先添加 EditMode 源码合同测试，要求 tracker 在 `Task.Run` 前构造，且后台块不再构造或释放 tracker；该测试在修复前必须失败。
2. 实现最小场景调整，运行该测试及相关场景测试。
3. 重新构建、签名并安装 iPhone 验收包，确认不再出现 `get_version` 主线程异常，并捕获 `Tracker.Init`、帧订阅、首次定位和诊断导出证据。

## 风险和处置

若复测暴露另一个后台 Unity API 调用，则记录精确异常并以同样的最小边界移动该调用；不以放弃后台初始化或改写定位算法作为规避手段。
