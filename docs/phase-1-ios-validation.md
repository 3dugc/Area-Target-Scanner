# 阶段 1：iOS 真机验证记录

## 任务 2：扫描 ZIP 每帧元数据合同

- 日期：2026-07-13
- 验证方式：完成一次短扫描后，在受控本地临时目录中仅提取 ZIP 内的 `manifest.json`。
- 验证命令：`venv/bin/python tools/phase1/validate_scan_contract.py --scan-manifest <受控本地路径>/manifest.json`
- 终端摘要：`{"frameCount":31,"orientationCounts":{"landscapeRight":31},"schemaVersion":1}`
- 结果：退出码为 0，合同校验通过。
- 数据边界：扫描 ZIP 和图像未提交到 Git；本文不包含图像、设备标识或本地导出路径。
