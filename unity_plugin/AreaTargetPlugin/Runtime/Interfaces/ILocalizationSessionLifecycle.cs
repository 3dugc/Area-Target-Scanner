using System.Threading.Tasks;
namespace AreaTargetPlugin.PointCloudLocalization
{
    /// <summary>Platform lifecycle adapter; C++ alone determines alignment validity.</summary>
    public interface ILocalizationSessionLifecycle
    {
        int MapId { get; }
        void SetPlatformTrackingQuality(uint trackingQuality);
        Task ResetTrackingAsync();
    }
}
