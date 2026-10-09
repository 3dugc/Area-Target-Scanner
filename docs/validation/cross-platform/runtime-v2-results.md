# M0/M1 与本地回放执行证据

2026-10-05。实现位于 `codex/area-target-runtime-v2`，checkout 为 `/Users/dirui/.codex/worktrees/area-target-runtime-v2/Area-Target-Scanner`，从 `0495d644cd9c6114f4e3f1b051557b23acff54a7` 建立隔离 worktree。当前范围为 C++ v2 core/session 和最小测试工具；完整 Swift/Unity/Android SDK、Rokid/PICO/Quest 适配与现场验收仍待执行。未修改算法阈值，也未发布候选算法版本。

已保存本地任务提交：基线 `965db40`，合同 `3b0cb22`，共享 C++ 核心/CLI `6b87d8d`，本地数据/iOS 回放工具 `7c9b2f2`。此前生成报告中的实际二进制哈希与源码快照保持原值，不用后续提交号覆盖当时的构建身份。

## 核心与工具

- 新增同步 `atc_*` C ABI，Raw 光学相机坐标、只读 SQLite 地图 loader 和可选 tracking Session；legacy `vl_*` ABI 保留。独立 runtime 恰好导出 10 个 C 函数。
- 完整 native CTest：7/7 通过，45.75秒；Session65数值/状态/ABI案例、loader56真实SQLite案例包含工程现有92KF地图，Raw测试实际ORB/BoW/PnP及legacy转换。
- 最终适用 Python 回归：252/252通过，23.01秒（含localization129、跨平台合同/真实CLI、phase1/legacy/featureDB）。回放CLI9个真实集成案例通过。
- iOS device/Simulator框架打包、严格签名验证通过，合计21个C导出（11legacy+10v2）；实际Swift header/句柄和65项共享Session测试通过。device镜像与现有Immersal SDK composite link通过，OpenCV保持私有。
- 独立审查发现并修复Session初始化坏首样本阻塞及旧epoch清掉新对齐；评测身份占位符、无效Raw结果、实际读取超限、构建元数据占位符和CLI末行padding边界均有RED→GREEN及独立复核。

## 真实本地输入

使用未改写的 `ScanData`94帧、`ScanData_data1`64帧及 `SLAMTestAssets/features.db`。两组导入目录及摘要见 [本地数据](../local-data.md)。基线/候选复用同一二进制，按AB/BA/AB顺序各跑3个完整序列；这是固定输入诊断，不是算法版本提升。

| 输入 | 每轮返回位姿 | Raw识别/覆盖 | baseline单帧median/P95 | baseline载图median |
|---|---:|---|---|---|
| 94帧建图回归 | 91/94（三轮相同） | 已知正样本回归96.81%，无独立精度真值 | 165.76/229.94ms | 29.22s |
| 64帧unknown | 15/64（三轮相同） | 返回覆盖率23.44%，不能称识别准确率 | 206.64/616.73ms | 35.58s |

94帧第50、51、52帧连续NO_MATCH，三轮均复现。完整失败结果已保存在逐帧JSONL和报告中。优先核查这组帧的图像/校准与匹配失败，再做单因素候选实验。载图时间主要含大图BoW构造，已从SQL快照3秒预算中分离，不能混入单帧定位延迟。可将索引构造成本作为后续优化假设，不改变当前识别阈值来掩盖问题。

两组均为 `legacyDiagnostic:true/tune`、校正证据未核实，没有真实负样本或独立GT，故晋升全部false。94帧同二进制比较的性能门禁因本机耗时波动fail，64帧pass；仍需控制环境与更多重复再判断候选性能。真实精度、误识别率、真机功耗/稳定性没有证据。

报告：`/private/tmp/atc-real-replay-20261005/{scan-data,scan-data1}/report.json`及`report.md`。实际源码/dirty tree摘要：`/private/tmp/atc-validation-source-snapshot.json`；这轮CLI使用修复末行padding之前的可执行文件，实际runtime库包含已复核Session修复。后续padding只放宽CLI合法输入范围，不改定位算法；新CLI的9项测试已通过。

## macOS 与 iOS 同输入

相同158帧分别由macOS与iOS Simulator27.0 native框架回放，返回状态158/158一致；成功位姿在1mm/0.1°比较容差内一致。94帧共同成功91，64帧共同成功15。两个包的Swift与Session真实测试都通过。

host依赖：OpenCV4.11.0、SQLite运行库3.51.0；iOS：私有OpenCV4.10.0、SQLite运行库3.54.0。不同依赖身份已记录，不要求矩阵逐字节相同。报告：`/private/tmp/atc-ios-real-replay-20261005/{scan-data,scan-data1}/comparison.json`。

这些是已保存图像的native回放结果；现有App尚未切换完整v2 adapter，不代表iPhone/iPad现场测试完成。

## Sanitizer 与原有基线缺口

UBSan全部7项通过（Session审查修复后独立重建该项）；纯Session ASan/UBSan65案例通过，exit0，无诊断。混合HomebrewOpenCV构建ASan的Raw/loader/frame/legacy pose测试通过，Session/ABI/Cheader在程序退出时崩溃于`libtbb.12.15`析构。只调用OpenCV版本、完全不含本工程源码的最小ASan控制程序复现相同退出崩溃。因此全库ASan不能声明全绿；后续应使用兼容的依赖构建复核。日志：`/private/tmp/atc-sanitized.log`、`/private/tmp/atc-opencv-asan-control.log`、`/private/tmp/atc-ubsan.log`与`/private/tmp/atc-ubsan-session-fixed.log`。

原有iOS全量基线537pass/2keychain credentialStorage失败/3live-service opt-in跳过，native已知姿态SQLite测试通过，模拟器诊断收集超时。Unity临时副本992项EditMode通过，但使用6000.6.3f1及升级后的临时依赖；固定旧版编辑器未安装，UPM打包缺`opencv_ios/opencv2.framework`，clean install未执行。完整身份、回滚制品与日志见 [基线](baseline.md)。这些缺口不被新增工具的成功覆盖。

## 下一轮

固定当前数据为回归基线；用iOS原有扫描导出采集独立查询会话，确认图像方向/校准与场地对应，补真实负样本、失锁恢复、光照/视角变化与独立位姿真值。每次只改一个算法因素，保留同输入基线/候选回放、失败样例、heldOut门禁及iPhone/iPad真机复核。合成或旧数据不能晋升候选。可运行命令与合同见 [迭代方法](../../localization-iteration.md)。
