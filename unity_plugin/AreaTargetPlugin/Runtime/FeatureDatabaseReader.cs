using System;
using System.Collections.Generic;
using System.IO;
using UnityEngine;
using SQLite;

namespace AreaTargetPlugin
{
    /// <summary>
    /// Represents a single keyframe loaded from the feature database.
    /// </summary>
    public class KeyframeRecord
    {
        public int Id;
        public float[] Pose;           // 4x4 matrix as 16 floats (row-major)
        public float[] GlobalDescriptor; // BoW vector
        public List<Vector2> Keypoints2D;
        public List<Vector3> Points3D;
        public List<byte[]> Descriptors; // Each is 32-byte ORB descriptor

        // AKAZE 特征数据
        public List<byte[]> AkazeDescriptors;  // 每个 61 字节
        public List<Vector2> AkazeKeypoints2D;
        public List<Vector3> AkazePoints3D;
    }

    /// <summary>
    /// Represents a visual word from the vocabulary table.
    /// </summary>
    public class VocabularyWord
    {
        public int WordId;
        public byte[] Descriptor;
        public float IdfWeight;
    }

    /// <summary>
    /// Reads the SQLite feature database produced by the processing pipeline.
    /// Uses gilzoide/unity-sqlite-net (SQLite-net) for cross-platform SQLite access.
    /// </summary>
    public class FeatureDatabaseReader : IDisposable
    {
        private List<KeyframeRecord> _keyframes;
        private List<VocabularyWord> _vocabulary;
        private bool _disposed;

        public IReadOnlyList<KeyframeRecord> Keyframes => _keyframes;
        public IReadOnlyList<VocabularyWord> Vocabulary => _vocabulary;
        public int KeyframeCount => _keyframes?.Count ?? 0;

        /// <summary>
        /// AKAZE 特征数据是否可用。当 features.db 包含 akaze_features 表且有数据时为 true。
        /// </summary>
        public bool HasAkazeFeatures { get; private set; }

        /// <summary>
        /// Loads the feature database from the given SQLite file path.
        /// </summary>
        public bool Load(string dbPath)
        {
            if (string.IsNullOrEmpty(dbPath) || !File.Exists(dbPath))
            {
                Debug.LogError($"[FeatureDatabaseReader] Database file not found: {dbPath}");
                return false;
            }

            _keyframes = new List<KeyframeRecord>();
            _vocabulary = new List<VocabularyWord>();
            HasAkazeFeatures = false;

            try
            {
                using (var conn = new SQLiteConnection(dbPath, SQLiteOpenFlags.ReadOnly))
                {
                    LoadKeyframes(conn);
                    LoadVocabulary(conn);
                    LoadAkazeFeatures(conn);
                }
                return true;
            }
            catch (Exception ex)
            {
                Debug.LogError($"[FeatureDatabaseReader] Failed to load database: {ex.Message}");
                return false;
            }
        }

        private void LoadKeyframes(SQLiteConnection conn)
        {
            // 1. Load all keyframe records
            var kfMap = new Dictionary<int, KeyframeRecord>();
            var kfStmt = conn.CreateCommand("SELECT id, pose, global_descriptor FROM keyframes ORDER BY id");
            foreach (var row in kfStmt.ExecuteDeferredQuery<KeyframeRow>())
            {
                var kf = new KeyframeRecord
                {
                    Id = row.id,
                    Keypoints2D = new List<Vector2>(),
                    Points3D = new List<Vector3>(),
                    Descriptors = new List<byte[]>(),
                    AkazeDescriptors = new List<byte[]>(),
                    AkazeKeypoints2D = new List<Vector2>(),
                    AkazePoints3D = new List<Vector3>()
                };

                // Parse pose (stored as 16 doubles, 128 bytes)
                if (row.pose != null)
                {
                    kf.Pose = new float[16];
                    for (int i = 0; i < 16; i++)
                    {
                        kf.Pose[i] = (float)BitConverter.ToDouble(row.pose, i * 8);
                    }
                }

                // Parse global descriptor if present
                if (row.global_descriptor != null && row.global_descriptor.Length > 0)
                {
                    int gdLen = row.global_descriptor.Length / 8;
                    kf.GlobalDescriptor = new float[gdLen];
                    for (int i = 0; i < gdLen; i++)
                    {
                        kf.GlobalDescriptor[i] = (float)BitConverter.ToDouble(row.global_descriptor, i * 8);
                    }
                }

                kfMap[kf.Id] = kf;
                _keyframes.Add(kf);
            }

            // 2. Load all features, group by keyframe_id
            var featStmt = conn.CreateCommand(
                "SELECT keyframe_id, x, y, x3d, y3d, z3d, descriptor FROM features ORDER BY keyframe_id, id");
            foreach (var row in featStmt.ExecuteDeferredQuery<FeatureRow>())
            {
                if (kfMap.TryGetValue(row.keyframe_id, out var kf))
                {
                    kf.Keypoints2D.Add(new Vector2((float)row.x, (float)row.y));
                    kf.Points3D.Add(new Vector3((float)row.x3d, (float)row.y3d, (float)row.z3d));
                    kf.Descriptors.Add(row.descriptor);
                }
            }
        }

        private void LoadVocabulary(SQLiteConnection conn)
        {
            var stmt = conn.CreateCommand("SELECT word_id, descriptor, idf_weight FROM vocabulary ORDER BY word_id");
            foreach (var row in stmt.ExecuteDeferredQuery<VocabularyRow>())
            {
                _vocabulary.Add(new VocabularyWord
                {
                    WordId = row.word_id,
                    Descriptor = row.descriptor,
                    IdfWeight = (float)row.idf_weight
                });
            }
        }

        /// <summary>
        /// 加载 AKAZE 特征数据。如果 akaze_features 表不存在则跳过，不产生错误。
        /// </summary>
        private void LoadAkazeFeatures(SQLiteConnection conn)
        {
            // 检查 akaze_features 表是否存在
            var checkStmt = conn.CreateCommand(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='akaze_features'");
            var tableExists = checkStmt.ExecuteDeferredQuery<TableNameRow>();
            bool found = false;
            foreach (var _ in tableExists)
            {
                found = true;
                break;
            }

            if (!found)
            {
                HasAkazeFeatures = false;
                return;
            }

            // 构建 keyframe id → KeyframeRecord 映射
            var kfMap = new Dictionary<int, KeyframeRecord>();
            foreach (var kf in _keyframes)
            {
                kfMap[kf.Id] = kf;
            }

            // 读取 AKAZE 特征数据
            var stmt = conn.CreateCommand(
                "SELECT keyframe_id, x, y, x3d, y3d, z3d, descriptor FROM akaze_features ORDER BY keyframe_id, id");
            int totalLoaded = 0;
            foreach (var row in stmt.ExecuteDeferredQuery<AkazeFeatureRow>())
            {
                if (kfMap.TryGetValue(row.keyframe_id, out var kf))
                {
                    kf.AkazeKeypoints2D.Add(new Vector2((float)row.x, (float)row.y));
                    kf.AkazePoints3D.Add(new Vector3((float)row.x3d, (float)row.y3d, (float)row.z3d));
                    kf.AkazeDescriptors.Add(row.descriptor);
                    totalLoaded++;
                }
            }

            HasAkazeFeatures = totalLoaded > 0;
        }

        /// <summary>
        /// Returns keyframes within the given radius of a position (extracted from pose translation).
        /// </summary>
        public List<KeyframeRecord> GetNearbyKeyframes(Vector3 position, float radius, int maxCount)
        {
            var candidates = new List<(KeyframeRecord kf, float dist)>();
            float radiusSq = radius * radius;

            foreach (var kf in _keyframes)
            {
                Vector3 kfPos = new Vector3(kf.Pose[3], kf.Pose[7], kf.Pose[11]);
                float distSq = (kfPos - position).sqrMagnitude;
                if (distSq <= radiusSq)
                {
                    candidates.Add((kf, distSq));
                }
            }

            candidates.Sort((a, b) => a.dist.CompareTo(b.dist));
            var result = new List<KeyframeRecord>();
            for (int i = 0; i < Math.Min(maxCount, candidates.Count); i++)
            {
                result.Add(candidates[i].kf);
            }
            return result;
        }

        /// <summary>
        /// Returns the top-K keyframes by BoW similarity to the given query BoW vector.
        /// </summary>
        public List<KeyframeRecord> GetTopKByBoWSimilarity(float[] queryBoW, int k)
        {
            var scored = new List<(KeyframeRecord kf, float score)>();

            foreach (var kf in _keyframes)
            {
                if (kf.GlobalDescriptor == null) continue;
                float score = ComputeBoWSimilarity(queryBoW, kf.GlobalDescriptor);
                scored.Add((kf, score));
            }

            scored.Sort((a, b) => b.score.CompareTo(a.score));
            var result = new List<KeyframeRecord>();
            for (int i = 0; i < Math.Min(k, scored.Count); i++)
            {
                result.Add(scored[i].kf);
            }
            return result;
        }

        private static float ComputeBoWSimilarity(float[] a, float[] b)
        {
            if (a == null || b == null) return 0f;
            int len = Math.Min(a.Length, b.Length);
            float dot = 0f, normA = 0f, normB = 0f;
            for (int i = 0; i < len; i++)
            {
                dot += a[i] * b[i];
                normA += a[i] * a[i];
                normB += b[i] * b[i];
            }
            float denom = (float)(Math.Sqrt(normA) * Math.Sqrt(normB));
            return denom > 1e-9f ? dot / denom : 0f;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _keyframes = null;
            _vocabulary = null;
        }

        // Internal row types for sqlite-net query mapping
        private class KeyframeRow
        {
            public int id { get; set; }
            public byte[] pose { get; set; }
            public byte[] global_descriptor { get; set; }
        }

        private class FeatureRow
        {
            public int keyframe_id { get; set; }
            public double x { get; set; }
            public double y { get; set; }
            public double x3d { get; set; }
            public double y3d { get; set; }
            public double z3d { get; set; }
            public byte[] descriptor { get; set; }
        }

        private class VocabularyRow
        {
            public int word_id { get; set; }
            public byte[] descriptor { get; set; }
            public double idf_weight { get; set; }
        }

        private class AkazeFeatureRow
        {
            public int keyframe_id { get; set; }
            public double x { get; set; }
            public double y { get; set; }
            public double x3d { get; set; }
            public double y3d { get; set; }
            public double z3d { get; set; }
            public byte[] descriptor { get; set; }
        }

        private class TableNameRow
        {
            public string name { get; set; }
        }
    }
}
