# iOS 定位数据与迭代闭环

目前尚无经过来源核验的独立验收查询数据。先用合成夹具和明确标记的旧数据诊断验证工具，再采集建图后的独立 iOS 查询会话；工具通过不等于真实精度提升。本阶段只比较 C++ v2 的 **Raw** 定位，不改 Swift 产品流程或 Session 阈值。

## 固定输入

每个包包含 UTF-8 `manifest.json`、原样 Gray8 文件及含 `features.db` 的地图目录。manifest 和所有引用文件的实际 SHA256 共同构成 `datasetDigest`；`mapDigest` 是 `features.db` 的 SHA256。非诊断数据必须声明已验证的 rectification；只有 `legacyDiagnostic:true` 且 `split:tune` 可声明 `rectification.verified:false` 进行工具诊断，仍须记录未知原因且不能晋升。

禁止运行时改像素、缩放、改 K、重新序列化 manifest 来“保持”旧身份。文件引用使用包根下的相对路径，拒绝跳出目录、符号链接及 SQLite sidecar；先关闭数据库并导出完整快照。

下面展示完整字段。实际 `frames` 必须包含整个连续序列，SHA256 必须替换成真实值。`syntheticOnly` 如实声明，`split` 为 `tune` 或 `heldOut`。Gray8 可带行 padding，文件长度须介于 `(height-1)*rowStride+width` 和 `height*rowStride`。

```json
{
  "schemaVersion": 1,
  "datasetID": "room-b-query-20261005",
  "sceneID": "room-b",
  "captureSessionID": "iphone-session-20261005-01",
  "split": "heldOut",
  "syntheticOnly": false,
  "coordinateBasis": {
    "camera": "optical-x-right-y-down-z-forward",
    "handedness": "right",
    "matrixLayout": "row-major-16",
    "units": "meters"
  },
  "rectification": {"verified": true, "method": "document-the-frozen-export-pipeline"},
  "map": {"bundlePath": "map", "featuresDBSha256": "REPLACE_WITH_SHA256", "generation": 1},
  "groundTruth": {
    "method": "independently-surveyed-targets",
    "independent": true,
    "translationUncertaintyM": 0.01,
    "rotationUncertaintyDeg": 0.1
  },
  "frames": [{
    "sequence": 0,
    "captureTimestampNs": 1000000000,
    "captureClockEpoch": 1,
    "cameraID": 1,
    "trackingEpoch": 1,
    "expectedMatch": "positive",
    "gray8": {"path": "frames/000000.gray8", "sha256": "REPLACE_WITH_SHA256", "width": 1920, "height": 1440, "rowStride": 1920},
    "intrinsics": {"fx": 1500.0, "fy": 1500.0, "cx": 960.0, "cy": 720.0},
    "groundTruthCameraFromScan": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1],
    "worldFromOpticalCamera": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
  }]
}
```

`groundTruth` 和每帧 `groundTruthCameraFromScan` 都可省略；有 pose 时必须有方法、独立性和误差声明。ARKit 跟踪需写 `independent:false`，只能评价稳定性，不可当作独立精度真值。`worldFromOpticalCamera` 可省略；存在时必须附 `trackingEpoch`，跟踪重置后增加 epoch。矩阵采用列向量，`T_A_B` 把 B 坐标映射到 A，16 个数按行保存；光学相机 x 向右、y 向下、z 向前，单位米。

本机已有 `ScanData` 的 94 张同地图建图帧，以及 `ScanData_data1` 的 64 张不同图像；后者是否同场地、同会话仍未经核验。现有打包地图有 92 keyframes、127685 ORB features、1000 vocabulary words。建图帧可测链路，不能替代建图后的独立查询。旧数据必须显式 `legacyDiagnostic:true`，默认为 unknown 标签；即使后续补标签/GT，它也不可晋升。具体文件来源与导入命令见 [local-data.md](validation/local-data.md)。

## 采集与导出

1. 地图构建完成后重新录制查询，覆盖不同距离、朝向、光照、运动模糊和遮挡。正样本应来自目标空间；负样本包含错误地图、其他空间、重复纹理和严重遮挡。无法可靠判断的帧标 `unknown`，保留回放但排除正负分母。
2. 在采集端完成并验证方向、去镜像、畸变校正及一次性预处理。导出最终送入定位器的 **Gray8 原始 bytes**、像素宽高/stride 和对应 `fx/fy/cx/cy`。已有 iOS recorder 会先做一次 nearest-neighbor resize；若复用它，导出 recorder 存下的像素与更新后的 K，离线工具不再 resize。
3. 保存曝光时刻的整数纳秒、时钟 epoch、物理相机 ID 与严格递增的 sequence。不要用提交、回调或处理结束时刻代替曝光时间。ARKit Double 秒转纳秒的方法与 epoch 必须在导出说明中冻结；不同相机或时钟 epoch 使用新 capture session。
4. 光学 tracking pose 必须由 ARKit pose 显式转换相机轴后保存；ARKit 的相机轴到光学轴为 `diag(1,-1,-1,1)`，不能直接把 AR pose 标成光学 pose。保存 tracking reset 边界。精度 GT 应独立测量并映射到原扫描坐标，写明方法与不确定度；不要用同一 ARKit tracking 生成“独立 GT”。
5. 按整个 `sceneID`、`captureSessionID` 分配 tune/heldOut，不能切分相邻帧。以多个 manifest 一起运行校验，检查跨包泄漏。heldOut 仅作冻结后的验收，不能据它反复调参。
6. 计算地图和每个 Gray8 文件 SHA256，写一次 manifest 后冻结该版本。当前工具没有新增 iOS 导出按钮；这是一份导出合同，需由采集端按上述字段交付文件。

## 执行命令

当前实现位于 `/Users/dirui/.codex/worktrees/area-target-runtime-v2/Area-Target-Scanner`（分支 `codex/area-target-runtime-v2`），以下命令在该 checkout 根目录执行。回放与比较工具只用 Python 标准库，pytest 验证使用已有 venv。两份 runner 须由相同构建选项的基线/候选源码构建；保存不同路径和 Git revision/build 身份，勿覆盖基线。`--baseline-source` / `--candidate-source` 应对应实际保存的源码：记录 Git HEAD；有未提交改动时同时保存包含新增文件的源树快照及逐文件 SHA256，单独的 tracked diff 不足以重建源码。

```bash
ATC_PYTHON=/Users/dirui/Documents/Area-Target-Scanner/venv/bin/python
"$ATC_PYTHON" -m pytest tests/localization -q
"$ATC_PYTHON" tools/localization/dataset.py /absolute/data/tune/manifest.json /absolute/data/heldOut/manifest.json
"$ATC_PYTHON" tools/localization/run_paired.py \
  --dataset /absolute/data/heldOut/manifest.json \
  --baseline /absolute/baseline/area_target_replay_runner \
  --candidate /absolute/candidate/area_target_replay_runner \
  --baseline-source 'git-sha; Release; toolchain/version' \
  --candidate-source 'git-sha; Release; toolchain/version' \
  --output-dir /private/tmp/localization-iteration-001 --repeat 3
"$ATC_PYTHON" tools/localization/compare_metrics.py \
  --dataset /absolute/data/heldOut/manifest.json \
  --baseline /private/tmp/localization-iteration-001/baseline.run.json \
  --candidate /private/tmp/localization-iteration-001/candidate.run.json \
  --policy tools/localization/gates.v1.json \
  --output /private/tmp/localization-iteration-001/recheck.json \
  --markdown /private/tmp/localization-iteration-001/recheck.md
```

引用相对路径默认相对于 manifest 所在目录；如需统一数据根，给所有命令添加 `--root /absolute/data`，manifest 内路径也须从该根起算。`dataset.py` 接受多个 manifest 检查完整场地/会话分割；只提供一个包无法发现其他包里的泄漏。

Harness 对完整序列交替 AB/BA，每次启动独立进程，每进程载图一次并连续回放。runner CLI 只接收 `--map-dir`、`--frames`、`--output`；`frames.tsv` 无表头，列为 sequence、capture timestamp ns、clock epoch、camera ID、map generation、width、height、row stride、fx、fy、cx、cy、绝对 Gray8 路径。

默认配置身份来自 `run_paired.py` 的 `FIXED_CONFIG`，与 native runner 的 `atc_default_config_v2()` 资源上限一致；`--config` 只接受该固定内容的 JSON 并哈希原始 bytes，**不会应用参数**。可复用上一轮 `config.json` 固定配置身份。门禁文件在调优前冻结，其 bytes SHA256 保存在报告。输出目录必须为空，以免覆盖旧证据。

runner 的 `--describe-build` 提供 API/OpenCV/SQLite/compiler 身份；harness 哈希实际加载的 runtime 文件并在每轮前后检查，报告保存 runtime SHA256。缺少该元数据或源码身份未指定时不可晋升。runtime 路径仅用于计算哈希，不进入报告。

导入器可附 top-level `provenance.poses/intrinsics/scanManifest/rectificationEvidence` 和逐帧 `sourceJPEG`，引用都为 `{path,sha256}`。validator 会验证这些源文件的实际哈希、目录边界和资源预算，并纳入 datasetDigest；decoder 版本/转换方法等 metadata 由原始 manifest bytes 绑定。

保存 `execution.json`、`config.json`、`policy.json`、manifest 原字节副本、baseline/candidate run JSON、每次原始 JSONL、stdout/stderr、报告；任何缺帧、重复、非法 pose、非有限数、数据/地图/配置/帧身份漂移都拒绝比较。进程退出或输出异常写 `failure.json`，不丢掉原始文件。`processElapsedNs` 含载图和 I/O，只供日志；`latencyNs` 才是算法逐帧耗时。native 的 `output.jsonl.meta.json` sidecar 单独记录 `loadTimeNs`、API 版本和输入帧数，harness 验证后汇总。缺少 sidecar 时报告 `loadTimeNs:not_measured`，不会用进程总耗时代替。

CLI 返回 0 表示没有已测回归，2 表示指标回归，1 表示无效输入或执行失败。0 本身不代表可晋升，必须读 `promotionEligible` 和 `promotionReasons`。

## 看报告并迭代

- 识别率 = 成功正样本 / 所有正样本；误识别率 = 成功负样本 / 所有负样本。成功仅由同一份 `ATC_OK + rawValid + finite rigid pose` 判定，不跨版本比较 confidence 来筛帧。报告保留分母、全部失败和总成功覆盖。
- 独立 GT 精度按相机中心 `-Rᵀt` 的距离及旋转角计算 median/P95；accurate recall 的分母是所有有 GT 的正样本，失败也计入，默认阈值 0.1 m / 3°。没有独立 GT 或没有成功 GT pose 时标 `not_measured`。
- 稳定性使用 `A = worldFromOpticalCamera × cameraFromScan`，两版本仅比较相同共同成功帧对的对齐差。报告共同帧对数、各版本覆盖、失败最长串及恢复次数；不跨 tracking epoch。跟踪稳定性不是精度证明。
- 延迟统计包含每个输入帧，包括定位失败。性能门禁须同 OS/已知 CPU/架构、同配置、相同重复数且至少 3 轮；比较各轮 P95 的 median，候选不超过基线 1.10 倍。稳定性 P95 允许增加最多 `max(5%,0.01 m)` 或 `max(5%,0.2°)`；正样本接受率不能降，负样本误识别率不能升，精度 recall/error 不能退化。

`smokePass` 只说明输入与输出结构可比较；`regressionPass` 表示已测项目无回归。缺正样本、缺负样本、缺共同成功帧对、缺独立 GT、跨环境或重复不足时相应项目未测，不能假造 PASS。默认必需指标须全部通过；`syntheticOnly:true`、`legacyDiagnostic:true`、tune 数据及证据不足均令 `promotionEligible:false`。

每轮只改一个可解释因素，记录假设、源码身份、配置、fixture/hash、工具版本和全部日志。先在 tune 验证，失败样例加入回归集；冻结候选后跑 heldOut。离线门禁通过后，用 iPhone/iPad 的新现场会话复核，并保留采集失败和 tracking reset 情况。没有真实包前只报告工具链验证，不报告算法已经提升。

## 本次工具验证记录

2026-10-05 在 macOS host 运行实际 `area_target_replay_runner`（API 2、OpenCV 4.11.0、SQLite 3.51.0），用同一二进制作 baseline/candidate，合成包 4 帧 × 每端 3 轮。dataset、paired replay、独立 compare CLI 均运行成功；两个正样本、blank 负样本和 unknown 帧全部保留。最终光学夹具报告位于 `/private/tmp/atc-localization-loop-smoke-optical-20261005`，`promotionEligible:false`。这是工具链 smoke，不是版本间算法提升。

原生生成器旧 `fixture.json.expectedCameraFromScan` 使用 legacy AR 相机轴；v2 GT 须显式左乘 `D⁻¹=diag(1,-1,-1,1)`，tracking optical pose 也须对应。首轮未转换的报告准确捕获 180° 差异，原始报告保留在 `/private/tmp/atc-localization-loop-smoke-20261005`；没有修改门槛来消除差异。


## 现有本地数据与 iOS native 回放

优先使用 [本地数据导入说明](validation/local-data.md)。`ScanData` 是建图会话，94 帧只用于回归；`ScanData_data1` 场地来源未核实，64 帧按 unknown 处理。用现有 iOS 扫描导出新的完整扫描目录作为查询输入，不用这次查询重新生成待测地图；先检查方向、内参与校正证据，再由 `import_scan.py` 导入。当前 App 仍保留既有 legacy 流程，完整 v2 Swift SDK/App 切换属于后续 H01。

同一包可以送入真实 iOS Simulator native 框架，核验 C++ Raw 与 macOS 结果。以下工具会编译 Swift C header/句柄 smoke、共享 Session 状态测试及 iOS replay runner；输出 `comparison.json`、逐帧 JSONL、加载时间、版本/哈希与日志。Simulator 回放不替代 iPhone/iPad 的真实相机采集。

```sh
python3 tools/ios/replay_runtime_v2.py \
  --dataset /private/tmp/atc-local-data/scan-data/manifest.json \
  --host-runner /private/tmp/atc-runtime-api-host/area_target_replay_runner \
  --output-dir /private/tmp/atc-ios-local-replay-new \
  --simulator booted

ATC_BUILD_DIR=/private/tmp/atc-runtime-api-host \
  python3 tools/ios/replay_runtime_v2.test.py
```

测试会生成自己的数据包；`ATC_SIMULATOR` 可指定当前启动的设备，`ATC_FIXTURE_DIR` 可复用已有合成夹具。缺少明确 host 构建或已启动的 Simulator 会标明跳过，不能当作通过。

离线 `promotionEligible` 只表示实验数据门禁允许候选继续验收，工具不会自动修改或发布 App。正式采用前仍须 iPhone/iPad 新会话真机复核。实际回放结果、失败帧和基线缺口见 [执行证据](validation/cross-platform/runtime-v2-results.md)。
