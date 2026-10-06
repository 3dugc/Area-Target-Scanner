# 扫描覆盖预处理 v2 本地验证

日期：2026-10-06。第一阶段代码及配套已实现；100 / 500 是验证档位。以下包含本机合成回归、模拟器和已有真实扫描的诊断，尚未完成独立现场定位验收。默认能力保持 100；500 未在生产启用。本次未提交、发布、部署或安装到真机。

## 已实现与检查的行为

- 新 iOS 任务显式协商 v2，全量上传源帧的独立副本。仅明确不支持 v2 时协商 v1 并显示实际旧能力；网络或未知策略失败会停止准备。历史任务保留原归档与身份。
- 服务端同时检查位置、完整旋转、tracking run、双向特征匹配和全图相似度。独特弱纹理视角保留并标记。局部共享纹理、改变的弱纹理区域和传递合并均有反例回归。
- 去重后保留全部独特视角，按实际总像素调整尺寸；长边上限 1600，最低 1024，小源图保持原尺寸。超过能力明确返回 `coverage_budget_exceeded` 及数字诊断，不再裁成 80。
- 特征阶段不进行第二次选帧，先做几何求交再均衡分配 200k 总特征，最后训练词典与 BoW。报告三维特征不足的帧，保留既有最低入库条件。
- UV 每批最多 4096 个面并逐相机更新，保持原首帧平局、不可见 `-1`、64 MiB 图片缓存和全局补洞。

资源边界：v2 100 档为 200M 像素，500 档为 600M；源图分析累计最多 2B 像素。旧 v1 的像素限制及 ZIP、解压、单图、路径安全检查保持原边界。服务端只接受自己的固定配置。

## 回归结果

Python 主回归 **234 通过，57.89 秒**：

```sh
LOKY_MAX_CPU_COUNT=4 venv/bin/python -m pytest \
  tests/test_frame_selection.py tests/test_scan_preparation_v2.py \
  tests/test_mobile_preparation_v2.py tests/test_scan_preparation.py \
  tests/test_mobile_scan_preparation.py tests/test_mobile_api.py tests/test_scan_security.py \
  tests/test_feature_budget.py tests/test_mobile_feature_limits.py \
  tests/test_feature_extraction.py tests/test_feature_db.py \
  tests/test_uv_texture_memory.py tests/test_uv_frame_calibration.py tests/test_uv_unwrap_worker.py -q
```

随后新增“上传 101 帧、权威去重后 1 帧”的真实归档回归；最新去重/准备/API 三文件 **30 通过，5.55 秒**。CLI、优化管线及特征属性三文件另有 **16 通过，8.78 秒**；3 条 sklearn 聚类警告来自合成描述子重复，不影响结果。合计覆盖 251 个不同 Python 测试。

检查包含：500 个独特图像不截断；500 张 1024×1024 实际输出为 524288000 像素；混合比例、奇数尺寸、小源图；实际逐轴内参；源索引/位姿/时间；成功/失败源摘要一致；预算不足不遗留半成品；伪造摘要、非整数能力与禁用的 500 档拒绝；v1 合同兼容。100/500 个建库帧及完整特征数组通过 SQLite 往返，最终 BoW 与存储描述子一致。

iOS 五个指定测试类：最新完整模拟器运行 **121 项，1 项跳过，0 失败**。跳过项为已有的外部合成定位查询夹具，缺少 `AREA_TARGET_SYNTHETIC_FIXTURE_DIR`；这不等于独立现场查询通过。实际 linked native 装载 100/500 帧测试已通过，同时录制适配器核对了每帧、每特征的转发。

可使用计划中的动态模拟器选择命令重跑以下测试类：`AreaTargetAPIClientTests`、`AreaTargetScanArchiveTests`、`AreaTargetProcessingModelTests`、`AreaTargetFeatureDatabaseTests`、`AreaTargetOfflineLocalizerTests`。本次使用隔离 DerivedData 与 `-parallel-testing-enabled NO`。服务端和 iOS 代码均经独立只读审查，发现的问题已修复并加回归。

## 已有真实扫描诊断

用户确认没有额外扫描后，完成 94 帧、64 帧与另一份带逐帧内参的 31 帧实拍数据测试：7 次实际建库、14 次完整原生回放、1010 条逐帧输出，原始照片、位姿、标定和几何摘要不变。详细数值、查询摘要、逐帧增减、资源与范围见 [scan-coverage-real-data-2026-10-06.md](scan-coverage-real-data-2026-10-06.md) 和配套 [JSON](scan-coverage-real-data-2026-10-06.json)。

94 帧扫描旧均匀抽样方案有 74 个有效建库关键帧，v2 有 91 个。实拍 94 / 31 帧均没有满足保守删除条件的重复帧；v2 未强制裁成 80。94 帧同源查询旧/新都返回 91/94；额外 64 帧查询 fast 由 19/64 变 20/64，quality 由 41/64 变 40/64。仅去重保留原始分辨率的 quality 对照为 36/64。更多保留视角并未证明稳定的定位效果提升，缩图也不是无损：源索引 52 的三维 ORB 对应由原图 23 降到 16，低于入库门槛。

真实 31 帧网格的 128413 面选图与旧算法逐面相同；选图进程峰值由 515.61 MiB 降到 58.50 MiB，实际 1024 atlas 渲染峰值 203.27 MiB。94 帧 quality 建库进程峰值仍约 1.76 GiB，不能用 UV 的局部内存代替完整链路资源验收。

94 帧查询与建图库同源，64 帧的场景对应和位置真值未知，31 帧也是同源回放。当前记录仅是原生库返回定位结果，不能当作正确召回或误接受。没有真实 500 帧输入，4096 atlas、完整模型优化/上传服务、目标服务器和手机仍待验收，Task 6 的独立现场条目继续未勾选。

## UV 合成资源复测

同一 50000 面网格，500 个不同相机位置，640×480 图像，512 atlas；每档单独进程。旧 80 的算法为冻结参考实现。三档均在结果中使用了对应数量的不同图片。

| 模式 | 选图耗时 | 光栅化耗时 | 渲染总耗时 | 进程峰值 RSS | 图片缓存峰值 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 旧 80 | 0.361 s | 1.055 s | 1.478 s | 582.41 MiB | 63.28 MiB |
| 新 100 | 0.156 s | 0.534 s | 0.712 s | 152.86 MiB | 63.28 MiB |
| 新 500 | 0.751 s | 2.512 s | 3.315 s | 168.78 MiB | 63.28 MiB |

本机测量包含解释器/测试参考导入开销；运行时负载会影响耗时。这验证有界选图结构，不代表真实扫描、4096 atlas 或目标服务器的最终内存/性能。

```sh
venv/bin/python tools/validation/scan_coverage_uv_benchmark.py legacy 80
venv/bin/python tools/validation/scan_coverage_uv_benchmark.py bounded 100
venv/bin/python tools/validation/scan_coverage_uv_benchmark.py bounded 500
```

独立 macOS native 装载补充证据保存在 [scan-coverage-native-load-v2.json](scan-coverage-native-load-v2.json)：100/500 帧均为 160k ORB + 40k AKAZE、1000 词；装载耗时分别 34.59/35.17 秒，SQLite 约 15.96/19.27 MB。文件记录实际库摘要及资源配置。此耗时提示必须继续验收地图载入体验，不能以容量通过替代手机性能通过。

## 现场与分档启用待验收

- [ ] 冻结独立重新拍摄的查询集及负样本，标记入口、短暂经过角落、转弯、不同朝向、重复走廊；查询不可直接使用建图帧。
- [ ] 在同一查询集上比较旧方案、仅去重、去重加缩图，记录每区域有效入库帧及定位输出；有独立真值后才报告正确召回与误接受。
- [ ] 记录首次定位、查询 P50/P95、地图载入、数据库大小、手机峰值内存及实际部署各阶段耗时，包含失败和超时。
- [ ] 先验收 100，再验收 500。目标服务器与手机的容量、内存、坐标、独立查询和负样本全部通过后，才设置 `AREA_TARGET_PREPARATION_TIER=500`。

当前仓库没有本次现场评测所需的冻结独立查询/真值/负样本，未编造识别率。CI 发布、生产部署与真机安装继续单独安排。

临界弱视角保护及公平iOS归档/冻结查询验证见[2026-10-06 临界帧保护报告（2026-10-07续验）](scan-coverage-critical-frame-2026-10-06.md)。

后续[2026-10-07三轮复测](scan-coverage-critical-frame-retest-2026-10-07.md)覆盖12组948帧，固定地图/查询/原生参数并记录全部成功、失败和每轮延迟。
