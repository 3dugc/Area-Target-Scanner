using System.Threading.Tasks;
using NUnit.Framework;
using FsCheck;
using FsCheck.NUnit;
using UnityEngine;
using AreaTargetPlugin.PointCloudLocalization;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Property-based tests for MapManager register/lookup behavior.
    /// Feature: pointcloud-localization, Property 5: MapManager 注册-查找 round-trip
    /// **Validates: Requirements 4.5, 4.7, 5.3, 5.4**
    /// </summary>
    [TestFixture]
    public class MapManagerPropertyTests
    {
        /// <summary>
        /// Minimal stub for ISceneUpdateable used in MapEntry construction.
        /// </summary>
        private class StubSceneUpdateable : ISceneUpdateable
        {
            public Transform GetTransform() => null;
            public Task SceneUpdate(SceneUpdateData data) => Task.CompletedTask;
            public Task ResetScene() => Task.CompletedTask;
        }

        [TearDown]
        public void TearDown()
        {
            MapManager.Clear();
        }

        /// <summary>
        /// Property 5a: For any mapId and MapEntry, after calling RegisterMap(mapId, entry),
        /// TryGetMapEntry(mapId) should return true and the output entry should be the
        /// same instance as the registered one.
        /// **Validates: Requirements 4.5, 4.7, 5.4**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property RegisterMap_ThenTryGet_ReturnsRegisteredEntry(int mapId)
        {
            var sceneParent = new StubSceneUpdateable();
            var entry = new MapEntry { MapId = mapId, SceneParent = sceneParent };

            MapManager.Clear();
            MapManager.RegisterMap(mapId, entry);

            bool found = MapManager.TryGetMapEntry(mapId, out MapEntry retrieved);

            return (found && ReferenceEquals(retrieved, entry)).ToProperty()
                .Label($"RegisterMap({mapId}) then TryGetMapEntry should return true with same entry");
        }

        /// <summary>
        /// Property 5b: For any unregistered mapId, TryGetMapEntry should return false.
        /// **Validates: Requirements 5.3**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property UnregisteredMapId_TryGet_ReturnsFalse(int mapId)
        {
            MapManager.Clear();

            bool found = MapManager.TryGetMapEntry(mapId, out MapEntry entry);

            return (!found && entry == null).ToProperty()
                .Label($"TryGetMapEntry({mapId}) on empty MapManager should return false with null entry");
        }

        /// <summary>
        /// Property 5c: Registering with an existing mapId overwrites the old entry.
        /// After overwrite, TryGetMapEntry returns the new entry.
        /// **Validates: Requirements 4.7**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property RegisterMap_Overwrite_ReturnsNewEntry(int mapId)
        {
            var oldParent = new StubSceneUpdateable();
            var newParent = new StubSceneUpdateable();
            var oldEntry = new MapEntry { MapId = mapId, SceneParent = oldParent };
            var newEntry = new MapEntry { MapId = mapId, SceneParent = newParent };

            MapManager.Clear();
            MapManager.RegisterMap(mapId, oldEntry);
            MapManager.RegisterMap(mapId, newEntry);

            bool found = MapManager.TryGetMapEntry(mapId, out MapEntry retrieved);

            return (found && ReferenceEquals(retrieved, newEntry) && !ReferenceEquals(retrieved, oldEntry)).ToProperty()
                .Label($"RegisterMap({mapId}) twice should overwrite, returning the new entry");
        }

        /// <summary>
        /// Property 5d: After RegisterMap then UnregisterMap, TryGetMapEntry returns false.
        /// **Validates: Requirements 4.5, 5.3**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property RegisterThenUnregister_TryGet_ReturnsFalse(int mapId)
        {
            var entry = new MapEntry { MapId = mapId, SceneParent = new StubSceneUpdateable() };

            MapManager.Clear();
            MapManager.RegisterMap(mapId, entry);
            MapManager.UnregisterMap(mapId);

            bool found = MapManager.TryGetMapEntry(mapId, out MapEntry retrieved);

            return (!found).ToProperty()
                .Label($"After Register then Unregister({mapId}), TryGetMapEntry should return false");
        }

        /// <summary>
        /// Property 6: For any N successfully loaded maps (N >= 1), each map's assigned mapId
        /// should be distinct, and each mapId should be findable via MapManager.TryGetMapEntry.
        /// Feature: pointcloud-localization, Property 6: 多地图 mapId 唯一性
        /// **Validates: Requirements 4.5, 4.8**
        /// </summary>
        [FsCheck.NUnit.Property(MaxTest = 100)]
        public Property MultipleDistinctMaps_AllFindable(int[] mapIds)
        {
            MapManager.Clear();

            var distinctIds = new System.Collections.Generic.HashSet<int>(mapIds);

            foreach (var id in distinctIds)
            {
                MapManager.RegisterMap(id, new MapEntry { MapId = id, SceneParent = new StubSceneUpdateable() });
            }

            bool allFound = true;
            foreach (var id in distinctIds)
            {
                if (!MapManager.TryGetMapEntry(id, out var entry) || entry.MapId != id)
                {
                    allFound = false;
                    break;
                }
            }

            return allFound.ToProperty()
                .Label($"All {distinctIds.Count} distinct mapIds should be findable with correct MapId");
        }

    }
}
