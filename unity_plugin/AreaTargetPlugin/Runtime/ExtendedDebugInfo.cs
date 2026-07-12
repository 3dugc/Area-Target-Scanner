namespace AreaTargetPlugin
{
    /// <summary>
    /// 扩展调试信息，包含 C# 端状态和 native 端 debug 信息。
    /// </summary>
    public struct ExtendedDebugInfo
    {
        /// <summary>当前定位模式（Raw / Aligned）。</summary>
        public LocalizationMode CurrentMode;

        /// <summary>Alignment Transform 是否已设置。</summary>
        public bool IsATSet;

        /// <summary>Raw 模式位姿缓冲区中的帧数。</summary>
        public int PoseBufferFrameCount;

        /// <summary>连续丢帧计数。</summary>
        public int ConsecutiveLostFrames;

        /// <summary>Aligned 模式滑动窗口中的帧数。</summary>
        public int SlidingWindowFrameCount;

        /// <summary>Native 端调试信息。</summary>
        public VLDebugInfo NativeDebugInfo;
    }
}
