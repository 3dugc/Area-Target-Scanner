# StreamingAssets 测试夹具

本目录中的录制数据只用于可重复的自动化回归测试，不是发布示例资产。

- `SLAMTestAssets`：Unity 定位回归测试使用的确定性 Area Target 资产；当前测试直接引用其中的 `features.db`、`manifest.json` 和 `optimized.glb`。
- `ScanData`：回放与跨会话测试使用的录制扫描序列。
- `ScanData_data1`：第二组跨会话回归序列，用于验证不同录制会话之间的行为。

替换任一夹具时，必须同步更新引用它的测试，并在提交说明中记录数据来源和采集日期。不得在此目录提交设备隐私内容、临时测试输出、崩溃转储或备份变体。
