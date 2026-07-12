# 阶段 0：可重复构建基线实施计划

> **面向 AI 执行者：** 必须使用 `superpowers:subagent-driven-development` 或 `superpowers:executing-plans`，逐项实施本计划。步骤使用复选框（`- [ ]`）跟踪。当前用户要求由单一 AI 执行，因此除非该约束发生变化，否则使用 `superpowers:executing-plans`。

**目标：** 建立干净、可重复的 `v1.2.1` 基线，使扫描器、Docker 流水线、Python 测试套件、原生制品、Unity 测试和 UPM 包都能从干净检出状态完成验证。

**架构：** 保留现有 Swift/Python/C++/Unity 架构。在 `tools/phase0` 下增加小型验证和打包工具，以 `package.json` 作为版本唯一来源，清理仓库中的生成物，并通过一个快速失败的统一入口编排现有构建和测试命令。

**技术栈：** Python 3.11、Bash/zsh、Docker Compose、CMake/OpenCV、Xcode、Unity 6000.3.11f1、UPM、GitHub Actions。

**事实来源：** 本目录中的 `requirements.md` 和 `design.md`。

---

## 进度规则

- 按编号顺序执行任务。
- 只有在命令产生预期结果后，才能勾选对应子步骤。
- 在所有必需子步骤完成前，父任务保持未勾选。
- 每个任务提交前，更新本文件中的完成状态，并将 `tasks.md` 包含在同一次提交中。
- 在受影响的复选框下记录阻塞原因，不得用“已通过”的表述替代真实结果。
- 本计划不实施 Rokid、Android ARM64、坐标对齐、异步定位或算法调优。

## 任务 1：统一包元数据和版本

> 进度：已完成。提交：`53aa72b`。

**对应需求：** R0.2、R0.3

**涉及文件：**

- 新建：`tools/phase0/check_package_metadata.py`
- 新建：`tests/phase0/test_package_metadata.py`
- 修改：`unity_plugin/AreaTargetPlugin/package.json`
- 修改：`unity_plugin/AreaTargetPlugin/CHANGELOG.md`
- 修改：`unity_project/Assets/Editor/PackageExporter.cs`

- [x] **步骤 1：添加预期失败的元数据测试**

新建 `tests/phase0/test_package_metadata.py`：

```python
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "tools/phase0/check_package_metadata.py"
PACKAGE_JSON = ROOT / "unity_plugin/AreaTargetPlugin/package.json"


def run_checker(path: Path):
    return subprocess.run(
        [sys.executable, str(CHECKER), str(path)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )


def test_current_package_metadata_is_canonical():
    result = run_checker(PACKAGE_JSON)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "1.2.1"


def test_duplicate_json_key_is_rejected(tmp_path):
    path = tmp_path / "package.json"
    path.write_text('{"version":"1.2.1","dependencies":{},"dependencies":{}}')
    result = run_checker(path)
    assert result.returncode != 0
    assert "duplicate key" in result.stderr.lower()


def test_required_dependencies_are_enforced(tmp_path):
    data = json.loads(PACKAGE_JSON.read_text())
    data["dependencies"].pop("com.gilzoide.sqlite-net", None)
    path = tmp_path / "package.json"
    path.write_text(json.dumps(data))
    result = run_checker(path)
    assert result.returncode != 0
    assert "com.gilzoide.sqlite-net" in result.stderr
```

- [x] **步骤 2：运行元数据测试并确认失败**

运行：

```bash
python3 -m pytest tests/phase0/test_package_metadata.py -v
```

预期结果：失败，因为检查器尚不存在，并且 `package.json` 仍包含重复的 `dependencies` 键，版本仍为 `1.2.0`。

- [x] **步骤 3：实现严格的元数据检查器**

新建 `tools/phase0/check_package_metadata.py`：

```python
#!/usr/bin/env python3
import json
import sys
from pathlib import Path

EXPECTED_VERSION = "1.2.1"
EXPECTED_DEPENDENCIES = {
    "com.unity.xr.arfoundation": "6.0.0",
    "com.gilzoide.sqlite-net": "1.3.2",
}


def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key: {key}")
        result[key] = value
    return result


def main() -> int:
    path = Path(sys.argv[1])
    try:
        data = json.loads(path.read_text(), object_pairs_hook=reject_duplicates)
        if data.get("version") != EXPECTED_VERSION:
            raise ValueError(f"version must be {EXPECTED_VERSION}")
        dependencies = data.get("dependencies", {})
        for name, version in EXPECTED_DEPENDENCIES.items():
            if dependencies.get(name) != version:
                raise ValueError(f"{name} must be {version}")
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"metadata error: {exc}", file=sys.stderr)
        return 2
    print(data["version"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [x] **步骤 4：规范化 `package.json` 并将版本设为 `1.2.1`**

只保留一个 `dependencies` 对象，内容必须为：

```json
"dependencies": {
  "com.unity.xr.arfoundation": "6.0.0",
  "com.gilzoide.sqlite-net": "1.3.2"
}
```

设置：

```json
"version": "1.2.1"
```

- [x] **步骤 5：移除 PackageExporter 中独立维护的版本常量**

将 `PackageExporter.cs` 中的版本常量替换为包元数据读取逻辑：

```csharp
[System.Serializable]
private class PackageManifest
{
    public string version;
}

private static string ReadPackageVersion()
{
    const string manifestPath = "Packages/com.areatarget.tracking/package.json";
    var json = File.ReadAllText(Path.GetFullPath(manifestPath));
    var manifest = JsonUtility.FromJson<PackageManifest>(json);
    if (manifest == null || string.IsNullOrWhiteSpace(manifest.version))
        throw new InvalidDataException($"Missing version in {manifestPath}");
    return manifest.version;
}
```

构造输出文件名时使用 `ReadPackageVersion()`。

- [x] **步骤 6：添加 `1.2.1` 变更日志条目**

只记录阶段 0 的元数据、打包、验证、CI 和仓库卫生变更，不得宣称支持 Rokid 或 Android。

- [x] **步骤 7：运行元数据测试**

运行：

```bash
python3 -m pytest tests/phase0/test_package_metadata.py -v
```

预期结果：全部测试通过，检查器标准输出为 `1.2.1`。

- [x] **步骤 8：提交任务 1**

```bash
git add tools/phase0/check_package_metadata.py tests/phase0/test_package_metadata.py unity_plugin/AreaTargetPlugin/package.json unity_plugin/AreaTargetPlugin/CHANGELOG.md unity_project/Assets/Editor/PackageExporter.cs docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git commit -m "chore: establish canonical package version"
```

## 任务 2：仓库卫生与测试夹具归属

> 进度：已完成。提交：`ae3f7c4`。

**对应需求：** R0.1

**涉及文件：**

- 新建：`tests/phase0/test_repository_hygiene.py`
- 新建：`unity_project/Assets/StreamingAssets/README.md`
- 修改：`.gitignore`
- 删除：下文列出的 XML、崩溃和备份生成物

- [x] **步骤 1：添加预期失败的仓库卫生测试**

新建 `tests/phase0/test_repository_hygiene.py`：

```python
import re
import subprocess

FORBIDDEN = [
    re.compile(r"^unity_project/mono_crash\..*\.json$"),
    re.compile(r"^unity_project/(?:.*?/)?(?:TestResults|test_results|unity_test_results|pbt_).*\.xml$"),
    re.compile(r"\.(?:bak2|data1_bak)(?:\.meta)?$"),
    re.compile(r"^unity_project/unity_project/"),
]


def test_generated_artifacts_are_not_tracked():
    tracked = subprocess.check_output(
        ["git", "ls-files"], text=True
    ).splitlines()
    violations = [
        path for path in tracked if any(pattern.search(path) for pattern in FORBIDDEN)
    ]
    assert violations == []
```

- [x] **步骤 2：运行仓库卫生测试并确认其列出现有生成物**

运行：

```bash
python3 -m pytest tests/phase0/test_repository_hygiene.py -v
```

预期结果：失败，并列出当前受 Git 跟踪的崩溃、XML 和备份路径。

- [x] **步骤 3：清理前证明保留夹具仍被使用**

运行：

```bash
rg -n "SLAMTestAssets|StreamingAssets/ScanData" unity_plugin unity_project tests
```

预期结果：现有测试引用 `SLAMTestAssets` 和已录制扫描序列；保留这些规范文件。

- [x] **步骤 4：从 Git 中移除生成物**

移除以下明确的生成物分组：

```bash
git rm unity_project/mono_crash.*.json
git rm unity_project/TestResults-*.xml unity_project/debug/unity_test_results_slam.xml
git rm unity_project/pbt_results_final.xml unity_project/pbt_test_results*.xml
git rm unity_project/test_results_*.xml unity_project/unity_test_results.xml
git rm -r unity_project/unity_project
git rm unity_project/Assets/StreamingAssets/SLAMTestAssets/*.bak2*
git rm unity_project/Assets/StreamingAssets/SLAMTestAssets/*.data1_bak*
```

- [x] **步骤 5：扩展 `.gitignore`**

添加：

```gitignore
# 生成的验证报告
unity_project/*test_results*.xml
unity_project/TestResults-*.xml
unity_project/pbt_*.xml
unity_project/mono_crash.*.json
unity_project/unity_project/

# 资产备份变体
*.bak2
*.bak2.meta
*.data1_bak
*.data1_bak.meta

# 阶段 0 构建产物
dist/
phase0-results/
```

- [x] **步骤 6：记录保留的测试夹具**

新建 `unity_project/Assets/StreamingAssets/README.md`，列出：

- `SLAMTestAssets`：Unity 定位回归测试使用的确定性打包资产。
- `ScanData` 和 `ScanData_data1`：回放及跨会话测试使用的录制序列。
- 替换这些夹具时，必须同步更新相关测试并记录来源和日期。

- [x] **步骤 7：运行仓库卫生测试和完整仓库搜索**

```bash
python3 -m pytest tests/phase0/test_repository_hygiene.py -v
git ls-files | rg 'mono_crash|test_results|TestResults|\.bak2|data1_bak' && exit 1 || true
```

预期结果：仓库卫生测试通过；搜索不输出任何受跟踪的匹配项。

- [x] **步骤 8：提交任务 2**

```bash
git add .gitignore tests/phase0/test_repository_hygiene.py unity_project/Assets/StreamingAssets/README.md docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git add -u unity_project
git commit -m "chore: remove generated repository artifacts"
```

## 任务 3：原生符号契约与占位文件清理

> 进度：进行中。步骤 1–7 已验证完成，正在执行步骤 8 提交。macOS 默认构建当前主机 `arm64` 架构；可通过 `MACOS_ARCHITECTURES` 覆盖，避免使用仅含 arm64 的 Homebrew OpenCV 伪造通用二进制。

**对应需求：** R0.4

**涉及文件：**

- 新建：`tools/phase0/required_native_symbols.txt`
- 新建：`tools/phase0/check_native_symbols.sh`
- 新建：`tests/phase0/test_native_contract.py`
- 修改：`native_visual_localizer/build_macos.sh`
- 修改：`native_visual_localizer/build_ios.sh`
- 删除：空的 Windows/Linux 占位二进制及对应 `.meta`

- [x] **步骤 1：定义必需的原生 API**

新建 `tools/phase0/required_native_symbols.txt`：

```text
vl_create
vl_destroy
vl_add_vocabulary_word
vl_add_keyframe
vl_add_keyframe_akaze
vl_build_index
vl_process_frame
vl_process_frame_out
vl_reset
vl_set_alignment_transform
vl_get_debug_info
```

- [x] **步骤 2：添加预期失败的原生契约测试**

新建 `tests/phase0/test_native_contract.py`：

```python
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "tools/phase0/check_native_symbols.sh"
IOS_LIB = ROOT / "unity_project/Assets/Plugins/iOS/libvisual_localizer.a"


def test_ios_archive_matches_native_contract():
    result = subprocess.run([str(CHECKER), str(IOS_LIB)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_empty_library_is_rejected(tmp_path):
    empty = tmp_path / "empty.so"
    empty.touch()
    result = subprocess.run([str(CHECKER), str(empty)], text=True, capture_output=True)
    assert result.returncode != 0
    assert "empty" in (result.stdout + result.stderr).lower()
```

- [x] **步骤 3：运行测试并确认因缺少检查器而失败**

```bash
python3 -m pytest tests/phase0/test_native_contract.py -v
```

预期结果：失败，因为检查器尚不存在。

- [x] **步骤 4：实现原生检查器**

新建可执行文件 `tools/phase0/check_native_symbols.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${1:?usage: check_native_symbols.sh <library>}"
SYMBOLS="$ROOT/tools/phase0/required_native_symbols.txt"

if [[ ! -f "$LIB" ]]; then
  echo "FAIL missing library: $LIB" >&2
  exit 2
fi
if [[ ! -s "$LIB" ]]; then
  echo "FAIL empty library: $LIB" >&2
  exit 2
fi

file "$LIB"
NM_OUTPUT="$(nm "$LIB")"
while IFS= read -r symbol; do
  [[ -z "$symbol" ]] && continue
  if ! grep -Eq "[[:space:]_]${symbol}$" <<<"$NM_OUTPUT"; then
    echo "FAIL missing symbol: $symbol" >&2
    exit 3
  fi
done < "$SYMBOLS"

echo "PASS native contract: $LIB"
```

运行 `chmod +x tools/phase0/check_native_symbols.sh`。

- [x] **步骤 5：两个构建脚本复用同一契约**

将重复的 `nm | grep` 列表替换为：

```bash
"$SCRIPT_DIR/../tools/phase0/check_native_symbols.sh" "$OUTPUT_LIBRARY"
```

确保每个脚本都能正确解析仓库根目录。macOS 部署改为通过 `--deploy` 显式启用；默认构建只验证构建目录中的输出，不修改受 Git 跟踪的插件二进制。

- [x] **步骤 6：移除不受支持的空占位文件**

```bash
git rm unity_project/Assets/Plugins/x86_64/libvisual_localizer.so
git rm unity_project/Assets/Plugins/x86_64/libvisual_localizer.so.meta
git rm unity_project/Assets/Plugins/x86_64-win/visual_localizer.dll
git rm unity_project/Assets/Plugins/x86_64-win/visual_localizer.dll.meta
```

- [x] **步骤 7：运行原生契约测试和 macOS 构建**

```bash
python3 -m pytest tests/phase0/test_native_contract.py -v
native_visual_localizer/build_macos.sh
tools/phase0/check_native_symbols.sh native_visual_localizer/build/libvisual_localizer.dylib
```

预期结果：全部测试通过，iOS 和 macOS 制品均报告包含所有必需符号。

- [ ] **步骤 8：提交任务 3**

```bash
git add tools/phase0 native_visual_localizer tests/phase0 docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git add -u unity_project/Assets/Plugins
git commit -m "build: enforce native artifact contract"
```

## 任务 4：可重复生成的 UPM 包

**对应需求：** R0.5

**涉及文件：**

- 新建：`tools/phase0/build_upm_package.py`
- 新建：`tests/phase0/test_upm_package.py`
- 修改：`unity_plugin/AreaTargetPlugin/BUILD_PACKAGE.md`
- 删除：受 Git 跟踪的过期 `1.2.0` 归档

- [ ] **步骤 1：添加预期失败的包内容测试**

新建 `tests/phase0/test_upm_package.py`，包含以下断言：

```python
import hashlib
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "tools/phase0/build_upm_package.py"
OUTPUT = ROOT / "dist/com.areatarget.tracking-1.2.1.tgz"

REQUIRED = {
    "package/package.json",
    "package/Runtime/AlignmentTransformCalculator.cs",
    "package/Runtime/ExtendedDebugInfo.cs",
    "package/Runtime/GLBMeshLoader.cs",
    "package/Runtime/Plugins/iOS/libvisual_localizer.a",
    "package/Runtime/Plugins/macOS/libvisual_localizer.dylib",
}


def build():
    subprocess.run([sys.executable, str(BUILDER)], cwd=ROOT, check=True)
    return hashlib.sha256(OUTPUT.read_bytes()).hexdigest()


def test_package_content_and_reproducibility():
    first = build()
    second = build()
    assert first == second
    with tarfile.open(OUTPUT, "r:gz") as archive:
        names = set(archive.getnames())
    assert REQUIRED <= names
    assert not any("/Tests/" in name or "/PropertyTests/" in name for name in names)
    assert not any(name.endswith((".unitypackage", ".tgz", ".bak2")) for name in names)
```

- [ ] **步骤 2：运行测试并确认因缺少打包器而失败**

```bash
python3 -m pytest tests/phase0/test_upm_package.py -v
```

预期结果：失败，因为打包器尚不存在。

- [ ] **步骤 3：实现确定性的包暂存流程**

新建 `tools/phase0/build_upm_package.py`，实现以下必需操作：

```python
#!/usr/bin/env python3
import gzip
import json
import shutil
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "unity_plugin/AreaTargetPlugin"
DIST = ROOT / "dist"
EXCLUDED_DIRS = {"Tests", "PropertyTests", "__pycache__"}
EXCLUDED_SUFFIXES = {".tgz", ".unitypackage", ".bak2", ".data1_bak"}


def ignored(_directory, names):
    return {
        name for name in names
        if name in EXCLUDED_DIRS or any(name.endswith(suffix) for suffix in EXCLUDED_SUFFIXES)
    }


def add_tree(archive, root):
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root.parent)
        info = archive.gettarinfo(str(path), arcname=str(relative))
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        if path.is_file():
            with path.open("rb") as stream:
                archive.addfile(info, stream)
        else:
            archive.addfile(info)


def main():
    metadata = json.loads((SOURCE / "package.json").read_text())
    version = metadata["version"]
    DIST.mkdir(exist_ok=True)
    output = DIST / f"com.areatarget.tracking-{version}.tgz"
    with tempfile.TemporaryDirectory(prefix="area-target-upm-") as temp:
        package = Path(temp) / "package"
        shutil.copytree(SOURCE, package, ignore=ignored)
        for platform, filename in (
            ("iOS", "libvisual_localizer.a"),
            ("macOS", "libvisual_localizer.dylib"),
        ):
            source = ROOT / "unity_project/Assets/Plugins" / platform / filename
            if not source.is_file() or source.stat().st_size == 0:
                raise SystemExit(f"missing native artifact: {source}")
            target = package / "Runtime/Plugins" / platform / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            meta = source.with_suffix(source.suffix + ".meta")
            if meta.is_file():
                shutil.copy2(meta, target.with_suffix(target.suffix + ".meta"))
        with output.open("wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as archive:
                    add_tree(archive, package)
    print(output)


if __name__ == "__main__":
    main()
```

- [ ] **步骤 4：移除受跟踪的过期归档**

```bash
git rm unity_plugin/AreaTargetPlugin/AreaTargetPlugin-1.2.0.unitypackage
git rm unity_plugin/AreaTargetPlugin/com.areatarget.tracking-1.2.0.tgz
```

历史版本仍可从 Git 历史恢复。

- [ ] **步骤 5：更新打包文档**

重写 `BUILD_PACKAGE.md`，将以下命令设为主要打包入口：

```bash
python3 tools/phase0/build_upm_package.py
```

记录输出路径、包含/排除规则以及 Unity 干净安装验证。保留 `.unitypackage` 导出作为旧版可选路径，但不再作为发布事实来源。

- [ ] **步骤 6：连续运行两次包测试**

```bash
python3 -m pytest tests/phase0/test_upm_package.py -v
tar -tzf dist/com.areatarget.tracking-1.2.1.tgz | sort | sed -n '1,120p'
```

预期结果：测试通过；可以看到必需的运行时源码和 iOS/macOS 库；测试代码和旧归档不存在。

- [ ] **步骤 7：提交任务 4**

```bash
git add tools/phase0/build_upm_package.py tests/phase0/test_upm_package.py unity_plugin/AreaTargetPlugin/BUILD_PACKAGE.md docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git add -u unity_plugin/AreaTargetPlugin
git commit -m "build: generate reproducible UPM package"
```

## 任务 5：统一验证驱动脚本

**对应需求：** R0.6

**涉及文件：**

- 新建：`tools/phase0/verify.sh`
- 新建：`tests/phase0/test_verify_driver.py`

- [ ] **步骤 1：添加验证驱动契约测试**

新建 `tests/phase0/test_verify_driver.py`：

```python
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / "tools/phase0/verify.sh"


def test_list_exposes_required_checks():
    result = subprocess.run([str(VERIFY), "--list"], text=True, capture_output=True)
    assert result.returncode == 0
    for name in ("metadata", "python", "docker", "native", "ios-archive", "xcode", "unity", "upm"):
        assert name in result.stdout


def test_invalid_mode_fails():
    result = subprocess.run([str(VERIFY), "invalid"], text=True, capture_output=True)
    assert result.returncode != 0
    assert "usage" in (result.stdout + result.stderr).lower()
```

- [ ] **步骤 2：运行测试并确认因缺少驱动脚本而失败**

```bash
python3 -m pytest tests/phase0/test_verify_driver.py -v
```

预期结果：失败，因为 `verify.sh` 尚不存在。

- [ ] **步骤 3：实现快速失败的验证驱动**

按照以下结构新建可执行文件 `tools/phase0/verify.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:-local}"
CHECKS=(metadata hygiene python docker native ios-archive xcode unity upm)

if [[ "$MODE" == "--list" ]]; then
  printf '%s\n' "${CHECKS[@]}"
  exit 0
fi
if [[ "$MODE" != "local" && "$MODE" != "ci" ]]; then
  echo "usage: $0 [local|ci|--list]" >&2
  exit 2
fi

pass() { echo "PASS $1"; }
skip() { echo "SKIP $1: $2"; }
run() { local name="$1"; shift; echo "RUN  $name"; "$@"; pass "$name"; }

cd "$ROOT"
run metadata python3 tools/phase0/check_package_metadata.py unity_plugin/AreaTargetPlugin/package.json
run hygiene python3 -m pytest tests/phase0/test_repository_hygiene.py -q
run python python3 -m pytest tests/ -v --tb=short
run docker-config docker compose config --quiet
run docker-build docker build -t area-target-scanner-phase0 .
run native native_visual_localizer/build_macos.sh
run ios-archive tools/phase0/check_native_symbols.sh unity_project/Assets/Plugins/iOS/libvisual_localizer.a

if [[ "$MODE" == "ci" ]]; then
  skip xcode "generic iOS build is a required local gate"
  skip unity "Unity license is not configured in CI"
else
  run xcode tools/phase0/verify_ios_scanner.sh
  run unity tools/phase0/validate_unity_package.sh
fi

run upm python3 tools/phase0/build_upm_package.py
run upm-content python3 -m pytest tests/phase0/test_upm_package.py -q
```

脚本必须保留第一个失败命令的非零退出码。

- [ ] **步骤 4：运行驱动契约测试**

```bash
python3 -m pytest tests/phase0/test_verify_driver.py -v
tools/phase0/verify.sh --list
```

预期结果：测试通过，并且仅列出规定的检查项名称。

- [ ] **步骤 5：提交任务 5**

```bash
git add tools/phase0/verify.sh tests/phase0/test_verify_driver.py docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git commit -m "build: add phase 0 verification driver"
```

## 任务 6：Xcode 与 Unity 本地门禁

**对应需求：** R0.5、R0.6、R0.7

**涉及文件：**

- 新建：`tools/phase0/verify_ios_scanner.sh`
- 新建：`tools/phase0/validate_unity_package.sh`
- 修改：`TEST_PLAN.md`

- [ ] **步骤 1：实现 iOS 扫描器通用设备构建验证**

新建可执行文件 `tools/phase0/verify_ios_scanner.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESULTS="$ROOT/phase0-results/xcode"
mkdir -p "$RESULTS"
xcodebuild \
  -project "$ROOT/ios_scanner/AreaTargetScanner.xcodeproj" \
  -scheme AreaTargetScanner \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$RESULTS/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build | tee "$RESULTS/build.log"
```

- [ ] **步骤 2：实现 Unity 测试和 UPM 干净安装验证**

新建可执行文件 `tools/phase0/validate_unity_package.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UNITY_PATH="${UNITY_PATH:-/Applications/Unity/Hub/Editor/6000.3.11f1/Unity.app/Contents/MacOS/Unity}"
RESULTS="$ROOT/phase0-results"
PROJECT="/tmp/area-target-phase0-unity"

[[ -x "$UNITY_PATH" ]] || { echo "Unity not found: $UNITY_PATH" >&2; exit 2; }
mkdir -p "$RESULTS"

"$UNITY_PATH" -batchmode -nographics \
  -projectPath "$ROOT/unity_project" \
  -runTests -testPlatform EditMode \
  -testResults "$RESULTS/unity-editmode.xml" \
  -logFile "$RESULTS/unity-editmode.log"

python3 - "$RESULTS/unity-editmode.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
total = int(root.attrib.get("total", "0"))
failed = int(root.attrib.get("failed", "1"))
if total <= 0 or failed != 0:
    raise SystemExit(f"Unity tests invalid: total={total}, failed={failed}")
PY

python3 "$ROOT/tools/phase0/build_upm_package.py"
VERSION="$(python3 "$ROOT/tools/phase0/check_package_metadata.py" "$ROOT/unity_plugin/AreaTargetPlugin/package.json")"
PACKAGE="$ROOT/dist/com.areatarget.tracking-$VERSION.tgz"

rm -rf "$PROJECT"
"$UNITY_PATH" -batchmode -nographics -createProject "$PROJECT" -quit -logFile "$RESULTS/unity-create.log"

python3 - "$PROJECT/Packages/manifest.json" "$PACKAGE" <<'PY'
import json
import sys
from pathlib import Path
manifest_path = Path(sys.argv[1])
package_path = Path(sys.argv[2]).resolve()
data = json.loads(manifest_path.read_text())
dependencies = data.setdefault("dependencies", {})
dependencies["com.gilzoide.sqlite-net"] = "https://github.com/gilzoide/unity-sqlite-net.git#1.3.2"
dependencies["com.areatarget.tracking"] = package_path.as_uri()
manifest_path.write_text(json.dumps(data, indent=2) + "\n")
PY

"$UNITY_PATH" -batchmode -nographics -projectPath "$PROJECT" -quit \
  -logFile "$RESULTS/unity-clean-install.log"

if rg -n "error CS|Scripts have compiler errors|Failed to resolve packages" "$RESULTS/unity-clean-install.log"; then
  echo "Unity clean install failed" >&2
  exit 3
fi

rm -rf "$PROJECT"
echo "PASS Unity EditMode and clean UPM install"
```

- [ ] **步骤 3：在 `TEST_PLAN.md` 中记录准确的本地门禁**

添加以下两个命令：

```bash
tools/phase0/verify_ios_scanner.sh
tools/phase0/validate_unity_package.sh
```

明确说明：模拟器运行不能证明支持 LiDAR 扫描；Unity 测试 XML 必须至少包含一个测试，且失败数为零。

- [ ] **步骤 4：运行 iOS 扫描器构建**

```bash
tools/phase0/verify_ios_scanner.sh
```

预期结果：`phase0-results/xcode/build.log` 中出现 `** BUILD SUCCEEDED **`。

- [ ] **步骤 5：运行 Unity 测试和包的干净安装验证**

```bash
tools/phase0/validate_unity_package.sh
```

预期结果：EditMode XML 报告的测试数大于零、失败数为零；临时项目编译时没有 `error CS` 或包解析错误。

- [ ] **步骤 6：提交任务 6**

```bash
git add tools/phase0/verify_ios_scanner.sh tools/phase0/validate_unity_package.sh TEST_PLAN.md docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git commit -m "test: add iOS and Unity baseline gates"
```

## 任务 7：将 CI 扩展到阶段 0 基线

**对应需求：** R0.7

**涉及文件：**

- 修改：`.github/workflows/ci.yml`
- 修改：`requirements-dev.txt`

- [ ] **步骤 1：替换抽样执行的 Python 测试命令**

Linux Python job 必须安装三组依赖并执行：

```yaml
- name: Install Python dependencies
  run: |
    python -m pip install --upgrade pip
    pip install -r requirements.txt
    pip install -r web_service/requirements.txt
    pip install -r requirements-dev.txt

- name: Run Phase 0 tests
  run: python -m pytest tests/ -v --tb=short

- name: Validate package metadata
  run: python tools/phase0/check_package_metadata.py unity_plugin/AreaTargetPlugin/package.json

- name: Build and inspect UPM package
  run: |
    python tools/phase0/build_upm_package.py
    python -m pytest tests/phase0/test_upm_package.py -v
```

- [ ] **步骤 2：在镜像构建前添加 Docker 配置验证**

```yaml
- name: Validate Docker Compose
  run: docker compose config --quiet

- name: Build web service image
  run: docker build -t area-target-scanner-web-service-ci .
```

- [ ] **步骤 3：添加 macOS 原生构建 job**

```yaml
native-macos:
  runs-on: macos-14
  steps:
    - uses: actions/checkout@v4
    - name: Install native dependencies
      run: brew install cmake opencv
    - name: Build and verify native library
      run: native_visual_localizer/build_macos.sh
    - name: Verify iOS archive contract
      run: tools/phase0/check_native_symbols.sh unity_project/Assets/Plugins/iOS/libvisual_localizer.a
```

- [ ] **步骤 4：在工作流注释中记录 Unity 本地门禁例外**

添加注释说明：在仓库 secrets 配置有效的 Unity 许可证前，Unity EditMode 仍是必需的本地发布门禁。不得添加虚假的绿色 Unity job。

- [ ] **步骤 5：添加工作流解析依赖**

在 `requirements-dev.txt` 中添加：

```text
PyYAML>=6.0,<7
```

- [ ] **步骤 6：验证工作流语法和本地 CI 模式**

```bash
python3 -c 'import yaml; yaml.safe_load(open(".github/workflows/ci.yml"))'
tools/phase0/verify.sh ci
```

预期结果：YAML 解析成功；所有 CI 模式检查通过，Xcode/Unity 被明确报告为 `SKIP`。

- [ ] **步骤 7：提交任务 7**

```bash
git add .github/workflows/ci.yml requirements-dev.txt docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git commit -m "ci: enforce phase 0 baseline checks"
```

## 任务 8：基线文档与支持范围声明

**对应需求：** R0.8

**涉及文件：**

- 修改：`README.md`
- 修改：`unity_plugin/AreaTargetPlugin/README.md`
- 修改：`unity_plugin/AreaTargetPlugin/BUILD_PACKAGE.md`

- [ ] **步骤 1：添加明确的阶段 0 支持范围表**

在根 README 和包 README 中写明：

| 目标平台 | 阶段 0 状态 |
|---|---|
| macOS 开发构建 | 已验证基线 |
| iOS 扫描器通用设备构建 | 已验证基线 |
| iOS 定位器归档 | 仅完成静态符号验证 |
| Rokid AR Studio | 计划在阶段 2 实施；阶段 0 不支持 |
| Android ARM64 | 计划在阶段 2 实施；阶段 0 不支持 |
| Windows/Linux 运行时 | 不支持；已移除空占位文件 |

- [ ] **步骤 2：修正构建和打包说明**

记录以下规范命令：

```bash
tools/phase0/verify.sh local
python3 tools/phase0/build_upm_package.py
tools/phase0/validate_unity_package.sh
```

删除把受 Git 跟踪的 `1.2.0` 归档作为当前版本的说明。

- [ ] **步骤 3：检查文档中的能力声明**

```bash
rg -n "supports.*Android|Windows|Linux|Rokid|支持.*Android|支持.*Windows|支持.*Linux|支持.*Rokid" README.md unity_plugin/AreaTargetPlugin/README.md
```

预期结果：所有剩余匹配项都明确标注为“不支持”或“计划中”，或者有阶段 0 验证证据支撑。

- [ ] **步骤 4：提交任务 8**

```bash
git add README.md unity_plugin/AreaTargetPlugin/README.md unity_plugin/AreaTargetPlugin/BUILD_PACKAGE.md docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git commit -m "docs: document phase 0 support baseline"
```

## 任务 9：完整的干净检出验收

**对应需求：** 全部需求和验收标准

**涉及文件：**

- 新建：`docs/phase-0-validation.md`
- 更新：随着检查完成同步更新本 `tasks.md`

- [ ] **步骤 1：在当前工作目录运行全部快速测试**

```bash
python3 -m pytest tests/ -v --tb=short
docker compose config --quiet
python3 tools/phase0/build_upm_package.py
python3 -m pytest tests/phase0 -v
```

预期结果：所有命令均返回零。

- [ ] **步骤 2：运行完整本地门禁**

```bash
tools/phase0/verify.sh local | tee phase0-results/phase0-local.log
```

预期结果：每个必需检查项都是 `PASS`，没有必需检查项为 `SKIP`。

- [ ] **步骤 3：在干净 worktree 中验证可重复性**

```bash
git worktree add /tmp/area-target-phase0-clean HEAD
cd /tmp/area-target-phase0-clean
git submodule update --init --recursive
tools/phase0/verify.sh local | tee phase0-results/phase0-clean.log
```

预期结果：完整门禁在干净 worktree 中通过。

- [ ] **步骤 4：根据实际版本和结果创建验证记录**

运行以下命令，然后使用命令原始输出以及两份日志中真实的 PASS/FAIL/SKIP 结果创建 `docs/phase-0-validation.md`：

```bash
git rev-parse HEAD
sw_vers
xcodebuild -version
python3 --version
docker --version
docker compose version
"$UNITY_PATH" -version
cmake --version
```

只复制结果摘要，不得复制完整扫描数据或设备隐私内容。

- [ ] **步骤 5：确认源码状态干净**

```bash
git status --short
git diff --check
```

预期结果：没有意外源码变更。`dist/`、`build/`、`phase0-results/` 和临时验证项目保持被忽略或位于仓库之外。

- [ ] **步骤 6：提交最终验证记录和已完成任务状态**

```bash
git add docs/phase-0-validation.md docs/superpowers/specs/phase-0-reproducible-baseline/tasks.md
git commit -m "chore: validate reproducible v1.2.1 baseline"
```

- [ ] **步骤 7：移除临时干净 worktree**

返回主 worktree，然后运行：

```bash
git worktree remove /tmp/area-target-phase0-clean
```

预期结果：临时 worktree 已移除，主 worktree 保持不变。

- [ ] **步骤 8：执行外部发布操作前验证验收状态**

```bash
git status --short --branch
git log --oneline --decorate -10
test "$(python3 tools/phase0/check_package_metadata.py unity_plugin/AreaTargetPlugin/package.json)" = "1.2.1"
```

预期结果：分支干净、阶段 0 提交记录完整、规范版本为 `1.2.1`。

到达此步骤后，未经用户明确授权，不得推送、打标签、创建 GitHub Release 或合并到 `main`。
