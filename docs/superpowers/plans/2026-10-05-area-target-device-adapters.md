# Area Target Device Adapters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在共享 Area Target Session 与冻结的 SDK 合同上，交付经能力探测确认的 ARCore、Rokid、PICO、Quest 设备适配器，并以分级现场证据决定支持声明。

**Architecture:** 核心 C01–C05 拥有坐标与校准合同、Session、定位和对齐；宿主 H01–H04 拥有 Swift/Kotlin/C#/C ABI 包装、制品和验证编排。设备包取得物理相机图像、内参、曝光时间和可选 VIO，按 C01 合同使用已核验的 SDK 校准实现完成图像标准化，再将帧提交给 Session；厂商的显示相机、预测头部位姿与设备品牌名称均不能替代该合同。

**Tech Stack:** C++17 与 `atc_*` C ABI、Android NDK/Gradle/Kotlin/JNI/AAR、Unity 独立平台 UPM 包、ARCore、经设备审计确认的厂商 SDK、Python/pytest、结构化设备与验收报告。

---

## 状态、依赖与既有证据

权威入口：[总计划](2026-10-05-area-target-cross-platform.md)、[核心合同](2026-10-05-area-target-runtime-core.md)、[宿主与制品](2026-10-05-area-target-sdk-bindings.md)。

本文件只制定计划；以下任务、代码片段和验证命令全部尚未执行。片段是实施时应创建的测试与辅助代码，不能作为运行证据。本文不实现适配器，不下载 SDK，不构建或发布制品。

- P01–P04 的帧提交、标定与对齐集成依赖 C01–C05、H01–H04 冻结并通过各自门禁；能力审计与公开资料/已获授权 SDK 的盘点可先进行。
- `tools/cross_platform/verify.py` 与 `tests/cross_platform/test_verify_driver.py` **当前不存在，须由 H04 创建**，模式为 `ci/local/device/release`。P01 和 P05 在 H04.1–H04.4 的 driver/schema 与基础制品门禁可用后扩展设备与验收入口；H04.6 随设备任务收敛，H04.7/release 在 M5 完成，不要求整个 H04 先完成。
- `tools/cross_platform/device_probe.py` 与 `tests/cross_platform/test_device_probe.py` **当前不存在，须由 P01 创建**。
- C01 创建 `docs/contracts/` 与 `tests/fixtures/cross_platform/` 的共享坐标 fixture；本计划不复制 ABI 签名、不另建核心 Session，也不冻结第二份公共帧接口。
- Android 原生构建、NDK/ABI、AAR/JNI 基础包装由 H03 提供；设备代码位于独立 `android_sdk/area-target-platform-arcore|rokid|pico|quest/` Gradle 模块；这些模块依赖 `area-target-sdk`，核心 AAR 不依赖厂商 SDK。
- Unity 共同入口使用 H02 创建的 `unity_plugin/AreaTargetPlugin/Runtime/Platforms/IFrameProvider.cs`。各设备包依赖宿主包，宿主包不强制安装所有厂商 SDK。

已读到的仓库基线：

| 现有路径 | 已有能力或限制 |
| --- | --- |
| `native_visual_localizer/CMakeLists.txt` | 已有 C++ 核心和 Android CMake 分支，但没有可发布的 Android 构建/设备适配工程 |
| `native_visual_localizer/build_ios.sh` | 现有 Unity iOS ARM64 静态库流程，单独链接 OpenCV，不能证明与其他 SDK 的符号隔离 |
| `tools/ios/build_area_target_native.py` | Swift 路线已有真实私有动态 framework、固定 OpenCV 4.10.0 来源与 SHA、C 导出白名单及 two-level namespace |
| `tools/ios/verify_area_target_native.py` | 已有真实 native fixture smoke、平台 slice 与 Immersal 同镜像链接验证 |
| `tools/phase0/build_upm_package.py` | 目前只装入 iOS/macOS native 制品与 iOS OpenCV，无 Android 制品 |
| `unity_plugin/AreaTargetPlugin/Runtime/Platforms/ARFoundationPlatformSupport.cs` | 当前读取最新 CPU 图像时读取当前 Unity transform，且可合成递增时间；其 OpenXR/Rokid/PICO/Quest 兼容注释不构成物理相机能力证据 |
| `tools/phase1/validate_ios_upm_build.sh` | 已有干净 UPM 安装、ARKit loader 配置、Unity iOS 导出与 generic-device Xcode 链接门禁 |
| `tools/phase1/verify.sh`、`.github/workflows/ci.yml` | 已有显式 PASS/FAIL/SKIP；CI 的 Unity、签名和设备项不冒充通过 |
| `docs/superpowers/specs/phase-1-ios-workflow/tasks.md` | 任务 9 的真机定位后续步骤及任务 10 的完整验收仍未完成 |
| `docs/phase-1-device-acceptance-template.md` | 原 Phase 1 为三个 20–100 m² 场地 × iPhone/iPad，共六份独立 30 分钟记录 |

旧商业设计 `docs/superpowers/specs/2026-07-12-internal-commercial-readiness-design.md` 曾将通用 Android 手机排除在首版范围外。本次已批准的跨平台方向应在总计划明确覆盖该旧范围约束；P01 只承诺经能力和现场门禁通过的具体参考设备，不作全 Android 支持声明。

## 所有设备共同遵守的帧与能力合同

1. `C` 为物理相机光学右手坐标（x 右、y 下、z 前）；`S` 保留扫描右手米制坐标；`W` 为规范右手追踪坐标。`T_A_B` 一律是 B→A。Unity 的左手世界转换由 H02 的唯一边界处理，设备包不得再反转一次。
2. 输出图像为 **Rectified Gray8**，数据深拷贝且无行填充，内参与实际输出分辨率对应。YUV 的 rowStride/pixelStride、裁剪、旋转、镜像、畸变及有效 ROI 都由 adapter 按 C01 校准合同使用已核验的 SDK 校准实现明确处理；禁止仅改内参而不改图像。厂家已整流图像必须带来源、模式及证据，不能由“看起来正常”推断。平台任务负责创建和测试标准化函数，本计划不依赖尚未定义的原生校准 API。
3. 图像、内参、曝光 timestamp 与可选 pose 必须对应同一次物理相机采集。记录 clock domain、单位、曝光时间语义、时间映射和同步误差；禁止用 `DateTime.Now`、最新渲染 transform 或人为 `last + 1` 代替采集时间。SDK 是否提供曝光中点/起点/其他语义需要审计，无法验证时不得宣称曝光同步。
4. 头部 VIO 只能在已测得 `T_H_C` 与采集时刻 `T_W_H(t_capture)` 后转换成 `T_W_C = T_W_H(t_capture) × T_H_C`。外参必须来自实际使用的物理摄像头，带 camera ID、标定版本/哈希和误差证据；不能使用中心眼、显示相机、identity 外参或另一摄像头的标定。直接提供物理 camera pose 的 provider 也须验证 pose reference 与光学坐标转换。
5. 对 pose 进行 clock 映射和插值；同步误差超出 C/H 冻结的 `maxPoseSkewNs` 时拒绝该帧的 VIO，不能外推预测显示位姿。Session 负责 W 对齐。VIO 缺失时走 Raw：只输出 `T_C_S`，不接收 VIO/外部位姿先验，不输出有效 `T_W_S`。
6. raw 相机不可访问、缺内参、无法整流、时间语义不可信或权限未获批时，能力结果为 unsupported；物理相机帧合格但 VIO/外参不合格时只开放 Raw。设备探测不能请求未记录的厂家权限或假定品牌所有型号开放相同相机 API。
7. 使用新的 `atc_*` ABI。旧 `vl_*` 保持冻结，不通过修改结构大小或改变旧符号语义扩展设备合同。所有平台使用 C/H 固定的错误类别、生命周期和线程所有权。

能力报告只保存型号/系统/SDK/runtime 的必要描述、匿名设备 alias、权限状态、camera 配置、标定哈希及布尔/枚举能力，不保存 UDID、序列号、图像、位置或绝对用户路径。建议报告 schema 如下，P01 创建并由 P02–P04 扩展厂家证据内容：

```json
{
  "schemaVersion": 1,
  "platform": "arcore",
  "deviceAlias": "ANDROID-REF-A",
  "deviceModel": "reported-by-device",
  "osVersion": "reported-by-device",
  "sdkVersion": "locked-by-build",
  "nativeAbi": "arm64-v8a",
  "permission": "granted",
  "cpuImage": true,
  "intrinsics": true,
  "rectifiedGray8": true,
  "captureTimestampVerified": true,
  "frameAgreementVerified": true,
  "vio": "absent",
  "poseReference": "none",
  "physicalCameraExtrinsicsVerified": false,
  "exposurePoseSyncVerified": false,
  "calibrationHash": "fixture-calibration-hash",
  "evidenceKind": "synthetic"
}
```

这里是 synthetic 合同样本，`reported-by-device` 等文本不得出现在现场通过报告中；现场值必须由实际探测填写。nativeAbi 仅列 H03 当前构建过的 ABI。`evidenceKind` 为 synthetic 的报告永远不能通过设备/商业验收。

## P01：Android ARCore 帧采集、设备探测与 Unity 平台包

**依赖：** C01–C05、H02–H04；保留 H01 的 iOS 回归。

**文件：**

- Create: `android_sdk/area-target-platform-arcore/src/main/java/com/areatarget/sdk/arcore/ArCoreFrameProvider.kt`
- Create: `android_sdk/area-target-platform-arcore/src/main/java/com/areatarget/sdk/arcore/AndroidLumaPlane.kt`
- Create: `android_sdk/area-target-platform-arcore/src/main/java/com/areatarget/sdk/arcore/ArCoreCapabilityProbe.kt`
- Create: `android_sdk/area-target-platform-arcore/src/test/java/com/areatarget/sdk/arcore/AndroidLumaPlaneTest.kt`
- Create: `android_sdk/area-target-platform-arcore/src/androidTest/java/com/areatarget/sdk/arcore/ArCoreFrameProviderDeviceTest.kt`
- Create: `android_sdk/area-target-platform-arcore/build.gradle.kts`，仅引入ARCore与核心SDK；Modify: `android_sdk/settings.gradle.kts` 注册可选设备模块。
- Create: `android_sdk/samples/arcore-app/`（独立 Gradle sample；application ID 为 `com.areatarget.sample.arcore`）
- Create: `unity_plugin/AreaTargetPlatformARCore/package.json`、`Runtime/AreaTargetPlatformARCore.asmdef`、`Runtime/ArCoreFrameProvider.cs`、`Editor/ArCoreBootstrap.cs`、`Tests/ArCoreFrameProviderTests.cs`、`Samples~/ArCoreLocalization/`
- Create: `tools/cross_platform/device_probe.py`、`tools/cross_platform/device_capabilities.schema.json`
- Create: `tests/cross_platform/test_device_probe.py`、`tests/fixtures/cross_platform/devices/arcore-capabilities.synthetic.json`
- Modify after H04: `tools/cross_platform/verify.py`、`tests/cross_platform/test_verify_driver.py`
- Create: `docs/platforms/android-arcore.md`

- [ ] **Step 1：冻结 Android 依赖与参考设备候选记录。** 读取 H03 的 NDK、AGP、Gradle、JDK、minSdk/targetSdk、C++ runtime 和 ABI 锁定清单；锁定 ARCore SDK 与 Unity ARCore XR provider 版本。记录设备报告的型号、OS、ARCore runtime、相机 ID、CPU image 模式、Camera2 feature level/可用配置和权限。先验证 ARCore 运行资格与相机特性，再确认 AR session 可启动；不得用 Android 版本或 Camera2 feature level 单独推导支持。参考设备候选记录尚未通过时，只允许写“待验设备”，禁止更新支持表。

- [ ] **Step 2：先创建 rowStride/pixelStride 的失败单元测试。** 在 `AndroidLumaPlaneTest.kt` 写入下列测试，执行后须因缺少 `copyPackedGray8` 失败：

```kotlin
package com.areatarget.sdk.arcore

import org.junit.Assert.assertArrayEquals
import org.junit.Test

class AndroidLumaPlaneTest {
    @Test fun rowPaddingIsExcludedAndPixelsAreOwned() {
        val source = byteArrayOf(1, 2, 99, 99, 3, 4, 99, 99)
        val packed = copyPackedGray8(2, 2, 4, 1, source)
        source[0] = 88
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), packed)
    }

    @Test fun pixelStrideIsApplied() {
        val source = byteArrayOf(1, 99, 2, 99, 3, 99, 4, 99)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4),
            copyPackedGray8(2, 2, 4, 2, source))
    }
}
```

Run: `android_sdk/gradlew -p android_sdk :area-target-platform-arcore:testDebugUnitTest --tests com.areatarget.sdk.arcore.AndroidLumaPlaneTest`

- [ ] **Step 3：创建最小 luma 拷贝实现并转绿。** `AndroidLumaPlane.kt` 使用下面的函数；这是去 stride 的输入步骤，整流必须随后按 C01 校准合同使用已核验的 SDK 校准实现处理，不能把此函数称作完成整流。

```kotlin
package com.areatarget.sdk.arcore

internal fun copyPackedGray8(width: Int, height: Int, rowStride: Int,
                            pixelStride: Int, source: ByteArray): ByteArray {
    require(width > 0 && height > 0 && pixelStride > 0 && rowStride > 0)
    val rowLast = (width - 1L) * pixelStride
    require(rowLast < rowStride)
    val last = (height - 1L) * rowStride + rowLast
    require(last < source.size && width.toLong() * height <= Int.MAX_VALUE)
    return ByteArray(width * height) { index ->
        source[(index / width) * rowStride + (index % width) * pixelStride]
    }
}
```

重跑 Step 2 命令，期望两项测试 PASS；追加无效 buffer 尺寸、负 stride、overflow 的拒绝用例再重跑。

- [ ] **Step 4：先创建能力选择的失败测试。** 在 `test_device_probe.py` 定义以下纯合同测试。`base_report()` 是此测试文件内的 fixture，不依赖真机：

```python
from tools.cross_platform.device_probe import select_modes


def base_report():
    return {
        "nativeAbi": "arm64-v8a", "permission": "granted",
        "cpuImage": True, "intrinsics": True, "rectifiedGray8": True,
        "captureTimestampVerified": True, "frameAgreementVerified": True,
        "vio": "absent", "poseReference": "none",
        "physicalCameraExtrinsicsVerified": False,
        "exposurePoseSyncVerified": False,
    }


def test_no_vio_remains_raw_without_prior():
    assert select_modes(base_report(), {"arm64-v8a"}) == ["raw"]


def test_head_pose_without_camera_extrinsics_is_raw_only():
    report = base_report()
    report.update(vio="present", poseReference="head",
                  exposurePoseSyncVerified=True)
    assert select_modes(report, {"arm64-v8a"}) == ["raw"]


def test_permission_denied_is_unsupported():
    report = base_report()
    report["permission"] = "denied"
    assert select_modes(report, {"arm64-v8a"}) == []


def test_clock_or_camera_mismatch_cannot_use_vio():
    report = base_report()
    report.update(vio="present", poseReference="head",
                  physicalCameraExtrinsicsVerified=True,
                  exposurePoseSyncVerified=False)
    assert select_modes(report, {"arm64-v8a"}) == ["raw"]
    report["frameAgreementVerified"] = False
    assert select_modes(report, {"arm64-v8a"}) == []


def test_verified_optical_pose_can_align():
    report = base_report()
    report.update(vio="present", poseReference="opticalCamera",
                  physicalCameraExtrinsicsVerified=True,
                  exposurePoseSyncVerified=True)
    assert select_modes(report, {"arm64-v8a"}) == ["raw", "aligned"]
```

Run: `python3 -m pytest tests/cross_platform/test_device_probe.py -q`

Expected RED: `device_probe.py` 不存在或尚无 `select_modes`。

- [ ] **Step 5：创建 probe 合同和选择逻辑，转绿并覆盖错误报告。** `device_probe.py` 的纯选择函数使用下列最小实现。CLI 首先以 schema 校验完整报告，然后调用此函数；不完整布尔值、未知权限/pose 枚举、重复 camera 配置、无效时间单位须给出稳定错误而非猜测。

```python
def select_modes(report, built_abis):
    raw_keys = ("cpuImage", "intrinsics", "rectifiedGray8",
                "captureTimestampVerified", "frameAgreementVerified")
    if report.get("nativeAbi") not in built_abis:
        return []
    if report.get("permission") != "granted":
        return []
    if not all(report.get(key) is True for key in raw_keys):
        return []
    modes = ["raw"]
    if (report.get("vio") == "present"
            and report.get("poseReference") in {"head", "opticalCamera"}
            and report.get("physicalCameraExtrinsicsVerified") is True
            and report.get("exposurePoseSyncVerified") is True):
        modes.append("aligned")
    return modes
```

实现 CLI `--input <capability JSON> --built-abi arm64-v8a --output <report JSON>`，输出含 `modes`、失败 capability 原因及原始证据摘要。可选 `--platform arcore --device <adb serial> --app-id com.areatarget.sample.arcore` 只读取 sample 写出的 `files/area-target-capabilities.json`；串号仅用于当前进程连接，不进入输出。执行 Step 4 转绿；新增未知 ABI、texture-only、未整流、未验证 timestamp、非 boolean 的拒绝用例。

- [ ] **Step 6：创建真实 ARCore provider 与 instrumentation RED。** 使用锁定版本已验证的官方 ARCore/AR Foundation API，针对同一个 ARCore frame 获取 CPU image、image intrinsics、曝光 timestamp 与 camera pose。不得把 texture intrinsics 应用于 CPU image，也不得从两个 `session.update` 取图像和 pose。设备测试先要求：相机权限 granted→帧可读、denied→稳定错误；真实 luma 尺寸/stride正确；重复 frame 不生成新的伪 timestamp；crop/rotation 后 K 与图像一致；无 VIO→Raw；暂停/恢复及关闭时 image/native handle 被释放。测试失败须记录实际能力错误；厂商 API 或数据缺失时报告 unsupported，不加 mock 通过分支。

- [ ] **Step 7：接入冻结的宿主合同并转绿。** Kotlin provider 输出 C/H 规定的不可变帧并提交共享 Session；权限变化、ARCore unavailable、tracking loss、camera config change、地图切换、后台/恢复必须使用公共状态/错误。Unity `ArCoreFrameProvider` 实现 H02 的 `IFrameProvider`，只选已配置的 ARCore provider；`ArCoreBootstrap` 固定 Android loader、权限和依赖，独立平台包不引入 Rokid/PICO/Quest 依赖。C/H fixture 必须由 provider 走实际标准化路径，比较 Rectified Gray8、K、`T_W_C` 与 native/Unity边界输出；运行上述 instrumentation 转绿。

- [ ] **Step 8：验证 Android 制品、Unity 干净安装与 device runner。** 通过 H03 的 JNI/AAR smoke，并核验 `libarea_target_runtime.so` 的 `atc_*` 导出、旧 `vl_*` 冻结、私有 OpenCV 符号不可见、NDK ABI、JNI线程/lifecycle和 C++ runtime 单份打包。Unity平台包在空项目安装后以 IL2CPP/ARM64构建；避免平台 AAR与宿主各打入一份同名 `.so`。P01扩展H04 runner 的 device入口读取probe报告；设备缺失、未授权、未支持、相机不可访问的结果不能标为PASS。

Run:

```bash
android_sdk/gradlew -p android_sdk :area-target-platform-arcore:testDebugUnitTest :area-target-platform-arcore:assembleDebug
android_sdk/gradlew -p android_sdk :area-target-platform-arcore:connectedDebugAndroidTest
python3 -m pytest tests/cross_platform/test_device_probe.py tests/cross_platform/test_verify_driver.py -q
python3 tools/cross_platform/device_probe.py --input tests/fixtures/cross_platform/devices/arcore-capabilities.synthetic.json --built-abi arm64-v8a --output /private/tmp/arcore-capabilities.synthetic-report.json
python3 tools/cross_platform/verify.py --mode device --platform android --evidence-dir /private/tmp/area-target-arcore-device --report /private/tmp/area-target-arcore-device/verification.json
```

第一组命令由 H03/P01 创建对应工程后才可运行；synthetic probe 只证明合同。设备模式须使用实际参考设备与现场地图；运行成功仍只解除设备能力gate，商业支持要等P05。

- [ ] **Step 9：记录并提交P01证据。** `docs/platforms/android-arcore.md` 写明已测型号/OS/runtime/SDK/ABI/相机模式、Raw/Aligned分别开放情况、权限流程、安装命令、错误和恢复行为；保存图像外的hash及PASS/FAIL/SKIP。提交仅包含P01范围，旧iOS门禁由H04并行回归；未通过的矩阵行保持未支持。

## P02：Rokid物理相机与头部VIO适配

**依赖：** C01–C05、H02–H04、P01的probe合同；ARCore provider本身不是Rokid依赖。

**文件：**

- Create: `android_sdk/area-target-platform-rokid/src/main/java/com/areatarget/sdk/rokid/RokidFrameProvider.kt`、`RokidCapabilityProbe.kt`
- Create: `unity_plugin/AreaTargetPlatformRokid/package.json`、`Runtime/AreaTargetPlatformRokid.asmdef`、`Runtime/RokidFrameProvider.cs`、`Editor/RokidBootstrap.cs`、`Tests/RokidFrameProviderTests.cs`、`Samples~/RokidLocalization/`
- Create after camera gate passes: `android_sdk/area-target-platform-rokid/build.gradle.kts`，厂商依赖只进入该模块；按显式平台选择注册到settings，不要求构建其他厂商模块。
- Create: `tools/cross_platform/probes/rokid.py`、`tests/cross_platform/test_rokid_adapter_contract.py`
- Create: `tests/fixtures/cross_platform/devices/rokid-capabilities.synthetic.json`、`rokid-geometry.synthetic.json`
- Create: `docs/platforms/rokid.md`、`docs/platforms/rokid-sdk-evidence.json`
- Modify: `tools/cross_platform/device_capabilities.schema.json`、H04 runner的Rokid配置、平台包构建/样例清单

- [ ] **Step 1：先做SDK/设备审计gate。** 从实际连接设备和已获授权SDK记录型号、系统/firmware、UXR/OpenXR/runtime版本、camera API访问资格、相机权限与适用模式。OpenXR的头追踪存在不意味着raw camera可读。核对是否有CPU像素、对应K、镜头畸变模型、capture timestamp、clock mapping、head pose history及物理camera-head外参；证据保存官方文档链接、SDK版本/文件hash、设备报告及获取方式。不得发明UXR API名；只在锁定的SDK文档与真机样例证明接口可调用后实现调用层。

- [ ] **Step 2：创建能力和几何RED。** `test_rokid_adapter_contract.py` 的能力测试复用P01 `select_modes`，并加入：texture-only→unsupported；head pose存在但`T_H_C`未知→Raw；timestamp仅为render time→unsupported；预测pose或不同clock未对齐→Raw。另写以下测试，fixture是运行设备适配器几何测试输出的契约形状：

```python
import json
from pathlib import Path
import numpy as np


def test_camera_lever_arm_is_not_replaced_by_head_pose():
    path = Path("tests/fixtures/cross_platform/devices/rokid-geometry.synthetic.json")
    frame = json.loads(path.read_text())
    world_from_camera = np.asarray(frame["T_W_C"], dtype=float).reshape(4, 4)
    assert frame["poseReference"] == "opticalCamera"
    assert frame["captureTimestampNs"] == frame["poseTimestampNs"]
    # Given identity rotations, T_W_H.translation=(1,2,3),
    # T_H_C.translation=(0.07,0,0); C01 fixture fixes these input values.
    np.testing.assert_allclose(world_from_camera[:3, 3], [1.07, 2.0, 3.0], atol=1e-6)
```

Run: `python3 -m pytest tests/cross_platform/test_rokid_adapter_contract.py -q`

RED必须来自缺少probe/适配器几何输出或错误的head/camera/clock转换；不要手工填期望输出使测试假绿。

- [ ] **Step 3：实施Rokid采集和标准化函数。** 使用Step1确认的SDK接口，固定所选camera配置，深拷贝像素；去stride后按C01合同使用已核验的SDK校准实现形成Rectified Gray8/K。将raw相机clock映射到pose history，使用真实`T_H_C`和曝光时刻插值计算`T_W_C`；只有完整能力均可信时打开Aligned，Raw不传pose先验。覆盖多摄像头误选、不同resolution的标定、左右手/轴约定、timestamp回绕/重复、相机暂停和SDK错误；原始厂商pose不会直接移动Unity内容根。

- [ ] **Step 4：独立Unity包与Android模块转绿。** 厂商引用放设备包专用asmdef/Gradle依赖中；Rokid平台包通过`IFrameProvider`注册，宿主不需安装UXR才能编译iOS/ARCore。用shared Session完成地图W对齐；供应商显示/渲染原点变化通过公共epoch/reset策略处理。测试应实际运行本平台的几何标准化函数输出Step2 fixture，并运行capture/pose错位拒绝和pause/reset/dispose的设备测试。

- [ ] **Step 5：构建、能力检查与同地图真机验证。** H03/H04检查ARM64/NDK/c++ runtime和native符号隔离，避免Rokid SDK自带OpenCV/JNI库冲突。使用已验证iOS地图，不重新定义地图坐标。真实设备完成权限→图像→native初始化→至少一次Raw/Aligned对应定位结果→受控失锁恢复；P05再做三场地30分钟和商业性能。

Run after corresponding tasks create the files:

```bash
python3 -m pytest tests/cross_platform/test_device_probe.py tests/cross_platform/test_rokid_adapter_contract.py -q
android_sdk/gradlew -p android_sdk :area-target-platform-rokid:testDebugUnitTest :area-target-platform-rokid:assembleDebug
python3 tools/cross_platform/verify.py --mode device --platform rokid --evidence-dir /private/tmp/area-target-rokid-device --report /private/tmp/area-target-rokid-device/verification.json
```

- [ ] **Step 6：提交确实通过的支持矩阵。** 文档列出具体型号/系统/UXR版本/相机配置和每种Session mode；能力缺口列FAIL或unsupported。如SDK访问资格缺失，保留证据与阻断原因，并继续独立平台工作，不承诺Rokid全系列。

## P03：PICO能力审计与条件适配

**依赖：** C01–C05、H02–H04、P01的probe合同；不以P02通过作为技术前提。

**文件：**

- Create: `docs/platforms/pico.md`、`docs/platforms/pico-sdk-evidence.json`
- Create after camera gate passes: `android_sdk/area-target-platform-pico/build.gradle.kts`，厂商依赖只进入该模块；按显式平台选择注册到settings，不要求构建其他厂商模块。
- Create: `tools/cross_platform/probes/pico.py`、`tests/cross_platform/test_pico_adapter_contract.py`
- Create: `tests/fixtures/cross_platform/devices/pico-capabilities.synthetic.json`
- Create only after camera gate passes: `android_sdk/area-target-platform-pico/src/main/java/com/areatarget/sdk/pico/PicoFrameProvider.kt`、`PicoCapabilityProbe.kt`
- Create only after camera gate passes: `unity_plugin/AreaTargetPlatformPico/package.json`、`Runtime/AreaTargetPlatformPico.asmdef`、`Runtime/PicoFrameProvider.cs`、`Editor/PicoBootstrap.cs`、`Tests/PicoFrameProviderTests.cs`、`Samples~/PicoLocalization/`
- Modify after capability proof: H04 runner平台清单、厂商隔离依赖清单

- [ ] **Step 1：审计具体候选型号与实际runtime。** 明确设备是否开放应用可访问的物理相机原始帧，权限是否需要企业资格/额外授权，API是否只提供passthrough显示纹理。记录可用CPU格式、相机ID、K/畸变/整流、时间语义、camera-to-head外参、pose history和坐标约定的实际证据。采集不可访问时本任务交付unsupported能力报告和文档；不创建虚假的成功FrameProvider，也不将另一型号的开放能力转移到本型号。

- [ ] **Step 2：创建probe RED。** 下列片段写入`test_pico_adapter_contract.py`；完整report fixture沿用P01形状并由PICO probe填实测信息：

```python
from tools.cross_platform.device_probe import select_modes
from tools.cross_platform.probes.pico import normalize_probe


def test_passthrough_texture_does_not_prove_cpu_camera_access():
    report = {
        "nativeAbi": "arm64-v8a", "permission": "granted",
        "cpuImage": False, "intrinsics": True, "rectifiedGray8": True,
        "captureTimestampVerified": True, "frameAgreementVerified": True,
        "vio": "present", "poseReference": "head",
        "physicalCameraExtrinsicsVerified": True,
        "exposurePoseSyncVerified": True,
    }
    assert select_modes(normalize_probe(report), {"arm64-v8a"}) == []
```

另外增加通过`pico.py`解析真实/合成厂家报告的测试：未知权限→unsupported；缺K→unsupported；有camera无外参→Raw；型号/runtime变化后旧能力结果不可复用。运行`python3 -m pytest tests/cross_platform/test_pico_adapter_contract.py -q`，RED须包含尚不存在的PICO probe解析层，而非只通过共享函数测试。

- [ ] **Step 3：能力报告先转绿。** `pico.py`提供`normalize_probe(report)`，输入是`PicoCapabilityProbe`导出的公共JSON报告，校验并转换已记录的SDK返回信息为公共schema，携带capability failure原因与证据hash；不能把未知值填true。unknown/model/runtime/权限不充分的probe按合同输出unsupported，属于“审计完成”，不属于“适配支持完成”。CLI命令使用公共device_probe入口和PICO插件配置，不自写第二套能力判定。

- [ ] **Step 4：只在raw camera gate通过后实现适配。** 创建上列PICO模块与独立Unity包，调用锁定SDK接口，输出标准图像/K/timestamp；设备包按C01合同使用已核验的SDK校准实现处理畸变，shared Session处理W对齐。按P02的lever-arm与clock测试建立PICO专用输出fixture，增加多camera、权限撤销、热暂停和tracking-origin变化测试。厂家API与所需权限必须来自Step1实际证据；不能在本计划中预设接口名。

- [ ] **Step 5：执行设备构建与现场能力验证。** 校验厂商native依赖与H03/H04 C ABI符号隔离、AAR去重、NDK/ABI；空Unity项目仅安装宿主+PICO包并构建IL2CPP/ARM64。实机测试有camera的Raw；有已校准且同步VIO才测Aligned。未满足条件时runner明确unsupported/FAIL，P05不得收录为支持设备。

Run after probe creation and, for the device command, adapter eligibility:

```bash
python3 -m pytest tests/cross_platform/test_pico_adapter_contract.py tests/cross_platform/test_device_probe.py -q
python3 tools/cross_platform/verify.py --mode device --platform pico --evidence-dir /private/tmp/area-target-pico-device --report /private/tmp/area-target-pico-device/verification.json
```

- [ ] **Step 6：提交审计或适配结果。** 文档分开标注`audited-unsupported`、`raw-capable`、`aligned-capable`及P05 qualification/commercial状态，列明精确型号/runtime；所有PICO商业支持必须另有P05完整证据。

## P04：Quest能力审计与条件适配

**依赖：** C01–C05、H02–H04、P01的probe合同；与P03可并行做只读审计。

**文件：**

- Create: `docs/platforms/quest.md`、`docs/platforms/quest-sdk-evidence.json`
- Create after camera gate passes: `android_sdk/area-target-platform-quest/build.gradle.kts`，厂商依赖只进入该模块；按显式平台选择注册到settings，不要求构建其他厂商模块。
- Create: `tools/cross_platform/probes/quest.py`、`tests/cross_platform/test_quest_adapter_contract.py`
- Create: `tests/fixtures/cross_platform/devices/quest-capabilities.synthetic.json`
- Create only after camera gate passes: `android_sdk/area-target-platform-quest/src/main/java/com/areatarget/sdk/quest/QuestFrameProvider.kt`、`QuestCapabilityProbe.kt`
- Create only after camera gate passes: `unity_plugin/AreaTargetPlatformQuest/package.json`、`Runtime/AreaTargetPlatformQuest.asmdef`、`Runtime/QuestFrameProvider.cs`、`Editor/QuestBootstrap.cs`、`Tests/QuestFrameProviderTests.cs`、`Samples~/QuestLocalization/`
- Modify after capability proof: H04 runner平台清单、厂商隔离依赖清单

- [ ] **Step 1：确认型号/OS/runtime/应用资格与相机权限。** 审计实际候选设备的相机API开放范围、required entitlement/系统权限、分发限制及raw CPU数据路径；passthrough可见与OpenXR追踪不能证明应用可取得符合合同的物理相机图像。记录K、分辨率/畸变模型、timestamp/clock、camera/head外参和曝光时刻pose的来源。权限未获批或型号不支持时输出有依据的unsupported，不以其他Quest型号的文档替代。

- [ ] **Step 2：创建Quest probe/同步RED。** `test_quest_adapter_contract.py`加入以下测试，并为尚不存在的`quest.py`实际解析层添加schema/权限/model/runtime测试：

```python
from tools.cross_platform.device_probe import select_modes
from tools.cross_platform.probes.quest import normalize_probe


def test_predicted_display_pose_does_not_unlock_alignment():
    report = {
        "nativeAbi": "arm64-v8a", "permission": "granted",
        "cpuImage": True, "intrinsics": True, "rectifiedGray8": True,
        "captureTimestampVerified": True, "frameAgreementVerified": True,
        "vio": "present", "poseReference": "head",
        "physicalCameraExtrinsicsVerified": True,
        "exposurePoseSyncVerified": False,
    }
    assert select_modes(normalize_probe(report), {"arm64-v8a"}) == ["raw"]
```

Run: `python3 -m pytest tests/cross_platform/test_quest_adapter_contract.py -q`

- [ ] **Step 3：probe报告转绿并决定实施范围。** `quest.py`提供`normalize_probe(report)`，输入是`QuestCapabilityProbe`导出的公共JSON报告，从锁定SDK和实机结果校验并转换公共报告；拒绝缺失camera metadata和时间语义，保留Raw/Aligned区别。基于真实probe结论，若raw gate失败则交付审计结果；若通过，再执行Step4。测试不能用OpenXR/品牌字符串直接开camera capability。

- [ ] **Step 4：实现Quest设备模块与独立Unity平台包。** 遵守共同帧合同，取得物理camera图像/K/timestamp，按C01合同使用已核验的SDK校准实现完成整流；需要VIO时使用物理camera外参和曝光同步pose，不采用render中心眼/预测display pose。用C01跨语言fixture验证坐标和共享Session对齐；添加左/右camera误用、分辨率切换、权限撤销、后台恢复、tracking-origin变化、native依赖冲突测试。SDK实调用只使用Step1确认过的API。

- [ ] **Step 5：构建、真实camera与mode验证。** 空Unity项目仅安装宿主+Quest平台包，IL2CPP/ARM64构建并确认H03/H04 JNI/native依赖无重复导出和runtime冲突。真实设备以same-map测Raw，若同步/外参可信再测Aligned；调用device runner，权限不足或不支持的模型不能生成绿色设备结果。

```bash
python3 -m pytest tests/cross_platform/test_quest_adapter_contract.py tests/cross_platform/test_device_probe.py -q
python3 tools/cross_platform/verify.py --mode device --platform quest --evidence-dir /private/tmp/area-target-quest-device --report /private/tmp/area-target-quest-device/verification.json
```

- [ ] **Step 6：提交准确范围。** `docs/platforms/quest.md`保存精确型号/runtime/SDK、访问资格与模式矩阵，审计通过不自动等同现场qualification或commercial。禁止“Quest全系列支持”等不具证据的声明。

## P05：跨设备现场qualification与最终商业验收

**依赖：** C01–C05、H01–H04；每个平台仅在对应P01–P04能力gate通过后入现场矩阵。原Phase1任务9–10仍要独立完成，不能因为跨平台计划出现就取消。

**文件：**

- Create: `tools/cross_platform/device_acceptance.schema.json`、`tools/cross_platform/validate_device_acceptance.py`
- Create: `tests/cross_platform/test_device_acceptance.py`
- Create: `tests/fixtures/cross_platform/acceptance/functional-valid.synthetic.json`、`commercial-incomplete.synthetic.json`
- Create: `docs/validation/cross-platform-device-matrix.json`、`docs/validation/cross-platform-device-acceptance-template.md`、`docs/validation/cross-platform-commercial-protocol.md`
- Modify: `tools/cross_platform/verify.py`、`tests/cross_platform/test_verify_driver.py`、`README.md`、`unity_plugin/AreaTargetPlugin/README.md`及各平台README
- Update only with real evidence: `docs/phase-1-ios-validation.md`、`docs/superpowers/specs/phase-1-ios-workflow/tasks.md`的原任务9–10

- [ ] **Step 1：冻结分级gate和矩阵。** 登记三个匿名20–100m²场地、每个支持参考设备的alias/型号/OS/runtime/SDK、应用/核心/SDK提交、ABI、地图schema/version/hash、标定hash、Session mode。iOS Swift与Unity iOS分别记录宿主；同设备不同宿主不是同一运行证据。原Phase1固定保留三场地×LiDAR iPhone/iPad六行Unity iOS记录；新跨平台矩阵以已通过能力gate的参考设备逐行展开三个场地，未支持设备明确exclude及原因，不能悄悄漏行。

| Gate | 通过含义 | 不足以证明的事项 |
| --- | --- | --- |
| ABI/build/synthetic | 制品可安装、真实native smoke与合同fixture通过 | 现场定位、曝光同步、设备商业支持 |
| Capability | 具体型号/配置能供给Rectified Gray8与可信metadata；分别开放Raw/Aligned | 三场地定位与长期稳定性 |
| Qualification | 每个必需设备×场地×宿主×mode完成真实同地图加载、定位、受控失锁/恢复与连续≥30分钟；无crash/native lifecycle failure | ≤10cm/≤3°/95%/两小时商业指标 |
| Commercial | 下表所有最终指标在冻结protocol和支持矩阵上有测量证据 | 未测型号、OS/runtime、相机配置或场地类型 |

原Phase1依照原requirements核验定位与失锁/恢复尝试及记录；新qualification另外要求受控失锁后恢复成功。不得把这一新增gate追写为旧Phase1已通过的证据。

- [ ] **Step 2：冻结最终商业protocol。** 承接原批准商业目标，不降阈值，也不在测量后改百分位、分母或accepted环境条件。协议写明ground truth测量/坐标对齐方式、测量误差、环境与图像覆盖条件、采样/拒绝规则、冷启动定义、受控失锁注入、恢复尝试分母、FPS统计窗口、内存趋势判据、热状态/电量与版本。本步骤创建并版本化benchmark协议；队列、同步和结果年龄限制引用C01/C05配置，报告身份与采集方式引用H04，不依赖未定义的C05 benchmark工具。

| 商业指标 | 最终gate |
| --- | --- |
| 平移误差 | accepted环境、protocol定义样本的误差≤0.10m |
| 旋转误差 | 同一组accepted样本误差≤3° |
| 首次定位 | P90≤3秒，失败运行也保留，不能只统计成功的快样本 |
| 重定位 | 成功率≥95%，显式记录成功数/总尝试数和置信区间 |
| 渲染 | 支持参考设备上≥30FPS，按冻结protocol统计 |
| 稳定性 | 每个必需运行≥2小时，无crash或持续内存增长，保留native生命周期与热状态摘要 |

这些为最终商业目标；现有构建成功、synthetic smoke和30分钟qualification都不代表已经达到。

- [ ] **Step 3：先创建验收判定RED。** `test_device_acceptance.py`创建下列测试。P05 validator公共测试接口为`validate_run(run, tier)`，返回稳定错误类别列表；其CLI另校验完整matrix行覆盖与证据版本/哈希。

```python
from tools.cross_platform.validate_device_acceptance import validate_run


def measured_run():
    return {
        "schemaVersion": 1, "evidenceKind": "device",
        "siteId": "SITE-A", "deviceAlias": "REF-A",
        "platform": "arcore", "host": "unity", "mode": "aligned",
        "sourceCommit": "a" * 40, "mapHash": "b" * 64,
        "calibrationHash": "c" * 64, "protocolVersion": "cross-device-v1",
        "capabilityPassed": True, "localized": True,
        "lossInjected": True, "recoveryAttempted": True,
        "recoverySucceeded": True, "durationSeconds": 1800,
        "crashes": 0, "nativeLifecycleFailures": 0,
        "privacyScanPassed": True, "metrics": None,
    }


def test_thirty_minutes_does_not_pass_commercial():
    failures = validate_run(measured_run(), "commercial")
    assert "commercial-duration" in failures
    assert "commercial-metrics-missing" in failures


def test_synthetic_evidence_cannot_qualify_a_device():
    run = measured_run()
    run["evidenceKind"] = "synthetic"
    assert "real-device-evidence-required" in validate_run(run, "qualification")


def test_unattempted_recovery_is_not_qualification():
    run = measured_run()
    run["recoveryAttempted"] = False
    assert "recovery-required" in validate_run(run, "qualification")


def test_native_failure_blocks_qualification():
    run = measured_run()
    run["nativeLifecycleFailures"] = 1
    assert "native-lifecycle-failure" in validate_run(run, "qualification")
```

Run: `python3 -m pytest tests/cross_platform/test_device_acceptance.py -q`

Expected RED: validator还不存在。追加矩阵缺行、设备runtime/hash不符、诊断混入图像/绝对路径、空分母、未定义百分位、指标null、2小时但精度失败的用例。

- [ ] **Step 4：实现schema/validator并转绿。** schema保存开始/结束UTC和duration，validator交叉检查时长、版本/地图/标定hash及matrix必需行；不从手工“passed”字段直接得出最终结果。实现`qualification/commercial`分级，原Phase1验证引用旧规范且保持单独报告。CLI形状固定为`--matrix <json> --report <json> --tier qualification|commercial`；缺证据或必需行失败退出非零，空数据不能通过。重跑Step3全部测试。

- [ ] **Step 5：完成原iOS与跨设备三场地30分钟。** 使用H01/H02新制品收集iPhone/iPad三场地六份记录，核对旧Phase1的适用条件并在旧任务中关联对应版本证据；随后让新平台对同场地使用同一地图hash，设备模式由真实probe开放。每行记录权限、图像标准化、SQLite/map加载、native初始化、首次定位、失锁/恢复、30分钟和诊断hash；不能用generic Xcode、APK安装或模拟器替代。视频/图像/地图与原始日志保留受控本地；Git仅保存匿名摘要/hash。失败行写FAIL或阻断，持续保留原支持范围。

- [ ] **Step 6：测量商业指标与两小时。** 根据Step2冻结protocol进行真实测量，保留每次首次定位和恢复尝试，包括失败/超时；验证准确定义的平移/旋转误差，记录FPS与内存/热状态趋势。Raw模式没有W对齐时，不能借用Aligned的world内容稳定性结果，须报告该模式适用的姿态/定位指标。逐必需行完成两小时后运行commercial validator，不以平均值遮盖失败设备或场地。

- [ ] **Step 7：接入H04的发布gate与显式SKIP。** `verify.py`的ci模式可对签名、Unity license、未配置厂家SDK、设备访问/实地测量输出SKIP及具体原因；没有跑的检查不算PASS。local模式完成适用build/contract/干净安装gate；device模式对所请求设备缺失/权限不足输出FAIL，不能静默跳过。release模式要求所声明平台的所有必需gate无SKIP，并验证qualification或commercial报告对应当次SDK提交/制品hash。PICO/Quest仅审计unsupported时可作为明确未支持范围排除，不可记成supported平台的绿色SKIP。

Run after H04/P05 creation:

```bash
python3 -m pytest tests/cross_platform/test_device_acceptance.py tests/cross_platform/test_verify_driver.py -q
python3 tools/cross_platform/verify.py --mode ci --platform ios --platform android --platform rokid --evidence-dir /private/tmp/area-target-cross-platform-evidence --report /private/tmp/area-target-cross-platform-ci.json
python3 tools/cross_platform/verify.py --mode local --platform ios --platform android --platform rokid --evidence-dir /private/tmp/area-target-cross-platform-evidence --report /private/tmp/area-target-cross-platform-local.json
python3 tools/cross_platform/validate_device_acceptance.py --matrix docs/validation/cross-platform-device-matrix.json --report /private/tmp/area-target-qualification-report.json --tier qualification
python3 tools/cross_platform/validate_device_acceptance.py --matrix docs/validation/cross-platform-device-matrix.json --report /private/tmp/area-target-commercial-report.json --tier commercial
python3 tools/cross_platform/verify.py --mode release --platform ios --platform android --platform rokid --evidence-dir /private/tmp/area-target-cross-platform-evidence --report /private/tmp/area-target-cross-platform-release.json
```

上述验证选择M3的ios/android/rokid；M4设备通过能力门禁且声明支持后追加`--platform pico --platform quest`。probe的`arcore`是Android采集provider ID，verify选择值统一为`android`。现场report文件由Step5/6实际运行生成；这里的命令不创建通过证据。runner/CLI参数须由H04/P01/P05按以上约定实现，再进入正式验证。

- [ ] **Step 8：审查支持声明与可追溯制品。** README/平台包README分别公布具体型号/OS/runtime/SDK/ABI/相机模式及Raw/Aligned、qualification/commercial状态。同一SDK版本发布Swift/iOS、Android AAR/JNI和Unity宿主/平台包的依赖与制品hash清单；vendor包独立版本按H04兼容矩阵绑定。确认第三方许可证、原生符号隔离、干净宿主安装、六份原Phase1记录与全部新增必需矩阵行一致，再提交验收报告。发布动作仍由总计划既定CI流程处理，本子计划不提前标记商业支持。

## 执行收尾检查

- [ ] C/S/W方向、Rectified Gray8、曝光同步、物理camera-head外参只使用C/H冻结合同；没有另造厂商公共ABI或Session。
- [ ] P01–P04每个平台有真实capability报告；审计结果与支持声明区分清楚，没有品牌全系列推断。
- [ ] Raw不接收先验、无有效W对齐输出；Aligned只在同步/外参gate均通过时开放。
- [ ] H03/H04的NDK/ABI、C++ runtime、JNI/AAR与native符号隔离门禁在所有已声明平台上通过。
- [ ] 原Phase1 iPhone/iPad三场地六份30分钟记录仍单独完整，未用新计划或generic build代替。
- [ ] qualification与commercial分级报告使用真实设备/地图/标定/制品hash，最终≤10cm/≤3°/P90≤3秒/≥95%/≥30FPS/两小时目标没有被降低或声称当前达标。
- [ ] CI明确SKIP原因；release对必需缺失证据失败，未测设备不进入支持矩阵。
