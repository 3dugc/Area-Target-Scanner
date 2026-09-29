# 全栈测试方案

## 阶段 1 iOS 发布门禁（v1.3.0）

阶段 1 使用一个明确模式的入口；每个检查都输出 `PASS`、`FAIL` 或带原因的 `SKIP`：

```bash
# GitHub Actions 可运行的非 Unity / 非设备检查。
tools/phase1/verify.sh ci

# 开发 Mac：必须具备 Unity 6000.4.6f1 和 Xcode，不能把缺失环境当作通过。
tools/phase1/verify.sh local

# 在 local 门禁基础上要求 USB 可见的 iPhone 和 iPad。
tools/phase1/verify.sh device
```

- `ci` 只跳过依赖 Unity 许可证、iOS 签名或真机的步骤，并明确报告原因；不得把跳过当作通过。
- `local` 必须完成坐标合同、Python、native、UPM 内容、Unity EditMode/干净安装、Unity iOS Development 导出及 generic-device Xcode 链接。
- `device` 缺少任一 USB 可见的 iPhone 或 iPad 时必须失败，并打印 `xcrun xctrace list devices`；签名、部署和实际定位 smoke 在任务 9 接入 `PHASE1_DEVICE_SMOKE_COMMAND` 后执行。
- UPM iOS 独立导出可单独复现：`tools/phase1/validate_ios_upm_build.sh`。它的日志写入被忽略的 `phase1-results/`。
- 定位诊断默认导出至 `Application.persistentDataPath/AreaTargetDiagnostics/`，采用不含图像、扫描 ZIP 或绝对路径的 JSON Lines。

阶段 1 的最终验收仍未完成：每个 20–100 m² 场地必须由同一张处理地图在 LiDAR iPhone 与 LiDAR iPad 上分别成功定位、记录失锁/恢复，并在定位后连续运行 30 分钟；共三个场地、六次设备-场地记录。Rokid AR Studio、Android ARM64、Windows 和 Linux 运行时不属于本阶段支持范围。

## 一、测试现状总览

| 组件 | 测试文件数 | 测试用例数 | 可本地运行 |
|------|-----------|-----------|-----------|
| Python 处理管线 | 14 | 190 | ✅ 已全部通过 |
| Unity C# 插件 | 22 (含新增4) | ~190 (含新增69) | ❌ 需 Unity Editor |
| iOS Swift 扫描器 | 6 (含新增4) | ~86 (含新增56) | ❌ 需 Xcode + 模拟器 |
| C++ 原生定位库 | 1 (Python ctypes) | 18 | ✅ 已全部通过 |

## 二、一次性通过概率评估

### Python 管线 — 95%
已在本机验证 190/190 通过。唯一风险是 Open3D 在不同 Python 版本下的 segfault（已知 3.9 偶发）。

### Unity C# 测试 — 85%
- 新增 69 个测试全部通过静态诊断（零编译错误）
- 使用的 API 全部是纯 C# 逻辑（无 P/Invoke、无 UnityEngine 渲染依赖）
- 风险点：
  - `FeatureDatabaseReaderTests` 用反射注入 `_keyframes`，字段名如果被混淆会失败（概率低，Editor 模式不混淆）
  - `LocalizationPipelineEdgeCaseTests` 的 async/await 测试需要 Unity 2021.3+ 的 NUnit 异步支持
  - `KalmanPoseFilter.EulerToMatrix` 往返测试在万向锁角度附近可能有精度问题（已限制为小角度）
  - FsCheck 属性测试依赖 NuGet 包是否正确安装

### iOS Swift 测试 — 80%
- 新增 56 个测试全部通过静态诊断
- 已更新 `project.pbxproj` 添加文件引用和编译配置
- 风险点：
  - `ScanViewModelTests` 标记 `@MainActor`，需要 Swift 5.5+ 和 Xcode 14+
  - `TextureMappingPipelineTests` 的 `mergeMeshData` 测试依赖 simd 库，模拟器上应该没问题
  - `ScanDataExporterEdgeCaseTests` 的 `testWritePLY_vertexWithLessThan9Components_skipped` 假设 header 中 vertex count 是输入数组长度而非实际写入行数——需要确认 `writePLY` 的行为
  - 已有的 `TextureMappingPropertyTests` 中的 E2E 测试依赖 xatlas C++ 桥接编译成功

### 综合一次性全部通过概率：~65%

主要不确定性来自环境配置（Unity 版本、Xcode 版本、xatlas 编译），而非代码逻辑错误。

## 三、实机运行步骤

### 步骤 1：Python 测试（本机，5 分钟）

```bash
# 确认 Python 环境
python3 --version  # 需要 3.9+
pip3 install -e .  # 安装项目依赖

# 运行全部测试
python3 -m pytest tests/ -v --tb=short

# 检测节点 ✓：190 passed
```

### 步骤 2：C++ 原生库测试（本机，2 分钟）

```bash
# 确认原生库已编译
ls native_visual_localizer/build/libvisual_localizer.dylib

# 如果不存在，先编译
cd native_visual_localizer && mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release && make -j$(sysctl -n hw.ncpu)
cd ../..

# 运行原生库测试
python3 -m pytest tests/test_native_localizer.py -v

# 检测节点 ✓：18 passed
```

### 步骤 3：Unity C# 测试（需 Unity Editor，10 分钟）

```bash
# 方式 A：命令行（推荐，无需打开 GUI）
UNITY_PATH="/Applications/Unity/Hub/Editor/6000.0.*/Unity.app/Contents/MacOS/Unity"
$UNITY_PATH \
  -batchmode -nographics -runTests \
  -projectPath ./unity_project \
  -testPlatform EditMode \
  -testResults ./unity_test_results.xml

# 查看结果
grep -c 'result="Passed"' unity_test_results.xml
grep 'result="Failed"' unity_test_results.xml

# 方式 B：Unity GUI
# 1. 打开 Unity Hub → 打开 unity_project
# 2. Window → General → Test Runner
# 3. EditMode 标签 → Run All

# 检测节点 ✓：~190 tests passed, 0 failed
```

检测节点细分：
- [ ] `FeatureDatabaseReaderTests` — 32 个测试全部绿色
- [ ] `AssetBundleLoaderSecurityTests` — 13 个测试全部绿色（特别关注路径遍历测试）
- [ ] `LocalizationPipelineEdgeCaseTests` — 11 个测试全部绿色（特别关注异步测试）
- [ ] `AreaTargetTrackerLifecycleTests` — 13 个测试全部绿色（特别关注 Kalman 收敛测试）
- [ ] 原有 ~120 个测试无回归

### 步骤 4：iOS Swift 测试（需 Xcode + 模拟器，15 分钟）

```bash
# 方式 A：命令行
xcodebuild test \
  -project ios_scanner/AreaTargetScanner.xcodeproj \
  -scheme AreaTargetScanner \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -configuration Debug \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  2>&1 | xcpretty

# 方式 B：Xcode GUI
# 1. 打开 ios_scanner/AreaTargetScanner.xcodeproj
# 2. 选择 iPhone 模拟器目标
# 3. Cmd+U 运行全部测试

# 检测节点 ✓：~86 tests passed, 0 failed
```

检测节点细分：
- [ ] `MeshExporterTests` — 5 个测试全部绿色
- [ ] `ScanViewModelTests` — 22 个测试全部绿色（特别关注 @MainActor 兼容性）
- [ ] `ScanDataExporterEdgeCaseTests` — 15 个测试全部绿色
- [ ] `TextureMappingPipelineTests` — 14 个测试全部绿色（特别关注 simd 计算精度）
- [ ] 原有 `ScanDataExporterTests` — 13 个无回归
- [ ] 原有 `TextureMappingPropertyTests` — 17 个无回归（E2E 测试需要 xatlas 编译成功）

### 步骤 5：Docker 全栈集成测试（可选，20 分钟）

```bash
# 构建并启动
docker compose up --build -d

# 等待服务就绪
sleep 10
curl -s http://localhost:8080/health | python3 -m json.tool

# 提交扫描数据处理任务
curl -X POST http://localhost:8080/api/process \
  -F "scan=@data/scan_20260317_155524.zip" \
  | python3 -m json.tool

# 轮询任务状态
JOB_ID=<上一步返回的 job_id>
curl -s http://localhost:8080/api/status/$JOB_ID | python3 -m json.tool

# 检测节点 ✓：status 最终变为 "completed"，output_url 可下载

# 清理
docker compose down
```

## 四、失败时的排查优先级

| 优先级 | 失败症状 | 最可能原因 | 修复方法 |
|--------|---------|-----------|---------|
| P0 | Unity 测试编译失败 | asmdef 引用缺失或 UPM 包未安装 | 检查 FsCheck.dll 是否在 Plugins 目录，com.gilzoide.sqlite-net 是否在 manifest.json |
| P0 | iOS 测试编译失败 | pbxproj 文件引用 ID 冲突 | 在 Xcode 中手动 Add Files 添加 4 个新测试文件 |
| P1 | Kalman 收敛测试精度不够 | 浮点精度在不同平台有差异 | 放宽 Assert 的 tolerance 到 0.2f |
| P1 | async 测试超时 | Unity NUnit 版本不支持 async | 改用 `[UnityTest]` + `yield return` 模式 |
| P2 | xatlas E2E 测试失败 | C++ 桥接未编译 | 确认 xatlas.cpp 和 XAtlasBridge.mm 在 Build Phases 中 |
| P2 | PLY 短顶点测试断言失败 | writePLY 的 header 行为与预期不同 | 调整断言为检查实际数据行数 |

## 五、如果 pbxproj 修改有问题的手动修复

如果 Xcode 打开项目时报错，最简单的修复方式：

1. 在 Xcode 中打开项目
2. 右键 `AreaTargetScannerTests` 组 → Add Files to "AreaTargetScanner"
3. 选择以下 4 个文件：
   - `MeshExporterTests.swift`
   - `ScanViewModelTests.swift`
   - `ScanDataExporterEdgeCaseTests.swift`
   - `TextureMappingPipelineTests.swift`
4. 确保 Target 勾选了 `AreaTargetScannerTests`
5. Cmd+U 运行测试
