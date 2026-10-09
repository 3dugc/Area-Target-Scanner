using System;
using System.IO;
using System.Threading.Tasks;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;
using AreaTargetPlugin.PointCloudLocalization;
using VideoPlaybackTestScene;
namespace AreaTargetPlugin.Tests
{
    [IgnoreLogErrors]
    public class ReplayFrameMetadataTests
    {
        private string _directory;
        [SetUp]
        public void SetUp()
        {
            _directory = Path.Combine(Path.GetTempPath(), "replay-metadata-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_directory);
            File.WriteAllText(Path.Combine(_directory, "intrinsics.json"),
                "{\"fx\":100,\"fy\":100,\"cx\":1,\"cy\":1,\"width\":2,\"height\":2}");
        }
        [TearDown]
        public void TearDown() { if (Directory.Exists(_directory)) Directory.Delete(_directory, true); }
        [Test]
        public async Task EditorSyntheticCapture_UsesItsActualGenerationClock()
        {
            var platform = new EditorPlatformSupport();
            await platform.ConfigurePlatform();
            long before = LocalizationClock.NowTimestampNs;
            var result = await platform.UpdatePlatform();
            long after = LocalizationClock.NowTimestampNs;
            Assert.That(result.CameraData.CaptureTimestampNs, Is.InRange(before, after));
            NativeSessionBridgeTests.AssertPose(Matrix4x4.identity, CameraDataAdapter.ToCameraFrame(result.CameraData).UnityWorldFromCamera.Value);
            await platform.StopAndCleanUp();
        }
        [Test]
        public void RecordedFrame_PreservesSourceIdentityExposureAndPose_WithOneFixedMapping()
        {
            WritePose("\"timestamp\":2.0,", "[1,0,0,0,0,1,0,0,0,0,1,0,1,2,-3,1]");
            var source = new ImageSeqFrameSource();
            Assert.That(source.Load(_directory), Is.True);
            // Reflection allows the pre-migration source to compile for actual RED.
            typeof(ImageSeqFrameSource).GetProperty("CaptureClockMapper")?.SetValue(source,
                new FixedOffsetCaptureClockMapper(1000000000, 4));
            var frame = source.GetFrame(0);
            Assert.That(frame.FrameId, Is.EqualTo(7));
            Assert.That(frame.CaptureTimestampNs, Is.EqualTo(3000000000));
            NativeSessionBridgeTests.AssertPose(Matrix4x4.Translate(new Vector3(1, 2, 3)), frame.UnityWorldFromCamera.Value);
            Assert.That(frame.TrackingMetadata.HasValue, Is.True);
            Assert.That(frame.TrackingMetadata.Value.ClockMappingValid, Is.True);
            Assert.That(frame.TrackingMetadata.Value.CaptureClockEpoch, Is.EqualTo(4));
            Assert.That(source.GetFrame(0).CaptureTimestampNs, Is.EqualTo(frame.CaptureTimestampNs));
        }
        [Test]
        public void MissingRecordedTimeOrPose_AllowsRawFrameButDisablesAlignment()
        {
            WritePose("", "null");
            var source = new ImageSeqFrameSource();
            Assert.That(source.Load(_directory), Is.True);
            typeof(ImageSeqFrameSource).GetProperty("CaptureClockMapper")?.SetValue(source,
                new FixedOffsetCaptureClockMapper(1000000000, 4));
            var frame = source.GetFrame(0);
            Assert.That(frame.TryCreateLocalizationFrame(out var rawFrame, out var error), Is.True, error);
            Assert.That(rawFrame.TrackingMetadata.ClockMappingValid, Is.False);
            Assert.That(rawFrame.TrackingMetadata.ExtrinsicsValid, Is.False);
        }
        [Test]
        public void DecodedImage_UsesTopLeftOpticalRowOrder()
        {
            WritePose("\"timestamp\":2.0,", "[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]", "pixels.png");
            var texture = new Texture2D(2, 2, TextureFormat.RGB24, false);
            try
            {
                // Unity texture rows start at bottom-left: red/green below white/black.
                texture.SetPixels32(new[]
                {
                    new Color32(255, 0, 0, 255), new Color32(0, 255, 0, 255),
                    new Color32(255, 255, 255, 255), new Color32(0, 0, 0, 255)
                });
                texture.Apply();
                File.WriteAllBytes(Path.Combine(_directory, "pixels.png"), texture.EncodeToPNG());
            }
            finally { UnityEngine.Object.DestroyImmediate(texture); }

            var source = new ImageSeqFrameSource();
            Assert.That(source.Load(_directory), Is.True);
            var frame = source.GetFrame(0);
            Assert.That(frame.Width, Is.EqualTo(2));
            Assert.That(frame.Height, Is.EqualTo(2));
            // Optical pixels must start at the upper-left, with x increasing rightward.
            Assert.That(frame.ImageData, Is.EqualTo(new byte[] { 255, 0, 76, 149 }));
        }
        private void WritePose(string timestampField, string transform, string imageFile = "absent.jpg")
        {
            File.WriteAllText(Path.Combine(_directory, "poses.json"),
                "{\"frames\":[{\"index\":7," + timestampField + "\"imageFile\":\"" + imageFile + "\",\"transform\":" + transform + "}]}");
        }
    }
}
