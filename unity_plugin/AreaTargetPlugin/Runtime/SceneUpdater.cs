using System.Threading.Tasks;

namespace AreaTargetPlugin.PointCloudLocalization
{
    public class SceneUpdater : ISceneUpdater
    {
        public async Task UpdateScene(MapEntry entry, ICameraData cameraData, ILocalizationResult result)
        {
            var data = new SceneUpdateData
            {
                Pose = result.Pose,
                Ignore = !result.Success,
                SetVisibility = true,
                Visible = result.Success
            };
            await entry.SceneParent.SceneUpdate(data);
        }
    }
}
