namespace AreaTargetPlugin
{
    /// <summary>
    /// Represents the current tracking state of the area target tracker.
    /// </summary>
    public enum TrackingState
    {
        /// <summary>Asset bundle loaded, tracker is initializing.</summary>
        INITIALIZING,

        /// <summary>Actively tracking with a valid pose.</summary>
        TRACKING,

        /// <summary>Tracking lost, attempting to relocalize.</summary>
        LOST
    }

    /// <summary>
    /// 定位质量等级，区分 Raw 模式识别和 Aligned 模式高精度定位。
    /// </summary>
    public enum LocalizationQuality
    {
        /// <summary>未定位。</summary>
        NONE,

        /// <summary>Raw 模式识别成功，尚未 AT 对齐。</summary>
        RECOGNIZED,

        /// <summary>Aligned 模式定位成功，已 AT 对齐，高精度。</summary>
        LOCALIZED
    }

    /// <summary>
    /// 定位模式：冷启动 Raw 或稳态 Aligned。
    /// </summary>
    public enum LocalizationMode
    {
        /// <summary>冷启动：ORB + AKAZE fallback。</summary>
        Raw,

        /// <summary>稳态：已应用 Alignment Transform。</summary>
        Aligned
    }
}
