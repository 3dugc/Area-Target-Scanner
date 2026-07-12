using System;
using System.Collections.Generic;
using System.IO;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for ZipExtractor.
    /// Tests required file validation across all presence/absence combinations.
    /// </summary>
    [TestFixture]
    public class ZipExtractorPropertyTests
    {
        private static readonly string[] RequiredFiles = { "optimized.glb", "features.db", "manifest.json" };

        private string _tempDir;
        private ZipExtractor _extractor;

        [SetUp]
        public void SetUp()
        {
            _tempDir = Path.Combine(Path.GetTempPath(), $"ZipExtractorTest_{Guid.NewGuid():N}");
            Directory.CreateDirectory(_tempDir);
            _extractor = new ZipExtractor();
        }

        [TearDown]
        public void TearDown()
        {
            if (Directory.Exists(_tempDir))
            {
                Directory.Delete(_tempDir, true);
            }
        }

        // Feature: ar-download-test-scene, Property 5: 必需文件验证与缺失报告
        /// <summary>
        /// Property 5: For any combination of presence/absence of the three required files
        /// (optimized.glb, features.db, manifest.json — 2³=8 combinations),
        /// ValidateRequiredFiles returns isValid=true only when all three exist,
        /// and otherwise returns exactly the missing file names.
        ///
        /// **Validates: Requirements 3.2, 3.3**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property RequiredFileValidation_ReportsCorrectResult()
        {
            return Prop.ForAll(
                Arb.Default.Bool(),
                Arb.Default.Bool(),
                Arb.Default.Bool(),
                (bool hasGlb, bool hasDb, bool hasManifest) =>
                {
                    // Clean directory for each iteration
                    foreach (var f in Directory.GetFiles(_tempDir))
                        File.Delete(f);

                    // Selectively create files based on generated booleans
                    if (hasGlb)
                        File.WriteAllText(Path.Combine(_tempDir, "optimized.glb"), "");
                    if (hasDb)
                        File.WriteAllText(Path.Combine(_tempDir, "features.db"), "");
                    if (hasManifest)
                        File.WriteAllText(Path.Combine(_tempDir, "manifest.json"), "");

                    var (isValid, missingFiles) = _extractor.ValidateRequiredFiles(_tempDir);

                    // Build expected missing list
                    var expectedMissing = new List<string>();
                    if (!hasGlb) expectedMissing.Add("optimized.glb");
                    if (!hasDb) expectedMissing.Add("features.db");
                    if (!hasManifest) expectedMissing.Add("manifest.json");

                    bool allPresent = hasGlb && hasDb && hasManifest;
                    bool validCorrect = isValid == allPresent;
                    bool missingCorrect = new HashSet<string>(missingFiles).SetEquals(expectedMissing);
                    bool countCorrect = missingFiles.Count == expectedMissing.Count;

                    return (validCorrect && missingCorrect && countCorrect)
                        .ToProperty()
                        .Label($"glb={hasGlb}, db={hasDb}, manifest={hasManifest} => " +
                               $"isValid={isValid} (expected {allPresent}), " +
                               $"missing=[{string.Join(", ", missingFiles)}] " +
                               $"(expected [{string.Join(", ", expectedMissing)}])");
                });
        }
    }
}
