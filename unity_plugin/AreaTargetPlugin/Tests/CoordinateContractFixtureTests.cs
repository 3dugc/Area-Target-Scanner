using System;
using System.IO;
using NUnit.Framework;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    [TestFixture]
    public class CoordinateContractFixtureTests
    {
        [Serializable]
        private class CoordinateContract
        {
            public int schemaVersion;
            public string coordinateSystem;
            public string units;
            public string scanPoseLayout;
            public string nativePoseLayout;
            public string imageOrientation;
            public ImageSize image;
            public Intrinsics intrinsics;
            public float[] unityWorldFromCamera;
            public float[] cameraFromScan;
            public float[] expectedUnityWorldFromScan;
        }

        [Serializable]
        private class ImageSize
        {
            public int width;
            public int height;
        }

        [Serializable]
        private class Intrinsics
        {
            public float fx;
            public float fy;
            public float cx;
            public float cy;
        }

        [Test]
        public void Fixture_DeclaresVersionedCoordinateAndImageContract()
        {
            var contract = ReadContract();

            Assert.AreEqual(1, contract.schemaVersion);
            Assert.AreEqual("arkit-world", contract.coordinateSystem);
            Assert.AreEqual("meters", contract.units);
            Assert.AreEqual("arkit-column-major", contract.scanPoseLayout);
            Assert.AreEqual("row-major", contract.nativePoseLayout);
            Assert.AreEqual("landscapeRight", contract.imageOrientation);
            Assert.AreEqual(640, contract.image.width);
            Assert.AreEqual(480, contract.image.height);
            Assert.AreEqual(500f, contract.intrinsics.fx, 0.00001f);
            Assert.AreEqual(510f, contract.intrinsics.fy, 0.00001f);
            Assert.AreEqual(320f, contract.intrinsics.cx, 0.00001f);
            Assert.AreEqual(240f, contract.intrinsics.cy, 0.00001f);
        }

        [Test]
        public void Fixture_StoresRowMajorTransformsWithExpectedUnityWorldFromScanTranslation()
        {
            var contract = ReadContract();

            AssertMatrix(contract.unityWorldFromCamera, "unityWorldFromCamera");
            AssertMatrix(contract.cameraFromScan, "cameraFromScan");
            AssertMatrix(contract.expectedUnityWorldFromScan, "expectedUnityWorldFromScan");
            Assert.AreEqual(5f, contract.expectedUnityWorldFromScan[3], 0.00001f);
            Assert.AreEqual(7f, contract.expectedUnityWorldFromScan[7], 0.00001f);
            Assert.AreEqual(9f, contract.expectedUnityWorldFromScan[11], 0.00001f);
        }

        private static CoordinateContract ReadContract()
        {
            var fixturePath = Path.GetFullPath(Path.Combine(
                Application.dataPath,
                "..",
                "..",
                "tests",
                "fixtures",
                "phase1",
                "coordinate-contract-v1.json"
            ));
            Assert.IsTrue(File.Exists(fixturePath), $"Coordinate fixture not found at {fixturePath}");

            var contract = JsonUtility.FromJson<CoordinateContract>(File.ReadAllText(fixturePath));
            Assert.IsNotNull(contract, "Coordinate fixture must deserialize");
            return contract;
        }

        private static void AssertMatrix(float[] values, string name)
        {
            Assert.IsNotNull(values, $"{name} must be present");
            Assert.AreEqual(16, values.Length, $"{name} must contain 16 row-major values");
        }
    }
}
