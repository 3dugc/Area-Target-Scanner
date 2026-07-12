# 阶段 0：v1.2.1 可重复基线验证记录

## 验证信息

- 验证日期：2026-07-12（Asia/Shanghai）
- 验证提交：`5cbc20e7527daf85a9d5df522e7410d586d72728`
- 分支：`develop`
- 规范版本：`1.2.1`
- 回滚基线：`81d815f18eac1a55babd21dbfc2c3a7726942e84`

## 验证环境

| 工具 | 版本 |
|---|---|
| macOS | 26.5.1（25F80） |
| Xcode | 26.2（17C52） |
| Python | 3.11.12 |
| Python OpenCV | 4.13.0.92 |
| Homebrew OpenCV（原生构建） | 4.11.0_1 |
| Docker | 27.4.0（bde2b89） |
| Docker Compose | v2.31.0-desktop.2 |
| Unity | 6000.4.6f1 |
| CMake | 4.0.2 |

## 验证结果

| 检查项 | 主工作区 | 干净 worktree | 结果说明 |
|---|---|---|---|
| 包元数据与版本 | PASS | PASS | `package.json` 输出 `1.2.1` |
| 仓库卫生 | PASS | PASS | 未发现受 Git 跟踪的禁止生成物 |
| Python 测试 | PASS | PASS | 主工作区 `299 passed, 3 skipped`；干净检出先运行 `281 passed, 4 skipped`，原生构建后再运行 18 项 native 测试并全部通过 |
| Docker Compose | PASS | PASS | `docker compose config --quiet` 返回 0 |
| Web Service 镜像 | PASS | PASS | `area-target-scanner-phase0` 构建成功 |
| macOS 原生定位器 | PASS | PASS | arm64 dylib 构建成功，必需 C API 符号完整 |
| iOS 定位器 archive | PASS | PASS | arm64 静态库架构与必需符号检查通过；不代表真机定位认证 |
| iOS Scanner | PASS | PASS | generic iOS device、禁用签名构建，输出 `BUILD SUCCEEDED` |
| Unity EditMode | PASS | PASS | 944/944 通过 |
| UPM 生成与内容 | PASS | PASS | 生成 `dist/com.areatarget.tracking-1.2.1.tgz`，内容与连续打包一致性检查通过 |
| UPM 干净安装 | PASS | PASS | 临时 Unity 工程解析依赖并完成编译 |

主工作区日志位于被忽略的 `phase0-results/phase0-local.log`。干净 worktree 的最终结果摘要记录在本文件中；临时构建目录和其中的完整日志已按计划移除。

## 执行说明

- 第一次 Docker 构建曾因腾讯云 Docker mirror 返回 EOF 中断；手动拉取 `python:3.11-slim` 后，同一 Dockerfile 构建通过。
- 干净 worktree 的 Git SSH 子模块连接被代理关闭，使用临时 `url.https://github.com/.insteadOf=git@github.com:` 重写后，仍检出锁定提交 `8ced6f3a908c5f2fcdec578238e65064e9f009e7`。
- 干净 Unity 首次解析 SQLite 的嵌套 Git 子模块时遇到一次 GitHub TLS 中断；未修改源码，重试同一门禁后 EditMode 和 UPM 干净安装通过。
- Unity 6000.4.6f1 会自动迁移由 6000.3 创建的工程文件；这些运行时改写已撤销，没有进入提交。

## 支持边界

阶段 0 验证 macOS 开发构建、iOS Scanner 通用设备构建和现有 iOS 定位器 archive 的静态契约。阶段 0 不声明 Rokid AR Studio、Android ARM64、Windows 或 Linux 运行时支持，也不包含真机定位精度认证。

## 发布状态

本记录只证明本地和干净检出门禁通过。未执行推送、标签、GitHub Release 或合并到 `main`；这些外部发布操作需要用户另行授权。
