# Area Target 通用定位核心 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在保留 legacy 行为的前提下交付真实 C++ Raw 定位、版本化 C ABI、共享 SQLite 加载与同步 Session，使所有宿主使用相同算法和融合规则。

**Architecture:** 新 `atc_*` 接口与旧 `vl_*` 并存但不混用坐标语义；core 只处理标准图像和地图，Session 只处理数值结果与可选 tracking。core/session 均同步，每个宿主维持一个串行 worker 和 latest pending slot，避免两层异步队列。

**Tech Stack:** C++17、OpenCV 4、SQLite C API、CMake/CTest、Python 合同 fixture；C-compatible fixed-width POD。

---

日期：2026-10-05。依赖总计划 B01/B02。C01–C05已完成实现与验证。权威文件为 [需求](../specs/area-target-cross-platform/requirements.md)、[设计](../specs/area-target-cross-platform/design.md)、[任务看板](../specs/area-target-cross-platform/tasks.md)。本文件新增路径、类型和测试名称是计划交付物。

## 文件职责

| 文件 | 职责 |
|---|---|
| `docs/contracts/area-target-runtime-v2.md` | 冻结坐标、数据拥有权、ABI、时钟与生命周期合同 |
| `tests/fixtures/cross_platform/coordinate-contract-v2.json` | 无真实图像的非对称坐标/内参 golden fixture |
| `tools/cross_platform/validate_contract.py` | 检查规范字段、矩阵与投影的可执行合同 |
| `native_visual_localizer/include/area_target_runtime.h` | v2 公共 C ABI，独立 `atc_*` 符号 |
| `native_visual_localizer/src/runtime_c_api.cpp` | 参数/错误边界、Raw API、版本查询 |
| `native_visual_localizer/src/frame_contract.h/.cpp` | 长度、stride、尺寸/内参与字段合法性 |
| `native_visual_localizer/src/map_loader.h/.cpp` | 只读 SQLite、资源策略、候选地图加载 |
| `native_visual_localizer/src/localization_session.h/.cpp` | 纯数值 Session 状态机、相对残差与跟踪融合 |
| `native_visual_localizer/src/runtime_session_c_api.cpp` | Session 的 C ABI 包装 |
| `native_visual_localizer/tests/runtime_*_test.cpp` | ABI、真实 Raw、地图和 Session 行为验证 |

现有 `visual_localizer.cpp/.h` 与 `visual_localizer_impl.cpp/.h` 保留为算法基础。新 runtime 目标与 legacy 目标分别构建，不能重复编译/加载两份可见 legacy symbols。

## C01：冻结合同与非对称 fixture

**Create:** 上表中的合同、JSON、`validate_contract.py`、`tests/cross_platform/test_coordinate_contract.py`。

**Read:** `src/pose_contract.cpp`、`tests/pose_contract_test.cpp`、`Runtime/CoordinateTransform.cs`、`Runtime/LocalizationFrame.cs`、Swift `AreaTargetLocalizationSession.swift`、现有 phase1 fixture。

- [x] 写实际合同测试：读取计划 JSON，要求 API=2、`T_A_B` 的方向、单位、完整 optical/tracking/map 坐标说明、Gray8 和真实时间戳语义。拒绝缺单位、未声明图像方向、非法刚体、NaN、转置混淆和未知 clock mapping。
- [x] 运行新测试确认失败来自合同文件/校验器缺失，而不是依赖或解释器错误。

```sh
venv/bin/python -m pytest tests/cross_platform/test_coordinate_contract.py -q --tb=short
```

- [x] 创建固定数值 fixture；矩阵全部是 row-major，禁止用 identity rotation 掩盖乘法/转置问题。以下是核心 golden case：

```python
import numpy as np

world_from_camera = np.array([
    [0, -1, 0, 3], [1, 0, 0, -2],
    [0, 0, 1, 1], [0, 0, 0, 1]], dtype=float)
camera_from_scan = np.array([
    [0, 0, 1, 1], [0, 1, 0, 0],
    [-1, 0, 0, 2], [0, 0, 0, 1]], dtype=float)
expected = np.array([
    [0, -1, 0, 3], [0, 0, 1, -1],
    [-1, 0, 0, 3], [0, 0, 0, 1]], dtype=float)
np.testing.assert_allclose(world_from_camera @ camera_from_scan, expected)
```

- [x] 同一 JSON 增加 optical 点 `[2,1,4]` 在 `fx=600, fy=500, cx=320, cy=240` 下投影为 `[620,365]`；增加90°旋转、非等比缩放、裁剪、镜像的图像/内参一致性案例。原始与 rectified 图像分别声明 camera basis 和尺寸，不能仅交换 fx/fy。
- [x] 将 ABI 初始合同字段固定下来。所有 v2 类型共有 prefix；配置中的资源限额与 Session 参数必须写明单位。

| 类型 | 必须字段（除 prefix 外） |
|---|---|
| `ATCConfigV2` | `max_image_bytes/max_dimension`、地图 policy、known map-coordinate policy |
| `ATCFrameV2` | `frame_id/capture_timestamp_ns/map_generation`、`data/byte_length`、`width/height/row_stride`、`pixel_format`、`fx/fy/cx/cy` |
| `ATCMapInfoV2` | `map_instance_id`、keyframe/ORB/AKAZE/vocabulary counts、asset schema compatibility ID |
| `ATCResultV2` | 帧身份/地图实例、`raw_pose_valid`、`camera_from_scan[16]`、inliers、confidence、reprojection error及其validity、status |
| `ATCTrackingSampleV2` | frame/capture身份、`tracking_epoch`、`pose_timestamp_ns`、clock-mapping/pose/extrinsics-valid、tracking quality、`world_from_camera[16]` |
| `ATCSessionConfigV2` | 窗口/初始化/恢复计数、平移与旋转残差限额、最大同步/结果年龄、平滑时间常数 |
| `ATCSessionResultV2` | 帧/地图/epoch身份、Raw/alignment/propagated有效性、`world_from_scan[16]`、模式、拒绝原因、alignment年龄 |

- [x] 文档明确 `ATCResultV2` optical 坐标与 legacy AR 坐标不同；定义双边坐标基转换、时钟epoch转换、插值允许条件、buffer借用、串行所有权和地图世代失效规则。宿主按同一会话单调时钟检查提交/交付年龄，Session按输入采集时间检查alignment年龄和skew；明确各字段/单位和统一配置，禁止在core猜测宿主时钟epoch。
- [x] 运行合同与旧 phase1 回归，输出相同 golden 矩阵。C++/Swift/C#/Kotlin 后续必须消费本夹具而非各自造 identity 案例。

```sh
venv/bin/python -m pytest tests/cross_platform/test_coordinate_contract.py tests/phase1/test_scan_contract.py -q
python3 tools/cross_platform/validate_contract.py tests/fixtures/cross_platform/coordinate-contract-v2.json
```

**Gate:** 上述真实通过；合同字段与设计一致；提交 C01 文档、fixture和校验器，更新任务看板。

## C02：新增 ABI 与冻结 legacy

**Create:** `include/area_target_runtime.h`、`src/runtime_c_api.cpp`、`src/frame_contract.h/.cpp`、`tests/runtime_abi_test.cpp`、`tests/runtime_c_header_test.c`、`tests/cross_platform/test_legacy_abi.py`。

**Modify:** `native_visual_localizer/CMakeLists.txt`。现有 `visual_localizer.h` 不增加字段、不改布局。

- [x] 写编译/链接失败测试：C compiler 能包含 v2 header；C++ 固定检查 legacy `sizeof(VLResult)==76`、`sizeof(VLDebugInfo)==48`；新类型的 prefix、`offsetof`与字段宽度写入目标架构ABI清单。

```cpp
#include "visual_localizer.h"
#include "area_target_runtime.h"
#include <cstddef>
static_assert(sizeof(VLResult) == 76);
static_assert(sizeof(VLDebugInfo) == 48);
static_assert(offsetof(ATCFrameV2, struct_size) == 0);
static_assert(offsetof(ATCFrameV2, api_version) == 4);
static_assert(sizeof(decltype(ATCFrameV2::frame_id)) == 8);
```

- [x] 新 CMake 测试目标注册为 `runtime_abi`、`runtime_c_header`，运行并确认失败原因是缺少新接口。

```sh
cmake -S native_visual_localizer -B /private/tmp/atc-runtime-host -DBUILD_TESTING=ON
cmake --build /private/tmp/atc-runtime-host --target area_target_runtime runtime_abi_test runtime_c_header_test
ctest --test-dir /private/tmp/atc-runtime-host -R 'runtime_(abi|c_header)' --output-on-failure
```

- [x] 实现 C01 定义的 POD 与以下状态码；使用 out 参数且不让 C++异常穿过ABI。查询版本/布局不能调用一次定位来探测符号。

```c
enum {
    ATC_OK = 0, ATC_NO_MATCH = 1,
    ATC_INVALID_ARGUMENT = -1, ATC_ABI_MISMATCH = -2,
    ATC_MAP_NOT_LOADED = -3, ATC_MAP_INVALID = -4,
    ATC_RESOURCE_LIMIT = -5, ATC_INTERNAL_ERROR = -6,
    ATC_STALE_FRAME = -7, ATC_UNSUPPORTED_FORMAT = -8
};
```

- [x] 实现完整输入/输出size/version检查，支持stride有padding的Gray8；计算最小可读字节为 `(height-1)*row_stride+width`，每次乘加检查溢出。拒绝短buffer、超限尺寸、非法内参和未知格式；合法输出在失败时清除validity，不移动场景。
- [x] 写 guarded-output test：output prefix标明过小size，返回ABI错误且不越界；传入完整合法out结构时所有未成功姿态标为无效。C API不能验证任意悬空指针，测试不把调用契约之外的非法地址交给库。
- [x] 创建/reset/destroy实行唯一句柄所有权。`atc_destroy(&h)`置空；重复销毁空句柄测试通过。独立handle的状态互不影响。
- [x] 执行 CTest、旧native合同、实际符号检查；新公共导出列表与old required symbols分开维护，先保持当前old库可用。

```sh
ctest --test-dir /private/tmp/atc-runtime-host -R 'runtime_(abi|c_header)' --output-on-failure
venv/bin/python -m pytest tests/cross_platform/test_legacy_abi.py tests/phase0/test_native_contract.py -q
bash native_visual_localizer/build_macos.sh
```

**Gate:** C compilation、size/offset、out写入范围与旧symbols均真实通过；不是只检查header字符串。

## C03：接通真实 Raw 定位

**Create:** `tests/runtime_raw_test.cpp`、`tests/cross_platform/test_runtime_frame_contract.py`。

**Modify:** `runtime_c_api.cpp`、`frame_contract.*`、`visual_localizer_impl.*`、`pose_contract.*`，只在必要边界抽取共享逻辑。

**Read/Reuse:** `tools/ios/generate_native_fixture.cpp/.py`、`tests/test_native_localizer.py`。非共面真实算法夹具继续使用；不以恒定成功或恒定LOST的stub替代。

- [x] 写失败测试：同一真实地图/图像分别走 legacy 与v2，v2 optical结果经明确轴转换后应等于legacy结果；无VIO也成功。空白图为NO_MATCH，非法输入为错误，二者不是同一个状态。
- [x] 生成受控临时夹具，注册 `runtime_raw` CTest。夹具与native测试同源码、同依赖身份；初始化seed/执行顺序只用于可重复测试，不以随机边缘样本规定精度。

```sh
python3 tools/ios/generate_native_fixture.py --output-dir /private/tmp/atc-runtime-fixture
cmake -S native_visual_localizer -B /private/tmp/atc-runtime-host -DBUILD_TESTING=ON -DATC_FIXTURE_DIR=/private/tmp/atc-runtime-fixture
cmake --build /private/tmp/atc-runtime-host --target runtime_raw_test
ctest --test-dir /private/tmp/atc-runtime-host -R runtime_raw --output-on-failure
```

- [x] v2以图像/内参调用共享ORB→BoW→PnP→AKAZE路径，关闭legacy AR一致性先验；将native现有AR相机输出转换回C01光学坐标。旧入口仍保留原来的结果和过滤语义。
- [x] 新结果必须关联输入frame/generation和当前map instance；重投影误差由真实inlier求出，缺少有效inlier时validity=false，不能填0表示高质量。
- [x] 以下是成功的关键断言；实际测试还比较非单位旋转/平移与已知姿态，以及stride padding后的相同像素结果。

```cpp
// h与frame由本文件的真实fixture装载代码构造。
ATCResultV2 result{};
result.struct_size = sizeof(result);
result.api_version = 2;
const ATCStatus status = atc_localize(h, &frame, &result);
assert(status == ATC_OK);
assert(result.raw_pose_valid == 1);
assert(result.frame_id == frame.frame_id);
assert(result.map_generation == frame.map_generation);
assert(result.capture_timestamp_ns == frame.capture_timestamp_ns);
```

- [x] 执行真实native回归；同样图像由不同宿主处理的目标是相同Raw算法和配置，不要求不同CPU浮点结果按字节一致。已知姿态夹具用其现有容差，阈值边缘案例记录差异并拒绝模糊“全部一致”声明。

```sh
cmake --build /private/tmp/atc-runtime-host
ctest --test-dir /private/tmp/atc-runtime-host -R 'runtime_(raw|abi)' --output-on-failure
venv/bin/python -m pytest tests/test_native_localizer.py tests/cross_platform/test_runtime_frame_contract.py -q
```

**Gate:** optical结果、legacy转换、真实Raw无VIO、NO_MATCH/ERROR、padding与短buffer都通过；ORB/AKAZE阈值没有迁移外调优。

## C04：共享 SQLite loader

**Create:** `src/map_loader.h/.cpp`、`tests/runtime_map_loader_test.cpp`、`tests/fixtures/cross_platform/map-policy-v2.json`。

**Modify:** `runtime_c_api.cpp`、CMake；链接只读SQLite依赖并记录其版本/来源。协议不增加网络/JSON/crypto运行依赖。

**Read:** Swift `AreaTargetFeatureDatabase.swift`、Python `processing_pipeline/feature_db.py`、Unity `FeatureDatabaseReader.cs`。

- [x] 用真实SQLite构造合法/损坏数据库：缺表、view冒充表、错误类型/BLOB长度、非finite、重复或孤立ID、非刚体pose、错误endianness、空词库、ORB/AKAZE超预算。测试必须实际打开DB，不能只匹配源码SQL字符串。
- [x] 用合法夹具确认 ORB32、optional AKAZE61、128-byte little-endian float64 pose；仅features.db且没有GLB的bundle也能加载。legacy生产者兼容只由明确policy允许。
- [x] 注册 `runtime_map_loader` 测试；运行并观察加载功能缺失或现有宽松reader不能拒绝损坏输入。
- [x] 迁移Swift最低校验：只读事务快照、schema/type、安全SQLite配置、总量/每帧/BoW/SQL步数与时间预算。严格按 vocabulary→ORB→AKAZE→build index装载，不让core重新下载或改写数据库。
- [x] 新地图先加载到候选对象，成功才替换已载入地图；失败释放候选并在core保留旧地图供显式回滚。宿主必须将失败请求的新generation标为不可用，不能把旧地图输出作为新地图结果。宿主取消时等待调用完成，再丢弃候选/世代结果，不能在native读取中释放handle。
- [x] 验证核心场景：加载A后，损坏B返回MAP_INVALID，core保留A的地图身份及known-pose定位；加载合法C更新map instance。宿主B请求不可用、显式回滚及迟到结果应用门禁是H01/H02接入要求，当前不标为已实现宿主行为。
- [x] 记录资源policy，并运行真实 loader + Raw + 既有数据库回归。

```sh
cmake --build /private/tmp/atc-runtime-host --target runtime_map_loader_test runtime_raw_test
ctest --test-dir /private/tmp/atc-runtime-host -R 'runtime_(map_loader|raw)' --output-on-failure
venv/bin/python -m pytest tests/test_feature_db.py tests/test_feature_properties.py -q
```

**Gate:** 所有拒绝场景、资源上限、atomic map replacement及无mesh定位通过；迁移后资源限制没有减少。

## C05：同步共享 Session 与可选融合

**Create:** `src/localization_session.h/.cpp`、`src/runtime_session_c_api.cpp`、`tests/runtime_session_test.cpp`、`tests/fixtures/cross_platform/session-sequence-v2.json`。

**Read:** Unity `AreaTargetTracker.cs`、`AlignmentTransformCalculator.cs`、`KalmanPoseFilter.cs`、`AsyncLocalizationRunner.cs` 与 Swift generation/barrier实现。

- [x] 写纯数值失败测试：Raw成功但tracking=null返回Raw且alignment=false；同帧合法tracking产生 `T_W_S`；NO_MATCH下VIO延续不能增加视觉成功数；不同frame/epoch、倒序时间、过大skew拒绝fusion；不合法矩阵不会移动内容。
- [x] fixture明确测试参数：初始化3个样本、窗口5、平移残差0.25m、旋转残差5°、最大skew5ms；这些仅是测试输入，不是商业精度或未经设备测量的生产默认值。实际SDK配置必须记录来源和单位。
- [x] 实现Session配置与同步C入口。输入字段校验和唯一世代状态共享；没有native内部worker、不启动相机、不调用render API。
- [x] 实现 `T_W_S=T_W_C×T_C_S`，以相对alignment的平移/旋转残差拒绝outlier；移植已验证的对齐/恢复状态职责。用整个轨迹左乘另一刚体world变换后，成功/拒绝决定应不变。

```text
raw_pose_valid = true, tracking = null
  => mode=RAW, alignment_valid=false
raw_pose_valid = true, tracking matched to frame and clock
  => alignment sample = T_W_C * T_C_S
raw_pose_valid = false, fresh valid tracking + prior alignment
  => propagated_pose_valid may be true; raw_pose_valid stays false
authorized map_generation / tracking_epoch reset
  => clear previous alignment/propagation
stale result or mismatched pinned tracking_epoch
  => reject without clearing the current valid alignment
```

- [x] 对输入路径、状态、平滑、结果年龄与拒绝原因写独立validity。Raw比较模式只调用 `atc_localize`，不让融合策略改变两算法回放评分。
- [x] reset测试序列：建立alignment→map切换→旧结果到达→STALE拒绝→新Raw→重新建立alignment。再用两个独立Session同序列运行，证明不共享可变history。
- [x] 执行native所有测试与旧API回归；ASan/UBSan宿主构建检查新增loader/ABI边界，记录与legacy外部依赖相关的不可执行项，不在设备门禁假绿。

```sh
cmake --build /private/tmp/atc-runtime-host
ctest --test-dir /private/tmp/atc-runtime-host --output-on-failure
cmake -S native_visual_localizer -B /private/tmp/atc-runtime-sanitized -DBUILD_TESTING=ON -DATC_FIXTURE_DIR=/private/tmp/atc-runtime-fixture -DCMAKE_CXX_FLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer' -DCMAKE_EXE_LINKER_FLAGS='-fsanitize=address,undefined' -DCMAKE_SHARED_LINKER_FLAGS='-fsanitize=address,undefined'
cmake --build /private/tmp/atc-runtime-sanitized
ctest --test-dir /private/tmp/atc-runtime-sanitized -R runtime --output-on-failure
```

**Gate:** Session与Raw分离、坐标origin不变性、复位、世代、skew、两会话隔离和边界内存检查通过；保存本次变更并更新C01–C05；按当前范围只进入最小iOS测试/迭代工具，完整宿主子计划仍暂缓。

## M1 交付清单

- [x] legacy ABI与v2 ABI同时有真实构建/符号证据。
- [x] 相同已知姿态夹具可在host v2定位，Raw不要求VIO。
- [x] 所有地图/帧资源限制、错误码和未知格式拒绝可执行。
- [x] 同步Session只接收通用数值数据；接口不包含Unity/ARKit对象。
- [x] API、地图、fixture、工具版本和源码身份已记录；不提前声明任何新增设备已支持。

执行证据：[runtime-v2-results.md](../../validation/cross-platform/runtime-v2-results.md)。全库ASan仍有已独立复现的外部TBB退出崩溃；具体通过/不可完成项已记录，不表示sanitizer全绿。
