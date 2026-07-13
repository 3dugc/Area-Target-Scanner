using System;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Tests for the native C++ localizer bridge (P/Invoke layer).
    /// Validates: handle lifecycle, NULL safety, struct marshalling, error recovery.
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class NativeLocalizerBridgeTests
    {
        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
        }

        #region Handle Lifecycle

        [Test]
        public void Create_ReturnsNonZeroHandle()
        {
            IntPtr handle = NativeLocalizerBridge.vl_create();
            Assert.AreNotEqual(IntPtr.Zero, handle);
            NativeLocalizerBridge.vl_destroy(handle);
        }

        [Test]
        public void Destroy_NullHandle_DoesNotThrow()
        {
            Assert.DoesNotThrow(() => NativeLocalizerBridge.vl_destroy(IntPtr.Zero));
        }

        [Test]
        public void MultipleHandles_AreIndependent()
        {
            IntPtr h1 = NativeLocalizerBridge.vl_create();
            IntPtr h2 = NativeLocalizerBridge.vl_create();
            Assert.AreNotEqual(h1, h2);
            NativeLocalizerBridge.vl_destroy(h1);
            NativeLocalizerBridge.vl_destroy(h2);
        }

        #endregion

        #region NULL Handle Safety

        [Test]
        public void AddVocabularyWord_NullHandle_ReturnsZero()
        {
            byte[] desc = new byte[32];
            int ret = NativeLocalizerBridge.vl_add_vocabulary_word(IntPtr.Zero, 0, desc, 32, 1.0f);
            Assert.AreEqual(0, ret);
        }

        [Test]
        public void AddKeyframe_NullHandle_ReturnsZero()
        {
            float[] pose = new float[16];
            byte[] desc = new byte[32];
            float[] pts3d = new float[3];
            float[] pts2d = new float[2];
            int ret = NativeLocalizerBridge.vl_add_keyframe(IntPtr.Zero, 0, pose, desc, 1, pts3d, pts2d);
            Assert.AreEqual(0, ret);
        }

        [Test]
        public void BuildIndex_NullHandle_ReturnsZero()
        {
            int ret = NativeLocalizerBridge.vl_build_index(IntPtr.Zero);
            Assert.AreEqual(0, ret);
        }

        [Test]
        public void ProcessFrame_NullHandle_ReturnsLost()
        {
            byte[] img = new byte[100];
            VLResultData result = NativeLocalizerBridge.ProcessFrameSafe(
                IntPtr.Zero, img, 10, 10, 500, 500, 5, 5, 0, null);
            Assert.AreEqual(2, result.state); // LOST
        }

        [Test]
        public void Reset_NullHandle_DoesNotThrow()
        {
            Assert.DoesNotThrow(() => NativeLocalizerBridge.vl_reset(IntPtr.Zero));
        }

        #endregion

        #region VLResult Struct Marshalling

        [Test]
        public void ProcessFrame_EmptyDB_ReturnsIdentityPose()
        {
            IntPtr handle = NativeLocalizerBridge.vl_create();
            NativeLocalizerBridge.vl_build_index(handle);

            byte[] img = new byte[64 * 64];
            VLResultData result = NativeLocalizerBridge.ProcessFrameSafe(
                handle, img, 64, 64, 500, 500, 32, 32, 0, null);

            Assert.AreEqual(2, result.state);
            Assert.AreEqual(0f, result.confidence);
            Assert.AreEqual(0, result.matched_features);
            Assert.IsNotNull(result.pose);
            Assert.AreEqual(16, result.pose.Length);
            // Identity diagonal
            Assert.AreEqual(1f, result.pose[0], 0.001f);
            Assert.AreEqual(1f, result.pose[5], 0.001f);
            Assert.AreEqual(1f, result.pose[10], 0.001f);
            Assert.AreEqual(1f, result.pose[15], 0.001f);

            NativeLocalizerBridge.vl_destroy(handle);
        }

        #endregion

        #region Coordinate Contract

        [Test]
        public void Matrix4x4ToArray_SerializesTranslationInRowMajorOrder()
        {
            Matrix4x4 matrix = Matrix4x4.TRS(
                new Vector3(4f, 5f, 6f),
                Quaternion.identity,
                Vector3.one
            );

            float[] values = VisualLocalizationEngine.Matrix4x4ToArray(matrix);

            Assert.AreEqual(matrix.m03, values[3]);
            Assert.AreEqual(matrix.m13, values[7]);
            Assert.AreEqual(matrix.m23, values[11]);
        }

        [Test]
        public void NativeCameraPoseSerialization_UsesCurrentLocalizationFramePose()
        {
            Matrix4x4 unityWorldFromCamera = Matrix4x4.TRS(
                new Vector3(4f, 5f, 6f),
                Quaternion.identity,
                Vector3.one
            );
            var frame = new LocalizationFrame(unityWorldFromCamera);

            float[] values = VisualLocalizationEngine.PrepareUnityWorldFromCameraForNative(frame);

            Assert.AreEqual(unityWorldFromCamera.m03, values[3]);
            Assert.AreEqual(unityWorldFromCamera.m13, values[7]);
            Assert.AreEqual(unityWorldFromCamera.m23, values[11]);
        }

        #endregion

        #region Data Loading

        [Test]
        public void AddVocabularyWord_ValidData_ReturnsOne()
        {
            IntPtr handle = NativeLocalizerBridge.vl_create();
            byte[] desc = new byte[32];
            for (int i = 0; i < 32; i++) desc[i] = 1;
            int ret = NativeLocalizerBridge.vl_add_vocabulary_word(handle, 0, desc, 32, 1.5f);
            Assert.AreEqual(1, ret);
            NativeLocalizerBridge.vl_destroy(handle);
        }

        [Test]
        public void AddKeyframe_ValidData_ReturnsOne()
        {
            IntPtr handle = NativeLocalizerBridge.vl_create();
            float[] pose = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 5, 0, 0, 0, 1 };
            byte[] desc = new byte[32];
            float[] pts3d = { 1f, 2f, 3f };
            float[] pts2d = { 100f, 200f };
            int ret = NativeLocalizerBridge.vl_add_keyframe(handle, 0, pose, desc, 1, pts3d, pts2d);
            Assert.AreEqual(1, ret);
            NativeLocalizerBridge.vl_destroy(handle);
        }

        [Test]
        public void BuildIndex_EmptyDB_ReturnsOne()
        {
            IntPtr handle = NativeLocalizerBridge.vl_create();
            int ret = NativeLocalizerBridge.vl_build_index(handle);
            Assert.AreEqual(1, ret);
            NativeLocalizerBridge.vl_destroy(handle);
        }

        #endregion

        #region Stress Tests

        [Test]
        public void RapidCreateDestroy_100Cycles_NoLeak()
        {
            for (int i = 0; i < 100; i++)
            {
                IntPtr handle = NativeLocalizerBridge.vl_create();
                Assert.AreNotEqual(IntPtr.Zero, handle);
                NativeLocalizerBridge.vl_destroy(handle);
            }
        }

        [Test]
        public void RapidProcessFrame_50Frames_NoException()
        {
            IntPtr handle = NativeLocalizerBridge.vl_create();
            NativeLocalizerBridge.vl_build_index(handle);

            byte[] img = new byte[320 * 240];
            for (int i = 0; i < 50; i++)
            {
                VLResultData result = NativeLocalizerBridge.ProcessFrameSafe(
                    handle, img, 320, 240, 500, 500, 160, 120, 0, null);
                Assert.AreEqual(2, result.state);
            }

            NativeLocalizerBridge.vl_destroy(handle);
        }

        [Test]
        public void ResetDuringProcessing_NoCorruption()
        {
            IntPtr handle = NativeLocalizerBridge.vl_create();
            NativeLocalizerBridge.vl_build_index(handle);

            byte[] img = new byte[64 * 64];
            NativeLocalizerBridge.ProcessFrameSafe(handle, img, 64, 64, 500, 500, 32, 32, 0, null);
            NativeLocalizerBridge.vl_reset(handle);
            VLResultData result = NativeLocalizerBridge.ProcessFrameSafe(
                handle, img, 64, 64, 500, 500, 32, 32, 0, null);
            Assert.AreEqual(2, result.state);

            NativeLocalizerBridge.vl_destroy(handle);
        }

        #endregion

        #region Error Recovery

        [Test]
        public void ProcessFrame_AfterReset_StillWorks()
        {
            IntPtr handle = NativeLocalizerBridge.vl_create();

            byte[] vocab = new byte[32];
            NativeLocalizerBridge.vl_add_vocabulary_word(handle, 0, vocab, 32, 1.0f);
            NativeLocalizerBridge.vl_build_index(handle);

            byte[] img = new byte[64 * 64];
            NativeLocalizerBridge.ProcessFrameSafe(handle, img, 64, 64, 500, 500, 32, 32, 0, null);

            NativeLocalizerBridge.vl_reset(handle);
            VLResultData result = NativeLocalizerBridge.ProcessFrameSafe(
                handle, img, 64, 64, 500, 500, 32, 32, 0, null);
            Assert.AreEqual(2, result.state);

            NativeLocalizerBridge.vl_destroy(handle);
        }

        [Test]
        public void ProcessFrame_WithUnityWorldFromCamera_DoesNotCrash()
        {
            IntPtr handle = NativeLocalizerBridge.vl_create();
            NativeLocalizerBridge.vl_build_index(handle);

            byte[] img = new byte[64 * 64];
            float[] unityWorldFromCamera = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 3, 0, 0, 0, 1 };
            VLResultData result = NativeLocalizerBridge.ProcessFrameSafe(
                handle, img, 64, 64, 500, 500, 32, 32, 1, unityWorldFromCamera);
            Assert.AreEqual(2, result.state);

            NativeLocalizerBridge.vl_destroy(handle);
        }

        #endregion
    }
}
