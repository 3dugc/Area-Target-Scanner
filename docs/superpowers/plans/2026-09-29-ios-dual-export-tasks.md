# iOS 双格式导出实施记录

依据：用户于本会话批准的《iOS 扫描器双格式导出计划》。保留扫描、模型与原生 ZIP；在预览页选择 Area Target / Immersal；新增 GPS；仅本地和真机验证，不上传云端。

- [x] 1. 固定 Immersal 格式、ARKit 转换和图像合同，增加独立投影测试。
  - 已实现并通过合成与真实编码图像测试：从持久化 schema-v1 manifest 按需生成逐帧 PNG/JSON；旋转 R×diag(1,-1,-1)，位置不变。
- [x] 2. GPS 与 run 分段采集、逐帧持久化；拒绝/无信号/过期填零，保持旧 manifest 兼容。
- [x] 3. 预览页双格式选择、异步进度/取消/防重复、原子 ZIP 替换、历史容量与删除。
- [x] 4. XCTest、原有扫描合同回归、签名构建与设备安装运行。
- [x] 5. 真机新扫描、两种 ZIP、历史重导出、预览/分享/删除及实拍坐标尺度检查。
  - 已在 iPhone 15 Pro 采集 44 帧并生成两类真实 ZIP，用户已提供文件；CRC、PNG/JSON、原模型材质与逐帧坐标交叉检查通过。
  - 用户于 2026-09-29 确认“都没问题了”，授权发布到 develop/main。构造空间点投影和原始米制轨迹尺度保持已验证；真实场景人工标注/独立绝对尺度标定未做。见 [验证记录](../../ios-dual-export-validation.md)。

## 固定约定

- ZIPFoundation SPM exact 0.9.20；新 ZIP 根目录仅 2N 个 PNG/JSON 文件。
- Immersal 包位于原生目录旁，后缀 `_immersal.zip`，不混入原生包。
- 帧 JSON 含 imagePath/run/index/anchor、像素内参、米制位姿、GPS，不含凭据。
- GPS 关联拍摄时最近有效定位，最大年龄 15 秒；仅海拔无效时保留经纬度。
- 保留现有工作区的 Xcode 自动格式化、Info.plist、子模块与格式说明变更。

## 验证证据

- 2026-09-29：全量 `xcodebuild test`（iPhone 17 Pro / iOS 27 模拟器、禁用并行测试）通过，123 tests / 0 failures，包括 17 个 Immersal exporter 测试、5 个异步/历史测试、7 个 GPS/run 测试和原有扫描器/纹理测试。
- 独立投影测试覆盖单位姿态、各轴 90°、组合旋转、非零平移；包含逆变换、距离、行列式/正交性及 `< 10⁻⁴` 像素误差断言。
- exporter 测试包含实际 RGB8 PNG、JPEG EXIF 不旋转、根目录 2N/CRC、真实只读目录写入失败、注入发布失败、取消保留旧包与元数据定位错误。
- `python -m pytest --confcutdir=tests/phase1 tests/phase1/test_scan_contract.py -q`：12 passed；隔离运行该自包含合同测试，避免无关顶层 numpy fixtures。
- 真机 `xcodebuild build` 成功，安装并启动于已连接的 iPhone 15 Pro。设备原有数据保留；已收到并验证两类真机 ZIP。用户已确认使用无问题，第 5 项按本地格式与真机导出范围验收。
- 测试日志：`/tmp/dual-export-full-tests.log`；xcresult：`/tmp/area-target-dual-export/Logs/Test/Test-AreaTargetScanner-2026.09.29_21-05-20-+0800.xcresult`；设备构建：`/tmp/dual-export-device-build.log`。
- 独立代码复查提出主线程重复 eligibility 校验、自动原格式打包失败离开预览两项问题；均已修复并复查，无已知阻塞问题。
- 发布授权：将本功能提交推送 develop，通过 CI 后合并并推送 main。model_optimizer 独立改动保留；未调用 Immersal 云端接口。
