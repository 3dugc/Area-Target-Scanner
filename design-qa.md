# Immersal 原扫描网格叠加（2026-09-30）

已实现原扫描 OBJ 的青色线框叠加、模型与地图的本机坐标核对、开关与透明度，以及定位丢失/中断时隐藏。最终 iOS 回归319项通过，独立macOS加载器13项通过；大模型缓冲区保留问题已修复。最终版本已签名构建、覆盖安装并在 iPhone 15 Pro 上成功启动。原空间视觉对齐与用户地图质量仍待现场实测。详见 [网格叠加验证](docs/design/immersal-mesh-overlay/design-qa.md)。

以下保留较早阶段的验证记录，测试数量及启动状态仅适用于相应版本。

# Immersal 离线定位测试（2026-09-30）

已完成下载缓存、原生离线定位、现场统计报告及原生界面检查。完整回归270项通过；最终质量suite16项和渲染suite3项通过。真机签名构建并覆盖安装完成，自动启动暂被锁屏拒绝。真实空间定位质量待现场采样。详见 [离线测试验证](docs/design/immersal-offline-test/design-qa.md)。

# 当前 Immersal 任务控制验证

已增加明确的任务阶段、中断和删除本机任务入口。最新验证见 [任务控制验证](docs/design/task-controls/design-qa.md)，[原生操作预览](docs/design/task-controls/task-controls-overview.png)。

---

# 当前平台工作区设计验证

本次已实现三页导航、平台模式隔离、共享场景及命名/改名。当前验证记录见 [平台工作区设计验证](docs/design/platform-workspace/design-qa.md)，实际原生页面见 [页面预览](docs/design/platform-workspace/workspace-overview.png)。

以下保留此前 Immersal 上传页的独立验证记录；其中测试数量与真机安装状态仅适用于当时版本。

---

# Immersal 上传页设计验证

- Source visual truth：`docs/design/immersal-upload/selected-guided.png`，用户选定第 3 张「准备 → 上传 → 建图」。源图 852×1846 px。
- Implementation：实际 SwiftUI View，由 XCTest 的 `UIHostingController` 加载本地 journal / fake API 渲染，非 HTML 模拟，也不调用真实 Immersal。
- Viewport：393×852 pt，renderer scale=1，截图 393×852 px。源图等比密度归一到 393×852 px；源图中的系统状态栏与测试窗口顶部安全区不作为应用内容匹配项。
- State：57 帧扫描，未上传，工作区有 4 张模拟图片。图中的 4 为 fixture，不代表用户实际云端数量。另有深色、大字体、12/57 已暂停和云端建图截图。

## 第一轮对照

Full-view comparison：`docs/design/immersal-upload/comparison-v1.png`。对应实现截图保存在 `/tmp/area-target-guided-qa-v1/`，清单为 `manifest.json`。工作区提示和底部操作足够清晰，不需要进一步缩小区域才能定位以下问题。

- [P2，已解决] 工作区提示被底部固定操作挤住，已有地图保留的说明未完整出现在首屏。修正：主间距从 28 到 20，顶部从 24 到 16，删除介绍区额外顶部间距，缩短工作区说明。最终截图已确认提示完整显示。
- [P2，已解决] 大字体下步骤数字超出 36 pt 圆形。修正：步骤图标数字使用固定 17 pt，步骤名称继续随动态字体缩放，保留完整的 VoiceOver 阶段标签。最终大字体截图已确认数字完整显示。

## 最终对照

Full-view comparison：`docs/design/immersal-upload/comparison-final.png`，包含同一画布上的选定源图及实际 SwiftUI 渲染。最终主页面标题缩短为「Immersal 建图」，普通字号下不再截断；更多入口具有 44×44 pt 点击区域。保留系统字体、原生卡片及主按钮外形，不复制栅格文字或系统状态栏。

最终截图保存在 `docs/design/immersal-upload/`：`guided-workspace-light.png`、`guided-workspace-dark.png`、`guided-workspace-accessibility.png`、`guided-upload-paused.png`、`guided-construction.png`、`guided-native-clear-confirmation.png`。`render-attachments.json` 只保存测试名、画布尺寸和截图名，去除设备标识与临时附件编号；原始导出清单保留在 `/tmp/area-target-guided-qa-verified/manifest.json`，不入 Git。

## 五项表面检查

- 字体：使用原生系统字体及中文回退，标题/正文/辅助文案分层；大字体步骤数字保持清晰，正文可以滚动查看，底部操作完整可见。大字体下原生导航标题可能省略，页面主标题仍完整可读。
- 间距与布局：步骤、扫描摘要、工作区及底部单一主操作符合选定层级；普通字号下工作区说明完整可见。历史与账号独立查看。
- 颜色：蓝色操作和当前阶段、橙色工作区提示、系统分组背景；深色截图清楚可读。使用原生系统颜色，未添加素材渐变。
- 图片与图标：选定图无内容图片，全部为标准原生控件和 SF Symbols，无图片占位或栅格化界面。
- 文案与内容：短地图名和 57 帧摘要可见，完整编号进入详情；实际工作区数量来自持久化的查询结果。取消/删除范围在确认弹窗说明。

## 交互及验证边界

最终全量 XCTest **169 项通过，0 失败**，日志 `/tmp/area-target-guided-final-verified.log`，结果包 `/tmp/area-target-upload-build/Logs/Test/Test-AreaTargetScanner-2026.09.30_10-26-05-+0800.xcresult`。模型测试覆盖自动确认、取消、重复提交、旧记录、账号变化、后台、数量变化重新确认和未知结果保护。原生弹窗测试确认实际呈现 `UIAlertController`，文案含 4 张/57 帧，操作含「清空并上传 57 帧」，请求只有 fake API 的 `/status`，没有清空或上传。为正确捕获 UIKit 弹窗，测试窗口关联前台 scene，并断言渲染成功；不修改生产界面。

真机签名构建通过，已更新到已连接的 iPhone 15 Pro 并成功启动，没有卸载应用。日志 `/tmp/area-target-guided-device-build.log`。构建、安装和本地渲染不代表实际真机点按、VoiceOver 操作或 Immersal 云端上传/建图通过；本次没有执行真实云端清空、上传或建图。CUA 的 Simulator app 当前不可访问，真机远程屏幕共享仍受 iOS 版本限制。

final result: passed（本地设计与原生渲染检查）
