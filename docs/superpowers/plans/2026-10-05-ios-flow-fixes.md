# iOS 扫描与处理流程问题修复计划

> **For agentic workers:** Execute independent file groups with superpowers:subagent-driven-development; verify behavior using superpowers:systematic-debugging and superpowers:verification-before-completion.

**Goal:** 修正现有 iOS 扫描、登录准备和本机任务停止流程，保留平台切换，同一份扫描跨平台使用。

**Architecture:** 以已安装的 develop 提交 ea7989e 为基线，在现有隔离工作区的 codex/ios-flow-fixes 分支修改。采集数据与平台选择相互独立；平台选择只决定当前显示的云端操作。已有 Area Target 会话、任务 token、上传恢复和源文件保护继续生效。

**Tech Stack:** SwiftUI, XCTest, Xcode iOS 26.5 Simulator, existing Area Target and Immersal APIs.

## 已确认根因与范围

- 预览页把本机扫描保存与云端完成混为“处理完成”，并列多种高强调操作。
- 删除保护由两平台共同触发，错误却仅指向 Immersal。
- Area Target 暂停任务仍需源数据，却没有停止本机跟踪入口。
- 未授权相机时已有扫描记录入口消失；系统用途说明为英文。
- 两平台的准备/登录顺序不一致，默认场景名称不易对应。

本轮只修这些问题。保留顶部平台胶囊切换；不整包引入主工作区未提交的定位、SDK、离线比较功能，不重新设计采集器，不上传真实扫描，不改变生产服务配置。

## Task 1: 删除保护的真实原因

**Files:** ScanViewModel.swift, ScanViewModelTests.swift, ContentView.swift.

- [x] 用现有 bool guard 重现：阻止删除时原扫描、两个ZIP和历史保留，但文案不应错误指定 Immersal。
- [x] 运行 XCTest，确认预期行为失败。
- [x] 新增可选 deletionBlockReason 回调；非空原因本身阻止，nil/空白仍由旧 bool guard 保护。
- [x] 接入两个平台实际的源保护原因，验证一个或两个平台阻止都能得到正确指引。

## Task 2: Area Target 停止本机任务

**Files:** AreaTargetProcessingJob.swift, AreaTargetProcessingModel.swift, AreaTargetProcessingView.swift, existing Area Target tests.

- [x] 用持久记录的 stopped phase 证明现版本无法恢复这种终态。
- [x] 新增 stopped 终态和确认操作，保持任务历史、原始文件、已下载资产与远端任务。
- [x] stopped 不再锁定源扫描，不再自动刷新/重试；迟到的异步响应不能恢复已停止任务。
- [x] 空闲时可停止，正在传输时要求先暂停；同一扫描可重新发起独立任务。

## Task 3: 当前平台入口与清晰文案

**Files:** ContentView.swift, ImmersalMappingView.swift, Info.plist, ScanHistoryItem.swift if shared naming is needed.

- [x] 保留平台 Menu，当前页面每次仅显示选中平台的云处理和账号入口。
- [x] 切换平台保持同一预览扫描，采集/本机处理/导出进行中禁用切换。
- [x] 本机状态显示“扫描已保存”；原始导出明确为次要操作。
- [x] 未授权仍可访问本机记录，相机用途中文化，开发修复版本说明从首页移除。
- [x] 两平台先确认选定扫描后登录；默认用可辨识的扫描时间，不覆盖用户输入。

## Task 4: 验证与交付

- [x] 运行回归与完整 XCTest，确认 Keychain 使用本机 ad-hoc 签名。
- [x] 完成 generic iOS device 编译。
- [ ] 在模拟器用合成样例交互检查平台切换、已有记录、预览、两个准备页与停止确认；Mac仍锁屏，已保存最终通过的7种状态明暗模式hosted渲染，交互复核待解锁。
- [x] 独立检查差异、请求恢复与源数据保留风险。
- [x] 记录实际结果；未执行的真机扫描或真实上传明确说明。

## 实际验证结果（2026-10-05）

- 完整 XCTest：301 passed，0 failures，0 skipped，iPhone 17 Pro / iOS26.5；本机 ad-hoc 签名，result bundle `/private/tmp/ios-flow-fixes-final.xcresult`。
- generic iOS device / Release build passed，未签名安装；日志 `/private/tmp/ios-flow-fixes-device-final.log`。
- 独立审查最终无 Critical/Important/Minor；diff检查通过。
- 增补权限生命周期回归：系统设置授权后返回可扫描，后台/历史/预览/进行中扫描保持原状态。ContentView重新出现复用同一受限刷新逻辑。
- SwiftUI hosted测试通过公开AX数组获取标签/按钮及启用状态，密码安全、无源不上传、退出登录仍可导出本机资产守护保持有效，未使用私有API或跳过。
- 本轮不含真机安装、真实扫描、真实账号登录、真实上传/下载；Mac锁屏阻止交互复核。主工作区未提交SDK/定位功能不受本轮影响。
