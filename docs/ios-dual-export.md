# iOS 扫描器双格式导出

扫描处理完成后，在预览页点击「导出」，选择「Area Target 原格式」或「Immersal 格式」。成功后打开系统分享面板。同一次扫描可以先后导出两种格式；从扫描历史进入预览页也使用相同入口。

## 文件与兼容性

两类 ZIP 均保存在扫描目录旁，历史容量统计与删除包含这两个文件：

```text
Documents/
├── scan_20260929_220000/             # 原始 JPEG、manifest、模型、纹理等
├── scan_20260929_220000.zip          # Area Target 原格式
└── scan_20260929_220000_immersal.zip # 按需转换，不重新生成模型
```

原格式保留原有目录与处理管线。Immersal 包根目录严格为 `frame_0000.png`、`frame_0000.json` 等成对文件，保留 manifest 中的原帧编号；无目录、模型、凭据或额外说明文件。JSON 固定包含：

- `imagePath`、`run`、`index`、`anchor`（默认 false）。
- `fx/fy/ox/oy`（每帧内参，以像素为单位）。
- `px/py/pz`（米）及 `r00`…`r22`。
- `latitude/longitude/altitude`。

缺少完整逐帧内参、位姿、图像尺寸或方向的旧记录会禁用 Immersal，并解释原因；原格式仍可导出。完整 schema-v1 历史记录不需要重新扫描。没有 `run` 时取 manifest 文件内容 SHA-256 前 4 字节的大端整数，掩码 `0x7fffffff`，将 0 替换为 1，得到重复导出稳定的编号。

## 图像和坐标合同

只接受 `schemaVersion: 1`、`arkit-world`、`arkit-column-major`、`meters` 以及原始 `landscapeRight` 图像。每张已保存 JPEG 解码为 8-bit RGB PNG（PNG color type 2），不按 EXIF/屏幕方向旋转，不缩放、裁剪；尺寸和像素方向保持一致。PNG 不能恢复 JPEG 已损失的画质。

内参 `fx/fy/cx/cy` 对应 `fx/fy/ox/oy`。输入为 ARKit 相机到世界的 4×4 矩阵；转换为：

```text
pImmersal = pARKit
RImmersal = RARKit × diag(1, -1, -1)

列主序数组 a:
位置 = (a[12], a[13], a[14])
RImmersal = [a[0], -a[4], -a[8];
             a[1], -a[5], -a[9];
             a[2], -a[6], -a[10]]
```

按 `r行列` 字段写入，不转置。实现依据用户批准的 [官方 Swift 示例](https://github.com/immersal/immersal-sdk-ios-samples/blob/main/PosePluginNativeTester/PosePluginNativeTester/ViewController.swift)与 [Capture 序列化源码](https://github.com/immersal/imdk-unity/blob/main/Runtime/Scripts/REST/RESTJobsAsync.cs)推导合同；合成投影和像素测试验证本地数学与编码一致性，实拍验证另行记录。

## GPS 和跟踪分段

开始扫描时申请「使用 App 期间」定位权限。仅扫描且 App 在前台时更新；停止扫描或进入后台后停止，无后台定位。扫描界面显示 GPS 是否可用。拒绝授权、定位失败或无信号均不阻塞扫描。

`CameraPose` 与 `manifest.frames` 增加可选 `run`、`location`，schema 仍为 1，既有必需字段不变。`location` 包含经纬度、海拔、Unix 定位时间、水平/垂直精度。每个关键帧绑定拍摄时最近的有效快照：坐标合法、水平精度非负、定位时间不晚于拍摄且相差不超过 15 秒。没有有效快照则省略 location，Immersal GPS 三项填 0；仅海拔或垂直精度无效时保留经纬度，海拔填 0。

每次新扫描及跟踪中断后恢复生成新的正 31 位 `run`，同一连续跟踪段保持一致，保存后导出不改变编号。导出从磁盘读取，不获取导出时当前位置。

## 可靠性与测试

ZIPFoundation 精确锁定 0.9.20。后台一次转换一帧并增量写入文件 ZIP，内存开销随单张图像大小变化；UI 显示转换、打包与保存状态。取消、重复点击、异常与迟到回调由独立任务标识和取消状态处理。临时 ZIP 与目标在同一目录；仅全部完成才用原子 rename 发布。失败或取消清理临时文件，保留扫描数据和之前成功包。

导出检查文件路径与配对、图片实际尺寸、有限内参与合法旋转矩阵。坏帧终止整包并报错，不静默丢帧。测试覆盖真实可解码 JPEG、不对称像素标记、PNG IHDR、ZIP 条目/CRC、坐标投影、旧 manifest、GPS、取消、写入/发布失败、重复点击及历史容量删除。

模拟器回归：

```sh
xcodebuild -project ios_scanner/AreaTargetScanner.xcodeproj \
  -scheme AreaTargetScanner -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO test
python3 -m pytest --confcutdir=tests/phase1 tests/phase1/test_scan_contract.py -q
```

## 真机验收步骤

1. 在 LiDAR iPhone 开始扫描，确认定位提示与 GPS 状态；采集包含平移和旋转的少量帧，停止后确认原有模型/纹理预览。
2. 分别选择两种格式并通过系统分享保存；检查包名、原格式内容及 Immersal 的 `2N` 个根目录 PNG/JSON。
3. 再次导出 Immersal 并取消，确认可重试，旧成功包仍存在。
4. 退出重开 App，从历史记录再次导出，确认 run/GPS 与第一次一致；检查容量，删除测试记录后确认目录与两类 ZIP 一起移除。
5. 离线结合实际相机运动与场景点检查方向、投影和米制尺度；允许/拒绝定位均走一次，不以模拟器结果替代实拍结论。

实际两种 ZIP 的检查结果见 [真机文件验证记录](ios-dual-export-validation.md)。实施与验证状态见 [实施记录](superpowers/plans/2026-09-29-ios-dual-export-tasks.md)。本页描述的本地导出不调用云端接口；另有 [直接上传与建图](ios-immersal-direct-upload.md) 入口，无需先生成 ZIP。尚不声明完成 Immersal 云端建图验证。已有包的格式核查见 [All.zip 核查](immersal-scan-upload-format.md)。
