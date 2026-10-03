# Immersal 工作区确认流程实施计划

> **For agentic workers:** 使用测试驱动开发实施，并在交付前独立审查状态机与界面。

**Goal:** 用户点击上传后，云端已有图片时立即显示实际数量与本次帧数，明确确认清空后自动上传并建图。

**Architecture:** 保留当前串行上传、写前日志与未知结果保护。上传模型发布绑定账号/任务的临时确认数据，任务日志增加可选的工作区图片数量；SwiftUI 用单一确认弹窗呈现清空与停止任务，取消和确认都绑定呈现快照。清空前再次核对账号、容量和已确认数量；变化时重新确认。界面使用准备、上传、建图三阶段，由状态决定一个主操作；历史独立查看，账号和详情放入更多入口。

**Tech Stack:** Swift、SwiftUI、XCTest、现有 Immersal REST API 客户端。

用户在本会话批准该流程。保持 `anchor=true` 和 `preservePoses=true`，本次只做模拟网络验证；不实际清空、上传或建图。保留工作区已有独立改动。实现验收后，用户另行授权提交推送 develop，再合并并推送 main。

- [x] 增加回归测试并确认失败：首次占用自动提示数量；取消与重复操作不发送；旧记录可读；重新确认与过期回调保护。
- [x] 模型实现：`ImmersalMappingModel.swift` 发布确认、刷新历史任务数量、绑定确认与数量复核；`ImmersalMappingJob.swift` / `ImmersalJobStore.swift` 兼容持久化可选数量。
- [x] 界面实现：`ImmersalMappingView.swift` 用一个 `confirmationDialog`，自动显示云端数量和扫描帧数；历史重传按钮重新查询后再询问，过期弹窗取消或确认不会影响新提示。
- [x] 全量 XCTest 169 项通过；独立只读审查状态机、历史源目录与账号隔离、未知结果保护及弹窗快照；更新使用说明与本记录。
- [x] 完成最终原生截图检查及真机签名构建、覆盖安装和启动。实际云端上传、建图及真机点按验收另行进行，不由本地测试推定。

## 用户追加的界面整理

用户提供当前页截图并调用 Product Design。已基于截图审查，生成三种布局；用户选择第 3 张「分阶段引导」。选定图：`docs/design/immersal-upload/selected-guided.png`，原始审查：`docs/design/immersal-upload/review.md`。

- [x] 现有 SwiftUI 页改为准备、上传、建图三阶段；当前阶段仅一个主操作。
- [x] 摘要显示扫描时间、帧数、短地图名称；文件名、长云端名、完整任务提示收进详情；历史独立查看，账号在更多入口管理。
- [x] 不把 0/N 空进度条当作正在上传；仅上传阶段显示实际已确认进度；未知建图只能核对，不能重传。
- [x] 使用实际 SwiftUI hosting 与 fake API 生成本地渲染截图，包含原生 `UIAlert` 工作区确认自动呈现验证；该场景只有模拟 `/status`，没有 `/clear`、`/capture` 或真实云端请求。
- [x] 完成最终截图 QA，核对选定布局、深色模式、大字体及各阶段显示；不将本地截图视为真机点按验证。

初次 RED：30 个状态机测试、21 处预期失败；日志 `/tmp/area-target-workspace-red.log`。
模型 GREEN：32 个状态机测试全部通过；日志 `/tmp/area-target-workspace-green.log`。

最终全量回归：169 项扫描、导出与模拟网络 XCTest 通过，0 失败，日志 `/tmp/area-target-guided-final-verified.log`。结果包 `/tmp/area-target-upload-build/Logs/Test/Test-AreaTargetScanner-2026.09.30_10-26-05-+0800.xcresult`。清空接口继续固定 `anchor=true`，建图继续固定 `preservePoses=true`。

实际 SwiftUI 截图及选定方案对照保存在 `docs/design/immersal-upload/`；设计验收见项目根目录 `design-qa.md`。已修复首屏工作区说明裁切、大字体步骤数字溢出和普通字号导航标题省略。原生确认弹窗截图的测试窗口关联前台 scene，断言渲染成功；不修改生产界面。本地弹窗验证覆盖自动呈现，不代表真实点按或云端验收。

最终签名构建日志 `/tmp/area-target-guided-device-build.log`：BUILD SUCCEEDED。已覆盖更新到连接的 iPhone 15 Pro，`devicectl` 确认安装与启动成功，未卸载 App。没有执行真实云端清空、上传或建图；真机人工操作与云端建图结果仍待用户验证。
