using System;
using System.IO;
using System.IO.Compression;
using NUnit.Framework;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Unit tests for ZipExtractor.
    /// Tests valid ZIP extraction, corrupted ZIP error handling, and extraction directory cleanup.
    /// Validates: Requirements 3.1, 3.4
    /// </summary>
    [TestFixture]
    public class ZipExtractorTests
    {
        private string _testDir;
        private ZipExtractor _extractor;

        [SetUp]
        public void SetUp()
        {
            _testDir = Path.Combine(Path.GetTempPath(), "ZipExtractorTests_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_testDir);
            _extractor = new ZipExtractor();
        }

        [TearDown]
        public void TearDown()
        {
            if (Directory.Exists(_testDir))
            {
                Directory.Delete(_testDir, true);
            }
        }

        #region Helper Methods

        /// <summary>
        /// Creates a valid ZIP file containing the three required Area Target files.
        /// </summary>
        private string CreateValidZip(string zipName = "test.zip")
        {
            string sourceDir = Path.Combine(_testDir, "zip_source_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(sourceDir);

            File.WriteAllText(Path.Combine(sourceDir, "optimized.glb"), "GLB_MESH_DATA");
            File.WriteAllText(Path.Combine(sourceDir, "features.db"), "SQLITE_FEATURES");
            File.WriteAllText(Path.Combine(sourceDir, "manifest.json"), "{\"version\":\"2.0\",\"name\":\"test\"}");

            string zipPath = Path.Combine(_testDir, zipName);
            ZipFile.CreateFromDirectory(sourceDir, zipPath);
            return zipPath;
        }

        #endregion

        #region Valid ZIP Extraction Tests (Requirement 3.1)

        [Test]
        public void Extract_ValidZip_ReturnsTrue()
        {
            string zipPath = CreateValidZip();
            string outputDir = Path.Combine(_testDir, "output");

            bool result = _extractor.Extract(zipPath, outputDir);

            Assert.IsTrue(result);
            Assert.IsNull(_extractor.LastError);
        }

        [Test]
        public void Extract_ValidZip_ExtractsAllFiles()
        {
            string zipPath = CreateValidZip();
            string outputDir = Path.Combine(_testDir, "output");

            _extractor.Extract(zipPath, outputDir);

            Assert.IsTrue(File.Exists(Path.Combine(outputDir, "optimized.glb")));
            Assert.IsTrue(File.Exists(Path.Combine(outputDir, "features.db")));
            Assert.IsTrue(File.Exists(Path.Combine(outputDir, "manifest.json")));
        }

        [Test]
        public void Extract_ValidZip_PreservesFileContents()
        {
            string zipPath = CreateValidZip();
            string outputDir = Path.Combine(_testDir, "output");

            _extractor.Extract(zipPath, outputDir);

            string glbContent = File.ReadAllText(Path.Combine(outputDir, "optimized.glb"));
            string dbContent = File.ReadAllText(Path.Combine(outputDir, "features.db"));
            Assert.AreEqual("GLB_MESH_DATA", glbContent);
            Assert.AreEqual("SQLITE_FEATURES", dbContent);
        }

        #endregion

        #region Corrupted ZIP Error Handling Tests (Requirement 3.4)

        [Test]
        public void Extract_CorruptedZip_ReturnsFalse()
        {
            string corruptPath = Path.Combine(_testDir, "corrupt.zip");
            var random = new Random(42);
            byte[] randomBytes = new byte[256];
            random.NextBytes(randomBytes);
            File.WriteAllBytes(corruptPath, randomBytes);

            string outputDir = Path.Combine(_testDir, "output");

            bool result = _extractor.Extract(corruptPath, outputDir);

            Assert.IsFalse(result);
        }

        [Test]
        public void Extract_CorruptedZip_SetsLastError()
        {
            string corruptPath = Path.Combine(_testDir, "corrupt.zip");
            File.WriteAllBytes(corruptPath, new byte[] { 0x00, 0xFF, 0xAB, 0xCD });

            string outputDir = Path.Combine(_testDir, "output");

            _extractor.Extract(corruptPath, outputDir);

            Assert.IsNotNull(_extractor.LastError);
            Assert.IsNotEmpty(_extractor.LastError);
        }

        [Test]
        public void Extract_NonExistentZip_ReturnsFalse()
        {
            string outputDir = Path.Combine(_testDir, "output");

            bool result = _extractor.Extract("/nonexistent/file.zip", outputDir);

            Assert.IsFalse(result);
            Assert.IsNotNull(_extractor.LastError);
        }

        #endregion

        #region Directory Cleanup Tests (Requirement 3.1)

        [Test]
        public void Extract_OutputDirExists_CleansOldFiles()
        {
            string outputDir = Path.Combine(_testDir, "output");
            Directory.CreateDirectory(outputDir);
            File.WriteAllText(Path.Combine(outputDir, "old_file.txt"), "OLD_DATA");
            File.WriteAllText(Path.Combine(outputDir, "stale_cache.bin"), "STALE");

            string zipPath = CreateValidZip();

            _extractor.Extract(zipPath, outputDir);

            Assert.IsFalse(File.Exists(Path.Combine(outputDir, "old_file.txt")));
            Assert.IsFalse(File.Exists(Path.Combine(outputDir, "stale_cache.bin")));
        }

        [Test]
        public void Extract_OutputDirExists_ExtractsNewFiles()
        {
            string outputDir = Path.Combine(_testDir, "output");
            Directory.CreateDirectory(outputDir);
            File.WriteAllText(Path.Combine(outputDir, "old_file.txt"), "OLD_DATA");

            string zipPath = CreateValidZip();

            bool result = _extractor.Extract(zipPath, outputDir);

            Assert.IsTrue(result);
            Assert.IsTrue(File.Exists(Path.Combine(outputDir, "optimized.glb")));
            Assert.IsTrue(File.Exists(Path.Combine(outputDir, "features.db")));
            Assert.IsTrue(File.Exists(Path.Combine(outputDir, "manifest.json")));
        }

        [Test]
        public void Extract_OutputDirDoesNotExist_CreatesItAndExtracts()
        {
            string outputDir = Path.Combine(_testDir, "brand_new_dir", "nested");
            string zipPath = CreateValidZip();

            bool result = _extractor.Extract(zipPath, outputDir);

            Assert.IsTrue(result);
            Assert.IsTrue(Directory.Exists(outputDir));
            Assert.IsTrue(File.Exists(Path.Combine(outputDir, "optimized.glb")));
        }

        #endregion
    }
}
