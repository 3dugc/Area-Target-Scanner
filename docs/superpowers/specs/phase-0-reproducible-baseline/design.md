# 阶段 0：可重复构建基线设计

## 1. 设计原则

阶段 0 采用最小改动策略：保留当前 Swift、Python、C++ 和 Unity 目录结构，只修改仓库卫生、版本元数据、构建脚本、验证脚本、CI、打包和相关文档。

定位算法、资产格式、公开 Unity API、Docker 服务名和端口均保持不变。

## 2. 组件与职责

### 2.1 元数据检查器

`tools/phase0/check_package_metadata.py` 负责：

- 使用拒绝重复键的 JSON loader 读取 `package.json`。
- 校验版本为 `1.2.1`。
- 校验 AR Foundation 和 SQLite 依赖。
- 输出供 shell 和 CI 使用的规范版本号。

### 2.2 仓库卫生检查

`tests/phase0/test_repository_hygiene.py` 使用 `git ls-files` 检查禁止跟踪的文件模式。真实回归 fixture 使用显式允许列表，并在 `StreamingAssets/README.md` 中登记。

### 2.3 原生符号契约

`tools/phase0/required_native_symbols.txt` 保存稳定的 C API 名称。`tools/phase0/check_native_symbols.sh` 接受一个库路径，检查：

- 文件存在且非空。
- 可识别的目标架构。
- `nm` 输出包含每个契约符号。

`build_macos.sh` 构建后调用该检查器。`build_ios.sh` 复用相同契约，不再维护另一份符号列表。

### 2.4 可重复 UPM 打包器

`tools/phase0/build_upm_package.py` 在临时目录构造 `package/`：

1. 复制 `unity_plugin/AreaTargetPlugin` 的运行时、编辑器、Samples 和元数据。
2. 排除测试目录、旧归档和生成物。
3. 从 Unity 测试工程复制已验证的 macOS/iOS 原生制品到 `Runtime/Plugins`。
4. 规范 tar 条目的时间、uid、gid 和顺序。
5. 输出 `dist/com.areatarget.tracking-<version>.tgz`。

包内容通过 `tests/phase0/test_upm_package.py` 检查，不依赖人工解包判断。

### 2.5 统一验证驱动

`tools/phase0/verify.sh` 只负责顺序编排，不在脚本中复制各组件的实现逻辑。

```text
metadata
  → repository hygiene
  → Python tests
  → Docker config/build
  → macOS native build/symbols
  → iOS archive symbols
  → iOS scanner compile
  → Unity EditMode tests
  → UPM build/content check
  → clean Unity install
```

驱动提供两个显式模式：

- `local`：发布前完整门禁，Unity 或 Xcode 缺失即失败。
- `ci`：仅允许跳过需要授权或连接设备的检查，并打印 `SKIP` 原因。

### 2.6 CI

现有 workflow 分为：

- Linux Python/metadata/package job。
- Linux Docker image job。
- macOS native build/symbol job。
- Unity job 在凭据准备后启用；此前由文档化本地门禁承担。

每个 job 上传必要的文本结果或包清单，不上传扫描图像。

## 3. 文件结构

### 新建

```text
tools/phase0/check_package_metadata.py
tools/phase0/check_native_symbols.sh
tools/phase0/required_native_symbols.txt
tools/phase0/build_upm_package.py
tools/phase0/verify.sh
tools/phase0/validate_unity_package.sh
tests/phase0/test_package_metadata.py
tests/phase0/test_repository_hygiene.py
tests/phase0/test_native_contract.py
tests/phase0/test_upm_package.py
tests/phase0/test_verify_driver.py
unity_project/Assets/StreamingAssets/README.md
docs/phase-0-validation.md
```

### 修改

```text
.gitignore
.github/workflows/ci.yml
README.md
TEST_PLAN.md
native_visual_localizer/build_macos.sh
native_visual_localizer/build_ios.sh
unity_plugin/AreaTargetPlugin/package.json
unity_plugin/AreaTargetPlugin/CHANGELOG.md
unity_plugin/AreaTargetPlugin/README.md
unity_plugin/AreaTargetPlugin/BUILD_PACKAGE.md
unity_project/Assets/Editor/PackageExporter.cs
requirements-dev.txt
```

### 删除或停止跟踪

- `unity_project/mono_crash.*.json`
- 根目录和意外嵌套目录中的历史 Unity 测试 XML。
- `SLAMTestAssets` 中的 `.bak2`、`.data1_bak` 及对应 `.meta`。
- 空的 Windows/Linux 原生占位文件及对应 `.meta`。
- 仓库内旧 `1.2.0` 二进制归档；历史版本由 Git 标签保留。

## 4. 数据与控制流

### 4.1 版本流

```text
package.json.version
  → metadata checker
  → PackageExporter display/output name
  → Python UPM packager output name
  → verification report
  → CHANGELOG release entry
```

### 4.2 包生成流

```text
current package source
  + verified macOS dylib
  + verified iOS static archive
  → deterministic staging directory
  → content allow/deny validation
  → reproducible tgz in dist/
  → clean Unity install validation
```

### 4.3 错误处理

- Python 工具把用户输入或元数据错误写到 stderr，并返回 2。
- 构建或外部命令失败保留原始退出码。
- shell 检查器使用 `set -euo pipefail`。
- 缺少 Unity/Xcode 在 `local` 模式是 `FAIL`；仅在 `ci` 模式且对应门禁明确外置时是 `SKIP`。
- 包内容缺失或包含禁止文件是硬失败。
- 验证脚本不修改源码；所有输出进入被忽略的 `build/`、`dist/` 或 `/tmp`。

## 5. 测试设计

### 元数据测试

- 重复键必须失败。
- 错误版本必须失败。
- 缺少 AR Foundation/SQLite 依赖必须失败。
- 正确文件输出 `1.2.1`。

### 仓库卫生测试

- 每个禁止模式使用一个合成路径证明会被拒绝。
- 允许的 fixture 必须存在于说明文档。
- 当前 `git ls-files` 结果不得命中禁止模式。

### 原生契约测试

- 缺失文件、空文件和缺失符号分别失败。
- 当前 iOS archive 必须通过架构和符号检查。
- macOS 构建产物必须通过相同符号列表。

### UPM 包测试

- 必需源码和原生制品存在。
- 测试代码、旧归档、备份和占位二进制不存在。
- tar 根目录固定为 `package/`。
- 连续两次打包的 SHA-256 一致。

### 验证驱动测试

- 子检查失败时驱动返回非零。
- `local` 模式不允许静默跳过 Unity/Xcode。
- `ci` 模式的跳过必须输出原因。
- 全部子检查成功时返回零。

## 6. 兼容性

- 资产 bundle 版本保持 `2.0`。
- 扫描 ZIP 结构不变。
- ORB、AKAZE、BoW、PnP、consistency 和 alignment 代码不变。
- Unity 公开类型及方法签名不变。
- Docker 服务名和 `8080` 对外端口不变。
- 干净 Unity 验证项目在根 `manifest.json` 中同时固定 SQLite Git URL 和本地 Area Target `.tgz`，不依赖未配置的第三方 registry。
- 旧 `1.2.0` 可通过 Git 历史恢复，但不再作为当前安装入口。

## 7. 发布与回滚

阶段 0 完成时生成 `1.2.1` UPM 包和验证报告。创建标签、推送远端或发布 GitHub Release 属于外部状态变更，必须在完整本地门禁和 CI 通过后由用户明确授权。

回滚目标固定为 `81d815f18eac1a55babd21dbfc2c3a7726942e84`。
