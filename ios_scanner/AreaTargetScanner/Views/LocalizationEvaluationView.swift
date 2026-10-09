import SwiftUI

struct LocalizationEvaluationView: View {
    let report: LocalizationEvaluationReport
    var isLive = false
    @Environment(\.sizeCategory) private var sizeCategory
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isLive ? "本段实时结果" : "本次测试结果").font(.headline)
            if !isLive {
                Text(report.date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour().minute())).font(.caption).foregroundStyle(.secondary)
            }
            if sizeCategory.isAccessibilityCategory {
                VStack(alignment: .leading, spacing: 8) { providerTitle; scoreTitle }
            } else {
                HStack(alignment: .firstTextBaseline) { providerTitle; Spacer(); scoreTitle }
            }
            Text(report.summary).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if let mode = report.identity.areaTargetRecognitionMode {
                Text(mode == .enhanced ? "识别模式：增强识别" : "识别模式：普通识别")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                row("定位成功率", String(format: "%.0f%% · %d / %d 帧", report.successRate * 100, report.successCount, report.attemptCount))
                row(report.timingMode == .live ? "首次识别响应" : "首次识别 · 累计计算", seconds(report.firstRecognitionSeconds))
                if report.timingMode == .recordedReplay { row("首成功帧 · 采集时间", seconds(report.firstRecognitionCaptureOffset)) }
                row("耗时 · 中位 / P95", "\(seconds(report.medianLatencySeconds)) / \(seconds(report.p95LatencySeconds))")
                row("对齐位置变化 · P95", report.p95TranslationDeltaMeters.map { String(format: "%.2f m", $0) } ?? "—")
                row("对齐角度变化 · P95", report.p95RotationDeltaDegrees.map { String(format: "%.1f°", $0) } ?? "—")
                row("采集时长 / 走动", String(format: "%.0f s / %.1f m", report.captureDuration, report.trackedTravelMeters))
            }.font(.subheadline)
            ForEach(report.recommendations, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.secondary) }
            DisclosureGroup("评分依据与限制") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("表现分 v\(report.scoreVersion)：成功率 40%，耗时 20%，位置稳定性 20%，角度稳定性 20%。至少 20 帧、30 秒和 3 米。")
                    Text(report.limitations)
                    Text("引擎配置：\(report.identity.engineVersion ?? "未记录")")
                    Text("结果仅描述这一次测试的表现，不是绝对定位精度。")
                }.font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
        }.padding(20).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            .accessibilityIdentifier("localization-evaluation")
    }
    private var providerTitle: some View {
        Text(report.identity.provider == .areaTarget ? "Area Target" : "Immersal").font(.title3.bold())
    }
    private var scoreTitle: some View {
        Text(report.score.map { "\($0) / 100" } ?? "暂不评分").font(.title2.bold()).monospacedDigit()
    }
    private func seconds(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0) } ?? "—" }
    @ViewBuilder private func row(_ title: String, _ value: String) -> some View {
        if sizeCategory.isAccessibilityCategory {
            VStack(alignment: .leading, spacing: 4) { Text(title).foregroundStyle(.secondary); Text(value) }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline) { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing) }
        }
    }
}
