import Foundation

/// Real-time scan progress information.
/// Tracks the number of captured points and estimated coverage area.
struct ScanProgress: Equatable {
    /// Total number of captured point cloud points
    let pointCount: Int
    /// Estimated coverage area in square meters
    let coverageArea: Float
    /// Number of captured keyframes (image + pose pairs)
    let keyframeCount: Int
    /// Whether the scan is currently active
    let isScanning: Bool
    let rejectedKeyframeCount: Int
    let qualityFeedback: String?

    init(pointCount: Int, coverageArea: Float, keyframeCount: Int, isScanning: Bool,
         rejectedKeyframeCount: Int = 0, qualityFeedback: String? = nil) {
        self.pointCount = pointCount; self.coverageArea = coverageArea
        self.keyframeCount = keyframeCount; self.isScanning = isScanning
        self.rejectedKeyframeCount = rejectedKeyframeCount; self.qualityFeedback = qualityFeedback
    }
}
