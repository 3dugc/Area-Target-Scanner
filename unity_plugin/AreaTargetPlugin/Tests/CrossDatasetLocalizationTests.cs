using System;
using System.Collections.Generic;
using System.IO;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;
using AreaTargetPlugin;
using VideoPlaybackTestScene;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// 跨数据集定位测试：用 data1 的 scan frames 对 data3 的 features.db 做定位验证。
    /// 模拟真实设备场景——不同扫描 session 的数据交叉匹配。
    ///
    /// 与 SLAMSequenceLocalizationTests（同数据集自洽验证）不同，这里：
    ///   - ScanData_data1: 64帧, fx=1588.85, 不同时间扫描
    ///   - SLAMTestAssets/features.db: data3 生成, 10个keyframe
    ///   - 两个数据集可能是同一物理空间的不同扫描
    ///
    /// 验证链路: 空间匹配 → DLT PnP → flip(Y,Z) → scanToAR
    /// 红蓝线规则: scanToAR ≈ identity 表示定位正确
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class CrossDatasetLocalizationTests
    {
        private string _data1ScanPath;
        private string _data3AssetPath;
        private string _dbPath;
        private FeatureDatabaseReader _featureDb;
        private ImageSeqFrameSource _data1Source;
        private bool _dataAvailable;

        // 跨数据集阈值（比同数据集宽松）
        private const float SPATIAL_MATCH_RADIUS = 5.0f;    // 空间匹配半径 (m)
        private const float S2A_ERROR_THRESHOLD = 0.5f;     // scanToAR 误差阈值（跨数据集更宽松）
        private const float TRANSLATION_ERROR_M = 0.5f;     // 平移误差 (m)
        private const float ROTATION_ERROR_DEG = 10.0f;     // 旋转误差 (°)
    }
}
