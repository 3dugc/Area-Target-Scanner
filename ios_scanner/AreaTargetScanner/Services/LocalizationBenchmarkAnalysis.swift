import Foundation

enum LocalizationBenchmarkMeasurementStatus: String, Codable { case measured, notMeasured = "not_measured" }
enum LocalizationBenchmarkTraceStatus: String, Codable {
    case measured, notMeasured = "not_measured", invalid = "invalid_trace", unpaired = "unpaired_trace"
}
enum LocalizationBenchmarkMetricDirection: String, Codable {
    case areaTargetBetter, immersalBetter, equal, notComparable
    var title: String {
        switch self {
        case .areaTargetBetter: return "本次 Area Target 较好"
        case .immersalBetter: return "本次 Immersal 较好"
        case .equal: return "本次数值相同"
        case .notComparable: return "不判定优劣"
        }
    }
}
enum LocalizationBenchmarkMetricPreference: String, Codable { case higher, lower, descriptive }
enum LocalizationBenchmarkMetricKey: String, Codable {
    case attemptCount, successCount, successRate, firstRecognitionSeconds, firstSuccessCaptureOffset, firstSuccessLatencySeconds
    case medianLatencySeconds, p95LatencySeconds, medianTranslationDeltaMeters, p95TranslationDeltaMeters
    case medianRotationDeltaDegrees, p95RotationDeltaDegrees, captureDuration, trackedTravelMeters, score
    case absoluteAccuracy, falseRecognitionRate, sdkConfidence, cpuUsage, memoryUsage, powerUsage
}

struct LocalizationBenchmarkMetricComparison: Codable, Equatable, Identifiable {
    let key: LocalizationBenchmarkMetricKey
    let label: String
    let unit: String
    let deltaUnit: String
    let preference: LocalizationBenchmarkMetricPreference
    let areaTargetValue: Double?
    let immersalValue: Double?
    /// Area Target minus Immersal; success-rate deltas use percentage points.
    let delta: Double?
    /// Area Target divided by Immersal. A zero denominator stays unmeasured.
    let areaTargetToImmersalRatio: Double?
    let direction: LocalizationBenchmarkMetricDirection
    let status: LocalizationBenchmarkMeasurementStatus
    var id: String { key.rawValue }

    func display(_ value: Double?) -> String {
        guard let value else { return "未测量" }
        return String(format: "%.4g", locale: Locale(identifier: "en_US_POSIX"), value) + (unit.isEmpty ? "" : " \(unit)")
    }
    var deltaDescription: String {
        guard let delta else { return "差值未测量" }
        let value = String(format: "%+.4g", locale: Locale(identifier: "en_US_POSIX"), delta)
        return "AT − Immersal：\(value) \(deltaUnit)"
    }
}

struct LocalizationBenchmarkScoreContribution: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let maximumPoints: Double
    let reference: Double?
    let referenceUnit: String?
    let areaTargetPoints: Double?
    let immersalPoints: Double?
}

struct LocalizationBenchmarkFailureStreak: Codable, Equatable {
    let startSequence: Int
    let endSequence: Int
    let failedFrameCount: Int
    let startCaptureOffsetSeconds: Double
    let endCaptureOffsetSeconds: Double
    let recoverySequence: Int?
    let captureSecondsToRecovery: Double?
    /// Sum of failed calls and the following successful call; excludes frame gaps.
    let algorithmSecondsToRecovery: Double?
}

struct LocalizationBenchmarkTraceAnalysis: Codable, Equatable, Identifiable {
    let provider: LocalizationProvider
    let status: LocalizationBenchmarkTraceStatus
    let longestFailureStreak: Int?
    let failureStreakCount: Int?
    let recoveredFailureStreakCount: Int?
    let unrecoveredFailureStreakCount: Int?
    let maximumRecoveryCaptureSeconds: Double?
    let maximumRecoveryAlgorithmSeconds: Double?
    let failureStreaks: [LocalizationBenchmarkFailureStreak]?
    var id: LocalizationProvider { provider }

    fileprivate init(provider: LocalizationProvider, attempts: [LocalizationReplayAttempt]?, result: LocalizationEvaluationReport?) {
        self.provider = provider
        guard let attempts else {
            status = .notMeasured; longestFailureStreak = nil; failureStreakCount = nil
            recoveredFailureStreakCount = nil; unrecoveredFailureStreakCount = nil
            maximumRecoveryCaptureSeconds = nil; maximumRecoveryAlgorithmSeconds = nil; failureStreaks = nil
            return
        }
        let ordered = attempts.sorted { $0.sequence < $1.sequence }
        let increasing = zip(ordered, ordered.dropFirst()).allSatisfy {
            $0.0.sequence < $0.1.sequence && $0.0.captureOffsetSeconds < $0.1.captureOffsetSeconds
        }
        guard let result, ordered.count == result.attemptCount,
              ordered.filter(\.poseReturned).count == result.successCount, increasing,
              ordered.allSatisfy({ $0.sequence >= 0 && $0.captureOffsetSeconds.isFinite && $0.captureOffsetSeconds >= 0 &&
                  $0.latencySeconds.isFinite && $0.latencySeconds >= 0 }) else {
            status = .invalid; longestFailureStreak = nil; failureStreakCount = nil
            recoveredFailureStreakCount = nil; unrecoveredFailureStreakCount = nil
            maximumRecoveryCaptureSeconds = nil; maximumRecoveryAlgorithmSeconds = nil; failureStreaks = nil
            return
        }
        var streaks: [LocalizationBenchmarkFailureStreak] = []
        var failures: [LocalizationReplayAttempt] = []
        func appendStreak(recovery: LocalizationReplayAttempt?) {
            guard let first = failures.first, let last = failures.last else { return }
            let algorithmTime = recovery.map { next in failures.reduce(next.latencySeconds) { $0 + $1.latencySeconds } }
            streaks.append(.init(startSequence: first.sequence, endSequence: last.sequence, failedFrameCount: failures.count,
                startCaptureOffsetSeconds: first.captureOffsetSeconds, endCaptureOffsetSeconds: last.captureOffsetSeconds,
                recoverySequence: recovery?.sequence, captureSecondsToRecovery: recovery.map { $0.captureOffsetSeconds - first.captureOffsetSeconds },
                algorithmSecondsToRecovery: algorithmTime.flatMap { $0.isFinite ? $0 : nil }))
            failures.removeAll(keepingCapacity: true)
        }
        for attempt in ordered {
            if attempt.poseReturned { appendStreak(recovery: attempt) } else { failures.append(attempt) }
        }
        appendStreak(recovery: nil)
        status = .measured
        failureStreaks = streaks
        longestFailureStreak = streaks.map(\.failedFrameCount).max() ?? 0
        failureStreakCount = streaks.count
        recoveredFailureStreakCount = streaks.filter { $0.recoverySequence != nil }.count
        unrecoveredFailureStreakCount = streaks.filter { $0.recoverySequence == nil }.count
        maximumRecoveryCaptureSeconds = streaks.compactMap(\.captureSecondsToRecovery).max()
        maximumRecoveryAlgorithmSeconds = streaks.compactMap(\.algorithmSecondsToRecovery).max()
    }
}

struct LocalizationBenchmarkRecommendation: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let evidence: String
    let hypothesis: String
    let nextExperiment: String
    let acceptanceCriterion: String
}

/// A screening analysis of one frozen replay. It never promotes an experiment or
/// converts repeated-pose stability, SDK confidence, or a comparator into truth.
struct LocalizationBenchmarkAnalysis: Codable, Equatable {
    var schemaVersion = 1
    let metrics: [LocalizationBenchmarkMetricComparison]
    let scoreContributions: [LocalizationBenchmarkScoreContribution]
    let scoresComparable: Bool
    let traces: [LocalizationBenchmarkTraceAnalysis]
    let pairedTraceStatus: LocalizationBenchmarkTraceStatus
    let commonSuccessfulFrameCount: Int?
    let recommendations: [LocalizationBenchmarkRecommendation]
    let limitations: [String]
    let promotionEligible: Bool

    init(comparison: LocalizationComparisonReport) {
        let area = comparison.results.first { $0.identity.provider == .areaTarget }
        let immersal = comparison.results.first { $0.identity.provider == .immersal }
        let validPair = comparison.results.count == 2 && area != nil && immersal != nil &&
            ScanSourceFingerprint.valid(comparison.sourceFingerprint) && comparison.results.allSatisfy {
                $0.timingMode == .recordedReplay && $0.identity.sourceFingerprint == comparison.sourceFingerprint
            }
        scoreContributions = Self.makeContributions(area: area, immersal: immersal)
        traces = [LocalizationProvider.areaTarget, .immersal].map { provider in
            LocalizationBenchmarkTraceAnalysis(provider: provider, attempts: comparison.attempts.map { $0.filter { $0.provider == provider } },
                result: provider == .areaTarget ? area : immersal)
        }
        if comparison.attempts == nil {
            pairedTraceStatus = .notMeasured; commonSuccessfulFrameCount = nil
        } else if traces.contains(where: { $0.status != .measured }) {
            pairedTraceStatus = .invalid; commonSuccessfulFrameCount = nil
        } else {
            let areaAttempts = comparison.attempts!.filter { $0.provider == .areaTarget }.sorted { $0.sequence < $1.sequence }
            let immersalAttempts = comparison.attempts!.filter { $0.provider == .immersal }.sorted { $0.sequence < $1.sequence }
            if areaAttempts.count == immersalAttempts.count && zip(areaAttempts, immersalAttempts).allSatisfy({
                $0.0.sequence == $0.1.sequence && $0.0.captureOffsetSeconds == $0.1.captureOffsetSeconds
            }) {
                pairedTraceStatus = .measured
                commonSuccessfulFrameCount = zip(areaAttempts, immersalAttempts).filter { $0.0.poseReturned && $0.1.poseReturned }.count
            } else { pairedTraceStatus = .unpaired; commonSuccessfulFrameCount = nil }
        }
        let inputsComparable = validPair && pairedTraceStatus != .invalid && pairedTraceStatus != .unpaired
        scoresComparable = comparison.hasComparableScores && inputsComparable && comparison.results.allSatisfy { $0.scoreVersion == 1 }
        metrics = Self.makeMetrics(area: area, immersal: immersal, scoresComparable: scoresComparable, inputsComparable: inputsComparable)
        promotionEligible = false
        limitations = [
            "本报告描述一次冻结输入的抽样回放。两个地图必须来自同一原扫描；重建地图、视频副本、缩图及重复回放不构成新增独立采集。",
            "没有独立真值。对齐平移差与旋转差仅描述同一原扫描坐标下相邻成功定位的重复稳定性，不能代表绝对定位精度；共同成功帧也未验证位置正确。",
            "回放首次识别使用截至首个返回姿态的累计算法耗时；首成功帧采集偏移是录制时间。恢复也分别报告这两种时间，均不能推断现场实时响应。",
            "算法调用耗时不含地图加载、校准、重新载入、录制及报告保存；地图建图预处理和各自的引擎配置可能不同。SDK 置信值、CPU 占用、内存占用、功耗、误定位率、绝对精度均为 not_measured。",
            "单次顺序回放可能受执行顺序、缓存、设备温度和系统状态影响，不能作因果或统计显著性结论。应在相同设备条件下重复并交换顺序复测。",
            "表现分 v1 固定使用 40/20/20/20 权重及 3 s、0.25 m、5°参考值。评分资格至少 20 次调用、30 秒、3 米、已验证来源和共同坐标；稳定性须至少 2 个成功姿态。经验门槛与总分独立。",
            "仅有失败到后续成功的完整区段才能测量恢复时间；末尾未恢复区段保留数量，恢复时间为 not_measured。缺失或不匹配的逐帧记录不生成共同成功帧数。",
            "走动距离来自 AR 相机轨迹而非地图覆盖率；AR 参考与共同坐标校准仍有误差。该报告不满足 Data 实验向产品工程交付的完整验证条件，promotionEligible 始终为 false。"
        ]
        recommendations = Self.makeRecommendations(area: area, immersal: immersal, traces: traces,
            scoresComparable: scoresComparable, pairedTraceStatus: pairedTraceStatus)
    }

    private static func makeMetrics(area: LocalizationEvaluationReport?, immersal: LocalizationEvaluationReport?, scoresComparable: Bool,
                                    inputsComparable: Bool) -> [LocalizationBenchmarkMetricComparison] {
        var values: [LocalizationBenchmarkMetricComparison] = []
        func add(_ key: LocalizationBenchmarkMetricKey, _ label: String, _ unit: String,
                 _ preference: LocalizationBenchmarkMetricPreference, deltaUnit: String? = nil,
                 _ read: (LocalizationEvaluationReport) -> Double?) {
            let a = area.flatMap(read).flatMap { $0.isFinite ? $0 : nil }
            let b = immersal.flatMap(read).flatMap { $0.isFinite ? $0 : nil }
            let difference = a.flatMap { a in b.map { a - $0 } }.flatMap { $0.isFinite ? $0 : nil }
            let ratio = a.flatMap { a in b.flatMap { $0 == 0 ? nil : a / $0 } }.flatMap { $0.isFinite ? $0 : nil }
            let direction: LocalizationBenchmarkMetricDirection
            if !inputsComparable || preference == .descriptive || (key == .score && !scoresComparable) || difference == nil { direction = .notComparable }
            else if difference == 0 { direction = .equal }
            else {
                let areaBetter = preference == .higher ? difference! > 0 : difference! < 0
                direction = areaBetter ? .areaTargetBetter : .immersalBetter
            }
            values.append(.init(key: key, label: label, unit: unit, deltaUnit: deltaUnit ?? unit, preference: preference,
                areaTargetValue: a, immersalValue: b, delta: difference, areaTargetToImmersalRatio: ratio,
                direction: direction, status: a != nil && b != nil ? .measured : .notMeasured))
        }
        add(.score, "表现分 v1", "分", .higher) { $0.score.map(Double.init) }
        add(.attemptCount, "有效算法调用", "次", .descriptive) { Double($0.attemptCount) }
        add(.successCount, "返回姿态", "帧", .descriptive) { Double($0.successCount) }
        add(.successRate, "位姿返回率", "%", .higher, deltaUnit: "百分点") { $0.successRate * 100 }
        add(.firstRecognitionSeconds, "首成功 · 累计算法耗时", "s", .lower) { $0.timingMode == .recordedReplay ? $0.firstRecognitionSeconds : nil }
        add(.firstSuccessCaptureOffset, "首成功帧 · 采集偏移", "s", .lower) { $0.firstRecognitionCaptureOffset }
        add(.firstSuccessLatencySeconds, "首成功调用 · 算法耗时", "s", .lower) { $0.firstRecognitionLatencySeconds }
        add(.medianLatencySeconds, "算法耗时 · 中位数", "s", .lower) { $0.medianLatencySeconds }
        add(.p95LatencySeconds, "算法耗时 · P95", "s", .lower) { $0.p95LatencySeconds }
        add(.medianTranslationDeltaMeters, "对齐平移变化 · 中位数", "m", .lower) { $0.medianTranslationDeltaMeters }
        add(.p95TranslationDeltaMeters, "对齐平移变化 · P95", "m", .lower) { $0.p95TranslationDeltaMeters }
        add(.medianRotationDeltaDegrees, "对齐旋转变化 · 中位数", "°", .lower) { $0.medianRotationDeltaDegrees }
        add(.p95RotationDeltaDegrees, "对齐旋转变化 · P95", "°", .lower) { $0.p95RotationDeltaDegrees }
        add(.captureDuration, "共同帧采集时长", "s", .descriptive) { $0.captureDuration }
        add(.trackedTravelMeters, "AR 相机走动距离", "m", .descriptive) { $0.trackedTravelMeters }
        add(.absoluteAccuracy, "绝对定位精度", "", .descriptive) { _ in nil }
        add(.falseRecognitionRate, "误定位率 · 需独立真值", "%", .descriptive) { _ in nil }
        add(.sdkConfidence, "SDK 置信值", "", .descriptive) { _ in nil }
        add(.cpuUsage, "CPU 占用", "%", .descriptive) { _ in nil }
        add(.memoryUsage, "内存占用", "MB", .descriptive) { _ in nil }
        add(.powerUsage, "功耗", "W", .descriptive) { _ in nil }
        return values
    }

    private static func makeContributions(area: LocalizationEvaluationReport?, immersal: LocalizationEvaluationReport?) -> [LocalizationBenchmarkScoreContribution] {
        func components(_ report: LocalizationEvaluationReport?) -> [Double?] {
            guard let report, report.scoreVersion == 1, report.score != nil else { return [nil, nil, nil, nil] }
            if report.eligibility == .noRecognition && report.score == 0 { return [0, 0, 0, 0] }
            guard report.eligibility == .eligible, let latency = report.p95LatencySeconds,
                  let translation = report.p95TranslationDeltaMeters, let rotation = report.p95RotationDeltaDegrees,
                  [report.successRate, latency, translation, rotation].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return [nil, nil, nil, nil] }
            func points(_ value: Double, _ reference: Double) -> Double { 20 * (value == 0 ? 1 : min(1, reference / value)) }
            return [40 * report.successRate, points(latency, 3), points(translation, 0.25), points(rotation, 5)]
        }
        let a = components(area), b = components(immersal)
        return [
            .init(id: "success", label: "位姿返回率", maximumPoints: 40, reference: nil, referenceUnit: nil, areaTargetPoints: a[0], immersalPoints: b[0]),
            .init(id: "latency", label: "P95 算法耗时", maximumPoints: 20, reference: 3, referenceUnit: "s", areaTargetPoints: a[1], immersalPoints: b[1]),
            .init(id: "translation", label: "P95 平移稳定性", maximumPoints: 20, reference: 0.25, referenceUnit: "m", areaTargetPoints: a[2], immersalPoints: b[2]),
            .init(id: "rotation", label: "P95 旋转稳定性", maximumPoints: 20, reference: 5, referenceUnit: "°", areaTargetPoints: a[3], immersalPoints: b[3])
        ]
    }

    private static func makeRecommendations(area: LocalizationEvaluationReport?, immersal: LocalizationEvaluationReport?,
        traces: [LocalizationBenchmarkTraceAnalysis], scoresComparable: Bool, pairedTraceStatus: LocalizationBenchmarkTraceStatus) -> [LocalizationBenchmarkRecommendation] {
        var recommendations: [LocalizationBenchmarkRecommendation] = []
        if !scoresComparable {
            let evidence = [area, immersal].compactMap { $0 }.map { "\(name($0.identity.provider))：\($0.summary)" }.joined(separator: "；")
            let traceEvidence = pairedTraceStatus == .invalid || pairedTraceStatus == .unpaired ? "；逐帧配对为 \(pairedTraceStatus.rawValue)，不能确认同帧比较。" : ""
            recommendations.append(.init(id: "score-gate", title: "先补齐可评分证据", evidence: (evidence.isEmpty ? "缺少引擎结果。" : evidence) + traceEvidence,
                hypothesis: "样本、扫描来源、共同坐标或同帧轨迹证据不足，尚不能用总分归因于算法表现。",
                nextExperiment: "在 Data 保存本次录制与地图身份，核对同源及坐标变换后对相同冻结输入回放；缺采样时新录制连续正常跟踪的会话。",
                acceptanceCriterion: "两引擎各至少 20 次调用、30 秒、3 米；来源和共同坐标已验证；取得至少 2 个可比较的成功姿态，或明确报告全失败 0 分。"))
        }
        if let area {
            if area.successRate < area.thresholds.minimumSuccessRate || area.successRate < (immersal?.successRate ?? area.successRate) || area.successCount == 0 {
                recommendations.append(.init(id: "recognition", title: "检查 Area Target 的未识别帧", evidence: "Area Target 返回 \(area.successCount)/\(area.attemptCount) 帧（\(exact(area.successRate * 100))%）；Immersal \(immersal.map { "\($0.successCount)/\($0.attemptCount) 帧" } ?? "未测量")。",
                    hypothesis: "特征覆盖、观察角度或匹配筛选可能影响返回率；本次结果无法确认根因，也没有验证返回姿态的正确性。",
                    nextExperiment: "在 Data 按失败帧序号核对纹理、模糊、光照与地图覆盖；固定录制摘要和地图基线，逐项测试特征或匹配筛选候选，并保留逐帧结果。",
                    acceptanceCriterion: "相同冻结输入下成功率至少 \(exact(max(area.thresholds.minimumSuccessRate, immersal?.successRate ?? 0) * 100))%，且 P95 对齐变化不恶化；另用带独立真值的采集验证误匹配。"))
            }
            if let latency = area.p95LatencySeconds, latency > area.thresholds.maximumP95LatencySeconds || latency > (immersal?.p95LatencySeconds ?? latency) {
                recommendations.append(.init(id: "latency", title: "定位 Area Target 的耗时阶段", evidence: "Area Target P95 算法耗时 \(exact(latency)) s；Immersal \(exact(immersal?.p95LatencySeconds)) s。CPU 和内存未测量。",
                    hypothesis: "图像处理、特征检索或位姿求解阶段可能限制速度；总调用耗时无法区分具体阶段。",
                    nextExperiment: "在 Data 的实验版本给各阶段计时；同一设备、相同地图与冻结输入重复回放，一次只改一个候选，并记录温度状态及执行顺序。",
                    acceptanceCriterion: "P95 算法耗时不高于 \(exact(min(area.thresholds.maximumP95LatencySeconds, immersal?.p95LatencySeconds ?? area.thresholds.maximumP95LatencySeconds))) s，成功率和对齐稳定性不低于基线；用多次复测确认。"))
            }
            for (id, title, measured, comparator, threshold, unit) in [
                ("translation", "检查 Area Target 的平移跳变", area.p95TranslationDeltaMeters, immersal?.p95TranslationDeltaMeters, area.thresholds.maximumP95TranslationDeltaMeters, "m"),
                ("rotation", "检查 Area Target 的旋转跳变", area.p95RotationDeltaDegrees, immersal?.p95RotationDeltaDegrees, area.thresholds.maximumP95RotationDeltaDegrees, "°")
            ] {
                if let measured, measured > threshold || measured > (comparator ?? measured) {
                    recommendations.append(.init(id: id, title: title, evidence: "Area Target P95 对齐变化 \(exact(measured)) \(unit)；Immersal \(exact(comparator)) \(unit)。这不是绝对精度。",
                        hypothesis: "共同坐标校准、AR 参考、视觉歧义或位姿筛选可能产生相邻对齐跳变；尚未确认具体原因。",
                        nextExperiment: "在 Data 查看跳变前后的成功帧和共同坐标变换，固定地图/录制对位姿筛选候选逐项回放；用静态参考或独立真值区分 AR 与定位误差。",
                        acceptanceCriterion: "P95 对齐变化不高于 \(exact(min(threshold, comparator ?? threshold))) \(unit)，成功率和耗时不恶化；独立真值验证不增加错误姿态。"))
                }
            }
        }
        if let trace = traces.first(where: { $0.provider == .areaTarget }), let longest = trace.longestFailureStreak, longest > 1 {
            recommendations.append(.init(id: "failure-streak", title: "检查 Area Target 的连续丢失与恢复", evidence: "最长连续失败 \(longest) 帧；未恢复区段 \(trace.unrecoveredFailureStreakCount ?? 0) 个；最长已完成恢复：录制时间 \(exact(trace.maximumRecoveryCaptureSeconds)) s / 累计算法 \(exact(trace.maximumRecoveryAlgorithmSeconds)) s。",
                hypothesis: "连续失败可能与视角转换、特征空白或重定位策略有关；未恢复末段不能推断恢复速度。",
                nextExperiment: "在 Data 对连续失败区段逐帧检查，再用相同冻结录制比较重定位候选；同时保留全序列，避免只测试成功区段。",
                acceptanceCriterion: "相同输入下最长连续失败低于 \(longest) 帧、未恢复区段不增加，已完成恢复的两种时间不高于基线；成功率与稳定性不恶化。"))
        }
        if pairedTraceStatus != .measured {
            recommendations.append(.init(id: "trace-evidence", title: "补齐共同帧与恢复证据", evidence: "逐帧配对状态为 \(pairedTraceStatus.rawValue)，共同成功帧数未测量。",
                hypothesis: "旧报告缺少逐帧轨迹，或调用序号/采集偏移与汇总不一致。",
                nextExperiment: "从已校验摘要的录制重新运行并保存两引擎逐帧轨迹；核对序号、采集偏移和成功/调用计数。",
                acceptanceCriterion: "两引擎序号与采集偏移逐一相同，轨迹计数匹配汇总；共同成功帧数与连续失败/恢复均可重算。"))
        }
        recommendations.append(.init(id: "repeat-and-truth", title: "复测顺序并验证真实误差", evidence: "仅有一次顺序回放；没有独立真值，promotionEligible 为 false。",
            hypothesis: "顺序、温度或缓存可能影响本次差异；更高表现分未必对应更小真实定位误差。",
            nextExperiment: "在 Data 保留相同冻结输入、地图身份和设备条件，重复并交换执行顺序；另采集有独立真值、不同位置/朝向/光照的原始会话，再做工程回归。",
            acceptanceCriterion: "报告多次及两种顺序的各项分布；候选在独立采集与真值误差评测通过预先登记的门槛，并完成工程回归后才考虑交付。"))
        return recommendations
    }

    func markdown(comparison: LocalizationComparisonReport) -> String {
        var lines = ["# 同帧定位基准分析", "", "报告：\(comparison.id.uuidString)", "日期：\(comparison.date.ISO8601Format())",
            "原扫描指纹：\(comparison.sourceFingerprint)", "冻结输入摘要：\(comparison.queryFingerprint)",
            "执行顺序：\(comparison.executionOrder.map(Self.name).joined(separator: " → "))",
            "报告版本 / 分析版本：\(comparison.schemaVersion) / \(schemaVersion)",
            "校准排除：\(comparison.calibrationExcluded.map { String($0) } ?? "not_measured")；引擎回放前重新载入：\(comparison.enginesReloadedBeforeReplay.map { String($0) } ?? "not_measured")",
            "可比较表现分：\(scoresComparable)", "promotionEligible: false", ""]
        if let policy = comparison.samplingPolicy {
            lines += ["采样策略：最小间隔 \(Self.exact(policy.minimumIntervalSeconds)) s；最多 \(policy.maximumFrameCount) 帧 / \(policy.maximumPixelBytes) 字节；最大长边 \(policy.maximumLongEdgePixels) 像素。",
                "输入格式：\(Self.cell(policy.imageFormat))；缩放：\(Self.cell(policy.resize))；跟踪：\(Self.cell(policy.tracking))。", ""]
        } else { lines += ["采样策略：not_measured", ""] }
        if let recording = comparison.recording {
            lines += ["录制会话：\(recording.id.uuidString)", "录制日期：\(recording.date.ISO8601Format())", "录制输入摘要：\(recording.inputDigest)",
                "录制原扫描指纹：\(recording.sourceFingerprint)", "帧数 / 时长：\(recording.frameCount) / \(Self.exact(recording.duration)) s",
                "录制设备：\(recording.context.deviceModel) / \(recording.context.systemVersion)",
                "录制 App：\(recording.context.appVersion) (\(recording.context.appBuild))", "预览丢帧：\(recording.context.previewDroppedFrames)",
                "录制结束原因：\(Self.cell(recording.context.captureEndReason ?? "not_measured"))", ""]
        } else { lines += ["录制身份/上下文：not_measured", ""] }
        if let runtime = comparison.runtimeContext {
            lines += ["回放设备：\(runtime.deviceModel) / \(runtime.systemVersion)", "回放 App：\(runtime.appVersion) (\(runtime.appBuild))",
                "回放温度状态：\(runtime.thermalState)（开始时快照）", ""]
        } else { lines += ["回放设备/温度上下文：not_measured", ""] }
        lines += ["## 地图身份与评分资格", ""]
        for result in comparison.results {
            let identity = result.identity
            lines += ["### \(Self.name(identity.provider))", "",
                "地图：\(Self.cell(identity.assetID))", "扫描指纹：\(identity.sourceFingerprint ?? "not_measured")",
                "地图摘要：\(identity.assetDigest ?? "not_measured")", "引擎：\(Self.cell(identity.engineVersion ?? "not_measured"))",
                "构建配置：\(Self.cell(identity.buildConfiguration ?? "not_measured"))",
                "评分版本 / 资格 / 分数：v\(result.scoreVersion) / \(result.eligibility.rawValue) / \(result.score.map(String.init) ?? "not_measured")",
                "采样门槛：\(result.thresholds.minimumAttemptCount) 次 / \(Self.exact(result.thresholds.minimumDurationSeconds)) s / \(Self.exact(result.thresholds.minimumTestedTravelMeters)) m",
                "经验门槛：成功率 ≥ \(Self.exact(result.thresholds.minimumSuccessRate * 100))%；首次 ≤ \(Self.exact(result.thresholds.maximumFirstSuccessSeconds)) s；P95 耗时 ≤ \(Self.exact(result.thresholds.maximumP95LatencySeconds)) s；平移 ≤ \(Self.exact(result.thresholds.maximumP95TranslationDeltaMeters)) m；旋转 ≤ \(Self.exact(result.thresholds.maximumP95RotationDeltaDegrees))°", ""]
        }
        lines += ["## 数值对比", "", "差值为 Area Target − Immersal；比例为 Area Target / Immersal，分母为 0 时不计算。", "",
            "| 指标 | Area Target | Immersal | 差值 | 比例 | 本次方向 | 状态 |", "| --- | --- | --- | --- | --- | --- | --- |"]
        for metric in metrics {
            lines.append("| \(metric.label) | \(Self.exact(metric.areaTargetValue)) \(metric.unit) | \(Self.exact(metric.immersalValue)) \(metric.unit) | \(Self.exact(metric.delta)) \(metric.deltaUnit) | \(Self.exact(metric.areaTargetToImmersalRatio)) | \(metric.direction.title) | \(metric.status.rawValue) |")
        }
        lines += ["", "## 每帧算法调用", "", "返回姿态仅表示引擎输出刚性位姿，没有独立真值确认正确。采集偏移来自冻结录制，算法耗时来自本次调用。", ""]
        if let attempts = comparison.attempts {
            lines += ["| 序号 | 引擎 | 采集偏移 (s) | 算法耗时 (s) | 返回姿态 |", "| --- | --- | --- | --- | --- |"]
            for attempt in attempts.sorted(by: { $0.sequence == $1.sequence ? $0.provider.rawValue < $1.provider.rawValue : $0.sequence < $1.sequence }) {
                lines.append("| \(attempt.sequence) | \(Self.name(attempt.provider)) | \(Self.exact(attempt.captureOffsetSeconds)) | \(Self.exact(attempt.latencySeconds)) | \(attempt.poseReturned) |")
            }
        } else { lines.append("逐帧记录：not_measured") }
        lines += ["", "## 表现分 v1 贡献", "", "权重 40/20/20/20；P95 参考 3 s / 0.25 m / 5°。分项相加后四舍五入；全失败总分固定 0，各贡献为 0；无资格时分项保持未测量。", "",
            "| 分项 | 满分 | Area Target | Immersal |", "| --- | --- | --- | --- |"]
        for component in scoreContributions { lines.append("| \(component.label) | \(Self.exact(component.maximumPoints)) | \(Self.exact(component.areaTargetPoints)) | \(Self.exact(component.immersalPoints)) |") }
        lines += ["", "## 连续失败与恢复", "", "轨迹配对：\(pairedTraceStatus.rawValue)；共同成功帧：\(commonSuccessfulFrameCount.map(String.init) ?? "not_measured")", ""]
        for trace in traces {
            lines += ["- \(Self.name(trace.provider))：\(trace.status.rawValue)；最长连续失败 \(trace.longestFailureStreak.map(String.init) ?? "not_measured") 帧；区段 \(trace.failureStreakCount.map(String.init) ?? "not_measured")；已恢复 \(trace.recoveredFailureStreakCount.map(String.init) ?? "not_measured")；未恢复 \(trace.unrecoveredFailureStreakCount.map(String.init) ?? "not_measured")；最长完整恢复：录制 \(Self.exact(trace.maximumRecoveryCaptureSeconds)) s / 累计算法 \(Self.exact(trace.maximumRecoveryAlgorithmSeconds)) s。"]
            for streak in trace.failureStreaks ?? [] {
                lines.append("  - 失败帧 \(streak.startSequence)…\(streak.endSequence)（\(streak.failedFrameCount) 帧），采集偏移 \(Self.exact(streak.startCaptureOffsetSeconds))…\(Self.exact(streak.endCaptureOffsetSeconds)) s；恢复帧 \(streak.recoverySequence.map(String.init) ?? "not_measured")；录制恢复 \(Self.exact(streak.captureSecondsToRecovery)) s / 累计算法 \(Self.exact(streak.algorithmSecondsToRecovery)) s。")
            }
        }
        lines += ["", "## Area Target 下一步实验", ""]
        for recommendation in recommendations {
            lines += ["### \(recommendation.title)", "", "证据：\(recommendation.evidence)", "", "待验证假设：\(recommendation.hypothesis)", "", "下一次实验：\(recommendation.nextExperiment)", "", "验收标准：\(recommendation.acceptanceCriterion)", ""]
        }
        lines += ["## 限制", ""] + limitations.map { "- \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func name(_ provider: LocalizationProvider) -> String { provider == .areaTarget ? "Area Target" : "Immersal" }
    private static func exact(_ value: Double?) -> String { value.map { String($0) } ?? "not_measured" }
    private static func cell(_ value: String) -> String { value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
}
