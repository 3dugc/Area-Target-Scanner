# 扫描覆盖去重与自适应分辨率 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 第一阶段完成重复帧去重和自适应分辨率，使独特视角能够进入定位数据库，并分档验证单图 100 / 500 张关键帧的处理能力。

**Architecture:** 服务端基于位姿、朝向和图像相似度保守去重，再按实际总像素分配分辨率；iOS 新版上传副本保留全部源帧，避免在服务端分析前均匀截断。定位特征按帧均衡分配既有 20 万总预算，UV 选图改为有界计算；通过 v2 策略协商保留旧任务兼容性。

**Tech Stack:** Python、Pillow、NumPy、OpenCV、Open3D、Swift / ImageIO、SQLite、pytest、XCTest。

**状态与范围：** 2026-10-05 编写，2026-10-06 用户授权实现。Task 1–5 的代码及本地回归已完成；Task 1 的独立现场数据与 Task 6 的现场评测/生产启用仍待实际结果验收。第一阶段针对自有 Area Target 链路，包含实现第 1、2 项所必需的上传、建库和 UV 配套；空间子地图、学习特征、PnP 与重定位算法优化列为后续工作。100 / 500 是拟验证能力，不是已经测得的识别效果。

---

## 当前问题与事实依据

1. iOS 上传归档先按序号均匀选取最多 80 帧：[AreaTargetScanArchive.swift](/Users/dirui/Documents/Area-Target-Scanner/ios_scanner/AreaTargetScanner/Services/AreaTargetScanArchive.swift:57)。本机原始扫描仍在，但服务器无法补回未上传的视角。
2. 服务端预处理同样固定 80 帧，fast / quality 共用这一限制：[scan_preparation.py](/Users/dirui/Documents/Area-Target-Scanner/processing_pipeline/scan_preparation.py:22)。
3. 移动定位建库又强制最多 80 帧：[optimized_pipeline.py](/Users/dirui/Documents/Area-Target-Scanner/processing_pipeline/optimized_pipeline.py:327)。只改上传或图片尺寸，覆盖改善不能传到最终数据库。
4. iOS 数据库读取器允许最多 1000 个关键帧，但要求 ORB + AKAZE ≤ 200000、ORB 数 × 词典数 ≤ 200000000，以及既有每帧限制：[AreaTargetFeatureDatabase.swift](/Users/dirui/Documents/Area-Target-Scanner/ios_scanner/AreaTargetScanner/Services/AreaTargetFeatureDatabase.swift:78)。
5. UV 已有 64 MiB 图片解码缓存，但选图仍创建面数 × 帧数的数组：[uv_unwrap.py](/Users/dirui/Documents/Area-Target-Scanner/processing_pipeline/uv_unwrap.py:443)。因此增加帧数必须同时改变这个计算的内存结构。
6. 有效 ORB 三维对应不足 20 的帧仍可能无法入库；应单独报告，不能把“保留 500 张图”称作“500 个有效定位视角”。

## 处理策略与首期参数

采用“保守去重 → 保留全部独特视角 → 按像素预算缩图 → 均衡分配定位特征”的路线。

| 能力档 | 去重后有效候选帧上限 | 处理总像素上限 | 长边上限 | 建议最低长边 |
| --- | ---: | ---: | ---: | ---: |
| 首个验收档 | 100 | 200000000 | 1600 | 1024 |
| 扩展验收档 | 500 | 600000000 | 1600 | 1024 |

这些是实施起点与资源保护参数，需通过后述评测才能启用扩展档。600M 总像素是总处理量，不能同时加载这些图片；500 张正方形 1024 × 1024 图片已有约 524M 像素。若仍沿用 200M 预算，500 张 4:3 图片平均只能达到约 730 × 548，可能损失局部纹理。

小于最低长边的源图不放大，也不进一步缩小到该源图以下来凑预算。去重后超过当前服务能力，或最低尺寸仍超预算时，返回 coverage_budget_exceeded，带源帧数、去重数、独特候选数和实际预算。不得重新按序号删到 80，也不得把未处理完的地图标成成功。

只提高 v2 的显式处理像素预算；旧 v1 的 200M 限制、ZIP / 解压字节、单图尺寸、路径与文件数量校验继续按各自策略验证。服务端不能信任上传者自报的预算。

### 第 1 项：保守重复帧去重

- 同时满足位移接近、完整旋转接近、画面几何匹配高度重合才删除重复帧。初始待校准阈值为位移 ≤ 8 cm、旋转测地角 ≤ 5°。
- 相机旋转在同一位置拍另一面、不同位置的相似走廊、不同 tracking run / 坐标批次，均不得仅凭图片相似而合并。
- 仅在长边 320 的等比例灰度缩略图上分析，ORB 最多 500 点。双方少于 50 点时不自动判为重复。
- 图像核验采用 Hamming KNN ratio ≤ 0.75 与双向匹配、单应性 RANSAC；初始重投影阈值为缩略图 2 像素、至少 50 个内点、内点率 ≥ 90%，匹配点覆盖双方 4 × 4 网格至少 9 格。阈值均属工程初值，必须用反例集校准。
- 位姿相近只用于筛选候选，不作为最终去重依据；白墙、动态遮挡、匹配不确定时保守保留。
- 每帧最多核验 32 个近邻代表帧；达到分析预算时保留，不执行全量两两比较。图片与分析缓存均有字节上限。
- 按清晰度、曝光有效性和缩略图特征数选代表帧。先计算质量再按稳定顺序选代表，删除帧必须直接与保留代表匹配，禁止相邻帧逐级串联导致整段路径被合并。
- 初始质量排序使用：非过曝/欠曝比例、拉普拉斯清晰度、缩略图特征数，最后按源索引稳定打破平局。它是采集质量代理，不是定位成功概率。
- 低纹理或模糊的独特视角不因质量排名被删除；在结果中报告潜在弱区域及后续实际建库失败帧。

### 第 2 项：按实际像素预算自适应尺寸

先在不放大的前提下把每张图长边限制到 1600，再以实际宽高之和计算总像素。超预算时使用平方根缩放；落到最低允许尺寸以下就报告预算不足。裁剪画面内容不在本次方案中。

拟实现的纯尺寸内核如下，放入 scan_preparation.py，v1 与 v2 通过明确策略参数分支：

~~~python
from dataclasses import dataclass
import math

@dataclass(frozen=True)
class WorkingImagePolicy:
    maximum_frames: int
    maximum_long_edge: int
    minimum_long_edge: int
    maximum_total_pixels: int

def working_image_sizes(dimensions, policy):
    if not dimensions or len(dimensions) > policy.maximum_frames:
        raise ValueError("coverage_budget_exceeded")
    if any(w <= 0 or h <= 0 for w, h in dimensions):
        raise ValueError("invalid_image_dimensions")
    initial = []
    for width, height in dimensions:
        ratio = min(1.0, policy.maximum_long_edge / max(width, height))
        initial.append((max(1, math.floor(width * ratio)),
                        max(1, math.floor(height * ratio))))
    pixels = sum(w * h for w, h in initial)
    ratio = min(1.0, math.sqrt(policy.maximum_total_pixels / pixels))
    output = [(max(1, math.floor(w * ratio)),
               max(1, math.floor(h * ratio))) for w, h in initial]
    for original, resized in zip(dimensions, output):
        floor_edge = min(policy.minimum_long_edge, max(original))
        if max(resized) < floor_edge:
            raise ValueError("coverage_budget_exceeded")
    if sum(w * h for w, h in output) > policy.maximum_total_pixels:
        raise ValueError("coverage_budget_exceeded")
    return output
~~~

实际缩放后，使用 sx = outputWidth / sourceWidth、sy = outputHeight / sourceHeight；分别更新 fx / cx 与 fy / cy。保留 transform、timestamp、源索引、图像方向与原扫描坐标；manifest / poses / intrinsics 指向一致的衍生图片。源图若大小未变化就复制编码字节，不重新编码。

## 执行任务

执行记录（2026-10-06）：已核对当前 develop 的既有采集质量/原生质量改进，保存相关文件基线。按文件归属实现服务端选帧、特征预算、UV 有界计算和 iOS 协议；未修改现有定位算法。去重经反例审查补充双侧特征重合 ≥85%、整图单应性覆盖 ≥90%、归一化相关 ≥0.97，并强制裁齐 OpenCV 的 ORB 响应平局至 500 点。尺寸分配按共同缩放与最低尺寸钳制迭代校验实际整数像素，避免小源图为凑预算继续缩小。上述均为保守完整性约束的实现细节。

### Task 1：冻结 v2 合同与独立验收数据

**修改文件：**
- processing_pipeline/scan_preparation.py
- web_service/mobile_api.py
- web_service/openapi.json
- docs/area-target-api.md
- tests/test_mobile_scan_preparation.py

- [x] 先保存旧 v1 输出与 80 帧抽样索引基线；新增重复静拍、原地转向、远处相似走廊、短暂经过角落、弱纹理独特区域的源扫描夹具。
- [ ] 增加独立拍摄的查询集和负样本；查询图不得直接使用建图图像。按区域标记，用同一查询集比较旧方案、仅去重、去重加缩图三组。
- [x] 默认 requirements 返回 v1；新版客户端通过 policy=mobile-scan-preparation-v2 请求 v2。未知策略明确报错，不依靠猜测字段决定版本。
- [x] 将能力档、最低长边、选择算法版本和预算写进 v2 requirements；服务端只接受自身允许的策略与配置。
- [x] v2 分开记录 originalFrameCount、receivedFrameCount、selectedFrameCount、duplicateFrameCount、selectedIndices、duplicateGroups、实际总像素、selectionDigest、scaleDigest。v2 不强制首尾源帧入选；v1 保留既有首尾规则。
- [x] 测试默认 v1、显式 v2、未知版本、伪造预算/计数、合法 v1 provenance；原始 scan manifest 的 schemaVersion 继续保持 1。

验证命令：python3 -m pytest tests/test_mobile_scan_preparation.py tests/test_scan_security.py -q。预期旧合同不变，新合同的成功与拒绝分支均有真实资源校验。

### Task 2：实现服务端去重与自适应缩图

**新增文件：**
- processing_pipeline/frame_selection.py
- tests/test_frame_selection.py

**修改文件：**
- processing_pipeline/scan_preparation.py
- tests/test_scan_preparation.py

- [x] 为位置、完整旋转、视觉核验三项分别写反例测试，先验证原地 90° 转向、远处相似画面、无特征白墙均保留。
- [x] 实现缩略图分析、质量排序、空间近邻查询和有界视觉核验；每个删除记录都能追溯到保留代表。
- [x] 验证非传递链：A 与 B 接近、B 与 C 接近，但 A 与 C 不满足条件时，不允许三帧只剩 A。
- [x] 实现上述 working_image_sizes，测试 100 张与 500 张混合比例图片、奇数尺寸、源图低于 1024、不得放大以及预算不足明确失败。
- [x] 去重后按源索引排序，生成衍生图及内参；使用独立 prepared_ 图片名，避免覆盖同一路径的模型材质图片。
- [x] 原始文件摘要在成功、失败、取消后保持一致；资源异常必须失败，不能悄悄跳过损坏图片来伪装完整扫描。

验证命令：python3 -m pytest tests/test_frame_selection.py tests/test_scan_preparation.py tests/test_mobile_scan_preparation.py -q。

### Task 3：取消二次均匀抽样并均衡分配特征预算

**新增文件：**
- processing_pipeline/feature_budget.py
- tests/test_feature_budget.py

**修改文件：**
- processing_pipeline/feature_extraction.py
- processing_pipeline/optimized_pipeline.py
- tests/test_mobile_feature_limits.py
- tests/test_feature_extraction.py
- tests/test_feature_db.py

- [x] v2 的准备结果是唯一的选帧集合；传入 max_keyframes=None。禁止特征阶段再裁成 80；v1 / legacy 调用仍保留既有行为。
- [x] quality 每帧检测仍最多 2000 ORB / 500 AKAZE；fast 每帧最多 1000 ORB。几何求交之后、词典训练之前进行总预算裁剪。
- [x] quality 使用 ORB ≤ 160000、AKAZE ≤ 40000；fast 使用 ORB ≤ 200000、无 AKAZE。词典保留既有 quality 1000 / fast 500 上限。
- [x] 每个符合原入库条件的帧先保护 20 个有效 ORB，再均分剩余额度。弱帧用不完的配额回收给其他帧；余数按源索引稳定分配。AKAZE 仅在有有效数据的帧间分配，无额外最低配额。
- [x] 按响应排序裁剪时同步二维点、三维点、描述子；响应相同按原特征序号打破平局。随后用最终特征建立词典、IDF 与 BoW，防止检索向量与持久化特征不一致。
- [x] 报告建库有效帧、因三维特征不足被跳过的帧、实际特征数量；保持原来的最低入库条件，不能仅为数量提高而放宽它。
- [x] 导出前再次核验总特征、每帧限制、ORB × vocabulary 和数组对应关系。

拟实现的预算内核，输入顺序必须先按源索引稳定排序：

~~~python
def balanced_quotas(demands, total_budget, per_frame_maximum, minimum=0):
    capacity = [min(per_frame_maximum, max(0, n)) for n in demands]
    quotas = [min(n, minimum) for n in capacity]
    remaining = total_budget - sum(quotas)
    if remaining < 0:
        raise ValueError("feature_budget_exceeded")
    active = [i for i, n in enumerate(capacity) if quotas[i] < n]
    while remaining and active:
        share = max(1, remaining // len(active))
        for i in active:
            grant = min(share, capacity[i] - quotas[i], remaining)
            quotas[i] += grant
            remaining -= grant
            if remaining == 0:
                break
        active = [i for i in active if quotas[i] < capacity[i]]
    return quotas
~~~

必须包含的预算测试：

~~~python
def test_quality_budget_for_500_full_frames():
    assert balanced_quotas([2000] * 500, 160000, 2000, 20) == [320] * 500
    assert balanced_quotas([500] * 500, 40000, 500) == [80] * 500

def test_weak_views_keep_features_and_return_unused_quota():
    assert balanced_quotas([20, 50, 2000], 1500, 2000, 20) == [20, 50, 1430]

def test_small_maps_do_not_lose_features():
    assert balanced_quotas([2000] * 80, 160000, 2000, 20) == [2000] * 80
~~~

验证命令：python3 -m pytest tests/test_feature_budget.py tests/test_mobile_feature_limits.py tests/test_feature_extraction.py tests/test_feature_db.py -q。500 × (320 ORB + 80 AKAZE) 只是满额预算例子，不是识别质量保证。

### Task 4：有界 UV 选图内存

**修改文件：**
- processing_pipeline/uv_unwrap.py
- tests/test_uv_texture_memory.py
- tests/test_uv_frame_calibration.py

- [x] 保存现有选图函数在小场景上的参考输出，包括相同得分、图像边界与完全不可见的面。
- [x] 按最多 4096 个面分块，逐帧更新每面的最佳得分与帧索引；只用 score > best_score 更新，保持原首帧平局行为与无效值 -1。
- [x] 不创建全图 face_count × frame_count 数组；继续使用既有 64 MiB 图片 LRU，保留全局补洞与光栅化顺序。
- [x] 验证 100 / 500 帧输出与参考计算一致，并检查中间数组维度与内存上限。真实大量可见图片必须被使用，不能仅重复三帧充数。
- [x] 在同一代表性网格上记录进程峰值 RSS、阶段耗时和缓存峰值；比较旧 80、新 100、新 500，扩展档只在目标部署资源可承受时启用。

验证命令：python3 -m pytest tests/test_uv_texture_memory.py tests/test_uv_frame_calibration.py tests/test_uv_unwrap_worker.py -q。

### Task 5：iOS v2 上传、任务身份与数据库读取回归

**修改文件：**
- ios_scanner/AreaTargetScanner/Services/AreaTargetAPIClient.swift
- ios_scanner/AreaTargetScanner/Services/AreaTargetScanArchive.swift
- ios_scanner/AreaTargetScanner/Services/AreaTargetProcessingModel.swift
- ios_scanner/AreaTargetScanner/Models/AreaTargetProcessingJob.swift
- ios_scanner/AreaTargetScannerTests/AreaTargetAPIClientTests.swift
- ios_scanner/AreaTargetScannerTests/AreaTargetScanArchiveTests.swift
- ios_scanner/AreaTargetScannerTests/AreaTargetProcessingModelTests.swift
- ios_scanner/AreaTargetScannerTests/AreaTargetFeatureDatabaseTests.swift
- ios_scanner/AreaTargetScannerTests/AreaTargetOfflineLocalizerTests.swift

- [x] 新任务显式协商 v2；识别实际服务能力。旧服务器只支持 v1 时展示旧能力限制，不能把旧 80 帧处理结果描述成新版完整覆盖。
- [x] v2 归档保留全部源帧，由服务器权威去重。iOS 仅创建临时上传副本并限制长边、实际 ZIP 字节；不得先均匀选 80 帧，也不冒充服务端已完成选择。
- [x] 上传缩图同样保持内参正确、源文件不变，材质共享图保持原路径字节；所有相机衍生图使用新路径。
- [x] 如果全部源帧在最低允许尺寸下仍无法满足已有上传字节约束，明确返回上传预算不足；不自动删除独特视角。服务端总处理像素预算与上传编码字节预算分别校验。
- [x] 扩展 provenance / build identity，包含策略配置、选择与缩放摘要；ScanSourceFingerprint 继续表示原始扫描身份。
- [x] 已持久化任务重试继续复用原 archive、摘要和策略，不因 requirements 改变而偷偷重新准备。
- [x] v1 和 v2 客户端 provenance 都按各自规则验证；取消与失败只清理本任务临时文件。
- [x] 生成 100 / 500 个真实关键帧、总特征符合预算的 SQLite 夹具，验证 Swift reader 与 native 装载确实接收全部帧。保持 reader 的 1000 帧和 200k 特征安全限制。

先用 xcodebuild -showdestinations 获取本机可用模拟器，再通过以下脚本选择实际可用 iPhone，避免写死设备名称：

~~~sh
ATC_SIMULATOR_ID="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; data=json.load(sys.stdin); print(next(d["udid"] for runtime,devices in data["devices"].items() if "iOS" in runtime for d in devices if d.get("isAvailable") and d["name"].startswith("iPhone")))')"
xcodebuild test -project ios_scanner/AreaTargetScanner.xcodeproj -scheme AreaTargetScanner -destination "platform=iOS Simulator,id=$ATC_SIMULATOR_ID" -only-testing:AreaTargetScannerTests/AreaTargetAPIClientTests -only-testing:AreaTargetScannerTests/AreaTargetScanArchiveTests -only-testing:AreaTargetScannerTests/AreaTargetProcessingModelTests -only-testing:AreaTargetScannerTests/AreaTargetFeatureDatabaseTests -only-testing:AreaTargetScannerTests/AreaTargetOfflineLocalizerTests
~~~

本地实现/回归、UV 资源复测及真实 native 100/500 帧装载记录见 [scan-coverage-preparation-v2.md](/Users/dirui/Documents/Area-Target-Scanner/docs/validation/scan-coverage-preparation-v2.md)。Task 1 的现场独立数据尚未提供，因此 Task 6 不勾选定位效果和生产启用。

真实数据测试补充（2026-10-06）：按用户要求使用已有 94 / 64 / 31 帧实拍，完成旧 80、仅去重原图、v2 去重缩图的实际建库与冻结同源/未知场景查询回放，另核验真实 31 帧 OBJ 的 UV。共 7 次建库、14 次原生完整回放，数值与资源记录见 [scan-coverage-real-data-2026-10-06.md](/Users/dirui/Documents/Area-Target-Scanner/docs/validation/scan-coverage-real-data-2026-10-06.md)。用户确认没有额外数据；独立位置真值、负样本、真实 500 帧和部署设备结果仍缺失，所以以下涉及独立现场验收的条目继续待验收。

### Task 6：验收与分档启用

**记录文件：** docs/validation/scan-coverage-preparation-v2.md。

- [ ] 同一源扫描生成旧 80 帧、v2 去重、v2 去重加缩图数据库，用冻结的独立查询集回放。
- [ ] 按入口、短暂经过的角落、转弯、不同朝向、重复走廊分别统计有效入库帧和定位输出；有独立真值才报告正确定位召回与误接受。
- [ ] 报告首次定位、查询 P50 / P95、地图载入、数据库大小、手机峰值内存与服务器阶段耗时；明确失败与超时，不只比较成功样本。
- [ ] 先验收 100 帧，再验收 500 帧；500 帧档通过容量、内存、坐标、独立查询与负样本回归后才启用。
- [ ] 任何档位未达到最低分辨率、特征容量或部署资源要求时明确失败并保留原始数据，不以静默删帧通过验收。
- [ ] 更新 processing requirements 与用户可见处理统计。实施后的 CI 发布、生产部署和真机安装作为单独操作安排，不在本次计划交付中执行。

## 其他改进的后续顺序

1. 第一阶段：本计划的去重、自适应分辨率及必要配套。
2. 第二阶段：带重叠区域的子地图、块检索与缓存，在单图预算不足时继续扩大覆盖。
3. 第三阶段：附近候选失败后的全局重试、AKAZE 恢复入口和候选检索召回诊断。
4. 第四阶段：基于独立评测选择学习特征与匹配器，进一步提高视角和光照变化下的识别能力。

## Immersal 对比的边界

官方价格页当前列出 Mapper 单图 Free 100 / Pro 500，Enterprise 按合同定制：[Immersal Pricing](https://immersal.com/pricing)。实际接入额度以账号 /status 的 imageMax 为准：[REST API](https://developers.immersal.com/docs/rest-api/)；降低分辨率不能绕过其图片数量限制。

本计划的 100 / 500 是自有链路的容量验证目标，不能仅用帧数证明效果达到 Immersal，也不直接修改 Immersal SDK 或会员额度。服务端能力档与第三方账号权限各自有明确来源。

## 计划自检与交付

- 第 1 项对应 Task 2 的保守去重；第 2 项对应尺寸内核及 Task 2 / 5。
- Task 1 / 3 / 4 是必要配套，防止错误版本协商、二次 80 帧抽样和 UV 内存增长破坏覆盖目标。
- 所有参数均为拟实施起点；未写入生产代码，未声称独立查询或性能测试已通过。
- 代码实现、CI 发布与安装需在后续实施阶段按上述验收逐项记录。本次交付的是可审阅计划。
