# 平台工作区与场景命名实施计划

> **For agentic workers:** Use superpowers:subagent-driven-development for independent file ownership and final review. Track completion below.

**Goal:** 在现有 SwiftUI App 实现已选第 1 方案：扫描、记录、处理三个页面，Area Target / Immersal 平台切换，共用扫描与可编辑场景名。

**Architecture:** 平台是持久化的界面偏好，所有模式继续使用同一 ScanViewModel 与 Documents/scan_*。场景名称存在独立本地元数据中，不移动目录、不改 Immersal 任务与地图标识。所有云操作只在 Immersal 模式中可达。

**Tech Stack:** SwiftUI、Combine、原生 SF Symbols、现有 ARKit / Immersal 服务、XCTest 与 UIHostingController 离线截图。

## 已确认的设计与范围

- 视觉源：`docs/design/platform-workspace/selected-workbench.png`，对照图的左右两屏是两个互斥平台状态，不同时出现在 App。
- 扫描页：场景名称输入、采集提示、开始/停止扫描与真实进度。权限只在开始扫描时处理，首页和历史不被权限阻断。
- 记录页：共用所有本地场景；展示名称、日期、帧数和大小，支持进入处理、预览、重命名、确认删除。
- 处理页：保留选中的场景，摘要、改名和模型预览共用。Area Target 显示生成尚未接入及可用导出；Immersal 显示上传建图、专属数据导出、账号和任务。
- 扫描后保存基础数据即可；ZIP 在当前模式显式导出。切换平台只改变操作界面，不改变记录或当前场景。
- 场景名支持中文和空格，去除首尾空白，最多 60 个字符。新扫描未命名时使用扫描日期，改名时空白不提交；旧记录自动使用日期名称。
- 上传、采集中、准备启动、处理中或导出时阻止平台切换；已提交的云端建图继续执行。Area Target 不启动云任务轮询。
- 保留 Immersal 现有确认、暂停/恢复、账号隔离、未知结果检查、删除保护。云端地图名与本地场景名独立。
- 保持现有 LiDAR 采集能力边界，不实现 Area Target 云生成，也不更改其他工程或子模块。

## 执行任务

- [x] 名称与采集状态：修改 `ScanHistoryItem.swift`、`ScanViewModel.swift`；新增 `ScanMetadataStore.swift` 和 `ScanMetadataTests.swift`。先验证旧记录与元数据读写、非法名称、损坏存储、稳定路径/ZIP，再实施。
- [x] 平台与路由：新增 `ScannerWorkspace.swift` / `ScannerWorkspaceTests.swift`，验证平台偏好持久化、共享选择、忙状态切换锁定与平台导出映射。
- [x] 页面实现：重写 `ContentView.swift`、`ScanHistoryView.swift`；新增共用控件、扫描页与处理页，保留原生分享和模型预览。所有空态、权限拒绝、错误和大字体可操作。
- [x] Immersal 接入：给 `ImmersalMappingView.swift` 添加准备/任务/账号入口和场景名解析，保留现有模型状态机。
- [x] Xcode 集成：登记新 Swift 文件；在模拟器运行全部 XCTest，修复回归；构建 iOS 真机目标。
- [x] 原生视觉验证：通过 fake API 与临时扫描渲染两种处理页、扫描页、记录页、空态、深色和大字体，导出截图与视觉源同画布比较，修复布局问题。
- [x] 独立审查与交付：审查平台隔离、命名持久化、状态切换和既有上传保护；更新设计验证说明，保留当前工作区的既有用户改动。

## 验证命令

```sh
xcodebuild test -project ios_scanner/AreaTargetScanner.xcodeproj -scheme AreaTargetScanner -destination 'platform=iOS Simulator,id=3714FD58-944D-4020-A43E-AEE9D5DB0A57' -derivedDataPath /tmp/area-target-platform-build -parallel-testing-enabled NO
xcodebuild build -project ios_scanner/AreaTargetScanner.xcodeproj -scheme AreaTargetScanner -destination 'generic/platform=iOS' -derivedDataPath /tmp/area-target-platform-device CODE_SIGNING_ALLOWED=NO
```

模拟器测试和离线截图不代表真机 LiDAR 采集或真实云端上传通过；这次不执行真实云端清空、上传或建图。
