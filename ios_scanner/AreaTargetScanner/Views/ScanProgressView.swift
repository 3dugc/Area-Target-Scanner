import SwiftUI

/// Displays real-time scan progress: point count, coverage area, and keyframe count.
///
/// - Requirements: 2.1
struct ScanProgressView: View {
    /// Current scan progress snapshot, updated in real time.
    let progress: ScanProgress

    var body: some View {
        VStack(spacing: 8) {
          HStack(spacing: 12) {
            StatItem(
                icon: "circle.grid.3x3.fill",
                value: formattedPointCount,
                label: "点数"
            )
            StatItem(
                icon: "square.dashed",
                value: formattedCoverageArea,
                label: "路径范围"
            )
            StatItem(
                icon: "camera.fill",
                value: "\(progress.keyframeCount)",
                label: "采集帧数"
            )
          }
          if let feedback = progress.qualityFeedback {
            Text(feedback)
                .font(.caption)
                .foregroundStyle(.secondary)
          }
          if progress.rejectedKeyframeCount > 0 {
            Text("已跳过 \(progress.rejectedKeyframeCount) 次低质量画面")
                .font(.caption2)
                .foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Formatting

    /// Formats point count with K/M suffixes for readability.
    private var formattedPointCount: String {
        let count = progress.pointCount
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    /// Formats coverage area in square meters.
    private var formattedCoverageArea: String {
        String(format: "%.1f ㎡", progress.coverageArea)
    }
}

/// A single stat item with icon, value, and label.
private struct StatItem: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .monospaced, weight: .semibold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 72)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}
