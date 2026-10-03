# Immersal 直接上传与建图实施记录

依据：本会话中用户批准的直接上传方案，以及“只有邮箱和密码，Token 保存在本地下次使用”的更正。实现不要求先生成 ZIP，保留扫描、预览、历史及双格式导出；OpenCV 保持 4.x。

## 约定

- 邮箱/密码调用官方 HTTPS `/login`。仅账号信息和 Token 存入本机 Keychain，不保存密码，无手动 Token 入口。失效重新登录；退出清除凭据并暂停本机任务。
- 预览页（包括历史预览）选择“上传并建图”，使用已保存 JPEG/manifest，复用已有 RGB PNG 和坐标转换；串行逐帧 `/capture`，无需 ZIP 或中转服务器。
- 一次只处理一个工作区上传；先验证所有本地帧、容量、工作区图片数和账号绑定。已有图片时仅经用户明确确认才调用 `/clear`（含 anchor）；不静默混入。
- 本地任务持久保存账号 ID、来源、内容摘要、已确认帧数、发送中操作、地图名、地图 ID 和状态；不保存 Token/密码。暂停、退出、后台、重启后可恢复。发送中断结果不确定时禁止盲重试，提供明确的工作区清空重传；建图结果不确定时仅核对 `/list`，不重复 construct。
- 全部帧确认上传后自动 `/construct`，按用户最终要求固定 `preservePoses=true`。地图名只用英文字母数字并加任务唯一标识，用于请求失联后的查找。前台轮询 `/list` 显示真实阶段；云端建图不因关闭界面/进入后台停止。
- 上传任务独立于预览页；需本地源数据期间禁止删除对应扫描。首版上传在前台执行，后台暂停、回到前台由用户继续；建图查询可自动恢复。
- 真实云端验收需要用户在 App 输入凭据并选定扫描，本次不会索取明文密码或在自动测试中上传个人扫描。

## 实施任务

- [x] 1. 协议和转换：增加直接帧读取接口；测试与 ZIP 内容逐字节一致、无 ZIP 副产物、坏帧与源变化检测。
- [x] 2. REST/Keychain：登录、状态、capture、clear、construct、list；二进制协议、错误识别、凭据保存/删除及 URLProtocol 测试。
- [x] 3. 上传状态机：持久化、账号隔离、配额/工作区、取消/恢复、结果未知保护、建图与轮询；故障注入测试。
- [x] 4. SwiftUI 集成：邮箱密码登录、地图名称、上传/暂停/继续、清空确认、任务列表与状态、退出登录、扫描删除保护。
- [x] 5. 回归与交付：全部 XCTest、扫描契约测试、真机架构编译、说明文档和独立代码审查。云端实测单列实际状态，不与本地模拟网络测试混淆。
- [x] 6. 按用户最终更正将 `/construct` 的 `preservePoses` 固定为 `true`，更新请求体断言、功能说明并重新验证。

当前进度：本次授权的实现、本地验证和独立复查完成。用户已再次明确授权直接上传与建图及模拟网络测试，不实际上传数据。官方契约依据：https://developers.immersal.com/docs/rest-api/ 和 https://developers.immersal.com/docs/rest-api/python-example/ 。

## 验证记录（2026-09-30）

- Xcode 27 beta / iOS 26.5 iPhone 17 Pro 模拟器，全量 XCTest：154 项通过，0 失败。包含 21 项上传状态机、6 项 REST/Keychain、20 项 Immersal 转换/导出与 6 项导出界面模型测试，其余为既有扫描/纹理等回归。
- `venv/bin/python -m pytest --confcutdir=tests/phase1 tests/phase1/test_scan_contract.py -q`：12 项通过。
- `xcodebuild -project ios_scanner/AreaTargetScanner.xcodeproj -scheme AreaTargetScanner -destination 'generic/platform=iOS' -derivedDataPath /tmp/area-target-upload-device-build CODE_SIGNING_ALLOWED=NO build`：BUILD SUCCEEDED，真机架构编译通过。
- 随后按用户要求使用现有 Apple Development 签名构建，安装并前台启动到 iPhone 15 Pro（iOS 26.7），设备进程查询确认 App 正在运行。采用覆盖更新，未卸载 App；未操作 Immersal 登录、上传或建图。签名构建日志：`/tmp/area-target-scanner-iphone-run-build.log`。
- 独立审查的四个问题均先复现失败再修复：建图 `limit` 数据库错误误判、未知建图任务无法退出、轮询认证失效与上传并发、清空前检查失败抹掉旧待确认意图。复查未发现新的重要缺陷；`git diff --check` 通过。
- `preservePoses=true` 请求体断言先确认旧代码失败，再更新实现；最终全量 154 项 XCTest 再次通过，真机架构再次编译成功。
- 最终本地日志：`/tmp/area-target-upload-all-tests-final.log`、`/tmp/area-target-upload-device-final.log`。XCTest 结果：`/tmp/area-target-upload-build/Logs/Test/` 内对应最新 `.xcresult`。
- 自动化界面工具未提供 Simulator 应用，未完成模拟器手动点按检查。SwiftUI 已随模拟器及真机架构编译通过；操作流程还需真机人工确认。
- 未使用真实 Immersal 账号，未实际上传、清空工作区或提交云端建图；不声称云端验收通过。使用与后续验收见 [功能说明](../../ios-immersal-direct-upload.md)。
- 保留原扫描、双格式导出和 OpenCV 4.x；工作区既有 `model_optimizer` 子模块改动未处理。

## 工作区确认与界面后续

同日按用户追加要求实现实际数量自动确认及用户选定的第 3 张准备、上传、建图界面。最终全量 XCTest 169 项通过，签名版本再次构建并覆盖安装、启动到 iPhone 15 Pro；本地实际 SwiftUI 截图 QA 通过。真实云端操作和真机点按验收仍待验证。详见 [实施记录](2026-09-30-immersal-workspace-confirmation.md)。用户随后明确授权提交推送 develop，再合并并推送 main；独立 `model_optimizer` 子模块改动排除在发布范围之外。

用户询问有价值的优化器更新是否一起发布。只读核查确认新版 `0394e44` 已在优化器独立仓库 main 发布，无本地未提交源码；其嵌套支付子模块的两个提交 tree 相同。新版包含有效模型与平台改进，但停用根项目仍使用的同步优化接口，并要求认证、Worker 和新的存储流程，现有 Compose 也缺少所需启动配置。不能仅更新 gitlink；在完成独立适配和真实优化闭环前，本次发布保留主仓库原 `8ced6f3` 引用及本地子模块状态。
