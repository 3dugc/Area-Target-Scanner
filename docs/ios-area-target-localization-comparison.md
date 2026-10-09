# iOS 离线定位与同一扫描对比

## 操作流程

1. 在 iOS 中保存一次原始扫描。分别切换到 Area Target 和 Immersal，用这份扫描建图；等待处理完成并下载两套定位资产。首页右上角齿轮进入独立「设置」页，也可从 Area Target 处理页打开。新任务默认 Quality、开启 UV 与纹理重建；可以选择 Fast 或关闭重建，设置自动保存。关闭重建仅适用于已有完整 UV、材质和纹理的扫描。处理页显示新任务设置，已提交任务冻结模式与 UV 选项，暂停续传保持原配置；下载完成后点击「按设置重新建图」创建新任务，旧任务和地图保留，可在任务历史中查看实际设置。改设置不会修改已经下载的地图。
2. Area Target 的已下载任务进入「离线定位测试」，Immersal 的已下载地图进入定位测试。回到原空间后点击开始，允许相机权限，缓慢走动并改变观察角度。定位在本机执行。
3. 选择该扫描场景，进入「处理」页面的独立「算法比较」选项；在两个平台页面均可进入。两套本机地图必须下载完成且具有同一个有效原扫描指纹。Area Target 任务内的录像比较快捷入口进入同一功能。
4. 点击「开始录制视频」，在原空间保持正常 AR 跟踪并移动至少 3 米。连续无声 MP4 用于回看，同时冻结评测帧和相机参数；建议采满 32 帧，约 47 秒，最长 60 秒。停止录制后先保存，用户点击「开始比较」再依次测试 Area Target、Immersal。
5. 查看每项数值、差值、评分贡献、逐帧返回/耗时、连续失败/恢复和 Area Target 下次实验建议。可分别分享 JSON、Markdown 报告与 MP4。保存失败可重试；容量不足时可先删除旧录像再保存当前录制。已保存录像可重复测试，地图更新后报告按准确资产身份隔离。

新版录像比较在追踪中断或进入后台时停止采集并保存此前的有效连续段；不足样本仍可保存和比较原始指标。用户明确取消录制会丢弃尚未保存的输入。实时定位测试、旧内存同帧测试及回放在进入后台时停止。相机授权提示引起的短暂 inactive 不会取消测试。重新开始后，旧运行的延迟结果不会进入新报告。

## 同一扫描如何确认

新任务在打包前后计算并核对 `sourceFingerprint`，随后将其与上传任务一起冻结。指纹覆盖规范化的帧姿态、时间、内参、图像尺寸/方向、原始图像字节和原始 `model.obj`；文件名、ZIP 包装和显示名称不作为身份依据。两家各自的上传包可以不同，原始扫描身份必须相同。

历史任务缺少指纹时保留「来源未知」，不能用当前文件回填并宣称旧地图来源相同。仍可离线定位、查看成功率和耗时；需要可比较评分时，用同一份仍保存完整的原扫描重新提交两家并下载结果。原扫描被修改后，重新上传形成新来源。Area Target 的实时定位与共同帧回放共享 `area-target-native-1/opencv-5.0.0/no-ar-prior` 身份；Immersal 保持 SDK 2.4.0 与原 SDK SHA256 身份。历史对比报告还须匹配两家完整资产身份（地图 ID、可用摘要、引擎版本和配置）；即使原扫描指纹相同，重新建图也不能显示旧地图配对的结果。

Area Target 的特征点直接位于原扫描 ARKit 世界坐标，单位为米。原 OBJ 只在当前扫描指纹与任务冻结指纹一致时叠加；模型缺失仍可用本机特征库定位。Immersal 地图坐标需要由原扫描帧估计到原扫描坐标的变换；无法确认时保留原始识别/耗时，暂不计算可比较总分。

## 测量与评分边界

评分至少需要 **20 次有效算法调用、30 秒采集时间、3 米正常 AR 跟踪轨迹**，三项同时满足。定位失败也计入调用总数和耗时；轨迹来自所有有效测试帧，不能只按成功帧算移动距离。缺失相机位置会断开运动段，无效时钟、耗时或姿态不能成为成功证据。

表现分 v1 使用成功率 40%、P95 耗时 20%、P95 对齐平移变化 20%、P95 对齐旋转变化 20%。后三项参考值分别为 3 秒、0.25 米、5°，达到或优于参考值获得该项满分。筛查结论还独立检查成功率至少 80%、首次识别响应不超过 10 秒等门槛，不能只凭总分判断。

来源已知且采集充分但完全未识别时为 0 分。来源未知、共同坐标未确认，或已有返回姿态但仅成功一次时总分为空，并明确说明缺少的证据。两家 SDK 的 confidence 含义不同，不参与共同评分。

对齐变化衡量连续识别的稳定程度，**不是经真值验证的绝对定位精度**。评分是当前设备、当前采集段的经验筛查；它不能证明所有空间中的算法优劣。

首次识别保留两种时间：从首个采集帧到首次成功的采集偏移，以及截至首次成功累计的算法调用耗时。实时测试的首次响应采用「采集偏移 + 首次成功调用耗时」；录制回放采用累计算法耗时，不能把录制期间的等待当成算法响应时间。

## 同帧回放的公平性

共同帧只录制一次：正常且连续的 AR 跟踪、至少间隔 1.5 秒、最多 32 帧/96 MiB 灰度像素。最长边限制为 1920；灰度像素和内参统一缩放一次，随后相同序列、时间、尺寸、内参及像素交给两家。

Immersal 使用原扫描帧校准坐标，校准照片不计入评分。校准完成后关闭并重新载入引擎，再开始评分；Area Target 同样以新载入句柄开始。两家算法不接收实时 AR 位姿先验，AR 位姿仅用于把返回结果组合到共同世界坐标并统计轨迹。评分回放内保留各自连续定位状态，因此这是连续流测试，非逐帧独立识别实验。

固定按 Area Target → Immersal 顺序执行，避免两引擎同时竞争资源；设备温度、后台负载、执行顺序仍可能影响结果，应重复测试并对照各项指标。对比 JSON 记录来源/共同帧指纹、资产身份与可用摘要、引擎版本/配置、采样策略、执行顺序、校准排除和重新载入标记，以及评分版本和实际阈值。新版录像比较将 MP4 与原始冻结评测帧保存于本机 Application Support/LocalizationRecordings，包含唯一录制 UUID、原扫描指纹、图像与参数二进制摘要、视频校验值及设备/App 版本。包在完整写入、校验后原子发布，不自动上传或删除；用户主动删除对应录像。灰度输入最多 96 MiB，单视频最多 128 MiB，录制包总量最多 2 GiB；视频编码队列最多保留 4 个相机像素缓冲。重复回放及副本沿用录制身份，不算新增独立采集。

JSON 报告不包含图像、令牌或 GPS，包含每次返回与耗时、共同成功帧数、录制身份、输入摘要、执行顺序、开始时热状态与工程实验建议；Markdown 提供可阅读的同一数据。没有独立真值时绝对精度、误识别率未测量；SDK 置信值、CPU、内存和功耗也明确未测量。跨供应商比较不满足同一 Area Target 候选的正式 A/B 晋升条件，promotionEligible=false。旧内存同帧测试仍只在本次运行期间持有图片；旧 schema v1 报告可继续读取。

完整保存的录像不会自动删除。未发布的临时包和已删除录像的残留会自动清理；损坏包提供明确删除入口，不会作为有效录像回放。录像容量不足时，保存重试页面允许删除其他扫描的旧录像，但不能用这些录像替代当前扫描的比较输入。

## 构建与合成复现

以下命令在仓库根目录执行。需要 Xcode、Python 3；首次 iOS native 构建需要下载并校验固定的官方 OpenCV 5.0.0 与 opencv_contrib 5.0.0 源码，包含 AKAZE 所需的 xfeatures2d。Xcode 构建阶段自动生成独立的动态 `AreaTargetNative.framework`，只导出 `vl_*` C 接口，其私有 OpenCV 与 Immersal 静态 SDK 隔离。产物和缓存位于临时/构建目录，不替换 Unity 插件或提交预编译 native 二进制。

```sh
xcodebuild -project ios_scanner/AreaTargetScanner.xcodeproj \
  -scheme AreaTargetScanner -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

合成夹具生成器要求已验证的 OpenCV 5.0.0 + contrib 静态安装和 Xcode Clang。通过 `OpenCV_DIR` 或 `--opencv-dir` 提供 `lib/cmake/opencv5` 的路径；下例路径可替换为实际固定依赖的安装位置。夹具生成及其端到端测试：

```sh
export OpenCV_DIR="$PWD/build/opencv5-unification/native-macos/install/lib/cmake/opencv5"
/usr/bin/python3 tools/ios/generate_native_fixture.py \
  --output-dir build/opencv5-unification/fixture
/usr/bin/python3 tools/ios/generate_native_fixture.test.py
```

输出生产格式 `features.db`、640×480 `query.gray8`、`fixture.bin` 与版本/已知姿态元数据 `fixture.json`。生成器实际编译三个定位 C++ 源文件，验证已知非共面合成场景姿态，以及空白/空输入丢失定位；固定的 OpenCV 5.0.0 producer 版本和实际库 SHA256 写入元数据；Swift 合成夹具测试要求 producer 为 5.0.0。它证明数据库、灰度图和 native 接口可接通，不代表跨会话现场准确率。

真实设备链接与私有符号检查：

```sh
python3 tools/ios/build_area_target_native.py --platform iphoneos \
  --output-dir /private/tmp/area-target-native-device
python3 tools/ios/verify_area_target_native.py --platform iphoneos \
  --framework /private/tmp/area-target-native-device/AreaTargetNative.framework \
  --composite-library ios_scanner/AreaTargetScanner/ThirdParty/Immersal/libPosePlugin.a
```

Simulator 的真实 C ABI smoke（先在 Xcode 启动一个 Simulator；避免与其他测试并发）：

```sh
python3 tools/ios/build_area_target_native.py --platform iphonesimulator \
  --output-dir /private/tmp/area-target-native-simulator
python3 tools/ios/verify_area_target_native.py --platform iphonesimulator \
  --framework /private/tmp/area-target-native-simulator/AreaTargetNative.framework \
  --smoke-fixture build/opencv5-unification/fixture --simulator booted
```

Swift SQLite→native 全链路使用 `AreaTargetNativeSmoke` scheme。它使用 `$(SRCROOT)/../build/opencv5-unification/fixture` 设置 `AREA_TARGET_SYNTHETIC_FIXTURE_DIR`；普通 scheme 默认跳过此 opt-in 夹具测试。

```sh
xcodebuild -project ios_scanner/AreaTargetScanner.xcodeproj \
  -scheme AreaTargetNativeSmoke \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UUID' \
  -parallel-testing-enabled NO \
  -only-testing:AreaTargetScannerTests/AreaTargetOfflineLocalizerTests test
```

将 `YOUR_SIMULATOR_UUID` 换成实际设备 ID。`LocalizationRenderTests` 仅渲染合成页面并附截图，禁止请求相机/网络或载入地图。默认保存 XCTest 附件；需要 host PNG 时在 scheme 的 Test 环境设置绝对路径 `AREA_TARGET_RENDER_OUTPUT_DIR`。现场定位、光照变化及跨会话精度仍需使用真实扫描和设备验证。

## 录像比较验证（2026-10-08）

完整 iOS 回归 660 项，656 通过、4 项需显式现场/线上条件的测试跳过、0 失败；最终 Session 调整后 7 项重跑通过。真实 H.264 编解码、保存/重载后同输入串行回放、报告兼容与校验、容量重试、两平台独立入口、窄屏和大字体渲染均已验证。自动化比较使用合成夹具，现场识别排名仍需要用户回到原空间录制。

签名 1.0（build 4）已安装到 iPhone 15 Pro，手机实际图标与升级前相同，原 Documents 598 文件共 2,402,305,596 字节的路径、大小、修改时间均保留。首次启动被手机锁屏阻止，解锁后继续核对。工程与设备证据见 [验证记录](validation/ios-recorded-comparison-install-2026-10-08.json)；方案、来源基线、评测结果保存在本机 Data checkout 的 `plans/2026-10-08-recorded-localization-comparison/` 与 `results/recorded-localization-comparison/2026-10-08/`。本次没有替换已确认图标或采用新的定位算法优化。

## 历史验证（2026-10-04）

主项目 `AreaTargetNativeSmoke` 完整回归：479 项中 478 项通过，1 项线上 opt-in 单独执行后通过，0 失败。真实 Swift → SQLite → iOS 原生定位的非共面已知姿态夹具通过；原生页面在浅色、深色和大字体下的 9 张截图经 iOS Vision OCR 验证。

`AreaTargetLiveSmoke` 使用三张程序生成图片完成实际 HTTPS 上传、处理、下载和产物校验，原生 iOS 引擎成功加载服务端生成的 3,000 个特征、500 个词。该测试不产生现场定位评分。

两套真实引擎在同一个 iPhone 目标的签名构建通过；设备与 Simulator 框架实际签名和严格校验通过。新版已安装到连接的 iPhone 15 Pro，用户解锁后已成功启动。现场识别率、跨会话稳定性及两种算法的实际排名仍需在原空间测试。

原项目的 90 个无关源文件和 SDK 文件保持冻结基线；Xcode 管理的界面状态保留。现有 Unity 原生插件未替换。


历史记录：2026-10-04 大扫描处理更新（旧 80 帧方案；2026-10-08 云端和手机已更新到 v2 的 100 帧方案，见 docs/validation）：iOS 在新任务打包前读取服务器公开的 `/api/v1/processing-requirements`。已知策略下，在只读原扫描之外生成临时派生包；按时间序列均匀选帧，保留首尾，最多 80 帧。各帧先约束长边 1600，再按总像素预算统一追加缩放，最终按实际宽高分别校正相机内参。该策略不是清晰度或特征价值评分，完整原始帧仍保留。获取要求失败或未知策略时提交原始包，服务器生成处理副本。

派生包、任务记录及构建报告保留客户端预处理策略、数量、选帧序号和缩放摘要；服务端结果另记录实际收到并处理的数量。客户端声明的原始帧数不是服务器对未上传原始数据的证明。原扫描来源身份由本机完整原始文件计算，资产身份还冻结结果包 SHA256；两家使用同原扫描、同测试帧，但建图预处理可能不同。

上传包仍受 512 MiB 请求、500 MiB 解压资源及每图尺寸安全检查约束。原扫描来源哈希的读取工作预算与派生上传大小分开；读入按 64 KiB 分块并可取消。它不改变原始文件，也不把派生包哈希用作共同扫描身份。

本次最终完整 iOS 回归：497 项，496 通过、1 项线上联调需显式开启、0 失败。结果 `/private/tmp/area-target-ios-preparation-release.xcresult`。原扫描来源哈希读取预算为总量 8 GiB、单文件 500 MiB，与上传包 500 MiB 解压限额分开；已有 v1 指纹完全兼容。新版签名构建通过，并已在保留 App 数据的情况下安装到连接的 iPhone 15 Pro，启动成功。线上 100 帧联调（`AreaTargetLiveSmoke` 显式开启）通过，1 项、0 失败，69.856 秒；结果 `/private/tmp/area-target-ios-preparation-live.xcresult`。


线上发布 `8ff69ce745794a43078edf3e853dd0a534033468` 已核对容器 revision，scanner/optimizer 均 healthy、scanner restart 0、OOM false。原始 100×1920×1440 合成输入（276,480,000 像素）在服务端生成 80×1600×1200 副本（153,600,000 像素），实际 ZIP 下载字节与 SHA256 校验通过。iOS 读取公开要求后完成 100→80 客户端预处理；服务器收到 80 帧、重复缩放 0，下载到真实 C++ 原生引擎成功载入 80,000 特征、500 词汇。此验证是合成数据的完整链路，不代表用户“测试大厅”的实际处理结果或现场定位评分。

客户端 13 项任务源文件在原项目与 iOS managed worktree SHA256 一致；85 项无关基线文件均保留。详细 CI、镜像、任务、构建和设备证据见工作区附件 `area-target-scan-preparation-verification.json`；三分支六工作流全部成功，临时推广目录已清理。原扫描可在新版中直接重试上传处理。

2026-10-08 客户端独立设置更新：Quality/Fast 与 UV/纹理重建设置自动保存，新任务默认 Quality 与开启重建。配置在创建任务时冻结，暂停续传不读取后来改动的偏好；现有 Fast 地图需要按设置重新建图才能获得新的 Quality 资产。689 项全套回归中 685 通过、4 opt-in 跳过、0 失败；深色截图夹具修正后另 2 个设置界面测试通过。App 1.0 build 5 已覆盖安装到 iPhone 15 Pro，用户解锁后成功启动并确认进程仍在运行。已确认图标保持一致，原 680 个 Documents 文件的路径、大小和修改时间一致；完整记录见 `validation/ios-client-settings-install-2026-10-08.json`。
