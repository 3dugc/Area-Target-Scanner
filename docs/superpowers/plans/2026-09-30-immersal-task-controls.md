# Immersal 任务阶段、中断与删除实施计划

> **For agentic workers:** 使用 subagent-driven-development 分离模型、视图与原生渲染验证；共享工作区内保留已有改动，不提交、不调用真实云 API。

**Goal:** 按用户确认的两项要求显示具体任务和执行阶段，并提供中断、删除本机任务能力。

**Architecture:** 保留持久化任务 phase 与未知请求恢复语义；新增瞬时 operationStage/busyJobID 描述当前本机操作。activeJobID 继续专指可能修改任务的上传流程。删除取消匹配操作、使旧回调失效，并原子保存移除后的当前账号任务记录。扫描、ZIP 和云端内容不在删除范围内。

**Tech Stack:** SwiftUI、Combine、现有 ImmersalJobStore、XCTest、离线 API 与原生截图。

## 已确定交互

- 准备图片、检查工作区、清空工作区、上传图片、提交建图、登录分别显示真实阶段；正在处理其他扫描时明确显示其场景名称。
- 任务列表和任务详情显示各自状态，不把其他任务的全局忙状态展示为当前扫描进度。
- 准备、状态检查和提交等待时都可中断本机操作；未确认的远端请求继续保持待确认语义。
- 详情/阻塞任务/任务列表均可发起删除，确认框说明只删本机记录，保留扫描及云端内容；已提交的云建图不会因此取消。
- 删除成功才退出被删除任务的详情，失败保留页面与记录；删除其他任务不会中断当前正在执行的任务。
- 完成测试后沿用当前用户授权，签名构建并更新到已连接的 iPhone。

## 实施检查

- [x] 在 ImmersalMappingTests 中先写并运行阶段归属、中断、删除、失败保存、跨账号、迟到回调与刷新竞态测试，确认现有逻辑失败。
- [x] 模型新增 operationStage、busyJobID、deleteJob；在每个等待边界更新阶段并确保取消后不继续发请求。
- [x] ImmersalEntryTests 验证目标任务状态隔离及删除提示语义，再更新视图，移除全局匿名 spinner。
- [x] WorkspaceRenderTests 生成其他任务正在检查、当前任务检查、大字体、任务列表、暂停及删除后的离线截图。
- [x] 运行完整 XCTest、审查截图与独立代码审查，修复发现的问题。
- [x] 签名构建、覆盖安装到现有 iPhone，记录验证范围。
- [x] 设备解锁后成功启动，查询确认进程持续运行（PID 12029）。

## 验证命令

```sh
xcodebuild test -project ios_scanner/AreaTargetScanner.xcodeproj -scheme AreaTargetScanner -destination 'platform=iOS Simulator,id=3714FD58-944D-4020-A43E-AEE9D5DB0A57' -derivedDataPath /tmp/area-target-platform-build -parallel-testing-enabled NO
xcodebuild build -project ios_scanner/AreaTargetScanner.xcodeproj -scheme AreaTargetScanner -configuration Debug -destination 'platform=iOS,id=00008130-001214D01ED8001C' -derivedDataPath /tmp/area-target-platform-device -allowProvisioningUpdates
```
