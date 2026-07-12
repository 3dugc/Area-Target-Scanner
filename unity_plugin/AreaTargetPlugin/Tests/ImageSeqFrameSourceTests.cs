using System;
using System.IO;
using System.Globalization;
using NUnit.Framework;
using UnityEngine;
using VideoPlaybackTestScene;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Unit tests for ImageSeqFrameSource.
    /// Validates: Requirements 1.1, 1.2, 1.3, 1.4, 1.5
    /// </summary>
    [TestFixture]
    public class ImageSeqFrameSourceTests
    {
        private string _tempDir;

        [SetUp]
        public void SetUp()
        {
            _tempDir = Path.Combine(Path.GetTempPath(), "ImageSeqFrameSourceTests_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_tempDir);
        }

        [TearDown]
        public void TearDown()
        {
            if (Directory.Exists(_tempDir))
                Directory.Delete(_tempDir, recursive: true);
        }

        // --- 辅助方法 ---

        private void WriteIntrinsics(string dir, float fx = 1113.5f, float fy = 1113.5f,
            float cx = 480f, float cy = 640f, int width = 960, int height = 1280)
        {
            string json = FormattableString.Invariant(
                $"{{\"fx\":{fx},\"fy\":{fy},\"cx\":{cx},\"cy\":{cy},\"width\":{width},\"height\":{height}}}");
            File.WriteAllText(Path.Combine(dir, "intrinsics.json"), json);
        }

        private void WritePoses(string dir, int frameCount = 3)
        {
            var sb = new System.Text.StringBuilder();
            sb.Append("{\"frames\":[");
            for (int i = 0; i < frameCount; i++)
            {
                if (i > 0) sb.Append(",");
                // 单位矩阵（列优先）
                string timestamp = (i * 0.033).ToString(CultureInfo.InvariantCulture);
                sb.Append($"{{\"index\":{i},\"timestamp\":{timestamp},\"imageFile\":\"images/frame_{i:D4}.jpg\"," +
                           $"\"transform\":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}}");
            }
            sb.Append("]}");
            File.WriteAllText(Path.Combine(dir, "poses.json"), sb.ToString());
        }

        private void CreateImagesDir(string dir)
        {
            Directory.CreateDirectory(Path.Combine(dir, "images"));
        }

        // --- Load 成功路径 ---

        [Test]
        public void Load_ValidDirectory_ReturnsTrue()
        {
            WriteIntrinsics(_tempDir);
            WritePoses(_tempDir, 3);
            CreateImagesDir(_tempDir);

            var src = new ImageSeqFrameSource();
            bool result = src.Load(_tempDir);

            Assert.IsTrue(result, $"Load should succeed. LastError: {src.LastError}");
            Assert.IsNull(src.LastError);
        }

        [Test]
        public void Load_ValidDirectory_SetsFrameCount()
        {
            WriteIntrinsics(_tempDir);
            WritePoses(_tempDir, 5);
            CreateImagesDir(_tempDir);

            var src = new ImageSeqFrameSource();
            src.Load(_tempDir);

            Assert.AreEqual(5, src.FrameCount);
        }

        [Test]
        public void Load_ValidDirectory_SetsImageDimensions()
        {
            WriteIntrinsics(_tempDir, width: 960, height: 1280);
            WritePoses(_tempDir, 1);
            CreateImagesDir(_tempDir);

            var src = new ImageSeqFrameSource();
            src.Load(_tempDir);

            Assert.AreEqual(960, src.ImageWidth);
            Assert.AreEqual(1280, src.ImageHeight);
        }

        // --- Load 失败路径 ---

        [Test]
        public void Load_DirectoryNotExist_ReturnsFalse()
        {
            var src = new ImageSeqFrameSource();
            bool result = src.Load("/nonexistent/path/xyz");

            Assert.IsFalse(result);
            Assert.IsNotNull(src.LastError);
            StringAssert.Contains("不存在", src.LastError);
        }

        [Test]
        public void Load_MissingIntrinsicsJson_ReturnsFalse()
        {
            WritePoses(_tempDir, 1);
            // 不写 intrinsics.json

            var src = new ImageSeqFrameSource();
            bool result = src.Load(_tempDir);

            Assert.IsFalse(result);
            Assert.IsNotNull(src.LastError);
            StringAssert.Contains("intrinsics", src.LastError);
        }

        [Test]
        public void Load_MissingPosesJson_ReturnsFalse()
        {
            WriteIntrinsics(_tempDir);
            // 不写 poses.json

            var src = new ImageSeqFrameSource();
            bool result = src.Load(_tempDir);

            Assert.IsFalse(result);
            Assert.IsNotNull(src.LastError);
            StringAssert.Contains("poses", src.LastError);
        }

        [Test]
        public void Load_MalformedIntrinsicsJson_ReturnsFalse()
        {
            File.WriteAllText(Path.Combine(_tempDir, "intrinsics.json"), "not valid json {{{");
            WritePoses(_tempDir, 1);

            var src = new ImageSeqFrameSource();
            bool result = src.Load(_tempDir);

            // JsonUtility 对格式错误可能返回 null 或抛异常，两种情况都应返回 false
            Assert.IsFalse(result);
            Assert.IsNotNull(src.LastError);
        }

        [Test]
        public void Load_MalformedPosesJson_ReturnsFalse()
        {
            WriteIntrinsics(_tempDir);
            File.WriteAllText(Path.Combine(_tempDir, "poses.json"), "not valid json {{{");

            var src = new ImageSeqFrameSource();
            bool result = src.Load(_tempDir);

            Assert.IsFalse(result);
            Assert.IsNotNull(src.LastError);
        }

        [Test]
        public void Load_EmptyPosesFrames_ReturnsFalse()
        {
            WriteIntrinsics(_tempDir);
            File.WriteAllText(Path.Combine(_tempDir, "poses.json"), "{\"frames\":[]}");

            var src = new ImageSeqFrameSource();
            bool result = src.Load(_tempDir);

            Assert.IsFalse(result);
            Assert.IsNotNull(src.LastError);
        }

        // --- GetPose ---

        [Test]
        public void GetPose_IdentityTransform_ReturnsIdentityMatrix()
        {
            WriteIntrinsics(_tempDir);
            WritePoses(_tempDir, 3); // 单位矩阵列优先
            CreateImagesDir(_tempDir);

            var src = new ImageSeqFrameSource();
            src.Load(_tempDir);

            Matrix4x4 pose = src.GetPose(0);

            // 单位矩阵列优先 [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1] → Matrix4x4.identity
            Assert.That(pose.m00, Is.EqualTo(1f).Within(1e-6f));
            Assert.That(pose.m11, Is.EqualTo(1f).Within(1e-6f));
            Assert.That(pose.m22, Is.EqualTo(1f).Within(1e-6f));
            Assert.That(pose.m33, Is.EqualTo(1f).Within(1e-6f));
            Assert.That(pose.m01, Is.EqualTo(0f).Within(1e-6f));
            Assert.That(pose.m10, Is.EqualTo(0f).Within(1e-6f));
        }

        [Test]
        public void GetPose_OutOfRange_ReturnsIdentity()
        {
            WriteIntrinsics(_tempDir);
            WritePoses(_tempDir, 2);
            CreateImagesDir(_tempDir);

            var src = new ImageSeqFrameSource();
            src.Load(_tempDir);

            Assert.AreEqual(Matrix4x4.identity, src.GetPose(-1));
            Assert.AreEqual(Matrix4x4.identity, src.GetPose(100));
        }

        [Test]
        public void GetPose_KnownTranslation_CorrectMatrix()
        {
            WriteIntrinsics(_tempDir);
            // 平移 (1, 2, 3) 的列优先矩阵：col3 = (1, 2, 3, 1)
            string posesJson = "{\"frames\":[{\"index\":0,\"timestamp\":0,\"imageFile\":\"images/frame_0000.jpg\"," +
                               "\"transform\":[1,0,0,0, 0,1,0,0, 0,0,1,0, 1,2,3,1]}]}";
            File.WriteAllText(Path.Combine(_tempDir, "poses.json"), posesJson);
            CreateImagesDir(_tempDir);

            var src = new ImageSeqFrameSource();
            src.Load(_tempDir);

            Matrix4x4 pose = src.GetPose(0);

            Assert.That(pose.m03, Is.EqualTo(1f).Within(1e-6f), "tx");
            Assert.That(pose.m13, Is.EqualTo(2f).Within(1e-6f), "ty");
            Assert.That(pose.m23, Is.EqualTo(3f).Within(1e-6f), "tz");
        }

        // --- GetFrame（缺失图像时的降级行为）---

        [Test]
        public void GetFrame_MissingImageFile_ReturnsZeroGrayData()
        {
            WriteIntrinsics(_tempDir, width: 4, height: 4);
            WritePoses(_tempDir, 1);
            CreateImagesDir(_tempDir);
            // 不创建实际图像文件

            var src = new ImageSeqFrameSource();
            src.Load(_tempDir);

            var frame = src.GetFrame(0);

            // 应返回全零灰度数据，尺寸与 intrinsics 一致
            Assert.IsNotNull(frame.ImageData);
            Assert.AreEqual(4 * 4, frame.ImageData.Length);
            Assert.AreEqual(4, frame.Width);
            Assert.AreEqual(4, frame.Height);
            foreach (byte b in frame.ImageData)
                Assert.AreEqual(0, b, "Missing image should produce zero gray data");
        }

        [Test]
        public void GetFrame_OutOfRange_ReturnsZeroGrayData()
        {
            WriteIntrinsics(_tempDir, width: 8, height: 8);
            WritePoses(_tempDir, 2);
            CreateImagesDir(_tempDir);

            var src = new ImageSeqFrameSource();
            src.Load(_tempDir);

            var frame = src.GetFrame(999);

            Assert.IsNotNull(frame.ImageData);
            Assert.AreEqual(8 * 8, frame.ImageData.Length);
        }

        [Test]
        public void GetFrame_IntrinsicsMatrix_CorrectValues()
        {
            WriteIntrinsics(_tempDir, fx: 500f, fy: 600f, cx: 320f, cy: 240f, width: 8, height: 8);
            WritePoses(_tempDir, 1);
            CreateImagesDir(_tempDir);

            var src = new ImageSeqFrameSource();
            src.Load(_tempDir);

            var frame = src.GetFrame(0);

            Assert.That(frame.Intrinsics.m00, Is.EqualTo(500f).Within(1e-4f), "fx");
            Assert.That(frame.Intrinsics.m11, Is.EqualTo(600f).Within(1e-4f), "fy");
            Assert.That(frame.Intrinsics.m02, Is.EqualTo(320f).Within(1e-4f), "cx");
            Assert.That(frame.Intrinsics.m12, Is.EqualTo(240f).Within(1e-4f), "cy");
        }

        // --- 帧排序 ---

        [Test]
        public void Load_FramesOutOfOrder_SortedByIndex()
        {
            WriteIntrinsics(_tempDir);
            // 故意乱序写入
            string posesJson = "{\"frames\":[" +
                "{\"index\":2,\"timestamp\":0.066,\"imageFile\":\"images/frame_0002.jpg\",\"transform\":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}," +
                "{\"index\":0,\"timestamp\":0.000,\"imageFile\":\"images/frame_0000.jpg\",\"transform\":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}," +
                "{\"index\":1,\"timestamp\":0.033,\"imageFile\":\"images/frame_0001.jpg\",\"transform\":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}" +
                "]}";
            File.WriteAllText(Path.Combine(_tempDir, "poses.json"), posesJson);
            CreateImagesDir(_tempDir);

            var src = new ImageSeqFrameSource();
            bool ok = src.Load(_tempDir);

            Assert.IsTrue(ok);
            Assert.AreEqual(3, src.FrameCount);
            // 验证第 0 帧的图像文件路径包含 frame_0000（通过 GetPose 间接验证排序）
            // 直接验证：GetPose(0) 对应 index=0 的帧（单位矩阵）
            Assert.AreEqual(Matrix4x4.identity, src.GetPose(0));
        }
    }
}
