# 2026-10-09 手机功能整合验收

产品采用 ORB 优先、无通过候选时使用 AKAZE，默认 standard。地图 CLAHE 开关可手动开启，默认关闭；Quality/Fast、UV/纹理和 CLAHE 随新任务冻结。LoMa 继续在 Data 做实验，不进入本轮产品依赖。

本轮整合覆盖扫描质量与关键帧、100 帧准备、任务暂停/续传和停止跟踪、源删除保护、AreaTarget/Immersal 离线入口、共享 Session、网格对齐、录像保存与同输入串行回放。产品以远端 develop `629bc98bd08c224ac6955fcb5cd1af393b5445fe` 为基线进行三方合并；原工作区和手机原采集数据保留。

## 验证记录

详细结果、首次失败、修复前后证据、源码及制品身份保存在 [Data 验收目录](https://github.com/3dugc/Data/tree/codex/confirmed-phone-delivery-20261009/results/traditional-phone-delivery-20261009)。

| 范围 | 结果 |
| --- | --- |
| 共享 C++ | 37 项通过，包含 SQLite fixture 的真实加载与定位 |
| Python | 719 项：713 通过、6 跳过、0 失败；另按文件隔离核对相同用例集合 |
| iOS framework | device/simulator 构建、31 个 ABI 导出、严格签名与 Immersal 同镜像链接通过 |
| 真机 | iPhone 15 Pro / iOS 26.7.1：794 项，789 通过、5 跳过、0 失败；App 1.0（6）已正常启动 |
| 模拟器 | iOS 26.5：794 项，789 通过、5 跳过、0 失败 |
| Unity | 真实 native dylib 的桥接单调用、缺符号分支、POD 布局及包构建通过；完整 Editor 回归待官方 UPM 认证恢复 |

已存录像的 32 帧均实际调用 standard native：8 帧返回、24 帧拒绝。没有独立位姿 GT，返回数量不能表示准确率，也不构成新增独立采集。完整候选探索诊断保留在 Data；手机 trace 记录该查询路径实际尝试的候选。

首轮真机失败推动修复了资产 URL 别名一致性、超大输入在 hash 前的预算预检，以及任务状态乱序回包保护。测试宿主使用临时存储与测试范围内的无障碍语义访问，不启动生产共享 Session。最终真机测试宿主保持亮屏；正常 App 启动关闭测试宿主。真机五项跳过为三个显式云端/外部包测试、一个原始采集诊断夹具和一个真实持久 owner 测试，逐项理由保存在 Data。

## 新电脑复现

```sh
git submodule update --init --recursive
python3 tools/ios/bootstrap_immersal_sdk.py
open ios_scanner/AreaTargetScanner.xcodeproj
```

SDK 恢复脚本固定官方来源提交并校验 SHA；SDK 二进制不纳入 Git。用本机合法 Apple 签名和设备运行 `AreaTargetDeviceSmoke`，保持设备解锁。OpenCV 5 + contrib 与共享 C++ framework 通过构建脚本恢复；缓存位置及实际命令在 Data 记录中。

真实录像验收需要设备上已有匹配地图和录像，并显式启用 `AREA_TARGET_DEVICE_RECORDING_REPLAY=1`。测试只读原文件，在 Caches 副本上重载回放。现场新采集、独立定位 GT、Android/Rokid/头显以及完整 Unity 场景回归仍按 Data 交接计划继续。
