using System;
using System.IO;
using System.Collections.Generic;
using System.Text;
using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>
    /// Minimal runtime GLB (Binary glTF 2.0) mesh loader.
    /// Extracts vertex positions, normals, and triangle indices from the first mesh primitive.
    /// Does NOT handle textures, animations, or multi-mesh scenes.
    /// </summary>
    public static class GLBMeshLoader
    {
        private const uint GLB_MAGIC = 0x46546C67; // "glTF"
        private const uint CHUNK_JSON = 0x4E4F534A;
        private const uint CHUNK_BIN  = 0x004E4942;

        /// <summary>
        /// Loads a GLB file and returns a Unity Mesh, or null on failure.
        /// </summary>
        public static Mesh Load(string path)
        {
            if (!File.Exists(path))
            {
                Debug.LogError($"[GLBMeshLoader] File not found: {path}");
                return null;
            }

            byte[] data;
            try { data = File.ReadAllBytes(path); }
            catch (Exception ex)
            {
                Debug.LogError($"[GLBMeshLoader] Read failed: {ex.Message}");
                return null;
            }

            return Parse(data, path);
        }

        private static Mesh Parse(byte[] data, string debugName)
        {
            if (data.Length < 12)
            {
                Debug.LogError("[GLBMeshLoader] File too small");
                return null;
            }

            uint magic = BitConverter.ToUInt32(data, 0);
            if (magic != GLB_MAGIC)
            {
                Debug.LogError($"[GLBMeshLoader] Bad magic: 0x{magic:X8}");
                return null;
            }

            uint version = BitConverter.ToUInt32(data, 4);
            uint totalLen = BitConverter.ToUInt32(data, 8);
            Debug.Log($"[GLBMeshLoader] glTF v{version}, {totalLen} bytes");

            // Parse chunks
            string jsonStr = null;
            byte[] binData = null;
            int offset = 12;

            while (offset + 8 <= data.Length)
            {
                uint chunkLen = BitConverter.ToUInt32(data, offset);
                uint chunkType = BitConverter.ToUInt32(data, offset + 4);
                int chunkDataStart = offset + 8;

                if (chunkType == CHUNK_JSON)
                    jsonStr = Encoding.UTF8.GetString(data, chunkDataStart, (int)chunkLen);
                else if (chunkType == CHUNK_BIN)
                {
                    binData = new byte[chunkLen];
                    Buffer.BlockCopy(data, chunkDataStart, binData, 0, (int)chunkLen);
                }

                offset = chunkDataStart + (int)chunkLen;
                // Align to 4 bytes
                offset = (offset + 3) & ~3;
            }

            if (jsonStr == null || binData == null)
            {
                Debug.LogError("[GLBMeshLoader] Missing JSON or BIN chunk");
                return null;
            }

            return ParseGltfJson(jsonStr, binData, debugName);
        }

        /// <summary>
        /// Minimal glTF JSON parser — extracts first mesh primitive's POSITION, NORMAL, indices.
        /// Uses Unity's JsonUtility with wrapper classes.
        /// </summary>
        private static Mesh ParseGltfJson(string json, byte[] bin, string debugName)
        {
            GltfRoot root;
            try { root = JsonUtility.FromJson<GltfRoot>(json); }
            catch (Exception ex)
            {
                Debug.LogError($"[GLBMeshLoader] JSON parse failed: {ex.Message}");
                return null;
            }

            if (root.meshes == null || root.meshes.Length == 0)
            {
                Debug.LogError("[GLBMeshLoader] No meshes in glTF");
                return null;
            }

            var prim = root.meshes[0].primitives[0];
            int posAccessor = prim.attributes.POSITION;
            int idxAccessor = prim.indices;

            // Read positions
            Vector3[] positions = ReadVec3Accessor(root, bin, posAccessor);
            if (positions == null) return null;

            // Read indices
            int[] indices = ReadIndexAccessor(root, bin, idxAccessor);
            if (indices == null) return null;

            // Read normals (optional)
            Vector3[] normals = null;
            if (prim.attributes.NORMAL >= 0)
                normals = ReadVec3Accessor(root, bin, prim.attributes.NORMAL);

            Debug.Log($"[GLBMeshLoader] Loaded: {positions.Length} verts, {indices.Length / 3} tris" +
                      $"{(normals != null ? $", {normals.Length} normals" : "")}");

            // Build Unity Mesh
            var mesh = new Mesh();
            mesh.name = debugName;
            if (positions.Length > 65535)
                mesh.indexFormat = UnityEngine.Rendering.IndexFormat.UInt32;
            mesh.vertices = positions;
            mesh.triangles = indices;
            if (normals != null)
                mesh.normals = normals;
            else
                mesh.RecalculateNormals();
            mesh.RecalculateBounds();

            Debug.Log($"[GLBMeshLoader] Mesh bounds: center={mesh.bounds.center} size={mesh.bounds.size}");
            return mesh;
        }

        private static Vector3[] ReadVec3Accessor(GltfRoot root, byte[] bin, int accessorIdx)
        {
            var acc = root.accessors[accessorIdx];
            var bv = root.bufferViews[acc.bufferView];
            int start = bv.byteOffset + acc.byteOffset;
            int stride = bv.byteStride > 0 ? bv.byteStride : 12; // 3 floats

            var result = new Vector3[acc.count];
            for (int i = 0; i < acc.count; i++)
            {
                int off = start + i * stride;
                float x = BitConverter.ToSingle(bin, off);
                float y = BitConverter.ToSingle(bin, off + 4);
                float z = BitConverter.ToSingle(bin, off + 8);
                result[i] = new Vector3(x, y, z);
            }
            return result;
        }

        private static int[] ReadIndexAccessor(GltfRoot root, byte[] bin, int accessorIdx)
        {
            var acc = root.accessors[accessorIdx];
            var bv = root.bufferViews[acc.bufferView];
            int start = bv.byteOffset + acc.byteOffset;

            var result = new int[acc.count];

            // componentType: 5121=UBYTE, 5123=USHORT, 5125=UINT
            switch (acc.componentType)
            {
                case 5121: // UNSIGNED_BYTE
                    for (int i = 0; i < acc.count; i++)
                        result[i] = bin[start + i];
                    break;
                case 5123: // UNSIGNED_SHORT
                    for (int i = 0; i < acc.count; i++)
                        result[i] = BitConverter.ToUInt16(bin, start + i * 2);
                    break;
                case 5125: // UNSIGNED_INT
                    for (int i = 0; i < acc.count; i++)
                        result[i] = (int)BitConverter.ToUInt32(bin, start + i * 4);
                    break;
                default:
                    Debug.LogError($"[GLBMeshLoader] Unsupported index type: {acc.componentType}");
                    return null;
            }
            return result;
        }

        // --- Minimal glTF JSON data classes ---

        [Serializable] private class GltfRoot
        {
            public GltfMesh[] meshes;
            public GltfAccessor[] accessors;
            public GltfBufferView[] bufferViews;
            public GltfBuffer[] buffers;
        }

        [Serializable] private class GltfMesh
        {
            public GltfPrimitive[] primitives;
        }

        [Serializable] private class GltfPrimitive
        {
            public GltfAttributes attributes;
            public int indices = -1;
        }

        [Serializable] private class GltfAttributes
        {
            public int POSITION = -1;
            public int NORMAL = -1;
        }

        [Serializable] private class GltfAccessor
        {
            public int bufferView;
            public int byteOffset;
            public int componentType;
            public int count;
            public string type;
        }

        [Serializable] private class GltfBufferView
        {
            public int buffer;
            public int byteOffset;
            public int byteLength;
            public int byteStride;
        }

        [Serializable] private class GltfBuffer
        {
            public int byteLength;
        }
    }
}
