# 统一 C++ 定位核心与第一阶段质量改进

本轮采用「时间驱动的姿态平滑 + 异常门控 + 多帧确认」，并将自有识别、恢复和定位稳定策略集中到 `native_visual_localizer`。Unity、iOS Native 和 Python 通过桥接调用相同 C++ 源码；不再分别维护 C#、Swift 的定位滤波和降级算法。最终本机软件验收日期：2026-10-06。

实施基线为 develop `802e1bbe24fdb77792fc2a0866da1fda8140d121`，隔离工作分支为 `codex/localization-quality`。验证时加载了原工作区尚未提交的 iOS 功能，不能把整个隔离工作树的 Git diff 当成本轮改动。最终增量及原文件哈希记录在 `build/localization-quality/implementation-delta.json`。

验证通过后，仅将本轮 131 个增量文件同步到原工作区。12 个已有待提交文件增加本轮修改，另外 153 个待提交文件保持原字节；没有提交、合并或发布，原 HEAD、develop 分支、暂存区和嵌套仓库状态保留。变更前文件备份位于 `build/localization-quality/implementation-before/`，保全检查为 `workspace-preservation.json`。

## 已实现的行为

| 环节 | 行为 | 唯一策略实现 |
| --- | --- | --- |
| 采集 | 检查模糊、曝光和纹理；按时间、平移、朝向变化触发，反馈跳过原因 | `gray_quality.cpp` |
| 地图 | 从完整源帧中按质量和空间、朝向覆盖选帧，保留原始 image ID，记录版本并更新缓存身份；最终地图保存全源淘汰报告 | `keyframe_selection.cpp` |
| 原始识别 | ORB 不足可独立尝试 AKAZE；附近失败后检查全局候选；无 ORB 检索时按有限批次轮转 | `visual_localizer_impl.cpp` |
| 跨帧对齐 | 多帧确认、异常拒绝、时间平滑、恢复、有限持有、过期和重置 | `localization_session.cpp` |
| 静态网格对齐 | Immersal 对齐候选及刚体共识 | `rigid_consensus.cpp` |

`visual_localizer` 是唯一完整的运行时原生库目标，`area_target_runtime` 是它的 CMake 别名。旧 `vl_*` 的 11 个导出和数据布局保留；版本化 `atc_*` 新增 19 个导出，共 30 个。平台分别编译对应二进制，维护同一份算法源码。服务端的轻量质量内核也直接编译这些 C++ 源码，Python 只解码图像、打包参数和写诊断。

桥接负责设备取帧、图像行方向、相机标定、坐标转换、曝光与姿态绑定、时钟和身份、句柄生命周期以及显示。Unity 的 GLB 局部坐标只转换一次。重复初始化活动 tracker 会拒绝操作，避免新地图名称与旧地图对齐状态混用；切换地图需要结束旧实例并创建新实例。

## 平滑与卡尔曼的选择

旧 C# `KalmanPoseFilter` 的位置、欧拉角公式没有原样迁入 C++。保留的兼容类转调共享核心，旧噪声参数和计帧降级参数不再控制活跃定位策略。

当前平滑作用于「地图到跟踪世界」的对齐变换。相机的连续运动仍由 ARKit/ARFoundation 跟踪提供。平移使用时间插值，旋转使用四元数最短弧插值，避免按帧率调参和重复平滑相机运动。

| 核心默认值 | 当前值 |
| --- | --- |
| 初始及恢复确认 | 2 个新鲜、相互一致的结果 |
| 平移 / 旋转一致性门槛 | 0.25 m / 5° |
| 姿态与图像最大时间差 | 50 ms |
| 定位结果最大年龄 | 3 s |
| 可靠对齐的最长持有 | 3 s |
| 平滑时间常数 | 2 s |

这些值由核心默认配置接口读取，属于待现场调优的工程起点。调用方显式设置的结果年龄会传入核心；修改配置会清空旧确认历史和在途结果。

迟到、逆序、重复、无效和身份不匹配的结果不能延长可靠对齐的有效期。宿主定时调用 `poll`，即使没有新的定位返回也会过期。持有旧对齐不增加原始视觉成功次数。地图、跟踪批次或时间基改变时清空历史。

未来若有可信速度、IMU、运动模型和观测协方差，可以在这个核心里评估误差状态卡尔曼滤波。仅更换滤波器不能改善特征匹配失败，也不能证明绝对对齐更准确。

## Immersal 与设备边界

iOS 保留现有 Immersal SDK 2.4 的原包、头文件和接口。SDK 私有识别实现仍属于外部后端；其定位输出进入自有 C++ Session，静态网格对齐也使用核心共识。SDK 原始分数仍用于界面和评测，不冒充自有引擎的归一化置信度。

设备构建保留 SDK 私有 OpenCV 与自有 OpenCV 5 的隔离链接。Simulator 无法证明 SDK 的真实设备定位行为，对应测试明确跳过。

ARFoundation 的 CPU 图像曝光时间与宿主单调时钟需要明确映射，`frameReceived` 中读取的相机变换也需要设备端确认与曝光绑定。桥接提供 `CaptureClockMapper` 和 `PoseSampleIsFrameBound`；未满足两个合同的输入仍可做原始识别，但不发布可显示的稳定对齐。Editor 和离线回放测试不能代替真实设备校准。

离线回放保留记录中的帧 ID、曝光时间和姿态，在 Play/Seek 时明确建立时间映射并重置 Session；暂停时使用真实宿主时钟检查过期。不会将旧曝光时间改成当前到达时间。与记录时间不相容的播放速度可能被核心拒绝。

## 验证记录

本轮软件回归已取得以下结果。Unity 使用本机已安装的 6000.6.3f1；项目指定的 6000.4.6f1 未在本机安装，未声明该版本也已验证。

| 验证 | 已取得的结果 | 证据位置（仓库内） |
| --- | --- | --- |
| macOS C++ | 18 / 18 CTest 通过；精确 30 个导出，旧 ABI 保留 | `build/localization-quality/native-combined-final-green.log`、`native-combined-symbol-validation.json` |
| 完整 iOS Swift | 执行 579 项，跳过 3 项，零失败 | `build/localization-quality/swift-complete.log`、`swift-complete.xcresult` |
| Apple framework | device / Simulator 严格签名、资源、源码身份与打包验证通过 | `build/localization-quality/apple-packaging-signing.log` |
| Unity iOS 原生库 | 合并库编译及全部导出链接通过 | `build/localization-quality/build-ios-wrapper-complete.log` |
| iPhoneOS App | 含原 Immersal SDK 的未签名 device 构建通过 | `build/localization-quality/device-build.log` |
| SDK 同镜像共存 | 30 个自有 C API 与 SDK 引用完整链接通过 | `build/localization-quality/immersal-composite.log` |
| Linux 服务端质量内核 | Docker 实际构建及无网络容器内 FFI、纹理、覆盖选择检查通过 | `build/localization-quality/docker-native-kernel.log` |
| Unity 完整 EditMode | 1020 / 1020 通过，无跳过 | `build/localization-quality/unity-complete.xml` |
| Python 完整回归 | 管线 436 项、网格 20 项通过，另 7 项跳过；两个进程均产生完整 JUnit | `build/localization-quality/python-regression-final.log` |
| 最后新增的全源报告合同 | 实际 RED 后修复，相关 worker 12 / 12 通过 | `build/localization-quality/python-source-report-worker-green.log` |

Python 的旧保全测试曾断言「任意 10 帧子集成功率都至少 90%」。相同 OpenCV 5 和相同数据在 HEAD 与当前测试中均为 92 / 94 成功，但包含两帧失败的 10 帧子集为 8 / 10，该全称断言在数学上不成立。本轮仅删除该断言，保留完整 94 帧大于 95% 的门槛、精度和内点率要求；没有降低阈值或过滤失败帧。该测试使用自己的历史 Python ORB/PnP helper，不能当作本轮 C++ 收益数据。证据为 `build/localization-quality/python-preservation-diagnosis.json`。

未验证 Android、Windows 的完整原生运行时，也未安装真机或发布服务。没有现场识别率、对齐精度、漂移、抖动或耗电提升的测量结论。

## 现场 A/B 与回滚

先用同一场景的原始采集与测试序列比较旧、新管线，保持帧、标定和评测分母一致；分别报告原始定位成功率、误接受率、首次定位时间、恢复时间、位置/角度误差、静止抖动及显示延迟。持有时长和稳定显示比例单独统计，不能计为新的识别成功。

再比较旧地图与质量覆盖地图，确认低纹理、转角、重复纹理、光照变化及快速运动下的结果。记录设备、配置、地图选择版本、每个拒绝原因及连续运行性能。平滑时间常数需要同时观察抖动与响应延迟，不能只看画面更稳。

旧底层 `even` 选帧模式保留用于对照；它不是自动切换所有新策略的总开关。回滚运行时代码时必须同时恢复对应桥接和原生二进制，避免 30 个导出契约与旧库混用。Immersal SDK 原包不需要随本轮回滚。使用本轮增量清单逐文件恢复变更前内容，保留原工作区其他未提交功能；不要对整个工作区执行 `reset --hard`。
