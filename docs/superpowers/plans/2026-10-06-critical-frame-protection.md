# 临界弱视角分辨率保护 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Track progress using the checkboxes below.

**Goal:** 按用户已授权的建议，在上传缩图前保留临界弱视角候选的高分辨率，保证服务端不会二次缩掉，并通过真实回放验证收益。

**Architecture:** v2 requirements 增加可选、严格版本化的 criticalFrameProtection 能力；客户端复用共享灰度质量指标选风险候选并保护最多 8 个上传副本。服务端只接受协商后的受限高分辨率输入，权威去重后按现有总像素预算生成混合尺寸。二维指标只是风险代理，真正的三维入库门槛与定位算法不变。

**Tech Stack:** Swift / ImageIO / 现有 C++ 灰度质量内核、Python / Pillow、pytest、XCTest、SQLite、现有原生回放工具。

**授权与状态：** 用户在 2026-10-06 明确请求增加该保护并回放验证；本计划细化已认可的路线，无需再确认实施。保留当前工作区已有修改，不提交、发布、部署或安装到真机。

## 冻结合同与边界

- v1 与没有新能力的旧 v2 行为和任务身份逐字保持。v2 requirements 可选 `criticalFrameProtection`：version=`critical-frame-protection-v1`，riskVersion=`gray-quality-risk-v1`，maximumProtectedFrames=8，maximumProtectedLongEdge=1920，sharpnessThreshold=16，contrastThreshold=20。未知/畸形能力明确拒绝。
- 上传前逐帧复用现有 C++ 质量内核；候选为质量拒绝、Laplacian 方差 ≤16 或灰度标准差 ≤20。按质量拒绝优先、清晰度升序、源序号排序选最多 8 帧；不根据此代理删除任何源帧，不称它预测了三维入库成功。
- `clientPreparation.criticalFrameProtection` 可选且严格：version、riskVersion、protectedIndices（有序唯一、最多8、属于原始源序号）、candidateFrameCount（合法整数、至少保护数、至多源帧数）。仅存在时加入任务身份，旧字符串不变。
- 受保护帧长边不超过 min(源长边,1920)，普通帧仍最多1600。原尺寸保留时复制原编码字节；任何尺寸变化均逐轴缩放内参，保留位姿、时间、方向和源序号。
- v2 仍全量上传，再由服务端权威去重；不新增上传帧数 ≤ tier 的门槛。上传源像素继续受既有2B分析上限与既有单图/ZIP/解压/路径安全约束，最终独特帧数及200M/600M工作像素由服务端核验。
- 上传字节重试只降低普通帧长边至既有1024地板，受保护帧尺寸固定；若仍不足明确失败。源扫描不改变，已保存ZIP重试不重新协商或归档。
- 服务端不信任客户端的风险判断或预算声明；重新验证实际逐帧尺寸、索引与安全预算。只将去重后仍保留的保护候选分配高分辨率，其他帧共用剩余像素预算，不能删帧或突破地板。保护最小预算不足时明确失败。
- 保护影响需要记录实际准备尺寸、候选/保护/去重淘汰索引、有效建库帧、实际三维特征和完整查询差异。20个入库门槛、200k特征、PnP/检索参数及默认100档均不改变。

## Task 1：服务端合同、混合尺寸和保护元数据

已完成：固定合同与混合预算实现；19项初始红测确认失败后转绿，最终175项准备/API/安全/特征回归通过，独立只读审查未发现问题。

**Files:** processing_pipeline/critical_frame_protection.py、processing_pipeline/scan_preparation.py、web_service/mobile_api.py、tests/test_critical_frame_protection.py、docs/area-target-api.md、web_service/openapi.json。app.py无需新增转发，准备函数直接读取客户端扩展。

- [x] 先添加并确认失败：新能力严格解析、保护8张1920而普通1600、实际200M/600M预算、畸形/伪造索引或尺寸拒绝、旧v1/v2不变。
- [x] 实现可选能力、严格客户端扩展字段、权威保护输入验证及混合像素分配；成功/失败原始摘要不变，不留半成品。
- [x] 让准备结果和用户可见统计携带保护的真实索引、尺寸与版本；内参和源身份一致。
- [x] 运行准备/API/安全/特征相关回归并只读审查合同一致性。

## Task 2：iOS 上传前候选保护与重试身份

已完成：实际ImageIO双归档、最多8帧保护、普通帧重试及严格元数据/持久任务核验。指定模拟器111项回归1项fixture跳过、0失败；真实94帧fixture另显式单跑1通过、0跳过。独立审查发现的typed decoder源范围问题已修复；root已复查最终严格JSON三入口。

**Files:** ios_scanner/AreaTargetScanner/Services/AreaTargetAPIClient.swift、AreaTargetScanArchive.swift、AreaTargetJobStore.swift（仅严格保护扩展入口校验）、对应三个测试类。AreaTargetProcessingModel.swift保留原有字节，已有归档进度显示实际保护数。

- [x] 先添加并确认失败：固定能力/未知能力、灰度候选排序、原图字节/K/源身份、字节重试不缩受保护帧、旧身份与已保存ZIP重试不变。
- [x] 实现有界逐帧质量分析、最多8帧1920保护及严格扩展元数据；无能力时使用旧v2路径。
- [x] 保持已有源SHA前后核验、取消/失败清理和任务冻结语义；进度说明实际保护数量。
- [x] 运行模拟器指定测试、独立检查客户端/服务端同一字段和预算合同。

## Task 3：真实建库与冻结查询回放

回放完成：同一真实几何、quality默认配置，iOS主对照与Pillow诊断各94/64完整回放，共8组632帧。iOS源52有效3D ORB15→23（Pillow16→23），有效KF91→92；iOS64返回38→39，只新增63，无丢失；94均91/94。31帧仅保护准备及实际逐帧K核验，未在本轮重复回放。数值报告及既有验证入口已更新；最终独立审计8组632帧、四地图366个KF位姿、全部归档/三维特征/31帧K/测试记录，未发现具体错误或夸大。全部本计划实施任务完成，真实500档及独立准确率验收仍为后续工作。

**Files:** docs/validation/scan-coverage-critical-frame-2026-10-06.md/.json（仅数值证据，照片/DB在隔离临时目录）。

- [x] 用原有94帧实拍构建同一几何、同一质量配置的旧v2与保护v2；保存原始SHA、实际混合尺寸和全部有效三维特征。
- [x] 比较源52的23→16临界案例是否恢复入库，亦记录其他帧是否退化；不能仅挑选有收益的帧。
- [x] 用相同冻结94/64 Gray8、同一个真实native库和参数完整回放，包含全部失败帧；记录新增/丢失、P50/P95、装载、数据库和内存。
- [x] 可用31帧现代扫描核验逐帧K和保护行为；无独立真值仍只报告返回行为，500真实验收保持待完成。
- [x] 保存报告，更新本计划和既有验证入口，独立审查后汇报实际收益与限制。

## 2026-10-07 用户授权复测

按用户“复测”指令，冻结现有两张iOS地图、94/64查询、实际macOS原生库和harness，AB/BA/AB各3轮严格串行、新进程/新handle，无并发新增建图或测试。已完成12组948帧；328文件摘要未变，返回777帧、NO_MATCH171帧、原生错误0。同一地图逐帧状态三轮一致：64每轮38→39，只新增63、丢失0；94每轮91/94，仍共同失败50/51/52。64 P95三轮中位数基线1.662s、保护1.678s（+1.00%），本轮未复现前次3.590s。负载采样、顺序2:1及输入SHA暖缓存的限制已记录，不称冷启动或独立准确率测试。报告见[三轮复测](../../validation/scan-coverage-critical-frame-retest-2026-10-07.md)；最终独立审计全部原始行、328文件SHA、状态/刚体矩阵/配置/数据库计数、串行窗口、所有轮次和报告统计，通过且无问题，数值审计已保存在报告JSON中。
