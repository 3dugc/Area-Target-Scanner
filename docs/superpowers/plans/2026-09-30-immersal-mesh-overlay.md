# Immersal 扫描网格叠加实现计划

> 使用并行子任务实现独立加载、坐标估计和关键帧准备，主任务整合相机与界面。

**目标：** 在离线定位画面中叠加同一任务原扫描网格，让用户直接对照真实墙角、门框和地面观察定位。

**架构：** 使用当前 App 已保存的 OBJ（当前基础和纹理导出均会生成），保持原米制坐标。虽然官方 preservePoses 对同源输入支持坐标匹配，仍以至多8张原始关键帧进行本机重定位，估计并验证 mapFromScan；这些建图帧仅用于模型坐标对齐，不计入现场质量报告。实时节点变换为 worldFromMap × mapFromScan。没有本机模型、坐标不连续或对齐不足时保留原现场测试，并解释模型未显示的原因。

**技术：** Swift、流式 OBJ 解析、SceneKit、ARKit、现有 Immersal native SDK。

- [x] `ImmersalScanMeshLoader.swift` + tests：载入同源网格，保留顶点/child变换，常亮青色线框，不重新居中或缩放；拒绝缺失、空模型和越界路径。文件分块读取，不复制整份模型文本或载入纹理。
- [x] `ImmersalAlignmentFrames.swift` + tests：验证schema、run、位姿、内参、图片尺寸与路径；均匀抽最多8帧，生成原尺寸灰度像素。
- [x] `ImmersalMeshAlignment.swift` + tests：CV相机轴转换，候选 mapFromScan，至少3匹配且60%一致（0.25m/5°），拒绝非刚性/离群/歧义结果；不拟合缩放来掩盖网格误差。
- [x] `ImmersalLocalizationSession.swift`：后台准备、离线原图标定、各await后的generation检查；模型准备失败不阻塞现场定位；重启/停止清除旧模型变换。
- [x] `ImmersalMappingView.swift` / `ImmersalMapTestView.swift`：通过任务scanName绑定原扫描目录；线框开关和透明度；只有有效现场定位与验证的mapFromScan同时存在才显示；未匹配/中断立即隐藏。
- [x] 运行定向及完整XCTest：iOS319项通过、独立macOS加载器13项通过；已检查原生渲染及独立审查，真机签名构建、覆盖安装和启动完成。验证记录见 `docs/design/immersal-mesh-overlay/design-qa.md`。

不下载或重建云端GLB，不把原扫描关键帧的匹配当作新场景质量测试。现场叠加准确性仍需要用户实际对照观察。
