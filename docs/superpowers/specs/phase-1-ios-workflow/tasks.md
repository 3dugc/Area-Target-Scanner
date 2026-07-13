# 阶段 1：iOS 完整扫描与定位工作流实施计划

> **面向 AI 执行者：** 必须使用 `superpowers:executing-plans` 按任务顺序执行；每个任务完成后更新本文件中的复选框、记录证据，并单独提交。当前约束是由单一 AI 执行，不分派实现任务给其他 agent。

**目标：** 发布 `v1.3.0`，使 LiDAR iPhone 和 LiDAR iPad 能完成扫描、处理、地图加载、异步视觉定位、结构化诊断和三场地 30 分钟真机验收。

**架构：** 以明确的 `T_U_C`、`T_C_S` 和 `T_U_S` 坐标合同贯穿 Swift、Python、SQLite、native C++ 与 Unity。Runtime 采用仅保留最新帧的单 worker，独占 native handle；UPM 包携带 iOS 后处理和链接所需制品；设备验收通过不含图像的结构化诊断记录保存证据。

**技术栈：** Swift/ARKit、Python 3.11、SQLite、C++/OpenCV、Unity 6000.4.6f1、AR Foundation 6.0.0、Xcode、UPM、GitHub Actions。

**事实来源：** `requirements.md`、`design.md`、`docs/async-localization-design.md`、`docs/ios-device-test-guide.md` 与当前代码实现。

---

## 进度规则

- 按任务编号顺序执行；一个任务的自动化验证通过后才开始下一任务。
- 每次修改先写会失败的测试或验证，再实现最小变更使其通过。
- 每个任务产生一个独立可运行产物；不得把尚未实现的后续任务作为前置条件。
- 每个任务提交前运行本任务列出的命令、`git diff --check` 和受影响的既有测试。
- 仅勾选已产生真实命令输出的步骤；设备缺失、签名缺失或外部网络故障必须记录为 `SKIP` 或阻塞原因。
- 阶段 1 不实现 Rokid、Android ARM64、云上传、远程地图分发或算法阈值调优。
- 每次提交必须包含本文件相应复选框和证据摘要更新。

## 任务 1：建立跨语言坐标契约 fixture

> 进度：已完成（2026-07-13）。隔离 worktree 已建立；实施前 Python 基线为 `281 passed, 4 skipped`。步骤 1–8 已完成，尚未开始任务 2。
>
> 环境记录：本机未安装计划中写明的 `iPhone 16 Pro` simulator；任务 1 的 Swift 验证改用已安装的 `iPhone 17 Pro (iOS 26.3.1)`，测试语义不变。
>
> 验证证据：Python fixture 与既有 feature DB 测试 `33 passed`；完整 Python 套件 `286 passed, 4 skipped`；Swift 的 `CoordinateContractTests` 在 iPhone 17 Pro simulator 上 `3 passed`；Unity EditMode fixture 测试 `2 passed`。合同检查器输出的 `T_U_S` 平移为 `(5, 7, 9)`，且 `git diff --check` 通过。Unity 运行时自动迁移的项目设置已按阶段 0 的既有惯例还原，未纳入本任务。

**对应需求：** R1.1、R1.6

**可运行产物：** 一个不含真实图片的 `coordinate-contract-v1.json`，可由 Swift、Python 和 Unity 测试读取并验证同一组矩阵、内参和图像方向。

**涉及文件：**

- 新建：`tests/fixtures/phase1/coordinate-contract-v1.json`
- 新建：`tools/phase1/validate_scan_contract.py`
- 新建：`tests/phase1/test_scan_contract.py`
- 新建：`ios_scanner/AreaTargetScannerTests/CoordinateContractTests.swift`
- 新建：`unity_plugin/AreaTargetPlugin/Tests/CoordinateContractFixtureTests.cs`
- 新建：`unity_plugin/AreaTargetPlugin/Tests/CoordinateContractFixtureTests.cs.meta`
- 修改：`ios_scanner/AreaTargetScanner.xcodeproj/project.pbxproj`（测试 target 与 fixture resource）
- 修改：`tests/test_feature_db.py`
- 修改：`unity_plugin/AreaTargetPlugin/Tests/AreaTargetPlugin.Tests.asmdef`

- [x] **步骤 1：定义 fixture 的固定语义和数值**

创建 `tests/fixtures/phase1/coordinate-contract-v1.json`，其中必须包含：

```json
{
  "schemaVersion": 1,
  "units": "meters",
  "scanPoseLayout": "arkit-column-major",
  "nativePoseLayout": "row-major",
  "imageOrientation": "landscapeRight",
  "image": { "width": 640, "height": 480 },
  "intrinsics": { "fx": 500.0, "fy": 510.0, "cx": 320.0, "cy": 240.0 },
  "unityWorldFromCamera": [
    1.0, 0.0, 0.0, 1.0,
    0.0, 1.0, 0.0, 2.0,
    0.0, 0.0, 1.0, 3.0,
    0.0, 0.0, 0.0, 1.0
  ],
  "cameraFromScan": [
    1.0, 0.0, 0.0, 4.0,
    0.0, 1.0, 0.0, 5.0,
    0.0, 0.0, 1.0, 6.0,
    0.0, 0.0, 0.0, 1.0
  ],
  "expectedUnityWorldFromScan": [
    1.0, 0.0, 0.0, 5.0,
    0.0, 1.0, 0.0, 7.0,
    0.0, 0.0, 1.0, 9.0,
    0.0, 0.0, 0.0, 1.0
  ]
}
```

数组在 JSON 中一律为 row-major；Swift 测试额外构造其等价的 ARKit column-major `simd_float4x4`，证明导出转换后仍等于 fixture 的 row-major 语义。

- [x] **步骤 2：先添加会失败的 Python fixture 验证测试**

创建 `tests/phase1/test_scan_contract.py`，测试应调用尚不存在的 checker，并覆盖：正确 fixture、16 元矩阵长度错误、未知方向、无效内参和错误的 `T_U_S`。

```python
def test_contract_fixture_is_valid():
    result = run_checker(FIXTURE)
    assert result.returncode == 0, result.stderr
    assert "unityWorldFromScan" in result.stdout

def test_wrong_composed_pose_is_rejected(tmp_path):
    data = json.loads(FIXTURE.read_text())
    data["expectedUnityWorldFromScan"][3] = 999.0
    path = tmp_path / "bad-contract.json"
    path.write_text(json.dumps(data))
    result = run_checker(path)
    assert result.returncode != 0
    assert "T_U_S" in result.stderr
```

- [x] **步骤 3：运行测试并确认因 checker 缺失而失败**

运行：

```bash
venv/bin/python -m pytest tests/phase1/test_scan_contract.py -v
```

预期结果：失败，错误指出 `tools/phase1/validate_scan_contract.py` 尚不存在。

- [x] **步骤 4：实现纯 Python 合同检查器**

创建 `tools/phase1/validate_scan_contract.py`。该脚本必须：

1. 拒绝缺失 `schemaVersion == 1`、非 `meters` 单位、未知 layout 或方向。
2. 检查图像尺寸、内参、所有矩阵元素均为有限数值。
3. 将 row-major 数组重组为 4×4 矩阵，计算 `unity_world_from_camera @ camera_from_scan`。
4. 在 `1e-5` 容差内比较 `expectedUnityWorldFromScan`。
5. 成功时打印 JSON：`{"schemaVersion":1,"unityWorldFromScan":[...]}`；失败写 stderr 并返回 2。

核心组合逻辑必须等价于：

```python
expected = matrix_from_row_major(data["expectedUnityWorldFromScan"])
actual = (
    matrix_from_row_major(data["unityWorldFromCamera"])
    @ matrix_from_row_major(data["cameraFromScan"])
)
if not numpy.allclose(actual, expected, atol=1e-5):
    raise ValueError("T_U_S must equal T_U_C × T_C_S")
```

若项目未声明 NumPy 为验证脚本依赖，使用标准库实现 4×4 乘法，避免新增依赖。

- [x] **步骤 5：补全 Python 测试并确认通过**

运行：

```bash
venv/bin/python -m pytest tests/phase1/test_scan_contract.py tests/test_feature_db.py -v
```

预期结果：所有测试通过；测试输出明确显示 fixture 被接受，四类损坏输入均被拒绝。

- [x] **步骤 5a：添加 Unity fixture-only Editor 测试**

新增 `CoordinateContractFixtureTests.cs`，通过 `Application.dataPath` 回溯到仓库根目录读取同一份 `tests/fixtures/phase1/coordinate-contract-v1.json`。测试只验证 fixture 数据合同：schema、方向、row-major 矩阵长度和 `T_U_S` 平移 `(5, 7, 9)`；不得新增 Runtime 坐标转换类或改变 tracker。`CoordinateTransform` 的行为测试仍保留在任务 4。

原因：任务 1 的产物要求 Swift、Python 和 Unity 都读取同一 fixture；原计划未列出对应 Unity 测试步骤，本步骤是保持该已确认产物所需的最小补正。

- [x] **步骤 6：添加 Swift fixture 互操作测试**

创建 `ios_scanner/AreaTargetScannerTests/CoordinateContractTests.swift`。测试读取 bundle 中的 fixture，并验证：

- `CameraPose` 的 column-major ARKit transform 导出为规定的 JSON 顺序。
- `imageOrientation == landscapeRight` 时宽高和 `fx/fy/cx/cy` 无额外交换。
- 将 fixture 的 `T_U_C` 和 `T_C_S` 转成 `simd_float4x4` 后，乘积平移为 `(5, 7, 9)`。

测试主断言：

```swift
XCTAssertEqual(result.columns.3.x, 5, accuracy: 0.00001)
XCTAssertEqual(result.columns.3.y, 7, accuracy: 0.00001)
XCTAssertEqual(result.columns.3.z, 9, accuracy: 0.00001)
```

- [x] **步骤 7：运行 Swift 测试和 Python 测试**

运行：

```bash
xcodebuild test \
  -project ios_scanner/AreaTargetScanner.xcodeproj \
  -scheme AreaTargetScanner \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
venv/bin/python -m pytest tests/phase1/test_scan_contract.py -v
```

另在 Unity Test Runner 运行 `AreaTargetPlugin.Tests/CoordinateContractFixtureTests`。

预期结果：三个测试入口均通过；若本机不存在指定 simulator，记录 `SKIP` 和可用 simulator 名称，Python 和 Unity 测试仍必须通过。

- [x] **步骤 8：提交任务 1**

```bash
git add \
  tests/fixtures/phase1/coordinate-contract-v1.json \
  tools/phase1/validate_scan_contract.py \
  tests/phase1/test_scan_contract.py \
  ios_scanner/AreaTargetScannerTests/CoordinateContractTests.swift \
  ios_scanner/AreaTargetScanner.xcodeproj/project.pbxproj \
  unity_plugin/AreaTargetPlugin/Tests/CoordinateContractFixtureTests.cs \
  unity_plugin/AreaTargetPlugin/Tests/CoordinateContractFixtureTests.cs.meta \
  tests/test_feature_db.py \
  docs/superpowers/specs/phase-1-ios-workflow/tasks.md
git commit -m "test: define phase 1 coordinate contract"
```

## 任务 2：让扫描 ZIP 声明每帧方向、内参和矩阵布局

> 进度：实施与真机验证已完成（2026-07-13）；本次提交将同时记录步骤 7 完成，尚未开始任务 3。
>
> 实施边界：当前 JPEG 导出不旋转像素，因此 ARKit 扫描帧将显式标记为 `landscapeRight`；若输入要求 portrait 变换而现有导出器无法安全重编码 JPEG，则必须失败，不能猜测或静默补默认值。
>
> 验证证据：先观察 Swift/Python 新合同用例在实现前失败，再通过最小实现使其通过。提交前最新回归：iPhone 17 Pro simulator（iOS 26.5）完整 Swift suite 为 `93 passed`（`0 failed`）；Python 合同测试为 `11 passed`，完整 Python suite 为 `292 passed, 4 skipped`。完整 Python suite 与 Xcode 回归并行时曾在既有 mesh 原生扩展内发生一次段错误；Xcode 结束后单独运行 mesh 测试 `20 passed`，再串行完整运行后通过，因此未将其归因于本任务代码。
>
> 真机验证：已完成一次短扫描。扫描 ZIP 仅保留在受控本地临时目录；只提取并检查 `manifest.json`，退出码为 0，终端摘要为 `{"frameCount":31,"orientationCounts":{"landscapeRight":31},"schemaVersion":1}`。无图像、设备标识或本地导出路径写入 Git；匿名摘要见 `docs/phase-1-ios-validation.md`。

**对应需求：** R1.1、R1.5

**可运行产物：** 由 LiDAR 扫描器生成的 ZIP 可被 Python checker 识别为 schema v1，且拒绝方向/内参不完整的扫描数据。

**涉及文件：**

- 修改：`ios_scanner/AreaTargetScanner/Models/CameraPose.swift`
- 修改：`ios_scanner/AreaTargetScanner/Services/ARKitScannerService.swift`
- 修改：`ios_scanner/AreaTargetScanner/Services/ScanDataExporter.swift`
- 修改：`ios_scanner/AreaTargetScannerTests/ScanDataExporterTests.swift`
- 修改：`ios_scanner/AreaTargetScannerTests/ScanDataExporterEdgeCaseTests.swift`（为既有导出测试提供显式帧元数据）
- 修改：`ios_scanner/AreaTargetScannerTests/TextureMappingPropertyTests.swift`（为既有导出测试提供显式帧元数据）
- 修改：`tools/phase1/validate_scan_contract.py`
- 修改：`tests/phase1/test_scan_contract.py`
- 新建：`docs/phase-1-ios-validation.md`（不含图像或设备隐私数据）

- [x] **步骤 1：添加失败的扫描导出测试**

在 `ScanDataExporterTests.swift` 中添加：

```swift
func testExportedManifestDeclaresCoordinateAndImageContract() throws {
    let manifest = try exportOneKeyframeAndReadManifest()
    XCTAssertEqual(manifest.schemaVersion, 1)
    XCTAssertEqual(manifest.matrixLayout, "arkit-column-major")
    XCTAssertEqual(manifest.units, "meters")
    XCTAssertEqual(manifest.frames[0].imageOrientation, "landscapeRight")
    XCTAssertEqual(manifest.frames[0].intrinsics.fx, 500, accuracy: 0.001)
}
```

再添加两个失败用例：缺少方向字段和 90 度旋转后未交换宽高/内参。不要以默认值静默填充缺失方向。

- [x] **步骤 2：运行扫描导出测试并确认失败**

运行：

```bash
xcodebuild test \
  -project ios_scanner/AreaTargetScanner.xcodeproj \
  -scheme AreaTargetScanner \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:AreaTargetScannerTests/ScanDataExporterTests
```

预期结果：新测试失败，因为当前导出 manifest 未声明完整合同。

- [x] **步骤 3：扩展扫描元数据模型与导出器**

在 `CameraPose` 中增加 `imageOrientation`、`intrinsics` 或 `intrinsicsRef`、`imageWidth`、`imageHeight`。在 `ARKitScannerService` 捕获时将当前 `ARFrame.camera.intrinsics` 与图像方向绑定到同一 keyframe；在 `ScanDataExporter` 顶层写入：

```json
{
  "schemaVersion": 1,
  "coordinateSystem": "arkit-world",
  "matrixLayout": "arkit-column-major",
  "units": "meters"
}
```

规则：`landscapeLeft`/`landscapeRight` 不交换宽高；`portrait`/`portraitUpsideDown` 必须把像素与 `fx/fy/cx/cy` 转换为导出 JPEG 的实际方向。不能正确转换时停止导出并报告错误。

- [x] **步骤 4：为 Python 检查器增加 scan ZIP manifest 模式**

`validate_scan_contract.py` 新增 `--scan-manifest <path>` 模式，校验：每帧 image filename 唯一、矩阵长度为 16、时间戳递增、图像尺寸为正、内参主点在图像范围内、方向为四种允许值之一。成功打印帧数与 schema 版本。

- [x] **步骤 5：运行 Swift 与 Python 回归测试**

运行：

```bash
xcodebuild test \
  -project ios_scanner/AreaTargetScanner.xcodeproj \
  -scheme AreaTargetScanner \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
venv/bin/python -m pytest tests/phase1/test_scan_contract.py -v
```

预期结果：所有导出与合同测试通过；损坏 manifest 的 Python 用例仍失败。

- [x] **步骤 6：在真机上生成一份无图像提交的验证摘要**

连接 LiDAR iPhone 或 iPad，构建扫描器并执行一次短扫描。将 ZIP 保留在受控本地目录，不提交 Git；对 manifest 运行：

```bash
venv/bin/python tools/phase1/validate_scan_contract.py \
  --scan-manifest /absolute/path/to/export/manifest.json
```

预期结果：返回 0 并打印 schema、帧数、方向分布。把终端摘要记录到 `docs/phase-1-ios-validation.md`，不复制图像或设备隐私数据。

- [x] **步骤 7：提交任务 2**

```bash
git add \
  ios_scanner/AreaTargetScanner/Models/CameraPose.swift \
  ios_scanner/AreaTargetScanner/Services/ARKitScannerService.swift \
  ios_scanner/AreaTargetScanner/Services/ScanDataExporter.swift \
  ios_scanner/AreaTargetScannerTests/ScanDataExporterTests.swift \
  ios_scanner/AreaTargetScannerTests/ScanDataExporterEdgeCaseTests.swift \
  ios_scanner/AreaTargetScannerTests/TextureMappingPropertyTests.swift \
  tools/phase1/validate_scan_contract.py \
  tests/phase1/test_scan_contract.py \
  docs/phase-1-ios-validation.md \
  docs/superpowers/specs/phase-1-ios-workflow/tasks.md
git commit -m "feat: export iOS scan coordinate metadata"
```

## 任务 3：将合同贯穿 Python、SQLite 与 native bridge

> 进度：步骤 1–6 已完成（2026-07-13）；步骤 7 待提交。已获用户授权，仅提前引入任务 4 所需的最小当前相机位姿载荷（`LocalizationFrame.UnityWorldFromCamera` 及其 bridge 传递），不提前实现坐标组合、异步运行器或场景更新。native 的 OpenCV→AR 相机规范化现由一个独立的 C++ 合同测试覆盖；为保持本任务 `T_C_S` 合同，legacy alignment ABI 不再改写 native PnP 输出，`T_U_S` 的实际应用仍留给任务 4。尚未开始任务 4。
>
> 验证证据：Python 合同与回归测试 `64 passed, 1 warning`；`native_visual_localizer/build_macos.sh` 成功构建并执行 `1/1` C++ 合同测试；macOS dylib 与现有 iOS arm64 静态库均通过 native 符号合同检查；Unity EditMode `NativeLocalizerBridgeTests` 为 `19 passed, 0 failed`。`build_ios.sh` 和 `build_macos.sh` 均已通过 `bash -n` 语法检查。Unity 自动改写的项目设置、包锁定和插件元文件已从本次提交中排除。

**对应需求：** R1.1、R1.6

**可运行产物：** 处理管线和 SQLite reader 对同一 fixture 产生明确的 row-major pose blob；native C API 与 C# bridge 均标注并验证 `T_C_S`。

**涉及文件：**

- 修改：`processing_pipeline/optimized_pipeline.py`
- 修改：`processing_pipeline/feature_extraction.py`
- 修改：`processing_pipeline/feature_db.py`
- 修改：`tests/test_feature_extraction.py`
- 修改：`tests/test_feature_db.py`
- 修改：`native_visual_localizer/include/visual_localizer.h`
- 修改：`native_visual_localizer/CMakeLists.txt`
- 修改：`native_visual_localizer/build_ios.sh`
- 修改：`native_visual_localizer/build_macos.sh`
- 修改：`native_visual_localizer/src/visual_localizer.cpp`
- 修改：`native_visual_localizer/src/visual_localizer_impl.cpp`
- 修改：`native_visual_localizer/src/visual_localizer_impl.h`
- 修改：`native_visual_localizer/src/visual_localizer_stub.c`
- 新建：`native_visual_localizer/src/pose_contract.h`
- 新建：`native_visual_localizer/src/pose_contract.cpp`
- 新建：`native_visual_localizer/tests/pose_contract_test.cpp`
- 修改：`unity_plugin/AreaTargetPlugin/Runtime/NativeLocalizerBridge.cs`
- 修改：`unity_plugin/AreaTargetPlugin/Tests/NativeLocalizerBridgeTests.cs`
- 经授权的最小提前载荷：`unity_plugin/AreaTargetPlugin/Runtime/LocalizationFrame.cs`、`unity_plugin/AreaTargetPlugin/Runtime/LocalizationFrame.cs.meta`、`unity_plugin/AreaTargetPlugin/Runtime/CameraFrame.cs`、`unity_plugin/AreaTargetPlugin/Runtime/CameraDataAdapter.cs`、`unity_plugin/AreaTargetPlugin/Runtime/VisualLocalizationEngine.cs`

- [x] **步骤 1：添加会失败的 Python pose blob 回归测试**

在 `tests/test_feature_db.py` 增加 fixture 测试：读取 `coordinate-contract-v1.json`，写入一条 keyframe 后读取 SQLite blob，断言 16 个 float 的顺序为 fixture 的 `cameraFromScan` row-major 顺序。再构造 column-major blob，断言 reader 明确拒绝或转换，而不是默默接受。

- [x] **步骤 2：运行 Python 测试并确认现状不满足合同**

运行：

```bash
venv/bin/python -m pytest \
  tests/test_feature_db.py \
  tests/test_feature_extraction.py -v
```

预期结果：至少一个新合同断言失败，暴露当前读取/写入布局没有固定合同。

- [x] **步骤 3：实现 Python 输入与数据库布局校验**

在 `optimized_pipeline.py` 入口读取 scan manifest 的 `schemaVersion`、`matrixLayout`、`units`、方向和内参，拒绝未知 schema。把 Swift column-major 转为处理管线内部矩阵时只能经过一个命名函数，例如：

```python
def arkit_column_major_to_matrix(values: list[float]) -> np.ndarray:
    return np.array(values, dtype=np.float64).reshape((4, 4), order="F")
```

在 `feature_db.py` 写入前由一个 `matrix_to_row_major_blob` 函数生成 `C` order、16 个 `float64` 的 blob；读取由对应逆函数完成。每个函数对长度、有限值和最后一行 `[0,0,0,1]` 做检查。

- [x] **步骤 4：明确 native 返回矩阵语义**

在 `visual_localizer.h` 的 `VLResult.pose` 注释改为 `T_C_S`，明确它是 row-major、scan/world 到当前 camera 的 PnP 结果。`visual_localizer_impl.cpp` 必须确保结果写出前仅做一次 OpenCV camera → AR camera 坐标规范化，并在单元/原生测试中以 fixture 矩阵验证。不得把上一次 PnP 结果作为 `has_last_pose` 的 AR camera C2W 输入。

`NativeLocalizerBridge.cs` 中将参数名从泛化的 `last_pose_4x4` 改为语义明确的 `unity_world_from_camera_4x4`（或同步调整 native API 名称），并在 P/Invoke 注释写明其空间和 row-major 布局。

- [x] **步骤 5：添加 native/C# bridge 测试**

在 `NativeLocalizerBridgeTests.cs` 中创建无 native handle 的序列化测试，验证：

```csharp
var values = VisualLocalizationEngine.Matrix4x4ToArray(matrix);
Assert.AreEqual(matrix.m03, values[3]);
Assert.AreEqual(matrix.m13, values[7]);
Assert.AreEqual(matrix.m23, values[11]);
```

另加 P/Invoke 参数测试，断言调用点传入的是当前 `LocalizationFrame.UnityWorldFromCamera`，而不是 `LastValidPose`。

- [x] **步骤 6：运行处理、native 与 Unity EditMode 验证**

运行：

```bash
venv/bin/python -m pytest \
  tests/test_feature_db.py \
  tests/test_feature_extraction.py \
  tests/phase1/test_scan_contract.py -v
native_visual_localizer/build_macos.sh
tools/phase0/check_native_symbols.sh \
  unity_project/Assets/Plugins/iOS/libvisual_localizer.a
```

随后在 Unity Test Runner 执行 `AreaTargetPlugin.Tests` 中的 `NativeLocalizerBridgeTests`。预期结果：全部通过，native 符号合同仍完整。

- [x] **步骤 7：提交任务 3**

```bash
git add \
  processing_pipeline/optimized_pipeline.py \
  processing_pipeline/feature_extraction.py \
  processing_pipeline/feature_db.py \
  tests/test_feature_db.py \
  tests/test_feature_extraction.py \
  native_visual_localizer/CMakeLists.txt \
  native_visual_localizer/build_ios.sh \
  native_visual_localizer/build_macos.sh \
  native_visual_localizer/include/visual_localizer.h \
  native_visual_localizer/src/pose_contract.h \
  native_visual_localizer/src/pose_contract.cpp \
  native_visual_localizer/src/visual_localizer.cpp \
  native_visual_localizer/src/visual_localizer_impl.cpp \
  native_visual_localizer/src/visual_localizer_impl.h \
  native_visual_localizer/src/visual_localizer_stub.c \
  native_visual_localizer/tests/pose_contract_test.cpp \
  unity_plugin/AreaTargetPlugin/Runtime/LocalizationFrame.cs \
  unity_plugin/AreaTargetPlugin/Runtime/LocalizationFrame.cs.meta \
  unity_plugin/AreaTargetPlugin/Runtime/CameraFrame.cs \
  unity_plugin/AreaTargetPlugin/Runtime/CameraDataAdapter.cs \
  unity_plugin/AreaTargetPlugin/Runtime/VisualLocalizationEngine.cs \
  unity_plugin/AreaTargetPlugin/Runtime/NativeLocalizerBridge.cs \
  unity_plugin/AreaTargetPlugin/Tests/NativeLocalizerBridgeTests.cs \
  docs/superpowers/specs/phase-1-ios-workflow/tasks.md
git commit -m "feat: enforce cross-language pose contract"
```

## 任务 4：实现 Runtime 坐标转换与帧封装

**对应需求：** R1.1、R1.4、R1.6

**可运行产物：** Unity Runtime 可接收带当前 AR 位姿的 `LocalizationFrame`，只通过 `CoordinateTransform` 计算内容根节点 `T_U_S`。

> **进度（2026-07-13）：** 步骤 1–8 已完成。任务 3 已按用户授权提前引入仅含 `T_U_C` 的 `LocalizationFrame` 前置载荷，本任务将其扩展为完整不可变帧，并新增唯一的 `CoordinateTransform`。本任务未提前实现任务 5 的异步运行器。
>
> **验证证据：** `CoordinateTransformTests` 的失败测试先确认旧 SLAM 场景会重复组合坐标（最终位置偏差 `9.5m`），改造后该测试通过。指定 Unity EditMode 回归为：`CoordinateTransformTests` `12/12`、`NativeLocalizerBridgeTests` `19/19`、`LocalizerIntegrationTests` `6/6`、`SLAMTestSceneIntegrationTests` `17/17`；受影响的 `SLAMTestSceneManagerTests` `18/18` 与 `ARTestSceneDebugUITests` `11/11` 也通过。Unity 自动改写的项目设置、包锁定和插件元文件已还原，未纳入本任务。

**涉及文件：**

- 新建：`unity_plugin/AreaTargetPlugin/Runtime/LocalizationFrame.cs`
- 新建：`unity_plugin/AreaTargetPlugin/Runtime/LocalizationFrameResult.cs`
- 新建：`unity_plugin/AreaTargetPlugin/Runtime/CoordinateTransform.cs`
- 新建：`unity_plugin/AreaTargetPlugin/Tests/CoordinateTransformTests.cs`
- 修改：`unity_plugin/AreaTargetPlugin/Runtime/CameraFrame.cs`
- 修改：`unity_plugin/AreaTargetPlugin/Runtime/CameraDataAdapter.cs`
- 修改：`unity_plugin/AreaTargetPlugin/Runtime/Interfaces/ICameraData.cs`
- 修改：`unity_plugin/AreaTargetPlugin/Runtime/Platforms/ARFoundationPlatformSupport.cs`
- 修改：`unity_plugin/AreaTargetPlugin/Runtime/VisualLocalizationEngine.cs`
- 修改：`unity_plugin/AreaTargetPlugin/Runtime/AreaTargetTracker.cs`
- 修改：`unity_plugin/AreaTargetPlugin/Runtime/AlignmentTransformCalculator.cs`

- [x] **步骤 1：添加失败的 CoordinateTransform EditMode 测试**

在 `CoordinateTransformTests.cs` 中从 fixture 读取矩阵，添加：

```csharp
[Test]
public void ComposeUnityWorldFromScan_usesCurrentCameraPose()
{
    var result = CoordinateTransform.ComposeUnityWorldFromScan(
        unityWorldFromCamera, cameraFromScan);
    Assert.That(result.m03, Is.EqualTo(5f).Within(0.00001f));
    Assert.That(result.m13, Is.EqualTo(7f).Within(0.00001f));
    Assert.That(result.m23, Is.EqualTo(9f).Within(0.00001f));
}
```

添加非法矩阵、非刚体最后一行、NaN、错误乘法顺序和 image orientation 不匹配的失败用例。

- [x] **步骤 2：运行 EditMode 测试并确认失败**

在 Unity Test Runner 运行 `AreaTargetPlugin.Tests/CoordinateTransformTests`。

预期结果：编译或测试失败，因为 `LocalizationFrame` 和 `CoordinateTransform` 尚不存在。

- [x] **步骤 3：实现不可变帧与结果类型**

`LocalizationFrame` 构造函数必须复制图像，验证尺寸、内参、时间戳、map ID 和 `UnityWorldFromCamera`。`LocalizationFrameResult` 必须保存输入 frame ID、map generation、worker 时间、`CameraFromScan`、`UnityWorldFromScan`、状态、quality、failure category 和 native debug 指标。失败结果的位姿必须为空/显式无效，不能使用 identity 冒充有效结果。

- [x] **步骤 4：实现唯一的坐标转换器**

`CoordinateTransform` 至少提供：

```csharp
public static Matrix4x4 ComposeUnityWorldFromScan(
    Matrix4x4 unityWorldFromCamera,
    Matrix4x4 cameraFromScan);

public static float[] ToNativeRowMajor(Matrix4x4 matrix);

public static Matrix4x4 FromNativeRowMajor(float[] values);
```

`ComposeUnityWorldFromScan` 必须验证两个输入均为有限刚体矩阵，然后返回 `unityWorldFromCamera * cameraFromScan`。所有 alignment 计算使用命名的帧对 `(T_U_C, T_C_S)`，不接受仅有 raw PnP pose 的 `List<Matrix4x4>`。

- [x] **步骤 5：将当前 AR pose 传到 tracker/native**

扩展 `ICameraData`、`CameraDataAdapter`、`CameraFrame` 和 `ARFoundationPlatformSupport`，使当前 AR 相机位置、旋转和 frame timestamp 可组成 `T_U_C`。修改 `VisualLocalizationEngine.ProcessFrame` 接受 `LocalizationFrame`，把其 `UnityWorldFromCamera` 以 row-major 传给 native。

移除 `LastValidPose` 被当作 native AR camera pose 参数的路径；若为 nearby search 保留上次地图结果，使用独立、语义明确的缓存字段，不能复用 `T_U_C` 参数。

- [x] **步骤 6：把内容根位姿和 alignment 收敛到 Runtime**

修改 `AreaTargetTracker`：成功 native PnP 后立即通过 `CoordinateTransform` 生成 `T_U_S`；`SceneUpdater` 仅接收该变换。改造 `AlignmentTransformCalculator` 的方法签名，使输入为成功 frame pair，并在测试中验证至少三个样本的鲁棒计算不会把 `T_C_S` 当成 `T_U_S`。

`ARTestSceneManager` 与 `SLAMTestSceneManager` 删除/停用各自的手写 matrix composition；它们调用 tracker 的公开结果，不访问 native bridge。

- [x] **步骤 7：运行 Unity 回归测试**

在 Unity Test Runner 运行：

```text
AreaTargetPlugin.Tests/CoordinateTransformTests
AreaTargetPlugin.Tests/NativeLocalizerBridgeTests
AreaTargetPlugin.Tests/LocalizerIntegrationTests
AreaTargetPlugin.Tests/SLAMTestSceneIntegrationTests
```

预期结果：所有测试通过；新增测试证明 `T_U_S = T_U_C × T_C_S` 且场景不再自行组合矩阵。

- [x] **步骤 8：提交任务 4**

```bash
git add \
  unity_plugin/AreaTargetPlugin/Runtime/LocalizationFrame.cs \
  unity_plugin/AreaTargetPlugin/Runtime/LocalizationFrameResult.cs \
  unity_plugin/AreaTargetPlugin/Runtime/CoordinateTransform.cs \
  unity_plugin/AreaTargetPlugin/Tests/CoordinateTransformTests.cs \
  unity_plugin/AreaTargetPlugin/Runtime/CameraFrame.cs \
  unity_plugin/AreaTargetPlugin/Runtime/CameraDataAdapter.cs \
  unity_plugin/AreaTargetPlugin/Runtime/Interfaces/ICameraData.cs \
  unity_plugin/AreaTargetPlugin/Runtime/Platforms/ARFoundationPlatformSupport.cs \
  unity_plugin/AreaTargetPlugin/Runtime/VisualLocalizationEngine.cs \
  unity_plugin/AreaTargetPlugin/Runtime/AreaTargetTracker.cs \
  unity_plugin/AreaTargetPlugin/Runtime/AlignmentTransformCalculator.cs \
  unity_project/Assets/Scripts/ARTestSceneManager.cs \
  unity_project/Assets/Scripts/SLAMTestScene/SLAMTestSceneManager.cs \
  docs/superpowers/specs/phase-1-ios-workflow/tasks.md
git commit -m "feat: unify iOS localization coordinates"
```

## 任务 5：实现 latest-frame 异步定位运行器

**对应需求：** R1.2、R1.4、R1.6

**可运行产物：** Runtime 的单 worker 在不阻塞 Unity 主线程的情况下定位，覆盖 pending 旧帧、拒绝过期结果，并安全 reset/dispose。

> **进度（2026-07-13）：** 步骤 1–7 已完成。`AsyncLocalizationRunner` 以单 worker 独占 `Process`、alignment、`Reset` 和 `Dispose`；输入只保留最新 pending frame，输出按 map、generation、时间和 frame ID 过滤，任何有输入上下文的 worker 异常（包含 alignment）都会产出 `LifecycleFailure` 后停机。`AreaTargetTracker` 与 `ARTestSceneManager`、`SLAMTestSceneManager` 已改为“提交帧→消费结果”，SLAM 场景的自建线程、2ms 轮询与反射读取已删除。审计额外发现 `PointCloudLocalizer` 直接绕过 engine，已做最小迁移至同一 runner 边界。
>
> **验证证据：** 先后观察到 runner 接口、Tracker 异步入口、两份场景迁移、PointCloud runner 委派、alignment worker 所有权及 alignment 异常传播的失败测试；实现后专用测试均通过。项目没有独立的 PlayMode 生命周期程序集，因此 `AsyncLocalizationRunnerTests` 的真实线程、latest-frame、reset/dispose 和异常路径覆盖作为需求 R1.6 所允许的等价生命周期验证。最终 Unity EditMode 回归为 `975/975` 通过、`0` 失败、`0` 跳过，且无 C# 编译错误；结果文件：`/private/tmp/phase1-task5-editmode-final4.xml`。

**涉及文件：**

- 新建：`unity_plugin/AreaTargetPlugin/Runtime/AsyncLocalizationRunner.cs`
- 新建：`unity_plugin/AreaTargetPlugin/Tests/AsyncLocalizationRunnerTests.cs`
- 修改：`unity_plugin/AreaTargetPlugin/Runtime/AreaTargetTracker.cs`
- 修改：`unity_plugin/AreaTargetPlugin/Runtime/VisualLocalizationEngine.cs`
- 修改：`unity_plugin/AreaTargetPlugin/Runtime/IAreaTargetTracker.cs`
- 修改：`unity_plugin/AreaTargetPlugin/Tests/AreaTargetTrackerLifecycleTests.cs`
- 修改：`unity_project/Assets/Scripts/ARTestSceneManager.cs`
- 修改：`unity_project/Assets/Scripts/SLAMTestScene/SLAMTestSceneManager.cs`

- [x] **步骤 1：添加失败的 runner 生命周期测试**

使用一个实现 `ILocalizationProcessor` 的 fake（不调用 native）测试以下行为：

```csharp
[Test]
public async Task Submit_replaces_pending_frame_with_newest_frame()
{
    runner.Start();
    runner.Submit(Frame(1));
    runner.Submit(Frame(2));
    await processor.WaitUntilStarted;
    Assert.AreEqual(2, processor.ProcessedFrameIds.Single());
    Assert.AreEqual(1, runner.OverwrittenPendingFrames);
}

[Test]
public async Task Reset_waits_for_worker_before_resetting_processor()
{
    runner.Start();
    runner.Submit(Frame(1));
    await processor.WaitUntilStarted;
    var reset = runner.ResetAsync();
    Assert.IsFalse(processor.ResetCalled);
    processor.Release();
    await reset;
    Assert.IsTrue(processor.ResetCalled);
}
```

还必须覆盖：深拷贝图像、map generation 变化、过期结果、乱序结果、重复 `Start`、`DisposeAsync` 后提交和 worker 异常。

- [x] **步骤 2：运行测试并确认失败**

在 Unity Test Runner 运行 `AreaTargetPlugin.Tests/AsyncLocalizationRunnerTests`。

预期结果：失败，因为 runner/processor 抽象尚不存在。

- [x] **步骤 3：定义可替换的处理器边界**

在 Runtime 内定义内部接口：

```csharp
internal interface ILocalizationProcessor : IDisposable
{
    LocalizationFrameResult Process(LocalizationFrame frame, long generation);
    void Reset();
}
```

由 `VisualLocalizationEngine` 实现该接口，确保它的 native handle 仅在 worker 使用。接口不得暴露 Unity `Transform` 或 UI 对象。

- [x] **步骤 4：实现单 worker 和 bounded latest-frame 槽**

`AsyncLocalizationRunner` 使用一个 worker、一个 input lock、一个 output lock 和一个 cancellation 信号。`Submit` 在锁内替换 pending frame，递增覆盖计数并唤醒 worker；worker 在锁外调用 `processor.Process`。任何时候仅有 worker 可进入 processor。

结果消费 API：

```csharp
public bool TryDequeueLatest(
    string expectedMapId,
    long expectedGeneration,
    long nowTimestampNs,
    long maxAgeNs,
    out LocalizationFrameResult result);
```

不匹配 map/generation、frame ID 倒退或超过 `maxAgeNs` 时返回 `false` 并写入诊断，而非应用结果。

- [x] **步骤 5：实现安全 reset/dispose**

`ResetAsync` 必须：停止接收、递增 generation、清空 pending/output、等待 processor 离开 `Process`、调用 `Reset`、恢复接收。`DisposeAsync` 必须：停止接收、唤醒 worker、等待其退出、调用 `Dispose`。所有返回前都不得存在可能访问 native handle 的活动 worker。

若 worker 抛出异常，将它转换为 `LifecycleFailure` 结果，停止 runner 并保留异常摘要供诊断导出；不得吞掉异常或继续使用未知状态 handle。

- [x] **步骤 6：将 tracker 和两个场景迁移到 runner**

`AreaTargetTracker` 公开提交/消费异步结果的入口，主线程仅调用 `SubmitFrame` 与 `TryGetLatestTrackingResult`。`ARTestSceneManager` 删除同步 `ProcessFrame` 调用；`SLAMTestSceneManager` 删除自有 worker、2ms polling、reflection 读取 debug 和直接 native reset 路径。

每帧场景逻辑只能：采集 ARFoundation 数据、提交 frame、消费已验证结果、更新 `SceneUpdater`/UI 摘要。

- [x] **步骤 7：运行 EditMode 与 PlayMode 生命周期测试**

在 Unity Test Runner 执行：

```text
AreaTargetPlugin.Tests/AsyncLocalizationRunnerTests
AreaTargetPlugin.Tests/AreaTargetTrackerLifecycleTests
AreaTargetPlugin.Tests/SLAMTestSceneManagerTests
AreaTargetPlugin.Tests/SLAMTestSceneIntegrationTests
AreaTargetPlugin.Tests/ARTestSceneDebugUITests
```

预期结果：全部通过；`AsyncLocalizationRunnerTests` 覆盖 latest-frame、过期/乱序、reset/dispose 和异常路径。

- [x] **步骤 8：提交任务 5**

```bash
git add \
  unity_plugin/AreaTargetPlugin/Runtime/AsyncLocalizationRunner.cs \
  unity_plugin/AreaTargetPlugin/Tests/AsyncLocalizationRunnerTests.cs \
  unity_plugin/AreaTargetPlugin/Runtime/AreaTargetTracker.cs \
  unity_plugin/AreaTargetPlugin/Runtime/VisualLocalizationEngine.cs \
  unity_plugin/AreaTargetPlugin/Runtime/IAreaTargetTracker.cs \
  unity_plugin/AreaTargetPlugin/Tests/AreaTargetTrackerLifecycleTests.cs \
  unity_project/Assets/Scripts/ARTestSceneManager.cs \
  unity_project/Assets/Scripts/SLAMTestScene/SLAMTestSceneManager.cs \
  docs/superpowers/specs/phase-1-ios-workflow/tasks.md
git commit -m "feat: run localization off Unity main thread"
```

## 任务 6：建立结构化、无图像诊断

**对应需求：** R1.4、R1.5、R1.6

**可运行产物：** Runtime 可以导出有界 JSON Lines 诊断；测试证明其中没有图像、ZIP 或绝对用户路径。

> **进度（2026-07-13）：** 步骤 1–6 已完成。`LocalizationDiagnosticRecord` 固定 schema `1` 并仅序列化身份、帧、定位和 native 数值摘要；`BoundedDiagnosticBuffer` 是线程安全 FIFO，满时丢弃最旧记录并累计计数。`LocalizationDiagnosticExporter` 在创建目录前拒绝路径分隔符与图像/扫描标记，按 UTC 和 map hash 写 JSON Lines。tracker 对帧提交、pending 覆盖、地图/SQLite/native 初始化失败、reset、dispose、过期结果和最终应用结果写入记录；runner 通过内部 `ResultProduced` 事件在 worker 产出 native 结果时直接写入同一 buffer，不改变公开 API。两个场景只显示最新标量摘要。
>
> **验证证据：** schema 测试先产生预期 C# 编译失败，随后模型 `3/3`、补齐 capture timestamp 后 `5/5` 通过；worker 结果事件 `1/1` 通过（`/private/tmp/phase1-task6-worker-event-green.xml`）；真实 `SLAMTestAssets` 初始化、native worker 结果和 JSONL 导出 `1/1` 通过（`/private/tmp/phase1-task6-sample-worker-export.xml`）。还原临时导出路径后，完整 Unity EditMode 回归 `987/987` 通过、`0` 失败（`/private/tmp/phase1-task6-editmode-restored.xml`）；真实样例 JSONL（`/private/tmp/phase1-task6-manual-sample-20260713t1018/20260713T101852924Z_3d5ea46587a0.jsonl`）执行规定的 `rg` 检查无输出。

**涉及文件：**

- 新建：`unity_plugin/AreaTargetPlugin/Runtime/LocalizationDiagnosticRecord.cs`
- 新建：`unity_plugin/AreaTargetPlugin/Runtime/BoundedDiagnosticBuffer.cs`
- 新建：`unity_plugin/AreaTargetPlugin/Runtime/LocalizationDiagnosticExporter.cs`
- 新建：`unity_plugin/AreaTargetPlugin/Tests/LocalizationDiagnosticTests.cs`
- 修改：`unity_plugin/AreaTargetPlugin/Runtime/ExtendedDebugInfo.cs`
- 修改：`unity_plugin/AreaTargetPlugin/Runtime/AreaTargetTracker.cs`
- 修改：`unity_project/Assets/Scripts/ARTestSceneManager.cs`
- 修改：`unity_project/Assets/Scripts/SLAMTestScene/SLAMDebugPanel.cs`

> 最小必要接入：为满足“worker 也可写入诊断”的设计约束，另修改 `AsyncLocalizationRunner.cs` 与其测试；为让 SLAM 场景实际调用面板摘要，另修改 `SLAMTestSceneManager.cs` 与其测试。这些改动不新增公开 Runtime API。

- [x] **步骤 1：添加失败的诊断 schema 与隐私测试**

在 `LocalizationDiagnosticTests.cs` 中构造一条完整记录，序列化后断言包含 schema、包版本、map hash、设备、frame ID、queue、latency、quality 和 native debug 字段；同时断言序列化文本不包含：

```text
ImageData
JPEG
ScanData
/Users/
file://
```

添加 buffer 上限为 2 时插入 3 条记录，断言保留最后两条且 `DroppedRecordCount == 1`。

- [x] **步骤 2：运行诊断测试并确认失败**

在 Unity Test Runner 运行 `AreaTargetPlugin.Tests/LocalizationDiagnosticTests`。

预期结果：失败，因为诊断模型和 exporter 尚不存在。

- [x] **步骤 3：实现版本化诊断记录与固定错误类别**

`LocalizationDiagnosticRecord` 的 schema 版本固定为 `1`；定义 `LocalizationFailureCategory`：`None`、`UnsupportedDevice`、`InvalidFrame`、`MapLoadFailed`、`NativeInitializationFailed`、`SqliteFailed`、`LocalizationFailed`、`StaleResult`、`LifecycleFailure`。

记录允许存 `MapId`、`MapVersion`、`MapHash`，但不存 scan ZIP 名称、扫描目录、图像内容或真实场地名称。帧记录仅保存数值摘要，`T_U_S` 只记录是否应用和可选的量化平移/旋转摘要，不保存完整原始矩阵到默认导出。

- [x] **步骤 4：实现有界 buffer 与 exporter**

`BoundedDiagnosticBuffer` 构造时要求正容量，按 FIFO 丢弃最旧记录。`LocalizationDiagnosticExporter` 以一行一个 JSON 对象写入应用 diagnostics 目录，文件名由 UTC 时间与 map hash 前缀组成。导出前校验每个记录的字符串字段不含路径分隔符和禁止字段名；违反时返回失败类别而不写文件。

- [x] **步骤 5：将 runner/tracker 事件写入诊断**

在帧提交、pending 覆盖、native 成功/失败、过期结果、reset、dispose、地图加载和 SQLite/native 初始化失败处写一条诊断记录。实时 UI 只显示最近一条摘要：frame ID、结果年龄、state、quality、inlier 与 worker 耗时；不要在每帧 `Debug.Log` 整个 pose。

- [x] **步骤 6：运行 Unity 回归测试并手动导出样本**

在 Unity Test Runner 执行 `LocalizationDiagnosticTests`、`ARTestSceneDebugUITests`、`SLAMDebugPanelTests`。随后在 Editor sample 中加载已有测试地图并导出一份诊断文件，检查：

```bash
rg -n "ImageData|JPEG|ScanData|/Users/|file://" /path/to/diagnostic.jsonl
```

预期结果：测试通过；`rg` 无输出，诊断文件包含 schema 和 frame 摘要。

- [x] **步骤 7：提交任务 6**

```bash
git add \
  docs/superpowers/specs/phase-1-ios-workflow/tasks.md \
  unity_plugin/AreaTargetPlugin/Runtime/LocalizationDiagnosticRecord.cs \
  unity_plugin/AreaTargetPlugin/Runtime/LocalizationDiagnosticRecord.cs.meta \
  unity_plugin/AreaTargetPlugin/Runtime/BoundedDiagnosticBuffer.cs \
  unity_plugin/AreaTargetPlugin/Runtime/BoundedDiagnosticBuffer.cs.meta \
  unity_plugin/AreaTargetPlugin/Runtime/LocalizationDiagnosticExporter.cs \
  unity_plugin/AreaTargetPlugin/Runtime/LocalizationDiagnosticExporter.cs.meta \
  unity_plugin/AreaTargetPlugin/Tests/LocalizationDiagnosticTests.cs \
  unity_plugin/AreaTargetPlugin/Tests/LocalizationDiagnosticTests.cs.meta \
  unity_plugin/AreaTargetPlugin/Runtime/AsyncLocalizationRunner.cs \
  unity_plugin/AreaTargetPlugin/Runtime/LocalizationFrameResult.cs \
  unity_plugin/AreaTargetPlugin/Runtime/VisualLocalizationEngine.cs \
  unity_plugin/AreaTargetPlugin/Runtime/ExtendedDebugInfo.cs \
  unity_plugin/AreaTargetPlugin/Runtime/AreaTargetTracker.cs \
  unity_plugin/AreaTargetPlugin/Tests/AsyncLocalizationRunnerTests.cs \
  unity_plugin/AreaTargetPlugin/Tests/ARTestSceneDebugUITests.cs \
  unity_plugin/AreaTargetPlugin/Tests/SLAMDebugPanelTests.cs \
  unity_plugin/AreaTargetPlugin/Tests/SLAMTestSceneManagerTests.cs \
  unity_project/Assets/Scripts/ARTestSceneManager.cs \
  unity_project/Assets/Scripts/SLAMTestScene/SLAMDebugPanel.cs \
  unity_project/Assets/Scripts/SLAMTestScene/SLAMTestSceneManager.cs
git commit -m "feat: add bounded iOS localization diagnostics"
```

## 任务 7：使生成的 UPM 包可独立导出和链接 iOS

**对应需求：** R1.3、R1.6、R1.7

**可运行产物：** 空 Unity 工程只安装 `com.areatarget.tracking-1.3.0.tgz` 就能导出并通过 generic iOS device Xcode 编译，不依赖 `unity_project/Assets/Editor` 或临时 manifest 注入。

> **进度（2026-07-13）：** 步骤 1–7 已完成。新增 Python UPM 内容与依赖断言后，生成 `1.2.1` 包的测试如预期失败：缺 `package/Editor/iOSPostProcess.cs`，且 `validate_unity_package.sh` 仍向临时 manifest 注入 SQLite Git URL。随后将后处理迁入 UPM，生成包内置 iOS 静态库和 OpenCV framework，根工程的重复后处理已删除。SQLite 改为包自身固定的 `1.3.2` SemVer 依赖；验证工程只添加 OpenUPM 的 `com.gilzoide` scoped registry，不注入 SQLite dependency。最新 UPM 内容/repro 测试为 `3 passed`；Phase 0 验证的 Unity EditMode 为 `989/989` 且干净 UPM 安装成功；新的最小工程导出后 generic iOS Xcode Debug 构建报告 `BUILD SUCCEEDED`。验证工程只复制 `BuildiOS`、最小场景和场景管理脚本，未复制根工程的 `iOSPostProcess.cs`。

**涉及文件：**

- 新建：`unity_plugin/AreaTargetPlugin/Editor/iOSPostProcess.cs`
- 新建：`tools/phase1/validate_ios_upm_build.sh`
- 修改：`tests/phase0/test_upm_package.py`
- 修改：`tests/phase0/test_package_metadata.py`
- 修改：`tools/phase0/check_package_metadata.py`
- 修改：`unity_plugin/AreaTargetPlugin/Editor/AreaTargetPlugin.Editor.asmdef`
- 修改：`unity_plugin/AreaTargetPlugin/Tests/iOSBuildConfigTests.cs`
- 修改：`unity_plugin/AreaTargetPlugin/package.json`
- 修改：`unity_plugin/AreaTargetPlugin/CHANGELOG.md`
- 修改：`unity_plugin/AreaTargetPlugin/BUILD_PACKAGE.md`
- 修改：`tools/phase0/build_upm_package.py`
- 修改：`tools/phase0/validate_unity_package.sh`
- 删除：`unity_project/Assets/Editor/iOSPostProcess.cs`
- 修改：`unity_project/Assets/Editor/BuildiOS.cs`
- 修改：`unity_project/Assets/Plugins/iOS/libvisual_localizer.a`
- 修改：`.gitignore`

- [x] **步骤 1：添加失败的 UPM 内容和依赖测试**

在 `UPMiOSBuildIntegrationTests.cs` 或 Python UPM 内容测试中断言生成 tar 包包含：

```text
package/Editor/iOSPostProcess.cs
package/Runtime/Plugins/iOS/libvisual_localizer.a
package/Runtime/Plugins/iOS/opencv2.framework/
package/package.json
```

并断言 `package.json` 自身的 dependencies 含固定 SQLite 依赖；测试不得通过读取临时项目 manifest 的额外注入 URL 才通过。

- [x] **步骤 2：运行内容测试并确认失败**

运行：

```bash
venv/bin/python tools/phase0/build_upm_package.py
venv/bin/python -m pytest tests/phase0/test_upm_package.py -v
```

预期结果：新断言失败，因为 iOS 后处理仍只位于 `unity_project/Assets/Editor/`，framework 未作为 UPM 自包含依赖验证。

- [x] **步骤 3：迁移 iOS postprocess 到 UPM Editor**

将可复用的 `iOSPostProcess` 迁入 `unity_plugin/AreaTargetPlugin/Editor/iOSPostProcess.cs`。它必须：

1. 用 `PackageInfo.FindForAssembly` 找到当前包根路径。
2. 校验 `Runtime/Plugins/iOS/libvisual_localizer.a` 和 `opencv2.framework` 都存在。
3. 复制或引用 framework 至导出的 Xcode 工程。
4. 添加 OpenCV、`libc++`、`z`、`sqlite3` 以及 AR Foundation 所需系统 framework。
5. 缺少制品时抛出 `BuildFailedException`，打印包内期望路径。

`unity_project/Assets/Editor/iOSPostProcess.cs` 改为仅转发到包内实现，或删除重复实现以避免两个后处理同时修改 Xcode 工程。

- [x] **步骤 4：固定 SQLite 包解析与版本**

将 `package.json` 升级至 `1.3.0`，SQLite 依赖使用阶段 0 已验证的固定来源/版本。修改 `validate_unity_package.sh`，移除向验证工程 `manifest.json` 注入 SQLite URL 的逻辑；验证工程只声明当前 `.tgz`，让 UPM 解析该包的正式 dependencies。

- [x] **步骤 5：实现 generic-device iOS UPM build 验证脚本**

创建 `tools/phase1/validate_ios_upm_build.sh`。脚本必须：

1. 创建新的临时 Unity 工程，安装刚生成的 `.tgz`。
2. 复制最小 iOS sample 和构建入口，不复制 `unity_project/Assets/Editor/iOSPostProcess.cs`。
3. 运行 Unity `-executeMethod BuildiOS.BuildDevelopment`。
4. 对导出的工程运行：

```bash
xcodebuild \
  -project "$PROJECT/Builds/iOS_Dev/Unity-iPhone.xcodeproj" \
  -scheme Unity-iPhone \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

5. 检查输出包含 `BUILD SUCCEEDED`，并把构建日志保存在被忽略的 `phase1-results/`。

脚本使用 `set -euo pipefail`，失败时保留日志路径。

- [x] **步骤 6：运行 UPM 安装、Unity 导出与 Xcode 链接验证**

运行：

```bash
venv/bin/python tools/phase0/build_upm_package.py
tools/phase0/validate_unity_package.sh
tools/phase1/validate_ios_upm_build.sh
```

预期结果：三个命令均返回 0；验证工程没有依赖仓库测试项目的 Editor 后处理文件。

- [x] **步骤 7：提交任务 7**

```bash
git add \
  .gitignore \
  unity_plugin/AreaTargetPlugin/Editor/iOSPostProcess.cs \
  unity_plugin/AreaTargetPlugin/Editor/iOSPostProcess.cs.meta \
  tools/phase1/validate_ios_upm_build.sh \
  unity_plugin/AreaTargetPlugin/Editor/AreaTargetPlugin.Editor.asmdef \
  unity_plugin/AreaTargetPlugin/Tests/iOSBuildConfigTests.cs \
  unity_plugin/AreaTargetPlugin/package.json \
  unity_plugin/AreaTargetPlugin/CHANGELOG.md \
  unity_plugin/AreaTargetPlugin/BUILD_PACKAGE.md \
  tests/phase0/test_upm_package.py \
  tests/phase0/test_package_metadata.py \
  tools/phase0/build_upm_package.py \
  tools/phase0/check_package_metadata.py \
  tools/phase0/validate_unity_package.sh \
  unity_project/Assets/Editor/iOSPostProcess.cs \
  unity_project/Assets/Editor/iOSPostProcess.cs.meta \
  unity_project/Assets/Editor/BuildiOS.cs \
  unity_project/Assets/Plugins/iOS/libvisual_localizer.a \
  docs/superpowers/specs/phase-1-ios-workflow/tasks.md
git commit -m "feat: make UPM iOS build self-contained"
```

## 任务 8：新增阶段 1 统一验证入口与 CI 覆盖

**对应需求：** R1.6、R1.7

**可运行产物：** `tools/phase1/verify.sh` 在 `ci`、`local`、`device` 模式以明确 PASS/FAIL/SKIP 汇总阶段 1 门禁；CI 自动运行非设备验证。

> **进度（2026-07-13）：** 步骤 1–7 已完成。新增 driver 测试初次运行因 `tools/phase1/verify.sh` 不存在而按预期 `5 failed`；实现后使用替换 PATH 的假命令回归为 `6 passed`。`ci` 对所有 Unity 依赖项（包括干净 UPM 安装）明确 `SKIP`，原因是 GitHub-hosted CI 未配置 Unity 许可证或 iOS 签名；`local` 和 `device` 均将这些项视为必过门禁，避免假绿。`device` 会拒绝缺少 USB 可见 iPhone/iPad 的情形；若任一本地构建门禁失败，`device` 也会跳过 smoke，避免部署旧包；实际签名、部署和定位 smoke 将由任务 9 提供命令后通过 `PHASE1_DEVICE_SMOKE_COMMAND` 接入。
>
> **验证记录（2026-07-13）：** 完整 Python 回归为 `323 passed, 3 skipped, 4 warnings`，driver 回归为 `6 passed`，真实 `tools/phase1/verify.sh ci` 为 `PASS=5 FAIL=0 SKIP=6`，UPM 内容回归为 `3 passed`，脚本语法、YAML 解析和 `git diff --check` 均通过。本机 `local` 门禁已通过合同、Python、macOS/iOS native 和 UPM 内容阶段；随后 Unity Licensing Client 在进入 EditMode 前返回 `505 Unsupported protocol version '1.18.1'` 并持续重试。该进程已停止，故本机 Unity/Xcode 门禁**未通过、未被记录为绿灯**；需修复 Unity Hub/许可证客户端协议不匹配后重跑 `tools/phase1/verify.sh local`。

**涉及文件：**

- 新建：`tools/phase1/verify.sh`
- 新建：`tests/phase1/test_verify_driver.py`
- 修改：`.github/workflows/ci.yml`
- 修改：`TEST_PLAN.md`
- 修改：`README.md`
- 修改：`unity_plugin/AreaTargetPlugin/README.md`
- 修改：`docs/ios-device-test-guide.md`

- [x] **步骤 1：添加失败的 verify driver 测试**

创建 `tests/phase1/test_verify_driver.py`，用替换后的 PATH 假命令验证：

- `ci` 运行合同、Python、native、UPM 内容检查，并对 Unity/Xcode/设备明确 `SKIP`。
- `local` 缺 Unity 或 Xcode 时返回非零，不能静默跳过。
- `device` 缺少可见设备时返回非零并输出设备发现命令。
- 子检查失败时整个 driver 返回非零并保留失败步骤名称。

- [x] **步骤 2：运行测试并确认失败**

运行：

```bash
venv/bin/python -m pytest tests/phase1/test_verify_driver.py -v
```

预期结果：失败，因为 `tools/phase1/verify.sh` 尚不存在。

- [x] **步骤 3：实现三个显式模式**

`verify.sh` 使用以下检查序列：

```text
contract → Python pipeline → Unity EditMode → native macOS/iOS → UPM content
→ clean UPM install → Unity iOS export → generic Xcode build → device smoke
```

`ci` 运行前两项、native、UPM 内容和干净 UPM install；对 Unity iOS export、generic Xcode build 和 device smoke 打印 `SKIP` 及“GitHub-hosted CI 未配置 Unity/iOS signing”的原因。`local` 不允许跳过 Unity 和 generic Xcode build。`device` 在 `local` 基础上要求 `xcrun xctrace list devices` 发现一个 iPhone 和一个 iPad，分别执行 smoke 步骤。

- [x] **步骤 4：将非设备阶段 1 检查加入 CI**

在 `.github/workflows/ci.yml`：

- Linux Python job 运行 `venv` 等价的 `python -m pytest tests/phase1 tests/ -v --tb=short`。
- macOS job 运行 native build、iOS archive contract 和 `tools/phase1/verify.sh ci` 中不依赖 Unity 的部分。
- 明确注释 Unity/Xcode generic iOS 与真机仍为本地发布门禁，避免假绿。

工作流继续使用 `actions/checkout@v6` 和 `actions/setup-python@v6`，不得回退到 Node.js 20 runtime。

- [x] **步骤 5：更新操作文档**

在 `TEST_PLAN.md`、根 README、UPM README 与 `docs/ios-device-test-guide.md` 写入：三个 verify 模式、从 UPM 验证工程导出 iOS 的命令、诊断导出位置、iPhone/iPad 双设备要求、三场地/30 分钟验收定义和阶段 1 支持边界。

- [x] **步骤 6：运行本地验证**

运行：

```bash
venv/bin/python -m pytest --import-mode=importlib tests/phase1 tests/ -v --tb=short
tools/phase1/verify.sh ci
tools/phase1/verify.sh local
```

预期结果：前两个命令通过；第三个命令在具备 Unity/Xcode 时通过，缺失环境时必须明确失败而不是绿灯。记录真实结果。

- [x] **步骤 7：提交任务 8**

```bash
git add \
  tools/phase1/verify.sh \
  tests/phase1/test_verify_driver.py \
  .github/workflows/ci.yml \
  TEST_PLAN.md \
  README.md \
  unity_plugin/AreaTargetPlugin/README.md \
  docs/ios-device-test-guide.md \
  docs/superpowers/specs/phase-1-ios-workflow/tasks.md
git commit -m "test: add phase 1 iOS release gates"
```

## 任务 9：完成单地图 iPhone/iPad 真机闭环

**对应需求：** R1.3、R1.4、R1.5、R1.6

**可运行产物：** 同一张真实地图可由 iPhone 和 iPad 分别扫描/处理、在 Unity iOS 应用加载并定位，且各自导出隐私安全的诊断证据。

> **进度（2026-07-13）：** 步骤 1 已完成，步骤 2–7 待执行。设备预检未发现在线 iPhone 或 iPad：`xcrun xctrace list devices` 仅返回离线历史设备，因此尚未执行扫描、安装、运行或定位，也未写入任何设备 UDID。需要将至少一台 LiDAR iPhone 和一台 LiDAR iPad 解锁、信任此 Mac 并保持 USB 连接后继续。

**涉及文件：**

- 新建：`docs/phase-1-ios-validation.md`
- 新建：`docs/phase-1-device-acceptance-template.md`
- 修改：`docs/ios-device-test-guide.md`
- 修改：`unity_project/Assets/Scripts/ARTestSceneManager.cs`
- 修改：`unity_project/Assets/Scripts/SLAMTestScene/SLAMDebugPanel.cs`

- [x] **步骤 1：创建验收记录模板**

`docs/phase-1-device-acceptance-template.md` 必须包含固定字段：

```text
场地代号；面积范围；扫描设备型号/系统；运行设备型号/系统；
扫描器提交；处理管线提交；Unity 应用提交；UPM 版本；
map ID/version/hash；首次定位 UTC 时间；首次定位耗时；
失锁次数；恢复尝试次数；30 分钟开始/结束 UTC 时间；
诊断文件 SHA-256；结果；异常摘要。
```

模板不得要求或存放场地地址、图像、扫描 ZIP 或设备 UDID。

- [ ] **步骤 2：执行 iPhone 扫描与处理**

连接 LiDAR iPhone，使用扫描器采集一个 20–100 m² 场地。对导出 manifest 运行合同验证；使用文档化 Docker/Python 命令处理 ZIP，生成 map manifest、`features.db` 和资产。把原始 scan 和地图制品保留在受控本地存储，不提交 Git。

必须记录：命令、处理提交、map manifest hash 与 checker 输出摘要。

- [ ] **步骤 3：在干净 UPM iOS 工程上部署并构建**

使用任务 7 验证过的 `.tgz`，导出 Development iOS 工程，针对 iPhone 使用 Xcode 签名、编译、安装和启动。运行时加载刚生成的地图，确认 SQLite 和 native 初始化诊断均成功，再执行：

```bash
xcrun devicectl device info log --device <IPHONE_UDID>
```

预期结果：至少一次 `TRACKING`/`LOCALIZED`，且导出的诊断不含禁止内容。

- [ ] **步骤 4：在同一地图上执行 iPad 运行验证**

连接 LiDAR iPad，使用相同 UPM 包和同一 map manifest 构建/安装。完成相机权限、地图加载和至少一次成功定位，导出第二份诊断。若 iPad 也执行扫描，按任务 2 合同验证其扫描 manifest；本任务的定位使用同一已处理地图以验证跨设备运行。

- [ ] **步骤 5：验证失锁与恢复**

在每台设备定位成功后，将相机明确移出地图视野至少 10 秒，再返回目标区域，记录 tracking state 变化和恢复尝试。不得通过重启应用或重新加载地图伪造恢复；若未恢复，记录真实失败类别和诊断 hash。

- [ ] **步骤 6：运行每设备 30 分钟稳定性记录**

每台设备在定位成功后连续运行 30 分钟。期间保留应用运行、定期导出或最终导出诊断；记录任何 crash、native lifecycle failure、map reload、失锁与恢复。结束后使用：

```bash
shasum -a 256 /path/to/diagnostic.jsonl
rg -n "ImageData|JPEG|ScanData|/Users/|file://" /path/to/diagnostic.jsonl
```

预期结果：哈希生成，隐私扫描无输出，验收模板中有完整时间范围。

- [ ] **步骤 7：更新单地图验证报告并提交文档**

将匿名化结果写入 `docs/phase-1-ios-validation.md`：仅包含场地代号、版本、命令摘要、成功/失败、时长、诊断哈希和已知限制。不得添加原始设备日志、图像、ZIP、地图数据库或绝对路径。

```bash
git add \
  docs/phase-1-ios-validation.md \
  docs/phase-1-device-acceptance-template.md \
  docs/ios-device-test-guide.md \
  docs/superpowers/specs/phase-1-ios-workflow/tasks.md
git commit -m "docs: record phase 1 iOS smoke validation"
```

## 任务 10：完成三个场地、双设备的阶段验收与发布准备

**对应需求：** R1.5、R1.6、R1.7

**可运行产物：** 六次设备-场地运行的验收报告、`v1.3.0` UPM 制品和可回滚发布候选。

**涉及文件：**

- 修改：`docs/phase-1-ios-validation.md`
- 修改：`docs/phase-1-device-acceptance-template.md`
- 修改：`unity_plugin/AreaTargetPlugin/CHANGELOG.md`
- 修改：`README.md`
- 修改：`unity_plugin/AreaTargetPlugin/README.md`
- 修改：`TEST_PLAN.md`
- 修改：`docs/superpowers/specs/phase-1-ios-workflow/tasks.md`

- [ ] **步骤 1：定义三个匿名场地和设备矩阵**

在验证报告中登记 `IOS-P1-A`、`IOS-P1-B`、`IOS-P1-C` 三个不含地址的场地代号，每个场地面积必须在 20–100 m²。建立六行矩阵：

```text
IOS-P1-A × iPhone
IOS-P1-A × iPad
IOS-P1-B × iPhone
IOS-P1-B × iPad
IOS-P1-C × iPhone
IOS-P1-C × iPad
```

每行复制任务 9 的固定验收字段。

- [ ] **步骤 2：逐场地完成扫描、处理和双设备定位**

对每个场地：至少使用一台 LiDAR iOS 设备生成符合任务 2 合同的扫描，运行固定处理版本产生 map manifest；然后在 iPhone 与 iPad 上使用同一发布候选包加载该地图并至少成功定位一次。每次运行保留各自诊断 hash。

不能将一个场地的成功诊断复制到另一个场地或设备行；map hash、设备型号和时间范围必须独立记录。

- [ ] **步骤 3：逐行完成 30 分钟稳定性与失锁恢复验证**

每一行在至少一次成功定位后连续运行 30 分钟，并执行一次受控失锁/恢复尝试。记录实际首次定位耗时、失锁次数、恢复结果和任何异常。阶段 1 不规定阶段 3 的精度/帧率阈值，但不得把 crash、未处理 lifecycle failure 或隐私导出违规标记为通过。

- [ ] **步骤 4：运行完整发布门禁**

运行：

```bash
tools/phase0/verify.sh local
tools/phase1/verify.sh local
tools/phase1/verify.sh device
venv/bin/python tools/phase0/build_upm_package.py
tools/phase1/validate_ios_upm_build.sh
```

预期结果：所有适用检查通过。若设备门禁因任一 iPhone/iPad/场地失败，阶段 1 保持未完成并在报告中写入失败行；不得跳过该行。

- [ ] **步骤 5：完成版本与支持声明审查**

确认：

```bash
venv/bin/python tools/phase0/check_package_metadata.py \
  unity_plugin/AreaTargetPlugin/package.json
rg -n "Rokid|Android ARM64|Windows|Linux" README.md \
  unity_plugin/AreaTargetPlugin/README.md \
  docs/phase-1-ios-validation.md
```

预期结果：包版本为 `1.3.0`；文档仅声明已验证的 iOS 范围，Rokid/Android 等仍明确属于后续阶段。

- [ ] **步骤 6：更新最终报告与提交发布候选文档**

在 `docs/phase-1-ios-validation.md` 汇总六行矩阵、所有工具版本、commit、UPM SHA-256、诊断 hash、通过/失败和回滚目标 `d656f09`。在 CHANGELOG 写 `1.3.0` 的用户可见变化、已验证设备类型和不支持的平台。

```bash
git add \
  docs/phase-1-ios-validation.md \
  docs/phase-1-device-acceptance-template.md \
  unity_plugin/AreaTargetPlugin/CHANGELOG.md \
  README.md \
  unity_plugin/AreaTargetPlugin/README.md \
  TEST_PLAN.md \
  docs/superpowers/specs/phase-1-ios-workflow/tasks.md
git commit -m "docs: complete phase 1 iOS acceptance evidence"
```

- [ ] **步骤 7：按受控 CI 流程发布**

仅在任务 10 的全部验收行和本地门禁通过后，使用既定顺序：

```text
develop CI success
→ merge/push main
→ main CI success
→ merge/push publish
→ publish CI success
```

记录三个分支提交 SHA、CI run ID 和任何非阻塞警告。未通过任何一段 CI 时立即停止后续提升，不强推、不重写共享分支。

## 最终自检清单

- [ ] requirements.md 的 R1.1–R1.7 都至少由一个已完成任务覆盖。
- [ ] design.md 中每个新 Runtime 组件都有实现、测试和运行入口。
- [ ] 所有 six device-area 验收行均有独立的匿名化证据和 30 分钟记录。
- [ ] UPM 包能在干净 Unity 项目中导出并链接 generic iOS device。
- [ ] 诊断导出默认不含图像、扫描 ZIP、绝对路径或设备 UDID。
- [ ] README、CHANGELOG、包版本、验证报告与 UPM 包名均为 `1.3.0`。
- [ ] publish CI 成功后才标记阶段 1 完成。
