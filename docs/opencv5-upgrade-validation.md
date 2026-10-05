# OpenCV 5 整项目升级验收记录

日期：2026-10-05。分支：`codex/opencv5-upgrade`。初始对照基线为本地已提交的 develop `0495d64`；随后按用户确认的方案整合最新 develop，包含 `60d88bb` 和 iOS 服务登录提交 `ea7989e`。升级分支仅提交 OpenCV 相关原生接口/工具，原工作区其他 iOS 功能和私有 Immersal SDK 保留其待提交状态；当前完整 Swift App 另在隔离副本验证。

项目自有默认依赖采用 OpenCV 5.0.0 + contrib，覆盖 Python、Docker/CI、Unity 原生库及 Swift iOS 的设备/模拟器私有框架。Immersal SDK 2.4.0 保留原版及其内部实现，通过私有符号隔离和实际同存链接验证兼容。合成样本证明现有算法与旧特征查询兼容，未证明真实场景识别率提升。构建/集成门禁与真机/现场发布验收分开记录。

## 最新 develop 整合与 Swift iOS / Immersal

| 检查 | 最新实际结果 |
|---|---|
| Python 全回归 | 462 通过、6 跳过：pipeline 442 + mesh 20；两份 fresh JUnit 经驱动校验完整，进程返回 0 |
| macOS 原生 | CTest 4/4；仅 11 个原 C ABI 导出，无外部 OpenCV 动态依赖 |
| Unity EditMode | 992/992，0 失败；独立工程使用现有 Editor 6000.6.3f1 |
| 干净 UPM / ARKit / iOS 导出 / 通用 Xcode | 全部通过，`BUILD SUCCEEDED`；签名关闭，Xcode 27 beta |
| Apple 依赖/夹具/签名 | 11/11 来源与篡改拒绝契约、1/1 真实夹具、1/1 双平台 strict ad-hoc 签名门禁 |
| Swift 原生框架 | 两平台均 arm64、OpenCV 5.0.0 + contrib、minOS 16、SDK 27、TWOLEVEL、11 个 C 导出、无 OpenCV C++ 导入，含 17 份依赖许可 |
| iOS 27 原生 Simulator | ORB TRACKING 1912 内点，位姿元素最大误差 1.19805e-5；强制 AKAZE TRACKING 600 内点、触发标志 1、误差 8.9407e-8；两条空白输入均 LOST |
| Immersal 同存设备镜像 | 完整链接 11 个 native 和 4 个 Immersal C API；SDK 与头文件哈希未变 |
| Swift 完整 App | 545 项：542 通过、0 失败、3 项真实线上 opt-in 测试跳过；完整 App 未签名设备构建成功，实际链接原 SDK 与 5 私有框架 |
| CI lint / Shell / Python 语法 / Compose | 通过；CI 补充原生依赖接受与夹具生产者门禁 |
| Docker 镜像及容器运行 | linux/arm64 实际构建与容器门禁均返回 0；单一 contrib 5.0.0.93 / 实际 OpenCV 5.0.0，ORB/AKAZE/PnP、Open3D ELF 依赖、服务认证及真实 Gunicorn 启停全部通过 |
| 签名真机部署、持续定位及真实跨会话识别率 | 未运行；缺少 iPhone/iPad 现场同图验收和独立真实查询集 |

Swift 的 3 项跳过仅为真实 Hall bundle 导入、真实 Hall 扫描云处理和生产 HTTPS 合成请求，需显式输入/授权。它们不构成线上 API 或真机定位通过。模拟器中的 Immersal 为既有 stub/契约路径；真实 SDK 由设备镜像链接验证。两项旧身份测试实际 RED（4.10 对 5.0）后 GREEN；Smoke scheme 的夹具路径需 MacroExpansion，已修复并验证真实 SQLite→5 原生定位与空白 LOST。

Python 跳过的 6 项与初始实验相同：2 项缺少现场数据、3 项只在 OpenCV 4 对照输入生产环境执行、1 项可选 xatlas helper 不存在。4 条警告为既有 KMeans 重复特征。最新远端仅追加 Swift 登录源码，没有改变已验证的 Python、Unity、OpenCV 或 Docker 构建输入。

首次 Docker 的 pip 安装完成，但 Open3D 0.20.0 导入失败，未执行到 OpenCV 检查。该 ARM64 构建动态依赖 Fortran runtime，与 [Open3D 0.20.0 官方构建配置](https://github.com/isl-org/Open3D/blob/v0.20.0/3rdparty/find_dependencies.cmake#L1936-L1945)一致；补 Debian `libgfortran5` 后，实际重建返回 0，Open3D 与 OpenCV 导入及 native xatlas helper 编译成功。依赖安装与导入检查拆层，避免后续验收失败丢失成功安装层的缓存。

容器使用镜像 ID `sha256:3120c712d91db4c7314090f334ffcdf97b2600e18e5118c5cad0e9954fa45767`，以 appuser 在无外网、无发布端口、只读根文件系统下运行门禁。实际 ORB/AKAZE 描述子分别为 32/61 字节，已知位姿 PnP 保留 8 个内点、平移最大误差 3.67434e-8；Open3D 0.20.0 的 ELF `ldd` 返回 0 且无缺失库。服务验证健康检查、登录/session/native header、注销撤销、匿名/错密码拒绝、job capability 与 CSRF，以及 Secure/HttpOnly/SameSite cookie；真实 Gunicorn 使用镜像启动参数（仅 bind 改为容器回环），healthz 为 200/no-store，正常结束返回 0。容器凭据在内部随机生成，不调用生产服务。该 smoke 不代表真实云处理任务或现场定位通过。

复现并修正了两个集成测试问题：移动端特征预算测试在 5 下 mock 不存在的根 `AKAZE_create`，现按实际命名空间 mock，RED 2 失败后 GREEN 4/4；Unity 旧测试把 iOS 枚举与 YAML 字节格式写死，Editor 重保存后 RED，现通过实际 iOS XR Manager/ARKit Loader 检查，单项和完整 992 套件 GREEN。原项目 XR 资产未修改。

新增 iOS 工具默认拒绝旧/基本版/来源缺失/二进制或许可证被改的框架。夹具使用显式固定的 macOS 5 CMake 安装，保留 SQLite 和原 C ABI 布局，覆盖真实 ORB、强制 AKAZE 和 blank LOST。live/replay 身份共享一个版本来源；Immersal 仍使用原 SDK 身份。签名前验证 producer 二进制哈希，签名会改变 Mach-O 字节，随后单独验证严格签名。

| 当前工件 | SHA256 |
|---|---|
| Unity macOS wrapper | `f6b5f35fca6276d1420b4c9ab89a2f01b85896b8554ebb0e81c4f84a1ecc2e63` |
| Unity iOS wrapper | `bb61f57f882405b0cd3dc466bbb9fe18d3b72c267fcc31a7813be99568d01029` |
| AreaTargetNative iPhoneOS | `84fb1851c102eb8975fcdb8a640d339c15188675cde925918e1a97234b78133f` |
| AreaTargetNative Simulator | `ddf43808b543423f80513802b7384a21e738631352d45266c8881ce5e1789b25` |
| 保留的 Immersal SDK | `45fad535dcbf0139feb9b15dafe74c8315436db21a138271924e10e56d2fca8f` |

macOS 原生 minOS 26 与旧已提交 wrapper 一致；Swift iOS 框架 minOS 16 与当前 App 一致。未在更早系统设备实测。私有 device/simulator 框架签名前分别约 4.67/4.70 MB；最终安装 App 的体积、内存和每帧耗时仍需真机测量。

## 升级范围与依赖

| 项目 | 旧版对照 | 升级分支 |
|---|---|---|
| Python / NumPy | 3.11.12 / 2.4.6 | 相同 |
| Python OpenCV | 实际导入 4.13.0，wheel 4.13.0.92 | `opencv-contrib-python-headless==5.0.0.93`，实际导入 5.0.0 |
| macOS 原生 OpenCV | Homebrew 4.11.0 | 固定源码 OpenCV + contrib 5.0.0，静态链接 |
| iPhoneOS 原生 OpenCV | 已提交的旧库 | 固定源码 OpenCV + contrib 5.0.0，arm64 静态 framework |
| Python 平台 | macOS 26.5.2 arm64 | 相同 |
| Unity / Xcode 验证工具 | 本次可用 Unity 6000.6.3f1、Xcode 27 beta | 使用同一工具链验证升级包 |

OpenCV 5 的 AKAZE 位于 contrib 的 `xfeatures2d`，因此仅替换基本版 OpenCV 包或 iOS release framework 会丢失现有回退算法。本分支使用 contrib，并保持默认 AKAZE 参数和 61 字节 MLDB 描述子。[官方 AKAZE 示例](https://docs.opencv.org/5.0/tutorials/features/akaze_matching/akaze_matching.html)、[5.0.0 contrib 声明](https://github.com/opencv/opencv_contrib/blob/5.0.0/modules/xfeatures2d/include/opencv2/xfeatures2d.hpp)。版本来源：[OpenCV 5.0.0 发布](https://github.com/opencv/opencv/releases/tag/5.0.0)。

生产代码保留 ORB、AKAZE、Hamming BoW、PnP、过滤参数、数据库字节布局和 11 个 `vl_*` C ABI。修改集中在模块/工厂命名空间、依赖构建、工件校验、测试及缓存身份。缓存默认由 v2 升为 v3，实际 OpenCV 版本始终参与输入哈希；manifest 新增 `producer.opencvVersion`，格式版本仍为 2.0。旧数据库兼容测试不等于重新处理过所有真实地图。

本次未接入 ALIKED、DISK、LightGlue。升级版本不会自动启用这些算法。

## 固定输入的质量对照

用 OpenCV 4 一次性生成输入；种子 `20261005`，输入 SHA256：

`785265e3ecd71179f5e0b626dc6d35094e36cc1ee6201c9e24c0696c47619540`

同一组 identity、lighting、affine、blur、blank、unrelated 图像在独立 4/5 进程中测试。使用相同 CLAHE、ORB 3000、AKAZE 默认参数、双向 Hamming ratio 0.75、几何阈值 3 px。OpenCL 关闭，OpenCV 并行关闭，NumPy 和线程环境相同。每项预热 3 次、记录 15 次，串行运行；另外交换版本运行顺序复核。数值记录见 [对照 JSON](opencv5-comparison-results.json)。

下表为几何真值内点数，三条路径结果相同：

| 算法 / 变换 | 4 生产→4 查询 | 5 生产→5 查询 | 4 生产→5 查询 |
|---|---:|---:|---:|
| ORB 原图 | 3000 | 3000 | 3000 |
| ORB 亮度 | 2480 | 2480 | 2480 |
| ORB 仿射 | 743 | 743 | 743 |
| ORB 模糊 | 632 | 632 | 632 |
| AKAZE 原图 | 2750 | 2750 | 2750 |
| AKAZE 亮度 | 2252 | 2252 | 2252 |
| AKAZE 仿射 | 1801 | 1801 | 1801 |
| AKAZE 模糊 | 1787 | 1787 | 1787 |

所有路径的空白和无关图像均得到 0 个 ratio 匹配；这两个负样本没有对应几何真值，不能把其几何内点字段的 null 当作测得的 0。ORB 仿射 770 个匹配中 743 个内点，模糊 639 中 632；AKAZE 模糊 1794 中 1787。三条路径的误差和精度相同，第二轮计数也一致。

非共面 3D PnP 使用 250 点、RANSAC 200 次、3 px、置信度 0.999，并优化内点。含噪声时两版都保留 250 内点，旋转误差约 0.01945°、平移误差约 0.001093；加入 50 个离群点后两版均为 200 内点且错误接纳 0 个离群点，旋转误差约 0.001995°、平移误差约 0.000327。平移单位随合成场景坐标，不能转述为真实现场毫米精度。

原生 C ABI 对照各版本分别加载一个动态库。ORB 正常路径与强制 AKAZE 回退都得到 800 内点、TRACKING；旧 4 生产数据库→5 查询也相同。旋转误差 0°，ORB 平移误差 `8.11e-9`、AKAZE `2.80e-8`，空白帧保持 LOST 并返回单位矩阵。独立 CTest 同时验证了 600 点定位、无效输入、位姿展开格式。

## 性能观察

耗时表随完整数值记录生成，列出两轮 median/P95。Python 包、编译器、CPU dispatch 和原生静态/动态链接没有完全配平，因此任何百分比只是本机这些构建的观察，不能归因于 OpenCV 版本。合成测试也不能代表 iPhone 每帧性能或真实跨会话识别率。

单位 ms；每格为 median / P95。第 1 轮先 4 后 5，第 2 轮先 5 后 4。Python 旧版 4.13.0，原生旧版 4.11.0。

| 操作 | 第 1 轮 4 | 第 1 轮 5 | 第 2 轮 4 | 第 2 轮 5 |
|---|---:|---:|---:|---:|
| ORB 提取 / 原图 | 11.33 / 13.16 | 10.82 / 11.45 | 10.99 / 11.35 | 10.81 / 11.08 |
| ORB 提取 / 仿射 | 11.03 / 12.41 | 11.91 / 14.01 | 11.30 / 12.57 | 11.42 / 12.61 |
| AKAZE 提取 / 原图 | 26.23 / 28.50 | 26.07 / 26.96 | 26.00 / 28.71 | 25.24 / 26.56 |
| AKAZE 提取 / 亮度 | 24.02 / 25.10 | 24.16 / 101.77 | 24.60 / 25.40 | 23.75 / 25.17 |
| PnP / 50 离群点 | 0.57 / 0.80 | 0.61 / 0.72 | 0.60 / 0.66 | 0.60 / 0.99 |
| 原生 ORB 定位 | 16.93 / 18.22 | 13.99 / 14.80 | 15.62 / 16.10 | 15.14 / 20.13 |
| 原生 AKAZE 定位 | 38.44 / 43.45 | 33.48 / 35.16 | 36.72 / 43.93 | 35.05 / 38.96 |

提取和 PnP 没有稳定、全面的加速。原生定位 median 在两轮均较低，但 ORB 的观察降幅由约 17% 变为 3%，第二轮 P95 反而较高。AKAZE 亮度提取首轮 P95 101.77 ms，复测降至 25.17 ms，体现短测量的波动；未丢弃首轮记录。当前证据足以排查兼容问题，不足以承诺现场性能收益。

## 初始 `0495d64` 实验门禁（历史记录）

以下结果保留初次实验原貌；最新整项目验收以前面的表格为准。

| 检查 | 本次结果 |
|---|---|
| Python 全回归 | 355 通过、6 跳过；pipeline 335 + mesh 20，两份完整 JUnit 验证成功 |
| Native OpenCV 4 / 5 CTest | 各 4/4 通过，正定位、AKAZE 回退、负样本和位姿契约覆盖 |
| 原生 ABI / 依赖 | macOS 仅导出原有 11 个 `vl_*`；无 Homebrew/临时路径 OpenCV 动态依赖，复制到新目录后可加载 |
| iPhoneOS 全归档链接 | arm64 wrapper + contrib framework 的 force-load 链接通过，包含第三方静态依赖 |
| UPM 内容/可复现打包 | 9 项通过，拒绝旧版、基本版、篡改 framework，带依赖许可 |
| Ruff / Shell / Python 语法 | CI 规定的 lint 范围及新增工具检查通过；构建/门禁脚本语法通过 |
| Unity EditMode | **991/992 通过，1 失败，门禁尚未全绿** |
| Unity 干净 UPM 安装 | Phase 0、Phase 1 均通过 |
| ARKit 配置 / Unity iOS 导出 | 通过 |
| 通用 iPhoneOS Xcode 构建 | `BUILD SUCCEEDED`，签名关闭；最终 UnityFramework 有 11 个 `vl_*`，无动态 OpenCV 依赖 |
| Docker Compose | 配置验证通过 |
| Docker 镜像 | **未运行**：本机 Docker daemon 未启动。Dockerfile 已增加实际 ORB/AKAZE/PnP 导入检查，CI 负责镜像构建 |
| 真机签名/部署/持续定位 | **未运行** |
| 真实跨会话识别率对照 | **未运行**：已提交基线缺少完整的独立查询图像/扫描集 |

6 个 Python 跳过分别为 2 项缺少现场数据的既有跨会话测试、3 项仅用于 OpenCV 4 输入生产的比较工具测试（已在 4 环境及真实对照运行覆盖）、1 项缺少可选 native xatlas helper 的测试。4 条警告来自既有 KMeans 重复特征聚类数量不足。

第一次未拆分的 pytest 在 Open3D Poisson 中提前退出，退出码为 0 但没有完成摘要/JUnit；同样问题也在 4 环境复现，因此该次运行没有记为通过。新增回归驱动将 mesh properties 单独串行运行，并要求每组 fresh JUnit 完整、无错误且实际执行测试。另有两个 pipeline 测试仍使用 Poisson；如它们提前退出，同样被 JUnit 校验拒绝。

初次 Unity 唯一失败（本轮已复现并修复）：`XRGeneralSettingsPerBuildTarget_KeysContainsiOS_ValuesReferencesGeneralSettings` 断言旧 XR YAML `Keys/Values`，可用 Editor 6000.6.3f1 将配置写为 `m_SettingsPerBuildTarget`。该测试和原 XR 配置没有升级分支差异，也不调用定位库；尚未在门禁指定的 6000.4.6f1（本机未安装）复核。初次失败未计为通过；本轮改为实际 XR 配置语义检查，并完成 992/992。Unity 操作全部在独立临时工程中执行，原 develop 工程未被 Editor 迁移。

## 工件与成本

源码下载和缓存内容均验证 SHA256，构建关闭无关模块及特征模型下载。iOS 使用源构建 contrib framework，不采用缺少 AKAZE 的基本版 release zip。生成的源码、framework、对照输入和临时工程不提交 Git；已有的两份 Unity 原生库更新为 5，防止新 framework 与旧 wrapper 混用。CI 先构建原生库，再将匹配工件交给 Python/UPM 测试。

UPM 打包器独立校验的是 framework 版本、来源和二进制 SHA，不直接识别 wrapper 的 OpenCV producer。本次两份 wrapper 经实际重建、哈希和链接验证；后续如手动替换 wrapper，需重新执行构建/链接门禁，不能仅以打包成功证明版本一致。

| 固定依赖 / 初次实验工件 | SHA256 |
|---|---|
| OpenCV 5.0.0 源码 | `b0528f5a1d379d59d4701cb28c36e22214cc51cf64594e5b56f2d3e6c0233095` |
| contrib 5.0.0 源码 | `c58f6344170c39abf187c56f3843b59cab1fd3e89cf19ba2ce25dc061659b27f` |
| macOS arm64 contrib headless 5.0.0.93 wheel | `bf1e2b3c502b4fbe7b06e307bd15c4e7bea7da8895de19c189db01d53062f997` |
| macOS wrapper | `a9a15ace34a4b16b94d442249f427e6a1f17df4cd23bf8b5cdd7fa6b18db67d9` |
| iOS wrapper | `df7e01f691b6b5148ce9a0dbb99088c882b88969973f2c8b4e4b137819cef5ca` |
| iOS contrib framework 二进制 | `d270aa3ed05fa9c94002c3b3d0c0b4fc8fb453bdd38f3ee27baaa736bd4c00b5` |

macOS wrapper 从 97,864 B 增至 8,309,592 B，因为现在静态携带所需 OpenCV，不再要求运行机器有相同 Homebrew 安装。旧体积不包含外部 OpenCV，不能据此计算完整应用增幅。iOS wrapper 从 83,360 B 到 83,848 B，另有 18,731,400 B 源构建 framework；最终 App 体积和内存尚未在真机测量。iOS framework 本次未启用下载失败的 KleidiCV HAL，保留 ARM NEON；macOS 构建保留可用 HAL。macOS 最低版本构建记录为 26，iOS wrapper 最低版本 14，未验证更早系统设备运行。

主要成本是 contrib 源构建和 CI 工件管理、NumPy 2+ 依赖、缓存重建、跨会话/真机回归，并非算法参数重写。本次收益是完成版本适配、固定可核验的依赖和可独立携带的 macOS runtime。识别率收益尚无证据，ALIKED/DISK/LightGlue 仍需另行主动接入和对照。

## 复核入口

在此分支的全新虚拟环境中安装 requirements、web_service/requirements 和 requirements-dev。构建命令：

```bash
bash tools/opencv5/build_dependency.sh
OpenCV_DIR="$PWD/build/opencv5/install/lib/cmake/opencv5" \
  bash native_visual_localizer/build_macos.sh --deploy
bash native_visual_localizer/build_ios.sh --deploy
VL_NATIVE_LIBRARY="$PWD/unity_project/Assets/Plugins/macOS/libvisual_localizer.dylib" \
  python tools/opencv5/run_regression.py --import-mode=importlib
python tools/phase0/build_upm_package.py
```

对照命令如下，`OPENCV4_PYTHON`、`OPENCV5_PYTHON` 分别指向两环境的 Python，`OPENCV4_LIBRARY`、`OPENCV5_LIBRARY` 指向分别构建的原生库。默认预热/重复参数与本次相同；第二轮保留同一 inputs 和旧特征，仅交换 run 顺序、另存输出。

```bash
"$OPENCV4_PYTHON" tools/opencv5/compare.py prepare --inputs inputs.npz
"$OPENCV4_PYTHON" tools/opencv5/compare.py run --inputs inputs.npz \
  --output 4.json --features-output 4-features.npz --native-library "$OPENCV4_LIBRARY"
"$OPENCV5_PYTHON" tools/opencv5/compare.py run --inputs inputs.npz \
  --output 5.json --features-output 5-features.npz --reference-features 4-features.npz \
  --native-library "$OPENCV5_LIBRARY"
"$OPENCV4_PYTHON" tools/opencv5/compare.py compare --old 4.json --new 5.json \
  --output comparison.json
```

本轮记录保存在升级工作树的 `build/opencv5-unification/`，包括 `python-regression.log`、`unity-editmode.xml`、`unity-workspace/phase1-results/`、`apple-validation-summary.json`、Apple 签名/同存链接/Simulator 日志、Swift 红绿结果和 `docker-build-green.log` / `docker-runtime-validation.json`。源码、框架缓存、完整 App 副本及 SDK 不提交 Git。初次 `/private/tmp/area-target-opencv5/` 已在会话延续时丢失；未完成的进程没有计为通过，受影响门禁已在持久目录重跑。初始完整数值记录保留在已提交的 `opencv5-comparison-results.json`；不得宣称旧原始临时文件仍可访问。

本地 develop 集成按用户确认的方案执行，并保留升级分支和现有待提交 iOS 功能。尚待发布验收：用真实旧地图和新会话查询对照成功率、误定位、位姿误差、恢复时间和 median/P95；在目标 iPhone/iPad 完成签名部署与持续定位验收。源码合并不更新手机上已安装的 App。本轮不推送、不推进 main/publish，也不更新线上服务。
