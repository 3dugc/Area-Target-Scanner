# 双平台主界面与按需登录实施计划

> **For agentic workers:** Use superpowers:subagent-driven-development with disjoint file groups. Root owns unified tests and independent review.

**Goal:** Area Target 和 Immersal 分别呈现自己的处理流程，共享扫描、源数据与预览；只有需要服务认证且当前未登录/会话失效的操作才显示登录界面。

**Architecture:** 继续使用顶部平台切换与共享 ScanViewModel。平台主页分别显示流程说明，前段没有账号或登录入口。两个处理页采用固定扫描/任务标识的操作意图驱动认证；取消/离页废弃意图，登录成功仅继续原显式操作。登录后的退出仅撤销服务登录，不删除源数据或任务。

**Tech Stack:** SwiftUI, public UIKit accessibility, XCTest, existing Area Target / Immersal models and API fakes.

## 用户确认的规则

- 顶部切换 Area Target / Immersal，两个平台分别执行自己的处理流程。
- 采集、数据、扫描历史和预览共享并始终免服务登录。
- 前段不显示登录按钮、登录字段或账号入口。
- 点击上传等需要认证的操作时，若没有有效登录才弹出登录页；有效登录直接执行。
- 用户明确同意：旧任务查询/下载在会话失效时按具体操作重新登录。
- 登录成功可以退出。取消登录不能上传，不覆盖扫描、地图名或任务身份。
- 页面载入或后台状态轮询遇到未登录不能自行弹出登录。

## Task 1: Area Target 按需认证

**Files:** Views/AreaTargetProcessingView.swift, Tests/AreaTargetProcessingViewTests.swift.

- [x] 新增现有API可运行的回归：未登录准备/任务页没有登录字段，上传或继续上传仍可达，打开页面无云请求。
- [x] 运行 RED，确认当前 inline 登录和认证 footer 造成预期失败。
- [x] 将用户名/SecureField 移到仅由显式认证意图呈现的登录 sheet；有有效session时显示用户名及退出。
- [x] 固定 upload scan/path/name、resume/refresh/download jobID/serverOrigin；用意图 nonce 丢弃取消/离页后的迟到成功，resume 不创建替代任务。
- [x] 实际登录页继续验证 username/textContentType/password secure；验证取消、不匹配上下文、有效session免弹出、旧任务恢复身份和本机资产免登录导出。

## Task 2: Immersal 按需认证

**Files:** Views/ImmersalMappingView.swift, Tests/ImmersalMappingTests.swift; Services/ImmersalMappingModel.swift 只增加只读本机记录入口。

- [x] 新增未登录准备页“上传并建图”可达、无账号/登录 UI、无云请求的 RED。
- [x] 未登录的更多选项及本机任务历史移除登录入口；已登录提供退出。
- [x] 上传/恢复/查询操作冻结 scan/mapName 或 jobID/userID，再按需登录，登录成功仅在当前账号仍能访问同一任务时继续。
- [x] 取消/离页废弃意图；退出保留源数据和选定任务。只读 localJobs 不改变当前账号 jobs 的云操作权限。
- [x] 保留工作区清空确认、上传恢复及不确定结果 guards，不因登录而自动清空或重复建图。

## Task 3: 双平台主界面与验证

**Files:** ContentView.swift；本计划及任务验证产物。

- [x] 平台主页分别显示 Area Target / Immersal 名称及各自流程，共同说明扫描、数据和预览共享。
- [x] 首页、权限页的“账号与任务”改为处理任务，不提供登录或账号按钮；共享预览源路径及平台切换禁用规则不变。
- [x] unified XCTest + generic iOS Release build，确认失败只属于目标行为，使用本机 ad-hoc 签名验证 Keychain。
- [x] 独立复查认证意图、取消竞态、原任务恢复、账号隔离、零自动上传及源数据保留。
- [x] 使用离线 hosted 渲染/公开AX检查双平台前段与登录页；能访问模拟器时补交互复核。真机或实际上传未执行时明确记录。


## Task 4: 工具型视觉简化（用户追加要求）

**用户方向:** 简单大方、功能优先；颜色参考 App 图标，保留顶部平台切换。

- [x] 读取用户指定扫描结果页截图及实际 App 图标，确认原深蓝背景为硬编码，并非系统外观适配。
- [x] 页面使用系统语义背景与文字，主要操作使用图标蓝色；取消深蓝渐变、超大状态图标和多个亮色胶囊按钮。
- [x] 扫描信息放在前，预览/导出作为中性列表，当前平台上传为唯一主要按钮；历史页同步采用语义颜色。
- [x] 保留来源路径、平台禁用、导出可用性、取消导出、删除保护和登录触发约束。
- [x] 模拟器验证 Area Target / Immersal 浅色与深色效果，保存原生截图；验证后恢复模拟器原有 Light 外观。

## 实施中发现并修正的问题

1. 首次打开处理页时，独立的扫描路径与 sheet Bool 可能让目标页读取空来源；改用不可变 item payload，同时携带 sheet 身份和来源路径，实际首次点击两平台均进入原扫描准备页。
2. Immersal 工作区预检认证失败后，workspaceConflict 被转成 paused，无法重新预检；保留冲突状态，使重新登录后先读取当前工作区，再生成新的确认，不能重放旧清空授权。
3. 区分明确拒绝与不确定结果：明确 capture/construct 401 没有远端副作用；真正不确定的建图状态在登录后只查询原任务。

## 最终验证

- 完整 XCTest: 330 passed、0 failed、0 skipped；结果 `/private/tmp/ios-functional-ui-final.xcresult`。本机 ad-hoc 签名用于真实 Keychain 测试，未跳过测试。
- generic iOS Release: BUILD SUCCEEDED，关闭设备签名以验证编译。
- 独立认证/流程与最终视觉增量复查均无 Critical/Important/Minor 问题；语法和 diff 检查通过。
- 原生模拟器实测：共享历史与 3D 预览免登录、首次处理页保留来源、真实上传动作才显示登录、取消保留扫描/地图名、平台切换共用原扫描、系统浅深色生效。
- 仅使用自建离线合成扫描；没有输入服务凭据、真实登录或上传，没有真实 LiDAR 扫描或安装到 iPhone。合成扫描已从测试模拟器移除。
- 截图与验证报告保存在本聊天 `ios-on-demand-auth` 产物目录；不写入原始 dirty develop 工作区。
