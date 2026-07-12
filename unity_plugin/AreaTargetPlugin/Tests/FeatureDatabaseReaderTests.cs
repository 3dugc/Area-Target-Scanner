using System;
using System.Collections.Generic;
using System.IO;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Tests for FeatureDatabaseReader: SQLite loading, pose parsing,
    /// spatial queries, BoW similarity, and edge cases.
    /// Covers the critical Python→C# data bridge.
    /// </summary>
    [TestFixture]
    [IgnoreLogErrors]
    public class FeatureDatabaseReaderTests
    {
        [SetUp]
        public void SetUp()
        {
            LogAssert.ignoreFailingMessages = true;
        }

        #region VisualLocalizationEngine Utility Tests

        // These test the pure-C# utility methods on VisualLocalizationEngine
        // that don't require native P/Invoke.

        [Test]
        public void ExtractTranslation_ReturnsCorrectXYZ()
        {
            var pose = Matrix4x4.identity;
            pose.m03 = 1.5f;
            pose.m13 = -2.3f;
            pose.m23 = 4.7f;

            Vector3 t = VisualLocalizationEngine.ExtractTranslation(pose);

            Assert.AreEqual(1.5f, t.x, 0.001f);
            Assert.AreEqual(-2.3f, t.y, 0.001f);
            Assert.AreEqual(4.7f, t.z, 0.001f);
        }

        [Test]
        public void ExtractTranslation_Identity_ReturnsZero()
        {
            Vector3 t = VisualLocalizationEngine.ExtractTranslation(Matrix4x4.identity);
            Assert.AreEqual(Vector3.zero, t);
        }

        [Test]
        public void ComposePoseMatrix_IdentityRotation_SetsTranslation()
        {
            float[] rot = { 1, 0, 0, 0, 1, 0, 0, 0, 1 };
            float[] trans = { 3f, 4f, 5f };

            Matrix4x4 pose = VisualLocalizationEngine.ComposePoseMatrix(rot, trans);

            Assert.AreEqual(1f, pose.m00, 0.001f);
            Assert.AreEqual(1f, pose.m11, 0.001f);
            Assert.AreEqual(1f, pose.m22, 0.001f);
            Assert.AreEqual(1f, pose.m33, 0.001f);
            Assert.AreEqual(3f, pose.m03, 0.001f);
            Assert.AreEqual(4f, pose.m13, 0.001f);
            Assert.AreEqual(5f, pose.m23, 0.001f);
            Assert.AreEqual(0f, pose.m30, 0.001f);
            Assert.AreEqual(0f, pose.m31, 0.001f);
            Assert.AreEqual(0f, pose.m32, 0.001f);
        }

        [Test]
        public void ComposePoseMatrix_90DegRotationZ_CorrectLayout()
        {
            // 90° rotation around Z: cos=0, sin=1
            float[] rot = { 0, -1, 0, 1, 0, 0, 0, 0, 1 };
            float[] trans = { 0, 0, 0 };

            Matrix4x4 pose = VisualLocalizationEngine.ComposePoseMatrix(rot, trans);

            Assert.AreEqual(0f, pose.m00, 0.001f);
            Assert.AreEqual(-1f, pose.m01, 0.001f);
            Assert.AreEqual(1f, pose.m10, 0.001f);
            Assert.AreEqual(0f, pose.m11, 0.001f);
        }

        #endregion

        #region FlattenDescriptors Tests

        [Test]
        public void FlattenDescriptors_EmptyList_ReturnsEmpty()
        {
            byte[] result = VisualLocalizationEngine.FlattenDescriptors(new List<byte[]>());
            Assert.AreEqual(0, result.Length);
        }

        [Test]
        public void FlattenDescriptors_Null_ReturnsEmpty()
        {
            byte[] result = VisualLocalizationEngine.FlattenDescriptors(null);
            Assert.AreEqual(0, result.Length);
        }

        [Test]
        public void FlattenDescriptors_SingleDescriptor_CopiedCorrectly()
        {
            byte[] desc = new byte[32];
            for (int i = 0; i < 32; i++) desc[i] = (byte)(i + 1);

            byte[] flat = VisualLocalizationEngine.FlattenDescriptors(new List<byte[]> { desc });

            Assert.AreEqual(32, flat.Length);
            for (int i = 0; i < 32; i++)
                Assert.AreEqual(i + 1, flat[i]);
        }

        [Test]
        public void FlattenDescriptors_MultipleDescriptors_ConcatenatedCorrectly()
        {
            var descs = new List<byte[]>();
            for (int d = 0; d < 3; d++)
            {
                byte[] desc = new byte[32];
                for (int i = 0; i < 32; i++) desc[i] = (byte)(d * 32 + i);
                descs.Add(desc);
            }

            byte[] flat = VisualLocalizationEngine.FlattenDescriptors(descs);

            Assert.AreEqual(96, flat.Length);
            // Check first byte of each descriptor
            Assert.AreEqual(0, flat[0]);
            Assert.AreEqual(32, flat[32]);
            Assert.AreEqual(64, flat[64]);
        }

        #endregion

        #region FlattenPoints3D / FlattenPoints2D Tests

        [Test]
        public void FlattenPoints3D_EmptyList_ReturnsEmpty()
        {
            float[] result = VisualLocalizationEngine.FlattenPoints3D(new List<Vector3>());
            Assert.AreEqual(0, result.Length);
        }

        [Test]
        public void FlattenPoints3D_Null_ReturnsEmpty()
        {
            float[] result = VisualLocalizationEngine.FlattenPoints3D(null);
            Assert.AreEqual(0, result.Length);
        }

        [Test]
        public void FlattenPoints3D_TwoPoints_CorrectLayout()
        {
            var pts = new List<Vector3>
            {
                new Vector3(1f, 2f, 3f),
                new Vector3(4f, 5f, 6f)
            };

            float[] flat = VisualLocalizationEngine.FlattenPoints3D(pts);

            Assert.AreEqual(6, flat.Length);
            Assert.AreEqual(1f, flat[0]); Assert.AreEqual(2f, flat[1]); Assert.AreEqual(3f, flat[2]);
            Assert.AreEqual(4f, flat[3]); Assert.AreEqual(5f, flat[4]); Assert.AreEqual(6f, flat[5]);
        }

        [Test]
        public void FlattenPoints2D_EmptyList_ReturnsEmpty()
        {
            float[] result = VisualLocalizationEngine.FlattenPoints2D(new List<Vector2>());
            Assert.AreEqual(0, result.Length);
        }

        [Test]
        public void FlattenPoints2D_TwoPoints_CorrectLayout()
        {
            var pts = new List<Vector2>
            {
                new Vector2(10f, 20f),
                new Vector2(30f, 40f)
            };

            float[] flat = VisualLocalizationEngine.FlattenPoints2D(pts);

            Assert.AreEqual(4, flat.Length);
            Assert.AreEqual(10f, flat[0]); Assert.AreEqual(20f, flat[1]);
            Assert.AreEqual(30f, flat[2]); Assert.AreEqual(40f, flat[3]);
        }

        #endregion

        #region Matrix4x4 ↔ Array Conversion Tests

        [Test]
        public void Matrix4x4ToArray_Identity_Returns16Floats()
        {
            float[] arr = VisualLocalizationEngine.Matrix4x4ToArray(Matrix4x4.identity);

            Assert.AreEqual(16, arr.Length);
            Assert.AreEqual(1f, arr[0]);  // m00
            Assert.AreEqual(1f, arr[5]);  // m11
            Assert.AreEqual(1f, arr[10]); // m22
            Assert.AreEqual(1f, arr[15]); // m33
            Assert.AreEqual(0f, arr[1]);  // m01
        }

        [Test]
        public void ArrayToMatrix4x4_Null_ReturnsIdentity()
        {
            Matrix4x4 m = VisualLocalizationEngine.ArrayToMatrix4x4(null);
            Assert.AreEqual(Matrix4x4.identity, m);
        }

        [Test]
        public void ArrayToMatrix4x4_TooShort_ReturnsIdentity()
        {
            float[] arr = new float[10];
            Matrix4x4 m = VisualLocalizationEngine.ArrayToMatrix4x4(arr);
            Assert.AreEqual(Matrix4x4.identity, m);
        }

        [Test]
        public void Matrix4x4_RoundTrip_PreservesValues()
        {
            var original = Matrix4x4.identity;
            original.m03 = 1.5f;
            original.m13 = -2.5f;
            original.m23 = 3.5f;

            float[] arr = VisualLocalizationEngine.Matrix4x4ToArray(original);
            Matrix4x4 restored = VisualLocalizationEngine.ArrayToMatrix4x4(arr);

            Assert.AreEqual(original.m03, restored.m03, 0.001f);
            Assert.AreEqual(original.m13, restored.m13, 0.001f);
            Assert.AreEqual(original.m23, restored.m23, 0.001f);
        }

        #endregion

        #region FeatureDatabaseReader Edge Cases

        [Test]
        public void Load_NullPath_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            var reader = new FeatureDatabaseReader();
            Assert.IsFalse(reader.Load(null));
        }

        [Test]
        public void Load_EmptyPath_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            var reader = new FeatureDatabaseReader();
            Assert.IsFalse(reader.Load(""));
        }

        [Test]
        public void Load_NonexistentPath_ReturnsFalse()
        {
            LogAssert.ignoreFailingMessages = true;
            var reader = new FeatureDatabaseReader();
            Assert.IsFalse(reader.Load("/nonexistent/path/features.db"));
        }

        [Test]
        public void KeyframeCount_BeforeLoad_ReturnsZero()
        {
            var reader = new FeatureDatabaseReader();
            Assert.AreEqual(0, reader.KeyframeCount);
        }

        [Test]
        public void Dispose_MultipleCalls_DoesNotThrow()
        {
            var reader = new FeatureDatabaseReader();
            Assert.DoesNotThrow(() =>
            {
                reader.Dispose();
                reader.Dispose();
            });
        }

        [Test]
        public void Dispose_ClearsKeyframes()
        {
            var reader = new FeatureDatabaseReader();
            reader.Dispose();
            Assert.AreEqual(0, reader.KeyframeCount);
        }

        #endregion

        #region GetNearbyKeyframes Logic Tests

        /// <summary>
        /// Tests GetNearbyKeyframes spatial query logic using reflection to inject keyframes.
        /// Pose translation is at indices [3], [7], [11] in row-major 4x4.
        /// </summary>
        [Test]
        public void GetNearbyKeyframes_ReturnsClosestWithinRadius()
        {
            var reader = new FeatureDatabaseReader();
            // Use reflection to inject test keyframes
            var keyframes = new List<KeyframeRecord>
            {
                MakeKeyframeAt(0, 0f, 0f, 0f),
                MakeKeyframeAt(1, 1f, 0f, 0f),
                MakeKeyframeAt(2, 5f, 0f, 0f),
                MakeKeyframeAt(3, 10f, 0f, 0f),
            };
            SetKeyframes(reader, keyframes);

            var result = reader.GetNearbyKeyframes(Vector3.zero, 2f, 10);

            Assert.AreEqual(2, result.Count); // id=0 (dist=0) and id=1 (dist=1)
            Assert.AreEqual(0, result[0].Id); // closest first
            Assert.AreEqual(1, result[1].Id);
        }

        [Test]
        public void GetNearbyKeyframes_RespectsMaxCount()
        {
            var reader = new FeatureDatabaseReader();
            var keyframes = new List<KeyframeRecord>();
            for (int i = 0; i < 20; i++)
                keyframes.Add(MakeKeyframeAt(i, i * 0.1f, 0f, 0f));
            SetKeyframes(reader, keyframes);

            var result = reader.GetNearbyKeyframes(Vector3.zero, 100f, 5);

            Assert.AreEqual(5, result.Count);
        }

        [Test]
        public void GetNearbyKeyframes_EmptyDB_ReturnsEmpty()
        {
            var reader = new FeatureDatabaseReader();
            SetKeyframes(reader, new List<KeyframeRecord>());

            var result = reader.GetNearbyKeyframes(Vector3.zero, 100f, 10);

            Assert.AreEqual(0, result.Count);
        }

        [Test]
        public void GetNearbyKeyframes_NoneInRadius_ReturnsEmpty()
        {
            var reader = new FeatureDatabaseReader();
            var keyframes = new List<KeyframeRecord>
            {
                MakeKeyframeAt(0, 100f, 100f, 100f),
            };
            SetKeyframes(reader, keyframes);

            var result = reader.GetNearbyKeyframes(Vector3.zero, 1f, 10);

            Assert.AreEqual(0, result.Count);
        }

        #endregion

        #region GetTopKByBoWSimilarity Logic Tests

        [Test]
        public void GetTopKByBoWSimilarity_ReturnsMostSimilar()
        {
            var reader = new FeatureDatabaseReader();
            var keyframes = new List<KeyframeRecord>
            {
                MakeKeyframeWithBoW(0, new float[] { 1, 0, 0 }),
                MakeKeyframeWithBoW(1, new float[] { 0, 1, 0 }),
                MakeKeyframeWithBoW(2, new float[] { 0.9f, 0.1f, 0 }),
            };
            SetKeyframes(reader, keyframes);

            // Query is close to [1, 0, 0]
            var result = reader.GetTopKByBoWSimilarity(new float[] { 1, 0, 0 }, 2);

            Assert.AreEqual(2, result.Count);
            Assert.AreEqual(0, result[0].Id); // exact match
            Assert.AreEqual(2, result[1].Id); // close match
        }

        [Test]
        public void GetTopKByBoWSimilarity_NullGlobalDescriptor_Skipped()
        {
            var reader = new FeatureDatabaseReader();
            var keyframes = new List<KeyframeRecord>
            {
                MakeKeyframeWithBoW(0, null),
                MakeKeyframeWithBoW(1, new float[] { 1, 0, 0 }),
            };
            SetKeyframes(reader, keyframes);

            var result = reader.GetTopKByBoWSimilarity(new float[] { 1, 0, 0 }, 10);

            Assert.AreEqual(1, result.Count);
            Assert.AreEqual(1, result[0].Id);
        }

        [Test]
        public void GetTopKByBoWSimilarity_ZeroVector_ReturnsZeroSimilarity()
        {
            var reader = new FeatureDatabaseReader();
            var keyframes = new List<KeyframeRecord>
            {
                MakeKeyframeWithBoW(0, new float[] { 0, 0, 0 }),
            };
            SetKeyframes(reader, keyframes);

            var result = reader.GetTopKByBoWSimilarity(new float[] { 1, 0, 0 }, 10);

            // Zero-length vector → cosine similarity = 0, but still returned
            Assert.AreEqual(1, result.Count);
        }

        [Test]
        public void GetTopKByBoWSimilarity_EmptyDB_ReturnsEmpty()
        {
            var reader = new FeatureDatabaseReader();
            SetKeyframes(reader, new List<KeyframeRecord>());

            var result = reader.GetTopKByBoWSimilarity(new float[] { 1, 0, 0 }, 10);

            Assert.AreEqual(0, result.Count);
        }

        [Test]
        public void GetTopKByBoWSimilarity_DifferentLengthVectors_HandledGracefully()
        {
            var reader = new FeatureDatabaseReader();
            var keyframes = new List<KeyframeRecord>
            {
                MakeKeyframeWithBoW(0, new float[] { 1, 0, 0, 0, 0 }),
            };
            SetKeyframes(reader, keyframes);

            // Query vector is shorter — ComputeBoWSimilarity uses Math.Min(a.Length, b.Length)
            var result = reader.GetTopKByBoWSimilarity(new float[] { 1, 0 }, 10);

            Assert.AreEqual(1, result.Count);
        }

        #endregion

        #region Helpers

        private static KeyframeRecord MakeKeyframeAt(int id, float x, float y, float z)
        {
            // Row-major 4x4 identity with translation at [3], [7], [11]
            float[] pose = {
                1, 0, 0, x,
                0, 1, 0, y,
                0, 0, 1, z,
                0, 0, 0, 1
            };
            return new KeyframeRecord
            {
                Id = id,
                Pose = pose,
                Keypoints2D = new List<Vector2>(),
                Points3D = new List<Vector3>(),
                Descriptors = new List<byte[]>()
            };
        }

        private static KeyframeRecord MakeKeyframeWithBoW(int id, float[] bow)
        {
            var kf = MakeKeyframeAt(id, 0, 0, 0);
            kf.GlobalDescriptor = bow;
            return kf;
        }

        private static void SetKeyframes(FeatureDatabaseReader reader, List<KeyframeRecord> keyframes)
        {
            // Use reflection to set the private _keyframes field
            var field = typeof(FeatureDatabaseReader).GetField("_keyframes",
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
            field.SetValue(reader, keyframes);
        }

        #endregion
    }
}
