# 阶段 1 iOS 单地图真机验收记录模板

每一份记录只对应一个“场地 × 运行设备”组合。iPhone 与 iPad 必须分别填写独立记录；三个场地共需六份记录。

> 隐私边界：不要填写场地地址、设备 UDID、原始图像、扫描 ZIP、地图数据库、完整设备日志或任何绝对路径。原始扫描与地图制品只保留在受控本地存储。

## 记录身份

| 字段 | 值 |
| --- | --- |
| 场地代号 | `<例如 IOS-P1-A>` |
| 面积范围（m²） | `<20–100>` |
| 扫描设备型号 / 系统 | `<匿名型号 / iOS 版本>` |
| 运行设备型号 / 系统 | `<匿名型号 / iOS 版本>` |
| 扫描器提交 | `<git SHA>` |
| 处理管线提交 | `<git SHA>` |
| Unity 应用提交 | `<git SHA>` |
| UPM 版本 | `1.3.0` |
| map ID / version / SHA-256 | `<匿名 map ID> / <version> / <hash>` |

## 可复现命令摘要

| 步骤 | 命令或操作摘要 | 结果 |
| --- | --- | --- |
| 扫描 ZIP 合同校验 | `tools/phase1/validate_scan_contract.py <受控本地 manifest>` | `<通过/失败>` |
| 本地处理 | `<Docker 或 Python 命令，不含绝对路径>` | `<通过/失败>` |
| iOS Development 构建 / 安装 | `<UPM 版本、目标设备类别、签名配置摘要>` | `<通过/失败>` |
| 地图加载 | `features.db` 与 native 初始化诊断摘要 | `<通过/失败>` |

## 定位、失锁与恢复

| 字段 | 值 |
| --- | --- |
| 首次定位 UTC 时间 | `<YYYY-MM-DDTHH:MM:SSZ 或未定位>` |
| 首次定位耗时（秒） | `<数值或未定位>` |
| 首次成功状态 | `<TRACKING / LOCALIZED / 未成功>` |
| 失锁次数 | `<整数>` |
| 恢复尝试次数 | `<整数>` |
| 恢复结果 | `<成功 / 失败 / 未执行>` |
| 异常摘要 | `<只写稳定错误类别和简短原因>` |

## 30 分钟稳定性与诊断

| 字段 | 值 |
| --- | --- |
| 连续运行开始 UTC 时间 | `<YYYY-MM-DDTHH:MM:SSZ>` |
| 连续运行结束 UTC 时间 | `<YYYY-MM-DDTHH:MM:SSZ>` |
| 连续运行时长（分钟） | `<至少 30>` |
| crash / native lifecycle failure / map reload | `<无，或匿名化摘要>` |
| 诊断文件 SHA-256 | `<hash>` |
| 隐私扫描 | `<“无匹配”或失败摘要>` |
| 最终结果 | `<通过 / 失败 / 阻断>` |

验收前，对导出的 JSON Lines 文件执行以下本地检查；只将 SHA-256 和“无匹配”结果回填到本模板：

```bash
shasum -a 256 /path/to/diagnostic.jsonl
rg -n "ImageData|JPEG|ScanData|/Users/|file://" /path/to/diagnostic.jsonl
```

若未完成定位、失锁/恢复或连续 30 分钟运行，最终结果必须是“失败”或“阻断”，不得将 generic-device Xcode 构建替代真机验收。
