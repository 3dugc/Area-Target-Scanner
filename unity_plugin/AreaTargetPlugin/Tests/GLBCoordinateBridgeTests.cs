using System;
using System.IO;
using System.Text;
using NUnit.Framework;
using UnityEngine;

namespace AreaTargetPlugin.Tests
{
    [TestFixture]
    public class GLBCoordinateBridgeTests
    {
        [Test]
        public void KnownTriangle_ReflectsLocalZNormalsAndWindingWithoutRecentering()
        {
            string path = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".glb");
            Mesh mesh = null;
            try
            {
                File.WriteAllBytes(path, Triangle());
                mesh = GLBMeshLoader.Load(path);
                Assert.That(mesh, Is.Not.Null);
                Assert.That(mesh.vertices[0], Is.EqualTo(new Vector3(1, 2, -3)));
                Assert.That(mesh.normals[0], Is.EqualTo(new Vector3(0, 0, -1)));
                CollectionAssert.AreEqual(new[] { 0, 2, 1 }, mesh.triangles);
                Matrix4x4 worldRhFromScan = Matrix4x4.Translate(new Vector3(4, 5, 6));
                Matrix4x4 unityFromScan = NativeSessionBridge.RightHandedWorldToUnity(worldRhFromScan);
                Assert.That(unityFromScan.MultiplyPoint3x4(mesh.vertices[0]),
                    Is.EqualTo(new Vector3(5, 7, -9)));
            }
            finally
            {
                if (mesh != null) UnityEngine.Object.DestroyImmediate(mesh);
                if (File.Exists(path)) File.Delete(path);
            }
        }

        private static byte[] Triangle()
        {
            const string json = "{\"asset\":{\"version\":\"2.0\"},\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1},\"indices\":2}]}],\"accessors\":[{\"bufferView\":0,\"count\":3},{\"bufferView\":1,\"count\":3},{\"bufferView\":2,\"count\":3,\"componentType\":5123}],\"bufferViews\":[{\"byteOffset\":0},{\"byteOffset\":36},{\"byteOffset\":72}]}";
            byte[] jsonBytes = Encoding.UTF8.GetBytes(json.PadRight((json.Length + 3) & ~3));
            using (var bin = new MemoryStream())
            using (var writer = new BinaryWriter(bin))
            {
                foreach (float value in new float[] { 1,2,3, 2,2,3, 1,3,3,
                    0,0,1, 0,0,1, 0,0,1 }) writer.Write(value);
                writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)2); writer.Write((ushort)0);
                byte[] binary = bin.ToArray();
                using (var output = new MemoryStream())
                using (var glb = new BinaryWriter(output))
                {
                    glb.Write(0x46546c67u); glb.Write(2u);
                    glb.Write((uint)(12 + 8 + jsonBytes.Length + 8 + binary.Length));
                    glb.Write((uint)jsonBytes.Length); glb.Write(0x4e4f534au); glb.Write(jsonBytes);
                    glb.Write((uint)binary.Length); glb.Write(0x004e4942u); glb.Write(binary);
                    return output.ToArray();
                }
            }
        }
    }
}
