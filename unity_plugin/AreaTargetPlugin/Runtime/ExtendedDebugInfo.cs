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

        /// <summary>最近一条诊断对应的帧 ID；生命周期事件为 -1。</summary>
        public long LastDiagnosticFrameId;

        /// <summary>最近一条诊断记录的帧采集时间戳（纳秒）。</summary>
        public long LastCaptureTimestampNs;

        /// <summary>最近一条诊断记录的 tracking state。</summary>
        public TrackingState LastDiagnosticState;

        /// <summary>最近一条诊断记录的定位质量。</summary>
        public LocalizationQuality LastDiagnosticQuality;

        /// <summary>最近一条诊断记录的结果年龄（纳秒）。</summary>
        public long LastResultAgeNs;

        /// <summary>最近一条诊断记录的 worker 处理耗时（纳秒）。</summary>
        public long LastWorkerProcessingTimeNs;

        /// <summary>最近一条诊断记录的稳定失败类别。</summary>
        public LocalizationFailureCategory LastFailureCategory;

        /// <summary>最近一条诊断记录的安全、可读摘要。</summary>
        public string LastFailureReason;

        /// <summary>有界诊断 buffer 已丢弃的最旧记录数。</summary>
        public long DiagnosticDroppedRecordCount;

        /// <summary>Native 端调试信息。</summary>
        public VLDebugInfo NativeDebugInfo;
    }
}
