# AreaTargetPlugin 打包流程

## 规范发布包

阶段 0 的发布事实来源是由当前源码生成的 UPM 压缩包，不再使用仓库中预先提交的二进制归档。

### 前置条件

- Python 3.11
- 已通过 `native_visual_localizer/build_macos.sh`
- `unity_project/Assets/Plugins/iOS/libvisual_localizer.a` 已通过原生符号检查
- Unity 6000.3.11f1（仅干净安装验证时需要）

### 生成命令

```bash
python3 tools/phase0/build_upm_package.py
```

版本从 `unity_plugin/AreaTargetPlugin/package.json` 读取。阶段 0 输出为：

```text
dist/com.areatarget.tracking-1.2.1.tgz
```

`dist/` 是生成目录，不进入 Git。

## 包内容规则

生成包包含：

- `Runtime/`、`Editor/`、`Samples~/` 和包根元数据。
- `AlignmentTransformCalculator.cs`、`ExtendedDebugInfo.cs`、`GLBMeshLoader.cs` 和当前 AKAZE 集成代码。
- Apache-2.0 许可证。
- 已验证的 iOS 静态库和 macOS 动态库，位于 `Runtime/Plugins/`。

生成包排除：

- `Tests/`、`PropertyTests/` 和 FsCheck 测试依赖。
- `.unitypackage`、旧 `.tgz`、备份资产及生成物。
- Windows/Linux 空占位二进制。

连续两次生成的压缩包必须具有相同 SHA-256。内容和可重复性由以下命令验证：

```bash
python3 -m pytest tests/phase0/test_upm_package.py -v
tar -tzf dist/com.areatarget.tracking-1.2.1.tgz
```

## Unity 干净安装验证

发布前必须执行：

```bash
tools/phase0/validate_unity_package.sh
```

该脚本会运行现有 EditMode 测试，并在临时 Unity 项目中通过本地 `.tgz` 安装包。临时项目的 `manifest.json` 同时固定 SQLite Git 依赖：

```text
https://github.com/gilzoide/unity-sqlite-net.git#1.3.2
```

## 旧版 `.unitypackage` 导出

Unity 菜单 `Tools > Export AreaTargetPlugin Package` 仅作为兼容旧项目的可选路径。它从 `package.json` 读取版本，但不是阶段 0 的发布事实来源，也不得提交其生成物。
