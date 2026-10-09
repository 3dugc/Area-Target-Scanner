# Immersal 原扫描网格叠加验证

## 交付范围

离线测试读取所选建图任务对应的本机 `model.obj`，保持米制坐标、原点与尺寸。相机画面默认叠加青色线框，提供开关和透明度；准备阶段显示进度，未匹配、中断或停止时隐藏网格。

最多8张原扫描照片在本机核对模型与地图的坐标关系。至少3张有效匹配、60%在0.25米/5°以内一致才发布 `mapFromScan`；实时绘制使用 `worldFromMap × mapFromScan`。这些旧照片不加入现场测试报告。模型、照片缺失或坐标核对失败会给出原因，并继续使用原定位测试标记。

## 代码及流程验证

- OBJ 加载器采用最多256 KiB的分块读取，限制未完成行长度，不读纹理、不创建全文件字符串或临时副本；保留顶点和三角索引的必要内存。覆盖负索引、多边形、CRLF、分块断行、无尾换行、无效引用及路径校验。
- 原照片读取检查 manifest schema、同一追踪批次、刚性位姿、图片方向、内参、尺寸、唯一索引与路径。测试灰度图像的行顺序。
- 数学测试覆盖 CV/AR 相机坐标转换、非零平移/旋转组合、离群匹配及非刚性输入。
- 会话测试覆盖旧图不计入现场报告、无模型/无匹配回退、停止后迟到结果不发布、不启动相机。
- 节点测试验证父子变换组合、原几何不居中缩放、开关/无定位隐藏、任务目录关联。
- 独立复核发现并修复 `Data.removeFirst` 保留已读文本底层存储的问题。新增 macOS 100 MiB合成文本回归：修复前读取回调处的峰值分配增量约118.6 MB，修复后不再积累已读文本；13项独立加载器测试通过。该测试不代表完整网格的总内存或真机耗时，顶点、索引及GPU仍需必要内存。

最终 iOS 完整 XCTest **319项通过，0失败**，日志 `/tmp/immersal-mesh-final-full.log`。独立 macOS 加载器测试 **13项通过**，日志 `/tmp/immersal-mesh-storage-green.log`。原生视觉截图属于同一实现的组件渲染，另有完整回归中的重跑。

最终结果包：`/tmp/area-target-platform-build/Logs/Test/Test-AreaTargetScanner-2026.09.30_16-23-44-+0800.xcresult`，`xcresulttool` 确认 Passed、319 passed、0 failed、0 skipped。Xcode 在用例结束后卡于附加 `simctl diagnose` 收集，已仅终止该收集子进程；`xcodebuild` 随后正常以0退出并输出 TEST SUCCEEDED。保留一项SceneKit渲染测试的内部QoS运行时警告，不影响测试通过。

最终真机签名构建通过，日志 `/tmp/immersal-mesh-final-device.log`。已覆盖安装到连接的 iPhone 15 Pro，并成功启动；只读进程检查确认应用运行。安装、启动及进程记录分别为 `/tmp/immersal-mesh-final-install.json`、`/tmp/immersal-mesh-final-launch.json`、`/tmp/immersal-mesh-final-running.json`。没有卸载应用，原扫描文件保留。

## 原生视觉检查

`ImmersalMeshOverlayRenderTests` 通过 `UIHostingController` 和 `SceneView` 渲染实际原生组件，导出浅色、深色与大字体截图：

- [浅色](mesh-overlay-light.png)
- [深色](mesh-overlay-dark.png)
- [大字体](mesh-overlay-large-text.png)

截图尺寸393×852像素，使用合成几何，画面明确标注“线框示例（合成几何）”和“此截图不是实景定位结果”。它们只证明线框、开关、透明度与文字布局；不代表用户模型已正确对齐。普通及大字体下文案清晰，大字体可滚动，青色线框在深浅背景均可辨认。

## 真机数据与实测边界

只读检查连接设备的最新扫描：本机存在约102.6 MB的 `model.obj`；manifest有77帧、单一追踪批次、1920×1440图像，满足模型坐标核对的元数据条件。没有把用户网格或照片复制进仓库，也没有执行云端清空、上传或建图。

自动化验证不能代替原场景实测。仍需用户在原空间运行本机定位，比较墙角、门框、地面边缘，并检查不同位置和角度；视觉误差也可能来自原扫描模型漂移。尚未对用户地图给出质量结论。
