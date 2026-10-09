# Area Target SDK Bindings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Swift、Unity/C# 和 Android/Kotlin 通过同一个 `atc_*` C ABI 使用地图定位与共享 session，并用可复现制品和明确的验收证据推进平台接入。

**Architecture:** C++ core 和共享 session 都是同步组件；每个宿主拥有一个串行 worker 和一个 latest pending frame slot，负责调度、相机 buffer 所有权和 UI 线程切换。原始图像定位不接受 tracking 先验，共享 session 单独融合可选 VIO；包装层只转换 ABI、宿主坐标与生命周期。iOS 原生和 Unity iOS 复用私有动态 `AreaTargetNative.framework`，避免将 Unity 的静态全局 OpenCV 和私有动态 core 混装。

**Tech Stack:** C ABI v2、Swift/ARKit、Unity C#/IL2CPP、Android JNI/Kotlin/NDK/AAR、CMake、Xcode、Gradle、Python/pytest，以及仓库现有 native 构建和 symbols 检查工具。

---

## 依赖、边界与执行记录

- 总计划：[2026-10-05-area-target-cross-platform.md](2026-10-05-area-target-cross-platform.md)。
- 核心依赖：[2026-10-05-area-target-runtime-core.md](2026-10-05-area-target-runtime-core.md) 的 C01–C05；H01–H03 接入这些任务实际产出的头文件、地图加载器、同步 core、同步 session 和测试夹具。
- 平台采集依赖：[2026-10-05-area-target-device-adapters.md](2026-10-05-area-target-device-adapters.md) 的 P01–P05。Android ARCore 实采归 P01；Rokid、PICO、Quest 的独立平台包位置及采集合同以该子计划为准。
- Android 厂商采集代码分别属于可选 Gradle 模块 `android_sdk/area-target-platform-arcore/`、`area-target-platform-rokid/`、`area-target-platform-pico/`、`area-target-platform-quest/`，各自依赖 `area-target-sdk`；P01 注册可选模块。H03 的 core AAR 不包含 vendor SDK、vendor Kotlin 实现或厂商权限，不能为收集未来 adapter 而向 `area-target-sdk/src/main` 加入全部设备依赖。
- 产品要求：[requirements.md](../specs/area-target-cross-platform/requirements.md)、[design.md](../specs/area-target-cross-platform/design.md)、[tasks.md](../specs/area-target-cross-platform/tasks.md)。
- C01 创建接口合同 `docs/contracts/area-target-runtime-v2.md`；C02 创建 `native_visual_localizer/include/area_target_runtime.h`。这两个文件在依赖完成前不能被当作已经存在的实现。
- 本文新增路径均是计划目标；checkbox 未勾选表示未实施。下面的 `Expected` 是未来验证标准，不能用计划文档或 mock PASS 替代运行结果。
- 每项 red/green 后记录命令、退出码、实际测试数、跳过原因和制品 digest。只提交该任务所属代码、测试和实际记录；本次计划编写不运行制品构建或真机验收。

### 不变合同

`T_A_B` 表示从 B 到 A，使用列向量。C 是光学相机右手坐标（x 右、y 下、z 前），S 是原扫描右手坐标、单位米，W 是合同定义的规范右手追踪坐标。宿主坐标转换由包装层执行，矩阵序列化规则由 C01 定义；不能将数组转置和坐标基变化混为一谈。

所有 v2 C 结构以 `uint32_t struct_size`、`uint32_t api_version` 开头；不自行猜测结构字节偏移。使用 C01 的字段和 C02 的 layout 检查结果生成或验证包装层。ABI 版本来自 `atc_get_api_version()`，package version 沿用实际制品版本策略，不为这次迁移强制发布一个新版本号。

核心入口：`atc_create`、`atc_load_map`、`atc_localize`、`atc_reset`、`atc_destroy`。session 入口：`atc_session_create`、`atc_session_update`、`atc_session_reset`、`atc_session_destroy`。destroy 接收句柄地址并清空它；包装层必须先串行排空在途调用。`atc_localize` 的 `ATCFrameV2` 只含 frame identity、灰度图和内参，不能把 ARKit/ARCore/Unity tracking pose 塞进该调用。tracking 仅通过 `ATCTrackingSampleV2` 进入 session。

`ATCFrameV2` 的 frame ID、capture_ns、map_generation、gray8 pointer/bytes、width/height/stride、fx/fy/cx/cy 与输入图像一致；raw result 回填同一 frame identity 和光学 `T_C_S`。session 返回明确有效性标记的 `T_W_S`。无 tracking、tracking 不同帧或 epoch 不匹配时 Raw 仍可成功，而 world alignment 不可伪造。失败不以 identity matrix 冒充有效位姿。

旧 `vl_*` 导出、旧 `VLResult`/`VLDebugInfo` 布局和行为冻结。v2 包装不通过实际定位调用探测 API，也不通过调用 `vl_process_frame` 探测 `_out` symbol。保留现有 Immersal、服务端接口与双引擎 Raw 比较的评分语义。

### 文件所有权

| 任务 | 新文件或主要修改文件 | 职责 |
| --- | --- | --- |
| H01 | `ios_sdk/AreaTargetSDK`；现有 `AreaTargetOfflineLocalizer.swift`、`AreaTargetLocalizationSession.swift` | Swift 公共 SDK、串行 worker、ARKit 同帧薄 adapter、兼容 facade |
| H02 | Unity `IFrameProvider.cs`、`NativeRuntimeV2Bridge.cs`、`SharedLocalizationSession.cs`；tracker/frame/result/postprocess | 公共采集接口、C ABI 包装、latest-slot 调度、宿主坐标与场景应用 |
| H03 | `android_sdk/area-target-sdk` | JNI/Kotlin、native 制品打包、replay 与 lifecycle；不实现 ARCore 实采 |
| H04 | `tools/cross_platform/verify.py`、`tests/cross_platform/test_verify_driver.py`、制品 manifest schema、SDK 构建/分发配置、CI job | 统一验证入口、制品/依赖/头文件可追溯、private symbols 隔离、验收证据门禁 |

H01–H03 不各自发明 `verify_swift.sh`、`verify_unity_v2.sh` 或其他未定义验收脚本。它们先用明确的 Xcode、Unity、Gradle 测试命令；H04.1 创建并验证 driver 后才使用 `tools/cross_platform/verify.py`，各模式仍等待对应真实产物。P01 创建 `tools/cross_platform/device_probe.py` 并扩展 device 入口；该工具不归 H04 冒名实现。

H03.1 工程 setup、H04.1 的 driver mock 测试可以先并行进行；真实 ABI/算法/session 接入依赖 C01–C05 的对应产物。H01/H02 的真实 iOS 链接和 synthetic fixture green 必须等待 H04.3 构建出包含新 ABI 的 framework。H04.4 先基于 core 和已记录工具链构建 Android runtime，再交 H03.3 联通 JNI；H03.1–H03.2 无需等待这些 binary，H04.4 的最终 AAR/Unity 制品和真实报告核验则等 H03.3–H03.4 完成。H04.1–H04.5 可在宿主阶段完成；P01 不要求整个 H04 完成才启动。H04.6 在对应 P01–P05 产出能力与设备验收证据后收敛，H04.7 和 release gate 在总计划 M5 完成。因此“runtime 产物先行”和“最终包装验收后行”是分步依赖，不存在 H03 与整个 H04 互等的循环。

`load(bundleDirectory:)` 接收宿主资产层已经下载、解压和核对身份的本地 bundle；core 固定只读取其中的 `features.db` 并应用 load policy。manifest、ZIP、来源 fingerprint 和 SHA 身份由现有 `AreaTargetAssetStore.swift`/Unity `AssetBundleLoader.cs` 或平台资产层承担，不向 core 引入 JSON/crypto 依赖。

宿主收到新地图请求时，立即失效旧 active generation、停止该绑定的 frame 提交并清空输出。若新地图加载失败，则返回 MapLoadFailed 并保持无 active map，不能默默让该请求继续使用旧 generation 的地图。core 的 transactional candidate loader 可以保留旧地图内存，但只供用户或调用者显式回滚：重新绑定旧来源身份、赋予新的 generation、重置 session/tracking epoch 并记录回滚事件后才允许再次提交。

### 夹具来源与宿主 helper 所有权

| 来源任务 | 权威源 | 使用范围 |
| --- | --- | --- |
| C01 | `tests/fixtures/cross_platform/coordinate-contract-v2.json` | 无图像的非对称坐标、矩阵布局、内参/投影 golden 数据 |
| C03 | `tools/ios/generate_native_fixture.py` 生成的受控 synthetic map/图像/已知 pose；核心计划命令输出到 `/private/tmp/atc-runtime-fixture` | 真实 Raw 算法、旧新 ABI 转换、像素与 stride 绑定；宿主 staging 时记录 generator/source/内容 digest |
| C05 | `tests/fixtures/cross_platform/session-sequence-v2.json` | session 的 frame/generation/epoch/skew/失追/融合序列 |

宿主任务创建下表所有 fixture loader、spy、bounded blocking double 和断言 helper；它们只翻译/拷贝对应权威数据，不能自行修改 golden 预期或以 mock 成功替代真实算法。SDK test resources/Android assets 的生成与 staging 在宿主任务内完成，H04 负责分发时摘要核验。

| 宿主任务 | 计划创建的 helper 文件 | 定义 |
| --- | --- | --- |
| H01 | `ios_sdk/AreaTargetSDK/Tests/AreaTargetSDKTests/RuntimeFixtureHelpers.swift` | `fixtureFrame`、`fixtureBundleDirectory`、C02 的 supported/unsupported API 值、C01 坐标值及 `assertMatrixEqual`；装载 C03 Raw 数据与 C05 session 序列 |
| H01 | `ios_sdk/AreaTargetSDK/Tests/AreaTargetSDKTests/NativeRuntimeTestDoubles.swift` | `RecordingNativeRuntime`、带有界等待的 native spy 与 `ResultCollector` |
| H01 | `ios_scanner/AreaTargetScannerTests/LocalizationSDKFixtureHelpers.swift` | Scanner XCTest 使用的 C01 坐标断言及 C03/C05 adapter；不从另一 test target import helper |
| H02 | `unity_plugin/AreaTargetPlugin/Tests/RuntimeV2TestFixtures.cs` | 示例中的 internal `Fixtures`：C01 坐标/C03 BundleDirectory、RawEnvelope/C05 session sequence、NoMatchResult |
| H02 | `unity_plugin/AreaTargetPlugin/Tests/NativeRuntimeV2TestDoubles.cs`、`unity_plugin/AreaTargetPlugin/Tests/FrameProviderTestDoubles.cs` | `RecordingNativeRuntimeV2`、`BlockingNativeRuntimeV2`、`FakeFrameProvider` |
| H03 | `android_sdk/area-target-sdk/src/test/java/com/areatarget/sdk/RuntimeFixtureHelpers.kt`、`android_sdk/area-target-sdk/src/test/java/com/areatarget/sdk/NativeRuntimeTestDoubles.kt` | JVM tests 的 `Fixtures`、`RecordingNativeRuntime`、`BlockingNativeRuntime`；只用 fake/native seam，绝不装载真 so |
| H03 | `android_sdk/area-target-sdk/src/androidTest/java/com/areatarget/sdk/RuntimeFixtureHelpers.kt` | Instrumented tests 独立 source set 的 `Fixtures`、asset 拷贝和 `assertMatrixNear`，使用 C01/C03/C05 数据 |
| H03 | `android_sdk/area-target-sdk/src/test/cpp/area_target_jni_boundary_test.cpp`、`android_sdk/area-target-sdk/src/test/cpp/jni_boundary_test_doubles.h` | JNI checked boundary/fake holder 测试及失效句柄 helper |
| H04 | `tests/cross_platform/test_verify_driver.py` | 注入 runner、临时 manifest/report/evidence fixture；只测验证政策，不声称设备运行 |

上述 helper 路径也是各宿主任务的 Create 文件，分别随该任务提交；本计划中未展示其全文不表示可由其他核心任务隐含提供。

## H01：Swift SDK 与 iOS 原生接入

**Depends on:** C01–C05。ARKit 现有同帧采集可以复用；新 raw/fusion 接入必须遵循 C01 时钟合同。

**Files:**

- Create: `ios_sdk/AreaTargetSDK/Package.swift`。
- Create: `ios_sdk/AreaTargetSDK/Sources/AreaTargetSDK/RuntimeTypes.swift`。
- Create: `ios_sdk/AreaTargetSDK/Sources/AreaTargetSDK/NativeRuntimeCalling.swift`。
- Create: `ios_sdk/AreaTargetSDK/Sources/AreaTargetSDK/NativeRuntimeV2.swift`。
- Create: `ios_sdk/AreaTargetSDK/Sources/AreaTargetSDK/AreaTargetSDKRuntime.swift`，公共 facade，委托单 worker 与共享 session。
- Create: `ios_sdk/AreaTargetSDK/Sources/AreaTargetSDK/SharedLocalizationSession.swift`。
- Create: `ios_sdk/AreaTargetSDK/Sources/AreaTargetSDK/SerialLocalizationWorker.swift`。
- Create: `ios_sdk/AreaTargetSDK/Tests/AreaTargetSDKTests/NativeRuntimeV2Tests.swift`。
- Create: `ios_sdk/AreaTargetSDK/Tests/AreaTargetSDKTests/SerialLocalizationWorkerTests.swift`。
- Create: `ios_scanner/AreaTargetScanner/Services/AreaTargetSDKARKitAdapter.swift`。
- Modify: `ios_scanner/AreaTargetScanner/Services/AreaTargetOfflineLocalizer.swift`。
- Modify: `ios_scanner/AreaTargetScanner/Services/AreaTargetLocalizationSession.swift`。
- Modify: `ios_scanner/AreaTargetScanner/Services/LocalizationReplayAdapters.swift`。
- Modify: `ios_scanner/AreaTargetScanner.xcodeproj/project.pbxproj` 和共享 test scheme，添加本地 Swift package 与 SDK test target。
- Test/modify: `ios_scanner/AreaTargetScannerTests/AreaTargetOfflineLocalizerTests.swift`、`AreaTargetLocalizationSessionTests.swift`、`CoordinateContractTests.swift`、`LocalizationComparisonSessionTests.swift`。
- H04 owns distribution changes to: `tools/ios/build_area_target_native.py`、`tools/ios/verify_area_target_native.py`、`ios_scanner/AreaTargetScanner/ThirdParty/AreaTargetNative/AreaTargetNative.h` 和 XCFramework 布局。

- [ ] **H01.1 定义 Swift 边界并写 red 测试。** 公共值类型定义 `RuntimeFrame`（frameID/captureNs/mapGeneration/灰度 Data/width/height/rowStride/fx/fy/cx/cy）、`RawLocalizationResult`（关联身份/status/optional 光学 cameraFromScan/confidence/inliers）、`TrackingSample`（同帧身份、时间/epoch/规范 worldFromOpticalCamera/quality）和 `SessionResult`（rawResult/optional worldFromScan/mode/rejection）。raw 类型不得持有 ARFrame、ARSession、SceneKit node 或 tracking pose。ABI 对象只存在于 `NativeRuntimeV2` 内，指针不外泄。

  注入 seam 使用下面的宿主协议；`RuntimeMapInfo` 是 C01 map info 的 Swift 值副本，`RuntimeStatus` 是 C01 状态码的穷尽映射。`OwnedRuntimeHandles` 不公开，并保存 core/session 两个 opaque handle。所有实调用与释放只允许 worker 进入。

  ```swift
  protocol NativeRuntimeCalling: AnyObject {
      func apiVersion() -> UInt32
      func create() throws
      func loadMap(bundleDirectory: URL) throws -> RuntimeMapInfo
      func localize(_ frame: RuntimeFrame) -> RawLocalizationResult
      func updateSession(_ raw: RawLocalizationResult,
                         tracking: TrackingSample?) -> SessionResult
      func reset(mapGeneration: UInt64, trackingEpoch: UInt64)
      func close()
  }
  ```

  `RecordingNativeRuntime` 是测试 target 内的协议实现，记录 operation/线程/frame identity；用 `DispatchSemaphore` 控制 localize 在途，不调用真实 C++。下面的协议反射/生命周期测试与真实 synthetic fixture 测试分开执行，不把 recording backend 的成功当算法成功。

  ```swift
  func testOpeningOnlyProbesAPIWithoutLocalizing() throws {
      let native = RecordingNativeRuntime(apiVersion: supportedAPIVersion)
      let sdk = AreaTargetSDKRuntime(native: native)
      try sdk.open()
      XCTAssertEqual(native.operations, ["apiVersion", "create"])
      XCTAssertEqual(native.localizationCalls, 0)
  }

  func testRawCallNeverReceivesTracking() async throws {
      let native = RecordingNativeRuntime(apiVersion: supportedAPIVersion)
      let sdk = AreaTargetSDKRuntime(native: native)
      try await sdk.load(bundleDirectory: fixtureBundleDirectory)
      let result = await sdk.localizeRaw(fixtureFrame)
      XCTAssertEqual(native.localizedFrameIDs, [fixtureFrame.frameID])
      XCTAssertEqual(native.sessionTrackingInputs.count, 0)
      XCTAssertEqual(result.frameID, fixtureFrame.frameID)
  }
  ```

  `AreaTargetSDKRuntime` 的公共入口固定为 `open()`、`load(bundleDirectory:) async throws`、`localizeRaw(_:) async`、`submit(_:tracking:)`、`reset(mapGeneration:trackingEpoch:) async`、`close() async`；`submit` 的输出通过 SDK result consumer 回到指定 executor。`supportedAPIVersion` 从 C02 header 的常量取得，unsupported 值在 helper 中明确构造为另一 API 值；fixtureFrame/fixtureBundleDirectory 由 H01 的 `RuntimeFixtureHelpers.swift` 装载 C03 synthetic map/图像。坐标预期来自 C01，融合序列来自 C05。H01 在此步骤创建前述 helper 文件，不引用生产录制私有路径。

  Run（Xcode scheme/target 加入后）：

  ```bash
  xcodebuild test -project ios_scanner/AreaTargetScanner.xcodeproj -scheme AreaTargetScanner -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:AreaTargetSDKTests -resultBundlePath /private/tmp/atc-h01-red.xcresult
  ```

  Expected RED: SDK 方法尚未实现时是编译错误或预期断言失败。若此 simulator 名称不在 `xcodebuild -showdestinations` 中，先选择已安装 simulator 并记录实际 destination；缺少 runtime 是 BLOCKED，不能写成测试 PASS。

- [ ] **H01.2 实现 ABI shim 与错误转换，运行 green。** 使用 C02 header 创建 `ATCConfigV2`/`ATCFrameV2`/`ATCResultV2` 等对象，填 prefix；先检查 API/layout，unsupported 直接报错。`Data.withUnsafeBytes` 的 pointer 仅在同步 `atc_localize` 范围有效。检查 Data 长度与 stride 的最后一行范围、正数尺寸、有限内参、Int 到 C 整数的 checked narrowing。调用后立即复制结果，按 validity 判定 optional matrix；每个 C 状态保留可诊断的 Swift enum，不能统一吞为 nil。

  ```swift
  func testUnsupportedAPIIsRejectedBeforeCreate() throws {
      let native = RecordingNativeRuntime(apiVersion: unsupportedAPIVersion)
      let sdk = AreaTargetSDKRuntime(native: native)
      XCTAssertThrowsError(try sdk.open())
      XCTAssertEqual(native.operations, ["apiVersion"])
  }

  func testFailedRawResultHasNoPose() async throws {
      let native = RecordingNativeRuntime(apiVersion: supportedAPIVersion)
      native.nextRawStatus = .noMatch
      let sdk = AreaTargetSDKRuntime(native: native)
      try await sdk.load(bundleDirectory: fixtureBundleDirectory)
      let result = await sdk.localizeRaw(fixtureFrame)
      XCTAssertNil(result.cameraFromScan)
      XCTAssertEqual(result.status, .noMatch)
  }
  ```

  使用全新 `/private/tmp/atc-h01-green.xcresult` 重跑 H01.1 命令，再执行现有 `AreaTargetOfflineLocalizerTests/testRealNativeRecognizesSyntheticKnownPoseFromProductionSQLite` 对 v2 fixture 等价路径的测试。Expected GREEN: mock 边界测试和真实 core fixture 分别报告通过；不从一项推导另一项。

- [ ] **H01.3 实现单串行 worker/latest-slot 和生命周期。** 采用每个 SDK 实例一条串行队列；只将最晚未处理帧保留在 pending slot。提交时拥有灰度 Data 副本；不得把 CVPixelBuffer base pointer 跨 async 边界保存。load/reset/close 与 localize/session_update 在同一 worker 顺序执行；取消/重载递增 generation，关闭完成前排空在途 native 调用。重复 close 返回同一 completion 或幂等完成；deinit 只安排安全释放，不能在调用中的句柄上 destroy。

  新增 recording tests：`testSubmissionOwnsImageAfterSourceMutation`、`testBusyWorkerOnlyKeepsNewestPendingFrame`、`testCloseWaitsForInFlightCallAndSuppressesResult`、`testReloadRejectsOldMapResult`、`testFailedMapRequestDisablesOldGenerationUntilExplicitRollback`、`testResetClearsTrackingEpoch`、`testTwoSDKInstancesHaveIndependentHandles`。地图 A 已加载而地图 B 请求失败时，测试断言 SDK 无 active map、B 请求之后 localize 计数不增加、A 迟到结果不交付；只有显式 rollback 重新绑定 A 的新 generation 才恢复。保持现有 `AreaTargetOfflineLocalizerTests` 的取消装载/失败装载不能继续使用旧图/close 不与 process 重叠等回归。

  ```swift
  func testCloseWaitsForInFlightCallAndSuppressesResult() async throws {
      let native = RecordingNativeRuntime(apiVersion: supportedAPIVersion)
      native.blockLocalization = true
      let collector = ResultCollector()
      let sdk = AreaTargetSDKRuntime(native: native, resultConsumer: collector.record)
      try await sdk.load(bundleDirectory: fixtureBundleDirectory)
      sdk.submit(fixtureFrame, tracking: nil)
      await native.waitUntilLocalizationEntered()
      let closing = Task { await sdk.close() }
      XCTAssertFalse(native.destroyed)
      native.releaseLocalization()
      await closing.value
      XCTAssertTrue(native.destroyed)
      XCTAssertEqual(collector.snapshot().count, 0)
      XCTAssertFalse(native.destroyOverlappedLocalization)
  }
  ```

  测试里 semaphore 等待使用有界超时；`ResultCollector` 在 test target 内用锁保护 `record(_:)` 和 `snapshot()`，通过 SDK 的 result consumer 收集结果，生产 SDK 不公开结果可变数组。Run H01 SDK tests 两次：第一次 red 证实错误排序能被发现，第二次 green 记录线程日志；时间到期必须 FAIL，不能沉默返回。

- [ ] **H01.4 接入 ARKit 同帧 adapter 与宿主坐标测试。** `AreaTargetSDKARKitAdapter` 一次从同一个 `ARFrame` 取 capturedImage、相机内参、timestamp 和 camera.transform；逐行拷贝 Y plane，并把 bytesPerRow/内参分辨率校验写入测试。TrackingSample 可选，含 matching frame ID 与 clock/epoch；ARSession interruption/relocalization/reset 产生显式 epoch/lifecycle 事件。光学与 AR camera 的变换记为 `F = diag(1,-1,-1,1)`：Swift scene 若使用原 ARKit world，则 `T_ARCamera_S = F × T_C_S`，`T_W_C = T_W_ARCamera × F`，二者组合仍为 `T_W_S`。不得继续把光学 `T_C_S` 当旧 vl 的 AR camera pose。

  ```swift
  func testOpticalCameraPoseIsConvertedExactlyOnceForARKit() {
      let flip = simd_float4x4(diagonal: SIMD4<Float>(1, -1, -1, 1))
      let optical = syntheticOpticalCameraFromScan
      let arCamera = flip * optical
      let worldFromOptical = syntheticWorldFromARCamera * flip
      assertMatrixEqual(worldFromOptical * optical,
                        syntheticWorldFromARCamera * arCamera,
                        accuracy: 0.00001)
  }
  ```

  `syntheticOpticalCameraFromScan`、`syntheticWorldFromARCamera` 必须含非对称旋转和平移，来自 C01 坐标 golden fixture；`assertMatrixEqual` 由 H01 的 `LocalizationSDKFixtureHelpers.swift` 定义并按 16 元素比较，单独测试 forward/up 点方向。padded Y plane、90°旋转/对应内参与无 tracking Raw 帧使用 C03 图像，epoch 改变使用 C05 session sequence；不将无图像坐标 fixture 冒充定位样本。

- [ ] **H01.5 替换 iOS facade，保留 Raw 评分语义。** `AreaTargetOfflineLocalizer` 委托 Swift SDK v2 raw 路径，将新光学 pose 显式转换为其现有调用者需要的 AR camera pose；过渡 facade 的 optional-return 行为不强迫新 SDK 丢失错误。`AreaTargetLocalizationSession` 可展示 session fusion 输出，但双引擎比较与 replay 默认仍调用 rawLocalize，并使用输入同帧 transform 做公平评估。无 tracking 时 Raw 结果可记录为 recognition，不能默认为 common alignment valid。保留 source fingerprint、asset digest、build provenance 和停止后清空可视对象规则。

  Run:

  ```bash
  xcodebuild test -project ios_scanner/AreaTargetScanner.xcodeproj -scheme AreaTargetScanner -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:AreaTargetScannerTests/AreaTargetOfflineLocalizerTests -only-testing:AreaTargetScannerTests/AreaTargetLocalizationSessionTests -only-testing:AreaTargetScannerTests/LocalizationComparisonSessionTests -only-testing:AreaTargetScannerTests/CoordinateContractTests -resultBundlePath /private/tmp/atc-h01-scanner.xcresult
  ```

  Expected: Raw 比较仍不向 core 传 AR 先验；同帧 raw pose/显示 pose/评分判断使用一致 decision，已有取消/代际和真实 synthetic fixture 回归通过。Simulator 通过仅证明绑定和 fixture，不代表 iPhone 真机性能或绝对精度。

- [ ] **H01.6 提交宿主接入与实际验证记录。** 不提交 cache/binary 或其他任务文件；真实 iOS 现场验收交由设备子计划与 H04 device/release gate 汇总。

## H02：Unity SDK、公共 frame provider 与 lifecycle

**Depends on:** C01–C05；H01 的动态 framework 绑定设计；H04 制品步骤完成后执行 v2 iOS clean-package export/link 验证。P01–P05 的 provider 实现通过本任务公共接口接入。

**Files:**

- Create: `unity_plugin/AreaTargetPlugin/Runtime/Platforms/IFrameProvider.cs`。
- Create: `unity_plugin/AreaTargetPlugin/Runtime/Platforms/FrameProviderCapabilities.cs`。
- Create: `unity_plugin/AreaTargetPlugin/Runtime/FrameEnvelope.cs`。
- Create: `unity_plugin/AreaTargetPlugin/Runtime/NativeRuntimeV2Bridge.cs`。
- Create: `unity_plugin/AreaTargetPlugin/Runtime/SharedLocalizationSession.cs`。
- Create: `unity_plugin/AreaTargetPlugin/Runtime/RuntimeCoordinateAdapter.cs`。
- Create: `unity_plugin/AreaTargetPlugin/Tests/NativeRuntimeV2BridgeTests.cs`。
- Create: `unity_plugin/AreaTargetPlugin/Tests/SharedLocalizationSessionTests.cs`。
- Create: `unity_plugin/AreaTargetPlugin/Tests/FrameProviderContractTests.cs`。
- Modify: `unity_plugin/AreaTargetPlugin/Runtime/LocalizationFrame.cs`、`LocalizationFrameResult.cs`、`AsyncLocalizationRunner.cs`、`AreaTargetTracker.cs`、`VisualLocalizationEngine.cs`。
- Modify: `unity_plugin/AreaTargetPlugin/Runtime/Platforms/ARFoundationPlatformSupport.cs`，将既有行为包装到 provider 过渡实现；实采验证以 P01–P05 为准。
- Modify: `unity_plugin/AreaTargetPlugin/Editor/iOSPostProcess.cs` 与 iOS build 配置测试，为 v2 dynamic profile 增加互斥制品检查。
- Modify: `unity_plugin/AreaTargetPlugin/Tests/AsyncLocalizationRunnerTests.cs`、`AreaTargetTrackerLifecycleTests.cs`、`CoordinateTransformTests.cs`、`iOSBuildConfigTests.cs`；保留 `NativeLocalizerBridgeTests.cs` 作为旧 ABI 回归。
- H04 owns package artifact population and reproducible UPM validation; keep `Runtime/NativeLocalizerBridge.cs` legacy ABI declarations frozen.

- [ ] **H02.1 定义公共 provider 接口并写 red 测试。** `IFrameProvider` 只采集和报告能力，不持有定位 core/session。`FrameEnvelope` 是拥有 image 的不可变 `LocalizationFrame` 加可选 `TrackingSample`/clock/epoch；Raw frame 不强制含 `UnityWorldFromCamera`。若为现有 public struct 增加重载，保留旧 constructor 并让旧字段只由 compatibility adapter 使用。能力对象必须区分 `RawImage`、`CalibratedIntrinsics`、`FrameTimestamp`、`SynchronizedTracking`、`CameraExtrinsics`，不能用一个 `Supported` boolean 代表全部。

  ```csharp
  public interface IFrameProvider
  {
      FrameProviderCapabilities Capabilities { get; }
      System.Threading.Tasks.Task ConfigureAsync(
          System.Threading.CancellationToken cancellationToken);
      bool TryAcquireLatest(out FrameEnvelope frame);
      System.Threading.Tasks.Task StopAsync();
  }
  ```

  `TryAcquireLatest` 成功后 envelope 的图像在 provider 释放 CPU image 后仍有效。接口采用 pull model；tracking-origin 改变通过 envelope 的 epoch 和明确 lifecycle event 从平台 adapter 传入，不从应用相机位置猜测。`FrameProviderContractTests` 中 `FakeFrameProvider` 自己重用源 byte[]，SDK submission 必须拥有拷贝。

  ```csharp
  [Test]
  public void RawFrameDoesNotRequireTrackingPose()
  {
      FrameEnvelope frame = Fixtures.RawEnvelope(frameId: 7, generation: 3);
      Assert.That(frame.Tracking, Is.Null);
      Assert.That(frame.Frame.FrameId, Is.EqualTo(7));
      Assert.That(frame.Frame.MapGeneration, Is.EqualTo(3));
  }

  [Test]
  public void ProviderImageRemainsOwnedAfterSourceBufferReuse()
  {
      var provider = new FakeFrameProvider(new byte[] { 1, 2, 3, 4 });
      Assert.That(provider.TryAcquireLatest(out FrameEnvelope frame), Is.True);
      provider.OverwriteSource(9);
      Assert.That(frame.Frame.GrayscaleImage, Is.EqualTo(new byte[] { 1, 2, 3, 4 }));
  }
  ```

  `Fixtures.RawEnvelope`/canonical tracking helper 在 H02 创建的 `RuntimeV2TestFixtures.cs` 中定义：坐标来自 C01，图像/地图来自 C03，session 帧序列来自 C05，并明确 frame identity。`FakeFrameProvider` 在 `FrameProviderTestDoubles.cs` 中定义；先实现 helper/interface declarations，再运行 red；缺少代码编译错误必须记录，不能只写“待实现”。

  Run（`ATC_UNITY_EXECUTABLE` 设置为当前已安装、适用于仓库项目的 Unity executable）：

  ```bash
  "$ATC_UNITY_EXECUTABLE" -batchmode -nographics -projectPath unity_project -runTests -testPlatform EditMode -testFilter 'AreaTargetPlugin.Tests.FrameProviderContractTests' -testResults /private/tmp/atc-h02-provider-red.xml -logFile /private/tmp/atc-h02-provider-red.log
  ```

  Expected RED: 缺失契约或 image ownership 错误导致失败。runner 检查 XML 实际测试数>0；Unity license/包导入失败是 BLOCKED，退出码 0 或空 XML 都不是 green。

- [ ] **H02.2 实现 v2 bridge，禁止定位式 symbol 探测。** 从 C02 layout 描述确定 C# sequential structs 的 size/offset，固定宽度整数和显式 pointer/length。入口设置明确 calling convention；iOS IL2CPP 的 `__Internal` direct symbols 由 linked dynamic `AreaTargetNative.framework` 提供，不能由旧静态库补齐；Editor/Android 加载 H04 manifest 指定的同名 runtime 动态库。不要修改旧 bridge 的参数/结构或为 v2 回退到旧 ABI。

  建立 `INativeRuntimeV2` 测试 seam，方法为 `GetApiVersion`、`Create`、`LoadMap`、`Localize`、`SessionCreate`、`SessionUpdate`、`Reset`、`SessionReset`、`Destroy`、`SessionDestroy`，参数分别使用 C01 对应 host DTO。bridge 用 `try/finally` unpin buffer，结果立即复制；invalid status/validity 不产生 pose。调用 API/layout version 时 spy 必须记录 `Localize` 次数为 0。

  ```csharp
  [Test]
  public void InitializeDoesNotRunLocalizationToProbeAPI()
  {
      var native = new RecordingNativeRuntimeV2();
      using (var sdk = SharedLocalizationSession.ForTests(native))
          sdk.ValidateApi();
      Assert.That(native.LocalizeCalls, Is.EqualTo(0));
      Assert.That(native.SessionUpdateCalls, Is.EqualTo(0));
  }

  [Test]
  public void InvalidResultIsNotRenderedAsIdentity()
  {
      var result = Fixtures.NoMatchResult();
      Assert.That(result.CameraFromScan, Is.Null);
      Assert.That(result.WorldFromScan, Is.Null);
      Assert.That(result.RawSuccess, Is.False);
  }
  ```

  `SharedLocalizationSession.ForTests` 和 `ValidateApi` 是 internal，通过已有 AssemblyInfo 的 test friend 使用；不对应用公开 mock API。重跑 bridge tests 为 green，然后跑现有 legacy `NativeLocalizerBridgeTests`；两条 ABI 路径分别报告。

- [ ] **H02.3 接入同步共享 session，保留一个宿主 worker。** `SharedLocalizationSession` 顺序调用 `atc_localize` 和可选 `atc_session_update`；保留/改造 `AsyncLocalizationRunner` 的一个 worker/latest-slot，而不是再加 C++ worker。`AreaTargetTracker` 委托共享 state/mode/fusion 输出，停止在 C# 维护第二套 alignment/Kalman 权威。既有滤波类保留给 legacy profile；v2 默认不再重复应用它们。

  C# worker 串行拥有 create/load/localize/session/reset/destroy。应用主线程只读取 immutable 最新 result 并更新场景；`ResultProduced` 的诊断 subscriber 不得调用 Unity scene API。map generation、tracking epoch、frame order 与过期判断使用 C01 时钟映射，不能将 provider hardware timestamp 直接与 Stopwatch origin 相减。地图/reset/stop 拒绝迟到输出并返回明确 failure/rejection。

  ```csharp
  [Test]
  public async System.Threading.Tasks.Task ResetInvalidatesInFlightGeneration()
  {
      var native = new BlockingNativeRuntimeV2();
      var sdk = SharedLocalizationSession.ForTests(native);
      await sdk.LoadAsync(Fixtures.BundleDirectory);
      sdk.Submit(Fixtures.RawEnvelope(frameId: 10, generation: sdk.MapGeneration));
      await native.WaitUntilEnteredAsync();
      var resetting = sdk.ResetAsync();
      native.Release();
      await resetting;
      Assert.That(sdk.TryGetLatest(out _), Is.False);
      Assert.That(native.ResetOverlappedLocalize, Is.False);
      await sdk.DisposeAsync();
  }
  ```

  `BlockingNativeRuntimeV2` 在 H02 的 `NativeRuntimeV2TestDoubles.cs` 中使用 bounded waits；定义 `LoadAsync`、`Submit`、`TryGetLatest`、`ResetAsync`、`DisposeAsync` 为 SDK facade 的实际方法。增加 newest pending、重复 dispose、map reload、tracking epoch reset、无tracking raw成功、多实例handle独立测试；地图 B 加载失败时，active binding 清空，旧 A generation 的输入/迟到输出都拒绝，直到显式回滚以新的 generation 重绑 A。运行 red/green 并保持原 runner/tracker lifecycle regressions；不写用 sleep 碰运气的并发断言。

- [ ] **H02.4 明确 Unity 坐标边界与 provider 失败分级。** `RuntimeCoordinateAdapter` 实现 C01 canonical→Unity 和 Unity tracking→canonical 的矩阵转换，左右两端空间都命名；取 C01 的非对称 rotation/translation/forward fixture 验证。C03 验证真实 Raw pose，C05 验证共享 session 序列，两者由 H02 fixture helper 独立装载。不得直接沿用“ARFoundation 已经是 Unity 左手所以无需转换”的旧注释，也不得把新的光学 pose 输入旧 vl row-major helper 后直接渲染。Raw success、shared world alignment、propagated VIO result 三类 validity 明确区分；没有 VIO 时可以输出 raw recognition，不能标为已对齐。

  Run:

  ```bash
  "$ATC_UNITY_EXECUTABLE" -batchmode -nographics -projectPath unity_project -runTests -testPlatform EditMode -testFilter 'AreaTargetPlugin.Tests.SharedLocalizationSessionTests;AreaTargetPlugin.Tests.CoordinateTransformTests;AreaTargetPlugin.Tests.AsyncLocalizationRunnerTests;AreaTargetPlugin.Tests.AreaTargetTrackerLifecycleTests' -testResults /private/tmp/atc-h02-session.xml -logFile /private/tmp/atc-h02-session.log
  ```

  Expected: 所有选择的测试均实际被收集且通过；provider 不能提供 synchronized tracking 时只阻止 fusion，不阻止具备图像/内参的 Raw。旧 ARFoundation 的 latest timestamp + 最新 image + 之后 pose 不能作为同帧证明；P01 必须给实采证据。

- [ ] **H02.5 增加互斥 iOS profile 与 dynamic framework export/link 测试。** `iOSPostProcess` 明确 v1 legacy static profile 和 v2 private dynamic profile。v2 引用包内 `AreaTargetNative.xcframework` 的匹配 slice，link UnityFramework、在 app target Embed & Sign；framework resources/notice保留。v2 导出不得同时含 `libvisual_localizer.a` 或全局 `opencv2.framework`。旧文件可以留存，构建选取互斥，发现混装就 fail，不靠链接器碰巧挑中一个实现。

  旧 `vl_*` 和新 `atc_*` 可同时存在于同一个私有 AreaTargetNative framework；同一进程不得再加载另一份提供相同 `vl_*` symbols 的 legacy 静态/动态实现。回滚必须重新选择构建 preset 并核验制品，不能在运行中通过双加载切换。

  增加 `iOSBuildConfigTests` fixture：v2 export包含 AreaTargetNative link/embed；不包含 legacy静态/全局OpenCV；重复 postprocess不重复条目；仅使用 UPM-owned artifacts；缺slice/mixed profile必失败。H04 clean UPM install/export/link验证完成前，该步骤只能报告配置单元测试通过，不能宣称 iOS 链接或真机完成。

- [ ] **H02.6 提交 Unity 接入与回归记录。** 保留 public tracker facade 和旧 ABI 回滚开关；未来 P01–P05 只需实现 `IFrameProvider`/坐标与权限adapter，不复制定位、session或fusion实现。

## H03：Android JNI/AAR 与 native SDK 基础

**Depends on:** H03.1 工程 setup 和 H03.2 的 mock lifecycle 可先进行；真实 JNI 接入使用 C01–C05 产物与 H04.4 的第一阶段 runtime 构建。H04.4 最后的 AAR/Unity 包装验收等待 H03.3–H03.4，双方不以整个任务完成作为互相前置条件。H03 支持 replay/synthetic buffer 和 lifecycle，Android ARCore 相机实采、时钟、外参以及权限产品流属于 P01。

**Files:**

- Create: `android_sdk/settings.gradle.kts`、`android_sdk/build.gradle.kts`。
- Create: `android_sdk/gradlew`、`android_sdk/gradlew.bat`、`android_sdk/gradle/wrapper/gradle-wrapper.properties`、`android_sdk/gradle/wrapper/gradle-wrapper.jar`。
- Create: `android_sdk/area-target-sdk/build.gradle.kts`、`android_sdk/area-target-sdk/consumer-rules.pro`。
- Create: `android_sdk/area-target-sdk/src/main/AndroidManifest.xml`。
- Create: `android_sdk/area-target-sdk/src/main/cpp/CMakeLists.txt`、`area_target_jni.cpp`。
- Create: `android_sdk/area-target-sdk/src/main/java/com/areatarget/sdk/RuntimeTypes.kt`、`NativeRuntimeV2.kt`、`AreaTargetSession.kt`、`SerialLocalizationWorker.kt`。
- Create: `android_sdk/area-target-sdk/src/test/java/com/areatarget/sdk/AreaTargetSessionTest.kt`。
- Create: `android_sdk/area-target-sdk/src/androidTest/java/com/areatarget/sdk/NativeRuntimeV2InstrumentedTest.kt`。
- Create: `android_sdk/area-target-sdk/src/androidTest/assets/canonical-runtime-fixture/`，staging C03 生成的 synthetic map/图像/已知 pose，同时分别包含 C01 坐标 JSON 与 C05 session sequence JSON，保留各来源和摘要。
- Modify: `native_visual_localizer/CMakeLists.txt`，仅补 v2 Android host artifact target/install；算法/session变更归核心子计划。
- H04 owns Android dependency/NDK provenance, native artifact population and final AAR/Unity same-runtime hash validation.

- [ ] **H03.1 建立 Android library 工程和精确工具链记录。** 使用当前团队已安装且能构建目标设备的 JDK/Gradle/AGP/NDK 组合生成 wrapper并锁定，不因文档主动升级版本。wrapper、AGP与NDK版本写入构建配置并加入 H04 manifest；没有已有组合可核验时先记录 BLOCKED和缺失项，不临时选择浮动“latest”。core `minSdk` 依据 core/JNI 实际使用的 Android API 和测试基线确定，不能从已有 iOS部署目标推导；可选 vendor 模块单独声明其更高的能力/版本要求。AAR main 不申请相机权限，Gradle dependencies 不含 ARCore/Rokid/PICO/Quest SDK；P01 及对应独立平台模块负责授权、vendor 依赖和采集。

  Run:

  ```bash
  android_sdk/gradlew -p android_sdk :area-target-sdk:tasks --all
  ```

  Expected: 能列出 `testDebugUnitTest`、`assembleRelease`、`connectedDebugAndroidTest`。此命令只验证工程入口，不代表 JNI或设备验收。记录 `java -version`、`android_sdk/gradlew -p android_sdk --version` 和所选NDK版本；后续 green不得依赖机器隐含目录中的另一版本。

- [ ] **H03.2 定义 Kotlin SDK seam并写 red lifecycle测试。** Host DTO定义与H01/H02相同字段与validity：`RuntimeFrame` 使用拥有的 gray8 byte array或私有direct buffer，`TrackingSample?`单独进入session。`NativeRuntimeCalling`接口只含create/load/rawLocalize/sessionUpdate/reset/close。`AreaTargetSession`公共入口为 `load(bundleDirectory)`、`submit(frame,tracking)`、`pollLatest()`、`reset()`、`closeAndAwait()`；每实例单串行executor/latest-slot。测试注入 `RecordingNativeRuntime`/`BlockingNativeRuntime`，不装载so。

  ```kotlin
  @Test fun rawSubmissionDoesNotNeedTracking() {
      val native = RecordingNativeRuntime()
      val session = AreaTargetSession(native)
      session.load(Fixtures.bundleDirectory)
      session.submit(Fixtures.rawFrame(frameId = 8), tracking = null)
      session.awaitIdleForTest()
      assertEquals(listOf(8L), native.localizedFrameIds)
      assertTrue(native.trackingInputs.all { it == null })
      assertNotNull(session.pollLatest()?.rawResult?.cameraFromScan)
      session.closeAndAwait()
  }

  @Test fun closeNeverDestroysAHandleDuringLocalization() {
      val native = BlockingNativeRuntime()
      val session = AreaTargetSession(native)
      session.load(Fixtures.bundleDirectory)
      session.submit(Fixtures.rawFrame(frameId = 9), tracking = null)
      native.awaitEntered()
      val closing = session.closeAsyncForTest()
      assertFalse(native.destroyed)
      native.release()
      closing.get(5, java.util.concurrent.TimeUnit.SECONDS)
      assertTrue(native.destroyed)
      assertFalse(native.destroyOverlappedLocalize)
      assertNull(session.pollLatest())
  }
  ```

  H03 在 `src/test/java/com/areatarget/sdk/RuntimeFixtureHelpers.kt` 与 `NativeRuntimeTestDoubles.kt` 中定义 JVM `Fixtures` 和两种 native double；`awaitIdleForTest`/`closeAsyncForTest` 为 `AreaTargetSession.kt` 的 test-visible 内部 seam，不进入公共SDK。测试消费有界futures，失败必须抛出。补齐frame源覆写、latest pending替换、map generation/epoch reset、重复close/提交关闭后拒绝、load失败清active binding测试：新的地图请求失败后不可默默继续旧generation；显式回滚要重绑身份、新generation与session reset。

  Run:

  ```bash
  android_sdk/gradlew -p android_sdk :area-target-sdk:testDebugUnitTest --tests 'com.areatarget.sdk.AreaTargetSessionTest'
  ```

  Expected RED: 未实现SDK或错误生命周期导致指定断言失败；编译红与行为红分别记录。随后实现 Kotlin serial host层并重跑 green，报告 Gradle XML测试数，不能以任务up-to-date代替本次证据。

- [ ] **H03.3 实现JNI checked boundary和真实so联通。** JNI仅转换参数、拥有权、Cstatus和结果；所有create/load/localize/reset/destroy通过同一宿主executor，C++core/session不新增内部worker。Java long保存opaque holder ID，不把可伪造整数直接当可解引用pointer；native holder保存两个ATC handles并在close后失效。DirectByteBuffer检查directness/capacity，byte array路径用受控owned副本；在提交边界拷贝而不是把JNI临时地址留给async任务。尺寸/stride/长度checked arithmetic、UTF-8本地路径、finite内参、矩阵长度及validity逐项检查。没有tracking时给session_update传NULL，不创建identity tracking sample。

  JNI转发 `atc_*`，不重新实现SQLite reader、ORB、session融合或状态机。拒绝unsupported API/layout时不能运行localize试探。C exception统一转换status，JNI pending exception检查后立即返回；不要跨线程保存局部JNI references。保留完整failure category，consumer ProGuard规则只固定所需JNI类/入口。

  Instrumented tests用 C03 synthetic map/图像与已知光学 `T_C_S` 验证真实 Raw，C01 提供坐标 golden 数据，C05 提供 session sequence；分别验证no-match无pose、frame身份回填、trackingNULL Raw成功，以及unsupported/invalidbuffer不导致崩溃。H03 在 `src/androidTest/java/com/areatarget/sdk/RuntimeFixtureHelpers.kt` 定义 asset 拷贝、`Fixtures` 和 `assertMatrixNear`。C++ fake seam 测试由 H03 创建 `src/test/cpp/area_target_jni_boundary_test.cpp`/`jni_boundary_test_doubles.h`，验证JNI pointer失效策略与边界，不使用真实进程非法地址进行“容错”测试。

  ```kotlin
  @Test fun realNativePreservesCanonicalOpticalPose() {
      val native = NativeRuntimeV2()
      native.create()
      native.loadMap(Fixtures.copyBundleFromAssets(context))
      val frame = Fixtures.frameFromAssets(context)
      val raw = native.rawLocalize(frame)
      assertEquals(frame.frameId, raw.frameId)
      assertEquals(frame.mapGeneration, raw.mapGeneration)
      assertMatrixNear(Fixtures.expectedOpticalCameraFromScan(context),
                       requireNotNull(raw.cameraFromScan), Fixtures.poseTolerance)
      native.close()
  }
  ```

  `Fixtures.poseTolerance` 来自 C03 synthetic Raw fixture 的已有数值容差与算法确定性约束；C01/C05 的矩阵与序列容差分别读取其合同，不混用，不自填“厘米级精度”。Run：

  ```bash
  android_sdk/gradlew -p android_sdk :area-target-sdk:assembleRelease
  android_sdk/gradlew -p android_sdk :area-target-sdk:connectedDebugAndroidTest
  ```

  Expected: AAR包含实际构建的arm64-v8a `libarea_target_runtime.so`和薄JNIshim；设备测试实际运行。无设备时第二项是BLOCKED；emulator synthetic fixture只证明ABI绑定，不能宣称ARCore实采完成。

- [ ] **H03.4 确保Android原生SDK与Unity复用同一runtime。** JNIshim独立为`libarea_target_jni.so`并link runtime so；不把第二份core静态编进JNIshim。默认发arm64-v8a；需要x86_64模拟器时作为独立明确slice构建，不能把缺slice写成设备不支持。Unity Android direct P/Invoke加载同一`libarea_target_runtime.so`，AAR和UPM各自manifest记录相同核心源版本/ABI/header digest/运行库digest。C++ runtime和OpenCV依赖必须归一，JNI外不导出其C++symbols；同一app不能自动加入不匹配的`libc++_shared.so`或另一份runtime。

  真实instrumented test新增API probe不调用定位、重复载入/释放、hostpause/reset事件。ARCore图像采集与世界坐标转换尚未实现时报告“Android SDK replay/ABI完成，P01实采待验收”。

- [ ] **H03.5 提交Android SDK、JUnit/XML与native fixture记录。** 不上传AAR、不发布Maven，也不修改服务端或Immersal Android接口。H04负责最终可复现产物与release证据。

  用 Gradle dependency report 验证 `area-target-sdk` 可独立 assemble/test，未安装任何 vendor SDK 时仍成立；独立平台模块由 P01–P05 各自注册/构建，不在本任务强制 include 所有可选模块。后续验证矩阵仅添加已选择的平台模块，不能把 vendor 依赖渗回 core AAR。

## H04：可复现制品、统一验证入口与CI矩阵

**Depends on:** H04.1 driver/mock 和 schema 可先进行；H04.3 及 H04.4 的 runtime producer 阶段依赖 C01–C05 对应核心产物和锁定工具链，最终 SDK 包装/fixture 验收才依赖 H01–H03 完成。H04.1–H04.5 属于宿主阶段；P01 提供 device_probe 入口，P02–P05 提供对应平台 probe/验收证据后收敛 H04.6；H04.7/release 在 M5。H04 与宿主工程 setup 可并行分步推进，P01 不依赖整个 H04 完成，不能把最终验收依赖误写为“构建 runtime 必须先等 H03 全部完成”。

**Files:**

- Create: `tools/cross_platform/verify.py`。
- Create: `tests/cross_platform/test_verify_driver.py`。
- Create: `docs/contracts/area-target-artifact-manifest.schema.json`。
- Create: `docs/contracts/area-target-sdk-distribution.md`。
- Modify: `tools/ios/build_area_target_native.py`、`tools/ios/verify_area_target_native.py` 及现有对应 `.test.py`。
- Modify: `ios_sdk/AreaTargetSDK/Package.swift`、`android_sdk` 构建/锁文件、UPM artifact配置、`native_visual_localizer/CMakeLists.txt` install规则。
- Modify: `.github/workflows/ci.yml`，增加独立v2 gates，保留已有服务端/Python与legacy回归。
- Create only if required by the existing UPM install test harness: fixture/package staging configurations under `tests/cross_platform/fixtures/`；禁止另起未定义validation脚本。
- P01 owns: `tools/cross_platform/device_probe.py` and its probe/evidence tests；H04只调用和验证返回证据。

- [ ] **H04.1 先写driver/schema的red测试。** driver CLI固定支持`--mode ci|local|device|release`与可重复`--platform ios|android|rokid|pico|quest`；增加明确定义的`--artifact-root PATH`、`--evidence-dir PATH`、`--report PATH`选项，默认路径为repo内`build/cross_platform`、`build/cross_platform/evidence`、`build/cross_platform/verification.json`。不从已归档chat或个人绝对路径取工具。`ci`执行当前host可运行自动化并显式报告缺runtime/license/device gates；`local`构建并核验所选宿主；`device`要求P01probe和实际设备证据；`release`只核验现有制品和验收记录，不联网构建、不上传、不触发云发布。

  Python内部定义`GateResult(name,status,required_for_release,reason,artifacts)`；status枚举为`PASS`、`FAIL`、`SKIP`、`BLOCKED`。`summarize(gates, mode)`返回`release_ready`及overall status；release模式任何required gate缺失/skip/blocked/fail都不得exit0。driver runner注入用于单元测试，真实subprocess使用argv数组、checked退出码、bounded timeout，不shell拼接。

  ```python
  import pytest
  from tools.cross_platform.verify import GateResult, parse_args, summarize

  def test_platform_flag_can_be_repeated():
      args = parse_args(["--mode", "ci", "--platform", "ios",
                         "--platform", "android"])
      assert args.platform == ["ios", "android"]

  @pytest.mark.parametrize("status", ["FAIL", "SKIP", "BLOCKED"])
  def test_release_cannot_pass_without_required_gate(status):
      report = summarize([
          GateResult(name="native-fixture", status="PASS",
                     required_for_release=True, reason="", artifacts=[]),
          GateResult(name="ios-device", status=status,
                     required_for_release=True, reason="missing evidence", artifacts=[]),
      ], mode="release")
      assert report["release_ready"] is False
      assert report["exit_code"] != 0

  def test_ci_skip_is_visible_and_never_claims_release_ready():
      report = summarize([
          GateResult(name="unity-license", status="SKIP",
                     required_for_release=True, reason="runner unavailable", artifacts=[]),
      ], mode="ci")
      assert report["release_ready"] is False
      assert report["overall"] == "COMPLETED_WITH_SKIPS"
  ```

  同文件新增tests验证：空Unity/XCTest/JUnit report拒绝PASS；required evidence缺失；artifact hash/header/layout不匹配；manifest路径越界；超时；release runner从不调用上传/curl/Maven publish；device_probe缺失不得自动fake PASS；已有失败日志内容仅当数据读取。

  Run:

  ```bash
  python3 -m pytest tests/cross_platform/test_verify_driver.py -q
  ```

  Expected RED: driver不存在时报import error；加入declarations后，错误summary/emptyreport策略必须被断言抓出。实现driver/schema后重跑Expected GREEN，测试无需Xcode、Unity、Android或外网。

- [ ] **H04.2 实现制品manifest/schema和证据关联。** manifest至少记录schema version、实际package version、core git commit/source-tree digest、ABI API/layout version、canonical contract digest、public header digest、每slice target/architecture/minimumOS、toolchain exact versions、dependency名称版本来源digest/licenses、build flags、artifact relative path/size/SHA256和测试报告digest。dirty工作树用source-tree digest记录，不伪称git commit可复现。验收记录包含artifact digest、设备型号/OS/adapter版本、map/query/groundtruth provenance、mode raw/fused、能力探测、执行时间与运行者、成功/失败/跳过、报告路径及digest。

  依赖锁显式包含 OpenCV、SQLite 和 C++ runtime：记录版本、编译选项、系统链接或 bundled 模式、官方来源/下载内容 digest、许可/notice 文本来源及摘要。SQLite 不能因为通过 `-lsqlite3` 或平台 SDK 链接就从 manifest 消失；system SQLite 记录目标 SDK/OS 提供者及实际运行版本，bundled SQLite 锁源码与构建输入。未核对来源或许可文本时 gate 失败，不用其他依赖的 notice 代替。

  schema不硬编码一个尚未发布的SDKpackage version；版本字段必须存在且与包metadata一致。稳定性、jitter、syntheticpose误差与真实绝对精度证据分开；没有externalreference则absoluteaccuracy为`not_measured`，不能从aligned或confidence生成。

  artifact path和evidence path以root为边界，拒绝absolute path、`..`越界、symlink逃逸；只打开bounded regular files。release查验selectedplatform所有required evidence，记录的是另一core digest、另一adapter/OS能力或未明确mode时不能通过。无需设备的driver tests不得调用网络。

- [ ] **H04.3 统一iOS私有动态framework与XCFramework包装。** 扩展现有builder的source/header/export inputs添加C02产物，cache key纳入新source/header/contract/toolchain/dependency摘要，包含 SQLite 的所选链接模式和来源。旧`visual_localizer.h`字节冻结；`AreaTargetNative.h`变为umbrella时分别校验其包含的legacyheader与newheader，更新现有“umbrella必须与旧header完全字节相同”的检查。runtime symbols 允许列表仅为既有冻结 `vl_*` 与明确新 `atc_*`；隐藏 OpenCV、SQLite 和其他实现细节 symbols，所有非公共 C ABI 导出及 C++ symbols 均由 symbols gate 拒绝。

  复用`tools/ios/build_area_target_native.py`已实现的private动态framework、two-level namespace、pinnedOpenCVprovenance、license resources和Immersalcomposite-link检查；不得重新引入Unity的staticcore/globalOpenCVprofile。

  Run（builder更新完成后；这些是existingtool而非尚未创建的新脚本）：

  ```bash
  python3 tools/ios/build_area_target_native.py --platform iphoneos --cache-dir /private/tmp/atc-sdk-cache --output-dir /private/tmp/atc-sdk-slices/iphoneos
  python3 tools/ios/build_area_target_native.py --platform iphonesimulator --cache-dir /private/tmp/atc-sdk-cache --output-dir /private/tmp/atc-sdk-slices/iphonesimulator
  xcodebuild -create-xcframework -framework /private/tmp/atc-sdk-slices/iphoneos/AreaTargetNative.framework -framework /private/tmp/atc-sdk-slices/iphonesimulator/AreaTargetNative.framework -output /private/tmp/atc-sdk-output/AreaTargetNative.xcframework
  ```

  Expected: device/simulator各自产物的Mach-O platform、architecture、header和symbols正确；两slice source/API/layout一致；distribution仅承诺实际构建的slice。output已存在时使用新验证目录，不删除用户其他产物。

  Swift package localbinarytarget指向staged XCFramework，源码repo不携带隐含downloadURL；UnityUPM同样只从已安装package取artifact。原生SwiftSDK与UnityiOS以同一frameworkslice digest比对。实际Immersalcomposite-link、Unitycleanexport/Xcodelink通过后才记录privateOpenCVisolationPASS；只检查文件名或README不构成链接证明。

- [ ] **H04.4 Android/Editor制品和可复现构建检查。** CMake/NDK产物为`libarea_target_runtime.so`，JNIshim为`libarea_target_jni.so`；AAR与UnityAndroidpackage复用完全相同runtime。Editor产生对应host的`libarea_target_runtime.dylib`/`.so`或`.dll`，只声明已测试OS/architecture；未构建Windows时不得写全平台完成。记录runtime动态依赖、SQLite所选来源/链接模式、C++runtime以及privateOpenCVsymbol边界；runtime只导出公共C ABI，JNIshim仅导出明确注册所需的C入口，不泄露OpenCV/SQLite或C++实现symbols。版本冲突直接失败，不能靠copy覆盖宿主依赖。

  分三段执行：先根据 C02/C04 的 CMake target 与锁定 NDK/SQLite 配置构建独立 runtime，不依赖 H03 的 AAR 工程完成；H03.1–H03.2 同时建立 Gradle/JVM mock 基础。然后 H03.3 使用该 runtime 构建 JNIshim 和真实 fixture 测试。最后 H04.4 等 H03.3–H03.4 的 AAR/Unity 包装与报告，核验同一 runtime digest 和全部依赖/许可摘要。这三个产出分别记录，第一段产物可供 H03 使用而不伪称最终 SDK gate green。

  driver `local`读取明确工具链配置后执行 H01–H03 命令，分别运行 C01 坐标校验、C03 真实 Raw synthetic fixture 和 C05 session sequence，打包到 artifactroot 并生成 manifest。producer和consumerpackage的header与ABI/layout必须一致。相同source/toolchain/lock/config在两个独立buildroot构建，比较header、exportset、依赖摘要与内容hash；若编译器时间/签名/zipentry导致bit-for-bit不同，记录归一化规则和差异，不声称字节可复现。签名证书不进入manifest，signing状态只记录有无/identity摘要。

  Run（H04driver创建后）：

  ```bash
  python3 tools/cross_platform/verify.py --mode local --platform ios --platform android --artifact-root build/cross_platform --report build/cross_platform/local-verification.json
  ```

  Expected: 当前机器具备requiredhost工具时全部自动化gatePASS，产物manifest与reports已保存；缺Unitylicense、AndroidSDK/NDK或Simulator时以BLOCKED列明，不能把部分成功改成全局PASS。

- [ ] **H04.5 添加CI矩阵并保留人工/设备门槛。** Linuxjob运行driver/schemaunit tests、核心C/CPP ABI与fixture及Androidcompile/JUnit；macOSjob运行native/editor、iOSdevice+simulatorframework、Swiftbinding/syntheticfixture、privateframework/composite-link。UnityEditMode/cleanUPM/export使用具备license和固定Editor的runner；没有该runner时CI报告SKIP并保留release-required项，不悄悄降低门禁。connecteddevice和厂商设备测试属于device验收，不在普通CI假造。

  在`.github/workflows/ci.yml`独立添加v2matrix，不删除legacygate、服务端或Immersaltests；旧staticprofile只在其独立legacyjob运行，不部署进v2package。cachekey含ABI/header/source/dep/toolchainhash；report随CIartifacts保存。CIjob成功只意味着其selectedautomatedgates执行结果，不生成“跨设备release-ready”结论。

  Run:

  ```bash
  python3 tools/cross_platform/verify.py --mode ci --platform ios --platform android --report build/cross_platform/ci-verification.json
  ```

  Expected: 每gate有明确PASS/FAIL/SKIP/BLOCKED及reason和实际tests/artifacts；required自动化失败退出非零。host不适用gate允许显式SKIP，但overall为`COMPLETED_WITH_SKIPS`且`release_ready=false`。

- [ ] **H04.6 接入device_probe并收敛设备证据。** 等 P01 创建 device_probe 后，driver device 调用它并保存 capability+run 证据；对应 P02–P05 补 adapter 能力和场景。本项在对应设备任务之后按已接入范围收敛，不作为启动 P01 的前置要求。缺少合格图像、内参或可核验采集时间时拒绝 Raw；缺相机外参、可用 tracking 或 tracking 同帧/时钟关系时，仅令 Aligned/fused capability 无效，合格图像/K/time 仍可运行 Raw。相机授权失败导致无图像应记录 Raw 缺失能力；没有真机是设备 gate BLOCKED，不能由普通 ABI 测试补齐。

  每设备 Raw 与 Aligned/fused 分开运行和记录；只有 Raw 能力时，保留 Raw 的真实结果及 Aligned 缺失项，不将整台设备标为不可用，也不宣称 Aligned 完成。若所声明 release 范围要求 Aligned，则仅 Raw 证据不能通过该项 gate；按总 spec 和 P01–P05 的能力分级核验，device 报告不能跨 artifact digest 重用。

  Run（device 命令在对应 P01–P05 设备任务完成且设备已连接时；release 命令在 M5、制品与声明范围的验收证据齐备时）：

  ```bash
  python3 tools/cross_platform/verify.py --mode device --platform ios --platform android --artifact-root build/cross_platform --evidence-dir build/cross_platform/evidence --report build/cross_platform/device-verification.json
  python3 tools/cross_platform/verify.py --mode release --platform ios --platform android --artifact-root build/cross_platform --evidence-dir build/cross_platform/evidence --report build/cross_platform/release-verification.json
  ```

  Rokid/PICO/Quest依平台计划进入release矩阵；用多次`--platform`选择已授权本轮接入范围，不将未选择设备宣传为支持。release只读制品、schema、report与验收记录，输出release_ready与缺失项；不调用gitpush、CI发布、Mavenpublish、AppStore或任何上传命令。Expected:所有selectedplatformrequired证据完整且digest吻合才exit0，否则failclosed。设备验收门槛遵循主spec，不把稳定叠加当绝对精度达成。

- [ ] **H04.7 在 M5 保存最终分发说明并收束 release gate。** `area-target-sdk-distribution.md`写清Swiftlocalpackage+XCFramework、UnityUPM及互斥nativeprofile、AndroidAAR+runtime、当前可用slice、依赖/notice位置、source/binaryprovenance、升级与rollback步骤，并明确各设备 Raw/Aligned 能力与验证状态。H04.1–H04.5 的 driver/schema/CI/tests 可在宿主阶段提交，本项等待 M5 的设备范围证据齐备；保留原package版本策略。实施者只对实际通过的matrix和实机证据作完成声明，不将未验收binary偷偷替换已发布制品。

## 收尾检查与交接

- [ ] 检查H01–H03所有publicraw入口没有tracking参数进入`atc_localize`；VIO只进共享session。
- [ ] 检查所有宿主只有一个串行worker/latest-slot；C++core/session仍同步，无第二个权威fusion状态机。
- [ ] 检查新光学C与旧vlARcamera在Swift/Unity边界显式区分，所有宿主通过同一非对称canonicalfixture。
- [ ] 检查legacyABI和Immersal/服务端API不变，iOSv2不混装staticglobalOpenCV。
- [ ] 检查地图/重置/epoch/停止/销毁按generation和barrier拒绝迟到结果，失败pose无效。
- [ ] 检查失败地图请求关闭旧 active generation；candidate loader 保留的旧图仅供显式回滚，不能自动续用。
- [ ] 检查 C01 坐标、C03 synthetic Raw 与 C05 session sequence 来源各自明确，所有宿主 helper 在本任务表中的文件创建；关闭完成等待在测试代码中只出现一次。
- [ ] 检查制品与依赖锁包含 SQLite 来源/许可/链接模式，runtime 和 JNIshim 的非公共 C 导出/实现 symbols 均隐藏。
- [ ] 检查 Android core AAR 无 vendor SDK；可选平台 Gradle 模块只依赖 core，不由 core 反向依赖厂商包。
- [ ] 检查driver是H04实际新增文件，device_probe是P01实际新增文件；未来命令不被当成本次已执行记录。
- [ ] 检查报告有实际tests>0/exitcode/digest，SKIP和BLOCKED不会被转换为releasePASS。
- [ ] 将完成任务与证据链接回总计划及`tasks.md`，进入设备子计划的下一平台gate；不在没有真机证据时宣称绝对精度或全平台支持。
