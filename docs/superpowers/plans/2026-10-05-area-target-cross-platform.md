# Area Target 跨平台 SDK Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 当前先完成执行基线与通用 C++ 核心，使用现有 iOS 测试入口建立可重复的准确率、稳定性评估与算法迭代；多平台 SDK 和设备适配保留为后续路线。

**Architecture:** 参照 Immersal 的公开组件策略，把建图与资产、Raw 定位核心、同步共享 Session、设备采集、宿主 SDK 和场景更新分开。C++/OpenCV 算法通过版本化 C ABI 复用，Swift/JNI/Unity 每个会话只有一个串行 worker；平台负责校准、曝光同步和生命周期。

**Tech Stack:** C++17、OpenCV 4、SQLite、CMake、Swift/ARKit、Unity/AR Foundation、Android NDK/Kotlin/JNI、各厂商设备 SDK；依赖版本与摘要在集成基线中锁定。

---

日期：2026-10-05。用户已要求先执行前两项（M0/M1），并在 C++ 核心完成后持续使用 iOS 检验识别准确率与稳定性。M0/M1与S01工具已实现并验证，真实新数据及真机验收待采集；新接口必须以实际实现与验证记录为准。

## 当前执行范围

只执行 B01/B02、C01–C05，并建立核心/iOS 的最小测试回放与基线比较工具。iOS 测试接入复用现有 App、私有 native framework 和回放数据；不展开 Swift SDK 产品化、Unity 迁移、Android/头显适配和正式发布。M2–M5 暂缓，未经新指令不启动。

核心迁移先保持现有算法阈值。随后每轮优化均执行“固定数据 → 基线/候选同输入回放 → 分组指标与误识别检查 → iOS 真机复核 → 保留改善且无回归的版本”；调优与独立验收按采集会话/场地划分，不能把同一视频相邻帧拆入两组。真实绝对精度必须有独立真值，无真值时只声明成功率、相对稳定性和延迟。

优先使用本地已有 158 帧与 92 关键帧特征地图；导入器保存原始来源与校验值，94 帧建图回归、64 帧未知标签分别回放。旧元数据不完整的数据集限定诊断调优并阻止候选晋升。后续 iOS 新采集补齐完整元数据、独立会话及负样本；详情见 [本地数据](../../validation/local-data.md) 和 [迭代工具](../../localization-iteration.md)。

## 权威文档与子项目

- [需求](../specs/area-target-cross-platform/requirements.md)：R01–R13、范围、设备试用与商业验收等级。
- [设计](../specs/area-target-cross-platform/design.md)：坐标、C ABI、线程、资源、符号与迁移边界。
- [任务看板](../specs/area-target-cross-platform/tasks.md)：执行中统一维护完成状态。
- [核心子计划](2026-10-05-area-target-runtime-core.md)：C01–C05。
- [宿主与 SDK 分发子计划](2026-10-05-area-target-sdk-bindings.md)：H01–H04。
- [设备适配与验收子计划](2026-10-05-area-target-device-adapters.md)：P01–P05。

旧 `phase-1-ios-workflow` 中的 iPhone/iPad 验收尚未完成；新计划补齐对应版本的真实证据，不覆盖旧记录或把本次架构规划计为验收。扫描、账号、服务器与 Immersal 当前功能只作为兼容边界。

## 交付顺序

| 里程碑 | 可独立运行的产物 | 放行条件 |
|---|---|---|
| M0 基线 | 有源码身份、环境、旧制品和回滚方法的集成 checkout | 原有适用检查真实运行，差异和缺口已记录 |
| M1 通用核心 | macOS 真实算法夹具、v2 C ABI、共享地图 loader/session | 旧 ABI 回归、v2 坐标/输入/生命周期/融合全部通过 |
| M2 多宿主 SDK | Swift、Unity、JNI 的同夹具结果及 iOS/Android SDK 制品 | iOS composite link、Android ABI、同源版本、跨宿主回放通过 |
| M3 Android/Rokid | 实际相机数据驱动的离线定位示例 | 指定设备闭环；随后逐设备三场地×30分钟 |
| M4 PICO/Quest | 各自专用 adapter 与能力报告 | 型号/权限/校准/同步满足条件，完成相同现场门禁 |
| M5 商业分发 | 支持矩阵、可安装制品、集成示例、验收和回滚包 | 独立真值、性能与两小时指标达标，最终 release gate通过 |

M1 核心完成后 H01/H03 可并行；H02 的坐标与 frame provider 可在 C01 后设计，真正切换需要 C02–C05。M2 完成 H04.1–H04.5 的 driver、基础制品与自动化门禁；H04.6 在 M3/M4 设备任务后收敛，H04.7/release 在 M5 完成，不构成“先完成全部 H04 才接设备”的循环依赖。P01/P02 仅在 H03/H04 的 arm64 核心稳定后做现场接通；P03/P04 可并行进行能力研究，但不能绕过 M1/M2，也不能在没有设备权限时宣称实现完成。共享 header、CMake、Xcode 注册和版本文件由集成负责人串行合并。

不按未经测量的日期承诺完成时间。每个里程碑先保证上一版可运行，再进入下一平台；厂商 SDK 访问、设备和签名是显式执行依赖。

## B01：冻结执行基线

**Files:** 新建 `docs/validation/cross-platform/baseline.md`；生成的全量工作区差异、扫描和制品保存在受控本地目录，不提交真实图像或令牌。

- [x] 运行以下只读命令，记录当前集成分支/HEAD、差异、子模块提交和 worktree，不把本次规划时的分支快照当作以后执行基线。

```sh
git status --short --branch
git rev-parse HEAD
git submodule status
git worktree list
git diff --stat
```

- [x] 逐项核对当前本地 iOS 新功能与已提交/部署来源；记录 optimizer 锁定与检出差异及影响。选择最新已核验集成基线，并记录须带入的任务文件。用 managed worktree 工具建立或复用隔离 checkout；不将未提交用户工作直接 reset、stash 或全量混入发布。
- [x] 将环境与回滚身份写入 `baseline.md`，至少包含下面字段。`source_commit`、哈希和版本必须是实际采集值，不能写示例值充当证据。

```json
{
  "schema_version": 1,
  "source_commit": "实际 git rev-parse HEAD 输出",
  "task_delta_manifest": "受控本地差异清单路径",
  "native_api": "vl-legacy",
  "rollback_artifact_sha256": "实际旧制品 SHA256",
  "tools": {},
  "unavailable_gates": []
}
```

- [x] 保存当前可运行 legacy 制品、生成命令和 preset；实际加载保存的 legacy dylib 完成同地图回滚 smoke，clean package reinstall 仍待 H04。版本漂移如需修改服务端合同，拆成独立任务；本 SDK 计划先用已核验资产夹具推进。

## B02：运行原有适用基线

- [x] 依次执行现有 Python/native/Swift/Unity 入口，读取完整结果和跳过原因；原生 mesh 或 Xcode/Unity 检查避免无意义并发造成资源竞争。

```sh
venv/bin/python -m pytest tests/phase1 tests/test_native_localizer.py tests/test_feature_db.py -q --tb=short
bash native_visual_localizer/build_macos.sh
python3 tools/ios/generate_native_fixture.test.py
python3 tools/ios/verify_area_target_native.test.py
bash tools/phase0/verify_ios_scanner.sh
bash tools/phase0/validate_unity_package.sh
```

- [x] Swift 全量使用执行时实际 Simulator destination 运行，并记录授权的真实原生夹具 opt-in；不得把 fixture 未开启记成真实算法通过。Unity 许可证/设备缺失分别记录，不能自动沿用历史全绿。
- [x] 比较命令输出与用户工作区基线，归因新失败；既有失败进入基线表并给出受影响里程碑。只在事实足够时放行依赖任务，不为修复无关问题扩大范围。
- [x] 提交仅包含基线文档的独立变更，进入 C01。

## 执行与提交规则

每个 C/H/P 任务包含失败验证、最小实现、回归和证据；提交前更新对应子计划与 `tasks.md`。一个逻辑任务一个可运行提交，使用具体任务文件清单暂存，避免 `git add .` 混入本地 UI、Immersal 或其他服务改动。正式发布版本沿用仓库版本规则，ABI v2 不等于强制 SDK v2.0。

所有未来验证命令在相应脚本/测试文件创建前不可执行；不能把命令列表当作已通过证据。`release` 模式只核验本地制品与已记录的设备证据，不自动部署、上传、发版或修改云服务。

首个实现交付是 M0+B01/B02 和 C01 的数据合同；不一开始同时修改所有平台或替换正在使用的原生二进制。

本次执行结果与基线缺口：[执行证据](../../validation/cross-platform/runtime-v2-results.md)。仅M0/M1与S01工具已完成；M2–M5和独立真实验收保持未完成，详见任务看板。
