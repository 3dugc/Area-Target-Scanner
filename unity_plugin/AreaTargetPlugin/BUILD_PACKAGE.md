# AreaTargetPlugin 打包流程

## 规范发布包

发布事实来源是由当前源码生成的 UPM 压缩包，不再使用仓库中预先提交的二进制归档。

### 前置条件

- Python 3.11
- OpenCV 4.x
- 已通过 `native_visual_localizer/build_macos.sh`
- 已运行 `native_visual_localizer/build_ios.sh`，使 `unity_project/Assets/Plugins/iOS/libvisual_localizer.a` 通过原生符号检查，并准备 `native_visual_localizer/opencv_ios/opencv2.framework`（该下载缓存不进入 Git）。
- Unity 6000.4.6f1（本次干净安装验证版本）
- Xcode（generic iOS device 链接验证）

完整本地发布门禁：

```bash
tools/phase0/verify.sh local
tools/phase0/validate_unity_package.sh
tools/phase1/validate_ios_upm_build.sh
```

### 生成命令

```bash
python3 tools/phase0/build_upm_package.py
```

版本从 `unity_plugin/AreaTargetPlugin/package.json` 读取。当前阶段 1 输出为：

```text
dist/com.areatarget.tracking-1.3.0.tgz
```

`dist/` 是生成目录，不进入 Git。

## 包内容规则

生成包包含：

- `Runtime/`、`Editor/`、`Samples~/` 和包根元数据。
- `AlignmentTransformCalculator.cs`、`ExtendedDebugInfo.cs`、`GLBMeshLoader.cs` 和当前 AKAZE 集成代码。
- Apache-2.0 许可证。
- 已验证的 iOS 静态库、OpenCV framework 和 macOS 动态库，位于 `Runtime/Plugins/`。
- `Editor/iOSPostProcess.cs`：从已安装 UPM 包解析制品，复制 OpenCV framework，并配置 iOS Xcode 链接依赖。

生成包排除：

- `Tests/`、`PropertyTests/` 和 FsCheck 测试依赖。
- `.unitypackage`、旧 `.tgz`、备份资产及生成物。
- Windows/Linux 空占位二进制。

连续两次生成的压缩包必须具有相同 SHA-256。内容和可重复性由以下命令验证：

```bash
python3 -m pytest tests/phase0/test_upm_package.py -v
tar -tzf dist/com.areatarget.tracking-1.3.0.tgz
```

## Unity 干净安装验证

发布前必须执行：

```bash
tools/phase0/validate_unity_package.sh
```

该脚本会运行现有 EditMode 测试，并在临时 Unity 项目中通过本地 `.tgz` 安装包。包自身正式声明 SQLite `1.3.2` 依赖；验证工程只声明本地 Area Target `.tgz`，不注入额外 SQLite dependency。

为使 Unity 解析 `com.gilzoide.sqlite-net`，验证工程仅添加 OpenUPM 的 `com.gilzoide` scoped registry 配置（`https://package.openupm.com`）；这是 registry 解析配置，不是额外的包依赖声明。

## generic iOS device 链接验证

发布 iOS 包前还必须执行：

```bash
tools/phase1/validate_ios_upm_build.sh
```

该脚本创建全新的临时 Unity 工程，只安装当前 `.tgz`、最小场景与 `BuildiOS` 入口，不复制仓库根目录的 `iOSPostProcess.cs`。它随后导出 iOS 工程，并以 `generic/platform=iOS`、Debug、禁用签名运行 `xcodebuild`。日志保存在被 Git 忽略的 `phase1-results/`。

## 旧版 `.unitypackage` 导出

Unity 菜单 `Tools > Export AreaTargetPlugin Package` 仅作为兼容旧项目的可选路径。它从 `package.json` 读取版本，但不是阶段 0 的发布事实来源，也不得提交其生成物。
