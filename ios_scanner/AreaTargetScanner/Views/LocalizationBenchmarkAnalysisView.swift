import SwiftUI

struct LocalizationBenchmarkAnalysisView: View {
    let comparison: LocalizationComparisonReport
    private let analysis: LocalizationBenchmarkAnalysis
    @Environment(\.sizeCategory) private var sizeCategory

    init(comparison: LocalizationComparisonReport) {
        self.comparison = comparison
        // Recompute from the saved measurements so a stale analysis cannot hide
        // missing evidence in an older or externally edited report.
        analysis = LocalizationBenchmarkAnalysis(comparison: comparison)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("同帧结果分析").font(.title3.bold())
            Text(analysis.scoresComparable ? "本次表现分可比较" : "本次证据不足，查看已测量指标")
                .font(.subheadline).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) { score(.areaTarget); score(.immersal) }
                VStack(alignment: .leading, spacing: 12) { score(.areaTarget); score(.immersal) }
            }
            Text("差值统一为 Area Target − Immersal。位姿返回率和分数越高越好，耗时与相邻对齐变化越低越好。方向仅描述本次测量。")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(analysis.metrics.filter { $0.key != .score && ($0.areaTargetValue != nil || $0.immersalValue != nil) }) { metric in
                    metricRow(metric)
                }
            }
            DisclosureGroup("表现分拆解与资格") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("v1 权重：位姿返回率 40、耗时 20、平移稳定性 20、旋转稳定性 20。参考值固定为 3 秒、0.25 米和 5°。分项相加后四舍五入；全失败总分与分项均为 0。")
                        .foregroundStyle(.secondary)
                    ForEach(analysis.scoreContributions) { contribution in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(contribution.label) · 满分 \(number(contribution.maximumPoints))").font(.subheadline.bold())
                            pair("Area Target", number(contribution.areaTargetPoints))
                            pair("Immersal", number(contribution.immersalPoints))
                        }
                    }
                    ForEach(comparison.results, id: \.identity.provider) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(name(result.identity.provider))：\(result.summary)").font(.subheadline.bold())
                            Text("资格门槛：至少 \(result.thresholds.minimumAttemptCount) 次调用、\(number(result.thresholds.minimumDurationSeconds)) 秒、\(number(result.thresholds.minimumTestedTravelMeters)) 米；须确认来源与共同坐标，稳定性至少需要 2 个成功姿态。")
                                .foregroundStyle(.secondary)
                        }
                    }
                }.font(.footnote).padding(.top, 12)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("连续失败与恢复").font(.headline)
                Text("共同成功帧：\(analysis.commonSuccessfulFrameCount.map(String.init) ?? "未测量")")
                    .font(.subheadline.monospacedDigit())
                ForEach(analysis.traces) { trace in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(name(trace.provider)).font(.subheadline.bold())
                        if trace.status == .measured {
                            Text("最长连续失败 \(trace.longestFailureStreak ?? 0) 帧 · 区段 \(trace.failureStreakCount ?? 0) 个")
                            Text("已恢复 \(trace.recoveredFailureStreakCount ?? 0) 个 · 未恢复 \(trace.unrecoveredFailureStreakCount ?? 0) 个")
                            Text("最长完整恢复：录制时间 \(number(trace.maximumRecoveryCaptureSeconds)) 秒；累计算法 \(number(trace.maximumRecoveryAlgorithmSeconds)) 秒")
                        } else {
                            Text(trace.status == .notMeasured ? "逐帧记录未测量" : "逐帧记录不完整，无法计算")
                        }
                    }.font(.footnote).fixedSize(horizontal: false, vertical: true)
                }
                Text("共同成功帧未验证绝对位置正确。恢复从首个失败帧到下一个返回姿态，录制时间与算法时间分别统计；末尾未恢复区段没有恢复时间。")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("每帧算法调用") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("返回姿态只表示引擎有位姿输出，没有独立真值验证正确。采集偏移来自录制；算法耗时来自本次回放。")
                        .foregroundStyle(.secondary)
                    if let attempts = comparison.attempts {
                        ForEach(Array(attempts.sorted(by: {
                            $0.sequence == $1.sequence ? $0.provider.rawValue < $1.provider.rawValue : $0.sequence < $1.sequence
                        }).enumerated()), id: \.offset) { entry in
                            let attempt = entry.element
                            VStack(alignment: .leading, spacing: 4) {
                                Text("帧 \(attempt.sequence) · \(name(attempt.provider))").font(.subheadline.bold())
                                Text("采集偏移 \(number(attempt.captureOffsetSeconds)) 秒；算法耗时 \(number(attempt.latencySeconds)) 秒")
                                Text("返回姿态：\(attempt.poseReturned ? "是" : "否")")
                            }.accessibilityElement(children: .combine)
                        }
                    } else { Text("逐帧记录：未测量（not_measured）") }
                }.font(.footnote).padding(.top, 12).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("Area Target 下一步实验").font(.headline)
                ForEach(analysis.recommendations) { recommendation in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(recommendation.title).font(.subheadline.bold())
                        evidence("证据", recommendation.evidence)
                        evidence("待验证假设", recommendation.hypothesis)
                        evidence("下一次实验", recommendation.nextExperiment)
                        evidence("验收标准", recommendation.acceptanceCriterion)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            DisclosureGroup("输入身份、未测量项与限制") {
                VStack(alignment: .leading, spacing: 12) {
                    metadata
                    ForEach(analysis.metrics.filter { $0.areaTargetValue == nil && $0.immersalValue == nil && $0.key != .score }) { metric in
                        Text("\(metric.label)：未测量（not_measured）")
                    }
                    ForEach(analysis.limitations, id: \.self) { Text($0) }
                }.font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("本次为筛查证据，尚不能交付优化结论。候选实验先在 Data 验证，再通过工程回归。")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityIdentifier("localization-benchmark-analysis")
    }

    private func score(_ provider: LocalizationProvider) -> some View {
        let result = comparison.results.first { $0.identity.provider == provider }
        return VStack(alignment: .leading, spacing: 4) {
            Text(name(provider)).font(.subheadline.bold())
            Text(result?.score.map { "\($0) / 100" } ?? "暂不评分")
                .font(.title2.bold()).monospacedDigit()
            if let result { Text(result.summary).font(.caption).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
    }

    private func metricRow(_ metric: LocalizationBenchmarkMetricComparison) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(metric.label).font(.subheadline.bold())
            pair("Area Target", metric.display(metric.areaTargetValue))
            pair("Immersal", metric.display(metric.immersalValue))
            Text(metric.deltaDescription).font(.caption).foregroundStyle(.secondary)
            if let ratio = metric.areaTargetToImmersalRatio {
                Text("AT / Immersal：\(number(ratio)) 倍").font(.caption).foregroundStyle(.secondary)
            }
            if metric.preference != .descriptive { Text(metric.direction.title).font(.caption).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
    }

    @ViewBuilder private func pair(_ label: String, _ value: String) -> some View {
        if sizeCategory.isAccessibilityCategory {
            VStack(alignment: .leading, spacing: 2) { Text(label).foregroundStyle(.secondary); Text(value).monospacedDigit() }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value).monospacedDigit().multilineTextAlignment(.trailing)
            }
        }
    }

    private func evidence(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.bold()).foregroundStyle(.secondary)
            Text(value).font(.footnote)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("执行顺序：\(comparison.executionOrder.map(name).joined(separator: " → "))")
            Text("校准排除：\(comparison.calibrationExcluded.map { $0 ? "是" : "否" } ?? "未记录")；回放前重新载入：\(comparison.enginesReloadedBeforeReplay.map { $0 ? "是" : "否" } ?? "未记录")")
            if let policy = comparison.samplingPolicy {
                Text("采样：间隔至少 \(number(policy.minimumIntervalSeconds)) 秒；最多 \(policy.maximumFrameCount) 帧 / \(number(Double(policy.maximumPixelBytes) / 1024 / 1024)) MiB；长边最多 \(policy.maximumLongEdgePixels) 像素。")
                Text("输入格式：\(policy.imageFormat)；缩放：\(policy.resize)；跟踪：\(policy.tracking)")
            } else { Text("采样策略：未记录") }
            Text("原扫描指纹：\(comparison.sourceFingerprint)").textSelection(.enabled)
            Text("冻结输入摘要：\(comparison.queryFingerprint)").textSelection(.enabled)
            if let recording = comparison.recording {
                Text("录制会话：\(recording.id.uuidString)").textSelection(.enabled)
                Text("录制：\(recording.frameCount) 帧 / \(number(recording.duration)) 秒；预览丢帧 \(recording.context.previewDroppedFrames)")
                if let reason = recording.context.captureEndReason { Text("录制结束原因：\(reason)") }
                Text("录制设备：\(recording.context.deviceModel) / \(recording.context.systemVersion)；App \(recording.context.appVersion) (\(recording.context.appBuild))")
            } else { Text("录制身份与设备上下文：未测量") }
            if let context = comparison.runtimeContext {
                Text("回放设备：\(context.deviceModel) / \(context.systemVersion)；App \(context.appVersion) (\(context.appBuild))")
                Text("回放开始时温度状态：\(context.thermalState)")
            } else { Text("回放设备与温度状态：未测量") }
            ForEach(comparison.results, id: \.identity.provider) { result in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(name(result.identity.provider)) 地图：\(result.identity.assetID)")
                    Text("引擎：\(result.identity.engineVersion ?? "未记录")")
                    Text("地图摘要：\(result.identity.assetDigest ?? "未记录")").textSelection(.enabled)
                    Text("构建配置：\(result.identity.buildConfiguration ?? "未记录")")
                }
            }
        }
    }

    private func name(_ provider: LocalizationProvider) -> String { provider == .areaTarget ? "Area Target" : "Immersal" }
    private func number(_ value: Double?) -> String {
        value.map { String(format: "%.4g", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "未测量"
    }
}
