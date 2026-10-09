# Immersal 离线测试验证

2026-09-30。用户明确选择下载地图后离线定位。本次实现、缓存和报告入口均限定在 Immersal 已完成任务中。

## 原生界面

[下载前](offline-download-light.png)、[已缓存](offline-cached-light.png)、[深色](offline-cached-dark.png)、[大字体操作区](offline-cached-large-text.png)、[质量报告样本](offline-report-detail-sufficient-light.png)、[大字体报告](offline-report-detail-sufficient-large-text.png)。

12 张截图来自实际 SwiftUI UIHostingController 渲染；不调用相机、网络或钥匙串。报告数据是测试 fixture，仅检查渲染，不是用户真实地图的质量。

目视检查后修复：报告日期使用中文；辅助功能字号的指标名称和值改为上下排列；深色卡片采用次级分组背景。主要下载/测试操作固定在底部，长内容可滚动。相机预览和蓝色空间标记需要现场真机验收，模拟器截图不覆盖这部分。

## 行为与数值检查

完整 XCTest 回归 **270 项，0 失败**，日志 `/tmp/immersal-offline-full.log`，结果包 `Test-AreaTargetScanner-2026.09.30_14-52-53-+0800.xcresult`。

其后两项质量提示回归补充到质量 suite，最终 **16 项，0 失败**，日志 `/tmp/immersal-offline-quality-final.log`；界面修正后渲染 suite **3 项，0 失败**、12 张附件，日志 `/tmp/immersal-offline-render-final.log`，结果包 `Test-AreaTargetScanner-2026.09.30_14-55-47-+0800.xcresult`。结果包位于 `/tmp/area-target-platform-build/Logs/Test/`。

覆盖：官方 POST 合同与哈希/大小/Base64 拒绝、账号目录隔离及原子发布失败、取消和迟到下载、账号变更、无需凭据的离线恢复、报告保存、灰度行步长、CV/ARKit 位姿转换、非有限位姿、首次结果完成时间、百分位与接近180°旋转、分段统计、零成功提示、相机拒绝及旧加载不释放新地图。

独立审查发现并已修复：旧加载回调释放新地图；大地图主线程读写和重复校验；首次定位时间漏算推理。对应回归均已通过。最终独立复核确认这三项均已修复，新界面和会话流程未发现新增 P1/P2 缺陷。

## 设备与现场边界

最终签名构建成功：`/tmp/immersal-offline-device-final.log`。包含官方 iOS arm64 静态库（SDK 2.4.0），旧示例缺失的 rmse 字段已补齐，并用编译期断言固定 ABI。

最终更新已覆盖安装到既有 iPhone 15 Pro：`/tmp/immersal-offline-install-final.json`，未卸载应用。自动启动被 iOS 锁屏拒绝（`/tmp/immersal-offline-launch-final.json`），已请求用户解锁。

未访问用户云端地图或在真实空间执行定位，无法据自动化样本给出这张实际地图的质量结论。用户下载后应在原空间走动60–90秒并结束测试，查看现场报告。报告明确稳定性不代表绝对精度，测试路程不代表完整覆盖。
