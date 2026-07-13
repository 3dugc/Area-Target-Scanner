using System;
using System.Collections.Generic;
using System.IO;
using NUnit.Framework;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    [TestFixture]
    public class CoordinateTransformTests
    {
        [Serializable]
        private class CoordinateContract
        {
            public float[] unityWorldFromCamera;
            public float[] cameraFromScan;
            public float[] expectedUnityWorldFromScan;
        }

        [Test]
        public void ComposeUnityWorldFromScan_UsesCurrentCameraPoseFromFixture()
        {
            CoordinateContract contract = ReadContract();

            Matrix4x4 unityWorldFromCamera = CoordinateTransform.FromNativeRowMajor(
                contract.unityWorldFromCamera);
            Matrix4x4 cameraFromScan = CoordinateTransform.FromNativeRowMajor(
                contract.cameraFromScan);

            Matrix4x4 result = CoordinateTransform.ComposeUnityWorldFromScan(
                unityWorldFromCamera, cameraFromScan);

            Assert.That(result.m03, Is.EqualTo(5f).Within(0.00001f));
            Assert.That(result.m13, Is.EqualTo(7f).Within(0.00001f));
            Assert.That(result.m23, Is.EqualTo(9f).Within(0.00001f));
            AssertMatrixEquals(
                CoordinateTransform.FromNativeRowMajor(contract.expectedUnityWorldFromScan),
                result);
        }

        [Test]
        public void ComposeUnityWorldFromScan_UsesUnityWorldFromCameraBeforeCameraFromScan()
        {
            Matrix4x4 unityWorldFromCamera = Matrix4x4.TRS(
                new Vector3(1f, 2f, 3f), Quaternion.Euler(0f, 90f, 0f), Vector3.one);
            Matrix4x4 cameraFromScan = Matrix4x4.TRS(
                new Vector3(4f, 5f, 6f), Quaternion.Euler(0f, 0f, 30f), Vector3.one);

            Matrix4x4 result = CoordinateTransform.ComposeUnityWorldFromScan(
                unityWorldFromCamera, cameraFromScan);
            Matrix4x4 reversed = cameraFromScan * unityWorldFromCamera;

            AssertMatrixEquals(unityWorldFromCamera * cameraFromScan, result);
            Assert.That(result.m03, Is.Not.EqualTo(reversed.m03).Within(0.00001f));
        }

        [Test]
        public void ComposeUnityWorldFromScan_RejectsNonFiniteInput()
        {
            Matrix4x4 cameraFromScan = Matrix4x4.identity;
            cameraFromScan.m00 = float.NaN;

            Assert.Throws<ArgumentException>(() => CoordinateTransform.ComposeUnityWorldFromScan(
                Matrix4x4.identity, cameraFromScan));
        }

        [Test]
        public void ComposeUnityWorldFromScan_RejectsNonRigidHomogeneousRow()
        {
            Matrix4x4 unityWorldFromCamera = Matrix4x4.identity;
            unityWorldFromCamera.m30 = 0.01f;

            Assert.Throws<ArgumentException>(() => CoordinateTransform.ComposeUnityWorldFromScan(
                unityWorldFromCamera, Matrix4x4.identity));
        }

        [Test]
        public void FromNativeRowMajor_RejectsWrongLength()
        {
            Assert.Throws<ArgumentException>(() => CoordinateTransform.FromNativeRowMajor(new float[15]));
        }

        [Test]
        public void LocalizationFrame_RejectsUnnormalizedImageOrientation()
        {
            Assert.Throws<ArgumentException>(() => new LocalizationFrame(
                frameId: 0,
                captureTimestampNs: 1,
                grayscaleImage: new byte[4],
                width: 2,
                height: 2,
                intrinsics: new Vector4(1f, 1f, 0.5f, 0.5f),
                orientation: ImageOrientation.Portrait,
                unityWorldFromCamera: Matrix4x4.identity,
                mapId: "fixture-map"));
        }

        [Test]
        public void LocalizationFrame_CopiesImageAndPreservesRequiredMetadata()
        {
            byte[] image = { 1, 2, 3, 4 };
            Matrix4x4 unityWorldFromCamera = Matrix4x4.TRS(
                new Vector3(1f, 2f, 3f), Quaternion.identity, Vector3.one);

            var frame = new LocalizationFrame(
                frameId: 42,
                captureTimestampNs: 100,
                grayscaleImage: image,
                width: 2,
                height: 2,
                intrinsics: new Vector4(100f, 101f, 1f, 1f),
                orientation: ImageOrientation.LandscapeRight,
                unityWorldFromCamera: unityWorldFromCamera,
                mapId: "fixture-map");

            image[0] = 99;
            byte[] exposedImage = frame.GrayscaleImage;
            exposedImage[1] = 88;

            Assert.That(frame.FrameId, Is.EqualTo(42));
            Assert.That(frame.CaptureTimestampNs, Is.EqualTo(100));
            Assert.That(frame.Width, Is.EqualTo(2));
            Assert.That(frame.Height, Is.EqualTo(2));
            Assert.That(frame.Intrinsics, Is.EqualTo(new Vector4(100f, 101f, 1f, 1f)));
            Assert.That(frame.Orientation, Is.EqualTo(ImageOrientation.LandscapeRight));
            Assert.That(frame.MapId, Is.EqualTo("fixture-map"));
            Assert.That(frame.GrayscaleImage[0], Is.EqualTo(1));
            Assert.That(frame.GrayscaleImage[1], Is.EqualTo(2));
            AssertMatrixEquals(unityWorldFromCamera, frame.UnityWorldFromCamera);
        }

        [Test]
        public void LocalizationFrame_RejectsInvalidImageMetadataAndPose()
        {
            Assert.Throws<ArgumentException>(() => new LocalizationFrame(
                -1, 1, new byte[4], 2, 2, new Vector4(1f, 1f, 1f, 1f),
                ImageOrientation.LandscapeRight, Matrix4x4.identity, "fixture-map"));
            Assert.Throws<ArgumentException>(() => new LocalizationFrame(
                0, -1, new byte[4], 2, 2, new Vector4(1f, 1f, 1f, 1f),
                ImageOrientation.LandscapeRight, Matrix4x4.identity, "fixture-map"));
            Assert.Throws<ArgumentException>(() => new LocalizationFrame(
                0, 1, new byte[3], 2, 2, new Vector4(1f, 1f, 1f, 1f),
                ImageOrientation.LandscapeRight, Matrix4x4.identity, "fixture-map"));
            Assert.Throws<ArgumentException>(() => new LocalizationFrame(
                0, 1, new byte[4], 2, 2, new Vector4(0f, 1f, 1f, 1f),
                ImageOrientation.LandscapeRight, Matrix4x4.identity, "fixture-map"));
            Assert.Throws<ArgumentException>(() => new LocalizationFrame(
                0, 1, new byte[4], 2, 2, new Vector4(1f, 1f, 1f, 1f),
                ImageOrientation.LandscapeRight, Matrix4x4.identity, ""));

            Matrix4x4 nonRigidPose = Matrix4x4.identity;
            nonRigidPose.m33 = 0.5f;
            Assert.Throws<ArgumentException>(() => new LocalizationFrame(
                0, 1, new byte[4], 2, 2, new Vector4(1f, 1f, 1f, 1f),
                ImageOrientation.LandscapeRight, nonRigidPose, "fixture-map"));
        }

        [Test]
        public void LocalizationFrameResult_StoresBothNamedPosesForSuccessfulFrame()
        {
            LocalizationFrame frame = CreateValidFrame();
            Matrix4x4 cameraFromScan = Matrix4x4.TRS(
                new Vector3(4f, 5f, 6f), Quaternion.identity, Vector3.one);

            LocalizationFrameResult result = LocalizationFrameResult.Succeeded(
                frame,
                mapGeneration: 3,
                workerStartedTimestampNs: 200,
                workerCompletedTimestampNs: 250,
                cameraFromScan: cameraFromScan,
                quality: LocalizationQuality.RECOGNIZED,
                confidence: 0.8f,
                matchedFeatures: 42,
                nativeDebugInfo: default);

            Assert.That(result.IsSuccess, Is.True);
            Assert.That(result.FrameId, Is.EqualTo(frame.FrameId));
            Assert.That(result.MapGeneration, Is.EqualTo(3));
            Assert.That(result.WorkerProcessingTimeNs, Is.EqualTo(50));
            Assert.That(result.CameraFromScan.HasValue, Is.True);
            Assert.That(result.UnityWorldFromScan.HasValue, Is.True);
            AssertMatrixEquals(cameraFromScan, result.CameraFromScan.Value);
            Assert.That(result.UnityWorldFromScan.Value.m03, Is.EqualTo(5f).Within(0.00001f));
            Assert.That(result.UnityWorldFromScan.Value.m13, Is.EqualTo(7f).Within(0.00001f));
            Assert.That(result.UnityWorldFromScan.Value.m23, Is.EqualTo(9f).Within(0.00001f));
        }

        [Test]
        public void LocalizationFrameResult_FailureDoesNotUseIdentityAsPose()
        {
            LocalizationFrame frame = CreateValidFrame();

            LocalizationFrameResult result = LocalizationFrameResult.Failed(
                frame,
                mapGeneration: 3,
                workerStartedTimestampNs: 200,
                workerCompletedTimestampNs: 250,
                failureCategory: LocalizationFailureCategory.InvalidFrame,
                nativeDebugInfo: default);

            Assert.That(result.IsSuccess, Is.False);
            Assert.That(result.State, Is.EqualTo(TrackingState.LOST));
            Assert.That(result.Quality, Is.EqualTo(LocalizationQuality.NONE));
            Assert.That(result.CameraFromScan.HasValue, Is.False);
            Assert.That(result.UnityWorldFromScan.HasValue, Is.False);
            Assert.That(result.FailureCategory, Is.EqualTo(LocalizationFailureCategory.InvalidFrame));
        }

        [Test]
        public void CameraFrame_TryCreateLocalizationFrameCarriesCurrentArPoseAndTimestamp()
        {
            Matrix4x4 unityWorldFromCamera = Matrix4x4.TRS(
                new Vector3(7f, 8f, 9f), Quaternion.identity, Vector3.one);
            var cameraFrame = new CameraFrame
            {
                ImageData = new byte[4],
                Width = 2,
                Height = 2,
                Intrinsics = CreateIntrinsics(100f, 101f, 1f, 1f),
                FrameId = 12,
                CaptureTimestampNs = 345,
                Orientation = ImageOrientation.LandscapeRight,
                MapId = "fixture-map",
                UnityWorldFromCamera = unityWorldFromCamera
            };

            bool success = cameraFrame.TryCreateLocalizationFrame(
                out LocalizationFrame localizationFrame, out string error);

            Assert.That(success, Is.True, error);
            Assert.That(localizationFrame.FrameId, Is.EqualTo(12));
            Assert.That(localizationFrame.CaptureTimestampNs, Is.EqualTo(345));
            AssertMatrixEquals(unityWorldFromCamera, localizationFrame.UnityWorldFromCamera);
        }

        [Test]
        public void AlignmentTransformCalculator_ComputesFromFramePairsNotRawCameraFromScan()
        {
            var pairs = new List<LocalizationFramePair>
            {
                new LocalizationFramePair(
                    Matrix4x4.TRS(new Vector3(1f, 0f, 0f), Quaternion.identity, Vector3.one),
                    Matrix4x4.TRS(new Vector3(10f, 0f, 0f), Quaternion.identity, Vector3.one)),
                new LocalizationFramePair(
                    Matrix4x4.TRS(new Vector3(2f, 0f, 0f), Quaternion.identity, Vector3.one),
                    Matrix4x4.TRS(new Vector3(10f, 0f, 0f), Quaternion.identity, Vector3.one)),
                new LocalizationFramePair(
                    Matrix4x4.TRS(new Vector3(3f, 0f, 0f), Quaternion.identity, Vector3.one),
                    Matrix4x4.TRS(new Vector3(10f, 0f, 0f), Quaternion.identity, Vector3.one))
            };

            bool success = AlignmentTransformCalculator.TryCompute(pairs, out Matrix4x4 alignment);

            Assert.That(success, Is.True);
            Assert.That(alignment.m03, Is.EqualTo(12f).Within(0.00001f));
            Assert.That(alignment.m03, Is.Not.EqualTo(10f).Within(0.00001f));
        }

        private static CoordinateContract ReadContract()
        {
            string fixturePath = Path.GetFullPath(Path.Combine(
                Application.dataPath,
                "..",
                "..",
                "tests",
                "fixtures",
                "phase1",
                "coordinate-contract-v1.json"));
            Assert.IsTrue(File.Exists(fixturePath), $"Coordinate fixture not found at {fixturePath}");

            CoordinateContract contract = JsonUtility.FromJson<CoordinateContract>(
                File.ReadAllText(fixturePath));
            Assert.IsNotNull(contract, "Coordinate fixture must deserialize");
            return contract;
        }

        private static LocalizationFrame CreateValidFrame()
        {
            return new LocalizationFrame(
                frameId: 7,
                captureTimestampNs: 100,
                grayscaleImage: new byte[4],
                width: 2,
                height: 2,
                intrinsics: new Vector4(1f, 1f, 0.5f, 0.5f),
                orientation: ImageOrientation.LandscapeRight,
                unityWorldFromCamera: Matrix4x4.TRS(
                    new Vector3(1f, 2f, 3f), Quaternion.identity, Vector3.one),
                mapId: "fixture-map");
        }

        private static Matrix4x4 CreateIntrinsics(float fx, float fy, float cx, float cy)
        {
            Matrix4x4 intrinsics = Matrix4x4.identity;
            intrinsics.m00 = fx;
            intrinsics.m11 = fy;
            intrinsics.m02 = cx;
            intrinsics.m12 = cy;
            return intrinsics;
        }

        private static void AssertMatrixEquals(Matrix4x4 expected, Matrix4x4 actual)
        {
            for (int index = 0; index < 16; index++)
            {
                Assert.That(actual[index], Is.EqualTo(expected[index]).Within(0.00001f),
                    $"Matrix value at index {index} differs.");
            }
        }
    }
}
