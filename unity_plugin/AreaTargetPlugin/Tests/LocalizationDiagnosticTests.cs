using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace AreaTargetPlugin.Tests
{
    [TestFixture]
    [IgnoreLogErrors]
    public class LocalizationDiagnosticTests
    {
        private string _diagnosticDirectory;

        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
            _diagnosticDirectory = Path.Combine(
                Path.GetTempPath(),
                "AreaTargetDiagnosticTests_" + Guid.NewGuid().ToString("N"));
        }

        [TearDown]
        public void TearDown()
        {
            if (Directory.Exists(_diagnosticDirectory))
                Directory.Delete(_diagnosticDirectory, true);
        }

        [Test]
        public void ToJson_ContainsRequiredSummariesWithoutCapturePayload()
        {
            var record = CreateRecord(
                frameId: 42,
                failureCategory: LocalizationFailureCategory.None,
                failureReason: string.Empty);

            string json = record.ToJson();

            Assert.That(json, Does.Contain("\"schemaVersion\":1"));
            Assert.That(json, Does.Contain("\"packageVersion\":\"1.3.0\""));
            Assert.That(json, Does.Contain("\"mapHash\":\"f00dbabe1234\""));
            Assert.That(json, Does.Contain("\"deviceModel\":\"iPhone17,1\""));
            Assert.That(json, Does.Contain("\"frameId\":42"));
            Assert.That(json, Does.Contain("\"captureTimestampNs\":7000000"));
            Assert.That(json, Does.Contain("\"overwrittenPendingFrames\":3"));
            Assert.That(json, Does.Contain("\"workerProcessingTimeNs\":3200000"));
            Assert.That(json, Does.Contain("\"quality\":"));
            Assert.That(json, Does.Contain("\"orbKeypoints\":120"));
            Assert.That(json, Does.Contain("\"bestInliers\":48"));

            foreach (string forbidden in new[]
            {
                "ImageData",
                "JPEG",
                "ScanData",
                "/Users/",
                "file://"
            })
            {
                Assert.That(json, Does.Not.Contain(forbidden));
            }
        }

        [Test]
        public void BoundedBuffer_WhenCapacityIsReached_DropsOldestRecord()
        {
            var buffer = new BoundedDiagnosticBuffer(2);

            buffer.Add(CreateRecord(1, LocalizationFailureCategory.None, string.Empty));
            buffer.Add(CreateRecord(2, LocalizationFailureCategory.None, string.Empty));
            buffer.Add(CreateRecord(3, LocalizationFailureCategory.None, string.Empty));

            IReadOnlyList<LocalizationDiagnosticRecord> records = buffer.Snapshot();
            Assert.That(records.Count, Is.EqualTo(2));
            Assert.That(records[0].FrameId, Is.EqualTo(2));
            Assert.That(records[1].FrameId, Is.EqualTo(3));
            Assert.That(buffer.DroppedRecordCount, Is.EqualTo(1));
        }

        [Test]
        public void FailureCategories_ExposeStableDiagnosticNames()
        {
            CollectionAssert.IsSubsetOf(
                new[]
                {
                    "None",
                    "UnsupportedDevice",
                    "InvalidFrame",
                    "MapLoadFailed",
                    "NativeInitializationFailed",
                    "SqliteFailed",
                    "LocalizationFailed",
                    "StaleResult",
                    "LifecycleFailure"
                },
                Enum.GetNames(typeof(LocalizationFailureCategory)));
        }

        [Test]
        public void TryExport_WritesSafeJsonLinesUsingMapHashPrefix()
        {
            var exporter = new LocalizationDiagnosticExporter(_diagnosticDirectory);
            var records = new List<LocalizationDiagnosticRecord>
            {
                CreateRecord(1, LocalizationFailureCategory.None, string.Empty),
                CreateRecord(2, LocalizationFailureCategory.LocalizationFailed, "no pose")
            };

            bool exported = exporter.TryExport(
                records,
                out string outputPath,
                out LocalizationFailureCategory failureCategory,
                out string failureReason);

            Assert.That(exported, Is.True, failureReason);
            Assert.That(failureCategory, Is.EqualTo(LocalizationFailureCategory.None));
            Assert.That(File.Exists(outputPath), Is.True);
            Assert.That(Path.GetFileName(outputPath), Does.Contain("f00dbabe1234"));

            string[] lines = File.ReadAllLines(outputPath);
            Assert.That(lines.Length, Is.EqualTo(2));
            Assert.That(lines[0], Does.Contain("\"schemaVersion\":1"));
            Assert.That(lines[1], Does.Contain("\"failureCategory\":"));
            Assert.That(string.Join("\n", lines), Does.Not.Contain("ImageData"));
            Assert.That(string.Join("\n", lines), Does.Not.Contain("file://"));
        }

        [Test]
        public void TryExport_WhenRecordContainsPathLikeValue_DoesNotWriteFile()
        {
            var exporter = new LocalizationDiagnosticExporter(_diagnosticDirectory);
            var records = new[]
            {
                CreateRecord(
                    7,
                    LocalizationFailureCategory.InvalidFrame,
                    "bad map identity",
                    mapId: "file:///private/scan")
            };

            bool exported = exporter.TryExport(
                records,
                out string outputPath,
                out LocalizationFailureCategory failureCategory,
                out string failureReason);

            Assert.That(exported, Is.False);
            Assert.That(outputPath, Is.Null.Or.Empty);
            Assert.That(failureCategory, Is.EqualTo(LocalizationFailureCategory.InvalidFrame));
            Assert.That(failureReason, Does.Contain("path"));
            Assert.That(Directory.Exists(_diagnosticDirectory), Is.False);
        }

        [Test]
        public void Tracker_MapLoadFailure_RecordsSafeDiagnostic()
        {
            var tracker = new AreaTargetTracker();
            string missingMapPath = Path.Combine(_diagnosticDirectory, "unavailable-map");

            try
            {
                LogAssert.Expect(
                    LogType.Error,
                    $"[AreaTargetPlugin] Asset directory does not exist: {missingMapPath}");
                Assert.That(tracker.Initialize(missingMapPath), Is.False);

                IReadOnlyList<LocalizationDiagnosticRecord> records = tracker.GetDiagnosticSnapshot();
                Assert.That(records.Count, Is.GreaterThan(0));

                LocalizationDiagnosticRecord record = records[records.Count - 1];
                Assert.That(record.FailureCategory, Is.EqualTo(LocalizationFailureCategory.MapLoadFailed));
                Assert.That(record.FailureReason, Does.Not.Contain(missingMapPath));
                Assert.That(record.ToJson(), Does.Not.Contain(_diagnosticDirectory));
                Assert.That(record.ToJson(), Does.Not.Contain("/Users/"));
            }
            finally
            {
                tracker.Dispose();
            }
        }

        [Test]
        public void Tracker_ResetAndDispose_RecordLifecycleEvents()
        {
            var tracker = new AreaTargetTracker();
            tracker.Reset();
            tracker.Dispose();

            IReadOnlyList<LocalizationDiagnosticRecord> records = tracker.GetDiagnosticSnapshot();
            Assert.That(records.Count, Is.GreaterThanOrEqualTo(2));
            Assert.That(records[0].FailureReason, Does.Contain("Reset"));
            Assert.That(records[records.Count - 1].FailureReason, Does.Contain("Dispose"));
        }

        [Test]
        public async Task SampleMap_ExportsSafeFrameDiagnostic()
        {
            var tracker = new AreaTargetTracker();
            string sampleMapPath = Path.Combine(Application.streamingAssetsPath, "SLAMTestAssets");

            try
            {
                Assert.That(tracker.Initialize(sampleMapPath), Is.True);

                var frame = new LocalizationFrame(
                    frameId: 1,
                    captureTimestampNs: 1,
                    grayscaleImage: new byte[] { 0 },
                    width: 1,
                    height: 1,
                    intrinsics: new Vector4(1f, 1f, 0.5f, 0.5f),
                    orientation: ImageOrientation.LandscapeRight,
                    unityWorldFromCamera: Matrix4x4.identity,
                    mapId: tracker.MapId);
                Assert.That(tracker.SubmitFrame(frame), Is.True);

                LocalizationDiagnosticRecord workerRecord = await WaitForWorkerDiagnostic(tracker);
                Assert.That(workerRecord.FrameId, Is.EqualTo(1));
                Assert.That(workerRecord.WorkerProcessingTimeNs, Is.GreaterThanOrEqualTo(0));

                var exporter = new LocalizationDiagnosticExporter(_diagnosticDirectory);
                Assert.That(exporter.TryExport(
                    tracker.GetDiagnosticSnapshot(),
                    out string outputPath,
                    out LocalizationFailureCategory failureCategory,
                    out string failureReason), Is.True, failureReason);
                Assert.That(failureCategory, Is.EqualTo(LocalizationFailureCategory.None));

                string exported = File.ReadAllText(outputPath);
                Assert.That(exported, Does.Contain("\"schemaVersion\":1"));
                Assert.That(exported, Does.Contain("\"frameId\":1"));
                Assert.That(exported, Does.Not.Contain("ImageData"));
                Assert.That(exported, Does.Not.Contain("JPEG"));
                Assert.That(exported, Does.Not.Contain("ScanData"));
                Assert.That(exported, Does.Not.Contain("/Users/"));
                Assert.That(exported, Does.Not.Contain("file://"));
            }
            finally
            {
                tracker.Dispose();
            }
        }

        private static async Task<LocalizationDiagnosticRecord> WaitForWorkerDiagnostic(
            AreaTargetTracker tracker)
        {
            DateTime deadline = DateTime.UtcNow.AddSeconds(3);
            while (DateTime.UtcNow < deadline)
            {
                IReadOnlyList<LocalizationDiagnosticRecord> records = tracker.GetDiagnosticSnapshot();
                for (int index = records.Count - 1; index >= 0; index--)
                {
                    LocalizationDiagnosticRecord record = records[index];
                    if (record.FrameId == 1
                        && record.FailureReason.StartsWith(
                            "Native localization",
                            StringComparison.Ordinal))
                    {
                        return record;
                    }
                }

                await Task.Delay(10);
            }

            Assert.Fail("The localization worker did not write a diagnostic outcome.");
            return null;
        }

        private static LocalizationDiagnosticRecord CreateRecord(
            long frameId,
            LocalizationFailureCategory failureCategory,
            string failureReason,
            string mapId = "fixture-map")
        {
            return new LocalizationDiagnosticRecord(
                timestampUtc: new DateTime(2026, 7, 13, 9, 0, 0, DateTimeKind.Utc),
                buildVersion: "AreaTargetApp 42",
                packageVersion: "1.3.0",
                mapId: mapId,
                mapVersion: "2.0",
                mapHash: "f00dbabe1234",
                deviceModel: "iPhone17,1",
                operatingSystem: "iOS 26.3",
                frameId: frameId,
                captureTimestampNs: 7_000_000,
                mapGeneration: 4,
                overwrittenPendingFrames: 3,
                resultAgeNs: 1_500_000,
                workerProcessingTimeNs: 3_200_000,
                state: TrackingState.TRACKING,
                quality: LocalizationQuality.LOCALIZED,
                confidence: 0.87f,
                poseApplied: true,
                failureCategory: failureCategory,
                failureReason: failureReason,
                nativeDebugInfo: new VLDebugInfo
                {
                    orb_keypoints = 120,
                    candidate_keyframes = 4,
                    best_kf_id = 17,
                    best_raw_matches = 83,
                    best_good_matches = 58,
                    best_inliers = 48,
                    best_bow_sim = 0.67f,
                    akaze_triggered = 0,
                    consistency_rejected = 0
                });
        }
    }
}
