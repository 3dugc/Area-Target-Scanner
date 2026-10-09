# S01：Raw 定位持续评估执行计划

范围：用户先完成 M0/M1 C++ core，再建立可重复的 iOS 精度/稳定性闭环。目前尚无核验过来源的独立验收查询数据；先交付可运行工具并诊断已有旧数据，再按导出合同采集。不得把合成通过写成真实提升，不改算法参数、Swift 产品流程或后续跨平台任务。

| 任务 | 文件 | 验证 |
| --- | --- | --- |
| 固定 dataset schema、原始 bytes 与地图/图像 SHA256、目录/资源/会话分割校验 | `tools/localization/dataset.py`、`tests/localization/test_dataset.py` | 非空、路径逃逸/符号链接、哈希、K/pose/身份、tune/heldOut 泄漏拒绝 |
| 各次独立进程 AB/BA 完整连续 Raw 回放、身份与日志 | `tools/localization/run_paired.py`、`tests/localization/test_run_paired.py` | 真实子进程烟测、缺输出保留 failure 与原始证据 |
| 逐帧分母、GT 精度、共同成功帧对稳定性、反复性能及未测门禁 | `tools/localization/compare_metrics.py`、`tools/localization/gates.v1.json`、`tests/localization/test_compare_metrics.py` | 失败留分母、光学相机中心/角度、无 GT 未测、跨环境/不足重复禁止晋升 |
| 按合同运行 current C ABI | `native_visual_localizer/tools/replay_runner.cpp`、`native_visual_localizer/CMakeLists.txt` | native tests 与实际 runner→Python CLI 烟测（由 core 任务负责） |
| iOS 采集/导出与每轮操作 | `docs/localization-iteration.md` | 整会话/场地 split、独立查询、独立 GT 声明、单因素迭代、新现场复核 |

先运行 RED，再实现 GREEN，按行为覆盖异常；当前 Python 测试初始 35 项因工具缺失而预期失败，第一轮实现后全部通过。补充测试或真实 runner 集成结果须以实际命令输出为准。

```bash
ATC_PYTHON=/Users/dirui/Documents/Area-Target-Scanner/venv/bin/python
"$ATC_PYTHON" -m pytest tests/localization -q
"$ATC_PYTHON" tools/localization/dataset.py /absolute/data/tune/manifest.json /absolute/data/heldOut/manifest.json
"$ATC_PYTHON" tools/localization/run_paired.py --dataset /absolute/data/heldOut/manifest.json --baseline /absolute/baseline/area_target_replay_runner --candidate /absolute/candidate/area_target_replay_runner --output-dir /private/tmp/localization-iteration-001 --repeat 3 --baseline-source 'git-sha;Release;toolchain' --candidate-source 'git-sha;Release;toolchain'
"$ATC_PYTHON" tools/localization/compare_metrics.py --dataset /absolute/data/heldOut/manifest.json --baseline /private/tmp/localization-iteration-001/baseline.run.json --candidate /private/tmp/localization-iteration-001/candidate.run.json --policy tools/localization/gates.v1.json --output /private/tmp/localization-iteration-001/recheck.json --markdown /private/tmp/localization-iteration-001/recheck.md
```

验收：固定相同输入/地图/配置/Raw 模式，每帧包括失败都保存；默认 heldOut 接受率不降、负样本误识别不增、独立 GT 精度不退化、共同帧对稳定性通过、同环境至少三轮性能通过后才可 `promotionEligible:true`。合成、legacyDiagnostic、tune 或任一必需项未测不可晋升。无真实数据时，以工具与 native runner 烟测完成 S01 工具准备，iOS 数据采集与真实算法提升仍未验证。

首轮历史证据：当时 dataset/metrics/paired tests 53 项通过；实际 native runner 在 `/private/tmp/atc-runtime-api-host/area_target_replay_runner` 进行 4 帧/每端 3 轮 AB/BA/AB，输出 `/private/tmp/atc-localization-loop-smoke-optical-20261005`。API 2、OpenCV 4.11.0、SQLite 3.51.0、实际 runtime SHA256 和独立 load-time sidecar 已记录。两端为同一二进制，报告仅证明烟测；syntheticOnly 保持晋升 false。当时 importer 与独立 review 尚未收敛；该 53 项是阶段记录，当前完整结果见下一段。

最终独立审查后的全量localization测试129项通过；包含25项importer测试及身份、结果和读取限额拒绝用例。真实158帧已完成三轮诊断及macOS/iOS同输入回放，结果与尚未完成的真机/独立精度任务见 [执行证据](../../validation/cross-platform/runtime-v2-results.md)。
