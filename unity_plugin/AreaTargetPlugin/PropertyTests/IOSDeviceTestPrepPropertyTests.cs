using System;
using System.IO;
using System.Linq;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for iOS device test prep.
    /// Validates: Requirements 2.2, 2.4
    /// </summary>
    [TestFixture]
    public class IOSDeviceTestPrepPropertyTests
    {
        private const string FixedStreamingAssetsPath = "/app/StreamingAssets";

        // Feature: ios-device-test-prep, Property 1: 资产路径解析正确性
        /// <summary>
        /// Property 1: For any path string p, if p is an absolute path (Path.IsPathRooted(p) is true),
        /// ResolveAssetPath returns p itself; if p is a relative path, ResolveAssetPath returns
        /// Path.Combine(streamingAssetsPath, p).
        ///
        /// **Validates: Requirements 2.2, 2.4**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 200)]
        public Property AssetPathResolution_AbsoluteOrRelative_ResolvedCorrectly()
        {
            // 生成非 null 路径字符串，过滤掉 null 和空字符串
            var pathGen = Arb.Generate<string>()
                .Where(s => s != null && s.Length > 0)
                .ToArbitrary();

            return Prop.ForAll(pathGen, (string path) =>
            {
                string resolved = ARTestSceneManager.ResolveAssetPath(path, FixedStreamingAssetsPath);
                bool isAbsolute = Path.IsPathRooted(path);

                if (isAbsolute)
                {
                    // 绝对路径：解析结果应等于原路径
                    return (resolved == path)
                        .ToProperty()
                        .Label($"Absolute path: resolved=\"{resolved}\" should equal input=\"{path}\"");
                }
                else
                {
                    // 相对路径：解析结果应等于 Path.Combine(streamingAssetsPath, path)
                    string expected = Path.Combine(FixedStreamingAssetsPath, path);
                    return (resolved == expected)
                        .ToProperty()
                        .Label($"Relative path: resolved=\"{resolved}\" should equal \"{expected}\"");
                }
            });
        }

        // Feature: ios-device-test-prep, Property 1 补充: 显式绝对路径测试
        /// <summary>
        /// 对以 "/" 开头的路径（Unix 绝对路径），ResolveAssetPath 应直接返回原路径。
        /// **Validates: Requirements 2.4**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property AssetPathResolution_UnixAbsolutePath_ReturnedUnchanged()
        {
            // 生成以 "/" 开头的绝对路径
            var absPathGen = Arb.Generate<string>()
                .Where(s => s != null && s.Length > 0)
                .Select(s => "/" + s.TrimStart('/'))
                .ToArbitrary();

            return Prop.ForAll(absPathGen, (string absPath) =>
            {
                string resolved = ARTestSceneManager.ResolveAssetPath(absPath, FixedStreamingAssetsPath);
                return (resolved == absPath)
                    .ToProperty()
                    .Label($"Unix absolute path: resolved=\"{resolved}\" should equal \"{absPath}\"");
            });
        }

        // Feature: ios-device-test-prep, Property 1 补充: 显式相对路径测试
        /// <summary>
        /// 对不以 "/" 或驱动器号开头的路径（相对路径），ResolveAssetPath 应返回
        /// Path.Combine(streamingAssetsPath, path)。
        /// **Validates: Requirements 2.2**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property AssetPathResolution_RelativePath_CombinedWithStreamingAssets()
        {
            // 生成以字母开头的相对路径（确保不是绝对路径）
            var relPathGen = Gen.Elements(
                    "SLAMTestAssets",
                    "AreaTargetAssets/test_room",
                    "data/models",
                    "assets",
                    "test",
                    "a/b/c"
                )
                .ToArbitrary();

            return Prop.ForAll(relPathGen, (string relPath) =>
            {
                string resolved = ARTestSceneManager.ResolveAssetPath(relPath, FixedStreamingAssetsPath);
                string expected = Path.Combine(FixedStreamingAssetsPath, relPath);

                return (resolved == expected)
                    .ToProperty()
                    .Label($"Relative path: resolved=\"{resolved}\" should equal \"{expected}\"");
            });
        }

        // Feature: ios-device-test-prep, Property 2: 资产缺失时显示具体错误信息

        /// <summary>
        /// Property 2a: 对任意不存在的目录路径，ValidateAssetDirectory 返回的错误消息
        /// 应包含 assetBundlePath 名称，而非通用的"加载失败"。
        ///
        /// **Validates: Requirements 2.3**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property ValidateAssetDirectory_NonExistentDir_ErrorContainsAssetName()
        {
            // 生成随机目录名（字母数字组合，确保不会意外匹配真实目录）
            var dirNameGen = Gen.Elements("a", "b", "c", "x", "y", "z")
                .Select(prefix => prefix + "_nonexistent_" + System.Guid.NewGuid().ToString("N").Substring(0, 8))
                .ToArbitrary();

            return Prop.ForAll(dirNameGen, (string dirName) =>
            {
                // 使用一个肯定不存在的完整路径
                string fullPath = Path.Combine(Path.GetTempPath(), dirName);
                string assetBundlePath = dirName;

                string error = ARTestSceneManager.ValidateAssetDirectory(fullPath, assetBundlePath);

                // 错误不应为 null（目录不存在）
                var notNull = (error != null)
                    .ToProperty()
                    .Label($"Error should not be null for non-existent dir '{dirName}'");

                // 错误消息应包含 assetBundlePath 名称
                var containsName = (error != null && error.Contains(assetBundlePath))
                    .ToProperty()
                    .Label($"Error '{error}' should contain asset name '{assetBundlePath}'");

                // 错误消息不应是通用的"加载失败"
                var notGeneric = (error != null && !error.Contains("加载失败"))
                    .ToProperty()
                    .Label($"Error '{error}' should not be generic '加载失败'");

                return notNull.And(containsName).And(notGeneric);
            });
        }

        /// <summary>
        /// Property 2b: 对存在但缺少 features.db 的目录，ValidateAssetDirectory 返回的
        /// 错误消息应包含 "features.db"。
        ///
        /// **Validates: Requirements 2.3**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 50)]
        public Property ValidateAssetDirectory_MissingFeaturesDb_ErrorContainsFileName()
        {
            var dirNameGen = Gen.Elements("a", "b", "c", "x", "y", "z")
                .Select(prefix => prefix + "_nofeatdb_" + System.Guid.NewGuid().ToString("N").Substring(0, 8))
                .ToArbitrary();

            return Prop.ForAll(dirNameGen, (string dirName) =>
            {
                string tempDir = Path.Combine(Path.GetTempPath(), dirName);
                try
                {
                    // 创建目录但不放 features.db
                    Directory.CreateDirectory(tempDir);

                    string error = ARTestSceneManager.ValidateAssetDirectory(tempDir, dirName);

                    var notNull = (error != null)
                        .ToProperty()
                        .Label($"Error should not be null for dir missing features.db");

                    var containsFileName = (error != null && error.Contains("features.db"))
                        .ToProperty()
                        .Label($"Error '{error}' should contain 'features.db'");

                    return notNull.And(containsFileName);
                }
                finally
                {
                    if (Directory.Exists(tempDir))
                        Directory.Delete(tempDir, true);
                }
            });
        }

        /// <summary>
        /// Property 2c: 对存在且有 features.db 但缺少 manifest.json 的目录，
        /// ValidateAssetDirectory 返回的错误消息应包含 "manifest.json"。
        ///
        /// **Validates: Requirements 2.3**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 50)]
        public Property ValidateAssetDirectory_MissingManifestJson_ErrorContainsFileName()
        {
            var dirNameGen = Gen.Elements("a", "b", "c", "x", "y", "z")
                .Select(prefix => prefix + "_nomanifest_" + System.Guid.NewGuid().ToString("N").Substring(0, 8))
                .ToArbitrary();

            return Prop.ForAll(dirNameGen, (string dirName) =>
            {
                string tempDir = Path.Combine(Path.GetTempPath(), dirName);
                try
                {
                    // 创建目录并放入 features.db，但不放 manifest.json
                    Directory.CreateDirectory(tempDir);
                    File.WriteAllText(Path.Combine(tempDir, "features.db"), "dummy");

                    string error = ARTestSceneManager.ValidateAssetDirectory(tempDir, dirName);

                    var notNull = (error != null)
                        .ToProperty()
                        .Label($"Error should not be null for dir missing manifest.json");

                    var containsFileName = (error != null && error.Contains("manifest.json"))
                        .ToProperty()
                        .Label($"Error '{error}' should contain 'manifest.json'");

                    return notNull.And(containsFileName);
                }
                finally
                {
                    if (Directory.Exists(tempDir))
                        Directory.Delete(tempDir, true);
                }
            });
        }

        // Feature: ios-device-test-prep, Property 3: TRACKING 状态下调试文本包含质量和模式信息
        /// <summary>
        /// Property 3: 对任意 LocalizationQuality 值，FormatQualityText 返回的文本
        /// 应包含该质量枚举值的字符串表示，并包含 "Aligned" 或 "Raw"。
        ///
        /// **Validates: Requirements 3.1, 3.2**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property FormatQualityText_ContainsQualityAndMode()
        {
            var qualityGen = Gen.Elements(
                Enum.GetValues(typeof(LocalizationQuality))
                    .Cast<LocalizationQuality>().ToArray()
            ).ToArbitrary();

            return Prop.ForAll(qualityGen, (LocalizationQuality quality) =>
            {
                string text = ARTestSceneManager.FormatQualityText(quality);

                // 文本应包含质量枚举值的字符串表示
                var containsQuality = text.Contains(quality.ToString())
                    .ToProperty()
                    .Label($"Text \"{text}\" should contain quality \"{quality}\"");

                // 文本应包含 "Aligned" 或 "Raw"
                var containsMode = (text.Contains("Aligned") || text.Contains("Raw"))
                    .ToProperty()
                    .Label($"Text \"{text}\" should contain \"Aligned\" or \"Raw\"");

                return containsQuality.And(containsMode);
            });
        }

        // Feature: ios-device-test-prep, Property 5: 调试文本包含所有必要字段
        /// <summary>
        /// Property 5: 对任意 TrackingResult 和 ExtendedDebugInfo 的随机值组合，
        /// FormatTrackingDebugText 返回的文本应包含所有 7 个字段标签：
        /// 置信度、特征点、帧、模式、质量、AKAZE、一致性。
        ///
        /// **Validates: Requirements 3.5, 3.6**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property FormatTrackingDebugText_ContainsAllSevenFields()
        {
            var confidenceGen = Gen.Choose(0, 100).Select(i => i / 100f);
            var matchedFeaturesGen = Gen.Choose(0, 500);
            var frameCountGen = Gen.Choose(0, 10000);
            var modeGen = Gen.Elements(
                Enum.GetValues(typeof(LocalizationMode))
                    .Cast<LocalizationMode>().ToArray());
            var qualityGen = Gen.Elements(
                Enum.GetValues(typeof(LocalizationQuality))
                    .Cast<LocalizationQuality>().ToArray());
            var akazeGen = Gen.Elements(0, 1);
            var consistencyGen = Gen.Elements(0, 1);

            var combinedGen = from confidence in confidenceGen
                              from matchedFeatures in matchedFeaturesGen
                              from frameCount in frameCountGen
                              from mode in modeGen
                              from quality in qualityGen
                              from akaze in akazeGen
                              from consistency in consistencyGen
                              select new { confidence, matchedFeatures, frameCount, mode, quality, akaze, consistency };

            return Prop.ForAll(combinedGen.ToArbitrary(), input =>
            {
                string text = ARTestSceneManager.FormatTrackingDebugText(
                    input.confidence, input.matchedFeatures, input.frameCount,
                    input.mode, input.quality,
                    input.akaze, input.consistency);

                string[] requiredLabels = { "置信度", "特征点", "帧", "模式", "质量", "AKAZE", "一致性" };

                bool allPresent = true;
                string missing = "";
                foreach (var label in requiredLabels)
                {
                    if (!text.Contains(label))
                    {
                        allPresent = false;
                        missing += (missing.Length > 0 ? ", " : "") + label;
                    }
                }

                return allPresent.ToProperty()
                    .Label(allPresent
                        ? $"All 7 labels present for conf={input.confidence}, feat={input.matchedFeatures}, frame={input.frameCount}, mode={input.mode}, quality={input.quality}, akaze={input.akaze}, consistency={input.consistency}"
                        : $"Missing labels: [{missing}] in text: \"{text}\"");
            });
        }

        // Feature: ios-device-test-prep, Property 4: LocalizationQuality 到颜色的确定性映射
        /// <summary>
        /// Property 4: 对任意 LocalizationQuality 枚举值，GetQualityColor 返回的颜色
        /// 应满足：LOCALIZED → 绿色，RECOGNIZED → 黄色，NONE → 红色。
        /// 映射是全函数（覆盖所有枚举值）且确定性的（两次调用结果相同）。
        ///
        /// **Validates: Requirements 3.3, 3.4**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property GetQualityColor_DeterministicAndCorrectMapping()
        {
            var qualityGen = Gen.Elements(
                Enum.GetValues(typeof(LocalizationQuality))
                    .Cast<LocalizationQuality>().ToArray()
            ).ToArbitrary();

            return Prop.ForAll(qualityGen, (LocalizationQuality quality) =>
            {
                Color color1 = ARTestSceneManager.GetQualityColor(quality);
                Color color2 = ARTestSceneManager.GetQualityColor(quality);

                // 确定性：两次调用结果相同
                var deterministic = (color1 == color2)
                    .ToProperty()
                    .Label($"Mapping should be deterministic for {quality}");

                // 正确性：验证具体映射
                Color expected;
                switch (quality)
                {
                    case LocalizationQuality.LOCALIZED:
                        expected = Color.green;
                        break;
                    case LocalizationQuality.RECOGNIZED:
                        expected = Color.yellow;
                        break;
                    default:
                        expected = Color.red;
                        break;
                }

                var correct = (color1 == expected)
                    .ToProperty()
                    .Label($"Quality {quality} should map to {expected}, got {color1}");

                return deterministic.And(correct);
            });
        }
    }
}
