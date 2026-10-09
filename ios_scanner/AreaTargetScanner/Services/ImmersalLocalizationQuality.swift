import Foundation
import simd

/// App screening rules, not a vendor accuracy specification. Store the rules with
/// the report so a saved session keeps its original interpretation.
struct ImmersalLocalizationQualityThresholds: Codable, Equatable {
    var minimumAttemptCount = 20
    var minimumDurationSeconds = 30.0
    var minimumTestedTravelMeters = 3.0
    var minimumSuccessRate = 0.8
    var maximumFirstSuccessSeconds = 10.0
    var maximumP95LatencySeconds = 3.0
    var maximumP95TranslationDeltaMeters = 0.25
    var maximumP95RotationDeltaDegrees = 5.0
}

struct ImmersalLocalizationQualityReport: Codable, Equatable {
    let mapID: Int
    let userID: Int
    let date: Date
    let duration: Double
    let attemptCount: Int
    let successCount: Int
    let successRate: Double
    let firstSuccessSeconds: Double?
    let medianLatencySeconds: Double?
    let p95LatencySeconds: Double?
    let medianTranslationDeltaMeters: Double?
    let p95TranslationDeltaMeters: Double?
    let medianRotationDeltaDegrees: Double?
    let p95RotationDeltaDegrees: Double?
    let testedTravelMeters: Double
    var thresholds = ImmersalLocalizationQualityThresholds()

    var sampleSufficient: Bool {
        attemptCount >= thresholds.minimumAttemptCount &&
        duration >= thresholds.minimumDurationSeconds &&
        testedTravelMeters >= thresholds.minimumTestedTravelMeters
    }

    var qualitySummary: String {
        if enoughAttemptsWithoutSuccess { return "本次未能识别此空间" }
        guard sampleSufficient else { return "样本不足，暂不评价地图表现" }
        return performanceIssues.isEmpty ? "本次测试定位表现稳定" : "本次测试建议继续改进"
    }

    var recommendations: [String] {
        if enoughAttemptsWithoutSuccess {
            return [
                "核对当前选择的是此空间的原地图，并回到已扫描位置，对准有明显视觉特征的固定物体。",
                "检查光照是否与建图时相近，避开强反光、运动模糊或外观已明显改变的区域。",
                "若仍无法识别，建议补采当前环境中更多位置和观察角度，重新建图后复测；本次没有成功匹配，暂不能评价对齐稳定性。"
            ]
        }
        guard sampleSufficient else {
            var missing: [String] = []
            if attemptCount < thresholds.minimumAttemptCount {
                missing.append("继续测试，累计至少 \(thresholds.minimumAttemptCount) 次有效尝试。")
            }
            if duration < thresholds.minimumDurationSeconds {
                missing.append("从首次有效尝试起，测试至少 \(number(thresholds.minimumDurationSeconds)) 秒。")
            }
            if testedTravelMeters < thresholds.minimumTestedTravelMeters {
                missing.append("在保持正常跟踪时缓慢移动，使成功匹配间的相机累计位移达到 \(number(thresholds.minimumTestedTravelMeters)) 米。")
            }
            return missing
        }
        let issues = performanceIssues
        return issues.isEmpty ? ["继续在不同位置、朝向和光照下复测，确认本次表现能否重复。"] : issues
    }

    var thresholdsSummary: String {
        "经验筛查规则：至少 \(thresholds.minimumAttemptCount) 次有效尝试、\(number(thresholds.minimumDurationSeconds)) 秒、\(number(thresholds.minimumTestedTravelMeters)) 米成功匹配间相机累计位移。" +
        "样本足够后，稳定条件须全部满足：成功率 ≥ \(number(thresholds.minimumSuccessRate * 100))%，首次成功 ≤ \(number(thresholds.maximumFirstSuccessSeconds)) 秒，" +
        "P95 延迟 ≤ \(number(thresholds.maximumP95LatencySeconds)) 秒，P95 平移差 ≤ \(number(thresholds.maximumP95TranslationDeltaMeters)) 米，" +
        "P95 旋转差 ≤ \(number(thresholds.maximumP95RotationDeltaDegrees))°。延迟统计全部有效尝试，百分位采用线性插值。"
    }

    var metricLimitations: String {
        "平移差和旋转差比较相邻成功定位时，地图与相机跟踪空间之间的对齐变化，仅描述本次重复定位稳定性，不能代表真实定位精度。" +
        "相机累计位移只统计具有有效 AR 相机位置的相邻成功匹配，不是地图覆盖率，也不能证明完整覆盖。" +
        "跟踪重置后须开始新测试；本结果只适用于本次实际采样的位置和环境。"
    }

    private var enoughAttemptsWithoutSuccess: Bool {
        successCount == 0 && attemptCount >= thresholds.minimumAttemptCount && duration >= thresholds.minimumDurationSeconds
    }

    private var performanceIssues: [String] {
        var issues: [String] = []
        if successRate < thresholds.minimumSuccessRate {
            issues.append("成功率低于 \(number(thresholds.minimumSuccessRate * 100))%，请在有明显视觉特征、与建图时外观相近的位置复测，必要时补充建图采集。")
        }
        if let firstSuccessSeconds, firstSuccessSeconds > thresholds.maximumFirstSuccessSeconds {
            issues.append("首次成功耗时超过 \(number(thresholds.maximumFirstSuccessSeconds)) 秒，请从已采集且特征丰富的位置开始，缓慢改变朝向。")
        }
        if let p95LatencySeconds, p95LatencySeconds > thresholds.maximumP95LatencySeconds {
            issues.append("P95 定位延迟超过 \(number(thresholds.maximumP95LatencySeconds)) 秒，请检查设备负载并在相同条件下复测。")
        }
        if let p95TranslationDeltaMeters, p95TranslationDeltaMeters > thresholds.maximumP95TranslationDeltaMeters {
            issues.append("P95 平移差超过 \(number(thresholds.maximumP95TranslationDeltaMeters)) 米，重复定位变换存在跳动；请检查跟踪状态，并对照实际环境复测。")
        }
        if let p95RotationDeltaDegrees, p95RotationDeltaDegrees > thresholds.maximumP95RotationDeltaDegrees {
            issues.append("P95 旋转差超过 \(number(thresholds.maximumP95RotationDeltaDegrees))°，请降低移动速度、增加多朝向采样并复测。")
        }
        return issues
    }

    private func number(_ value: Double) -> String {
        String(format: "%.4g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// One uninterrupted AR tracking world. Create a fresh accumulator after tracking
/// resets. Elapsed time is normalized to the first accepted attempt; no scene,
/// matrix, camera image, or credentials are included in the resulting report.
struct ImmersalLocalizationQualityAccumulator {
    private var firstElapsed: Double?
    private var lastElapsed: Double?
    private var duration = 0.0
    private var successCount = 0
    private var firstSuccessSeconds: Double?
    private var latencies: [Double] = []
    private var translations: [Double] = []
    private var rotations: [Double] = []
    private var previousMapPose: simd_float4x4?
    private var previousCameraPosition: SIMD3<Double>?
    private var testedTravelMeters = 0.0

    /// `elapsed` is the attempt's start time and `latency` ends at its result.
    /// Invalid or out-of-order timing is not an eligible attempt. A reported
    /// success without a finite pose counts as a failed attempt. Camera positions
    /// affect tested travel only, and missing positions break that travel segment.
    mutating func record(success: Bool, elapsed: Double, latency: Double,
                         worldFromMap: simd_float4x4? = nil, cameraPosition: SIMD3<Float>? = nil) {
        guard elapsed.isFinite, elapsed >= 0, latency.isFinite, latency >= 0,
              (elapsed + latency).isFinite,
              lastElapsed.map({ elapsed >= $0 }) ?? true else { return }
        if firstElapsed == nil { firstElapsed = elapsed }
        lastElapsed = elapsed
        let completionSeconds = elapsed - (firstElapsed ?? elapsed) + latency
        duration = max(duration, completionSeconds)
        latencies.append(latency)
        guard success, let pose = worldFromMap, Self.isFinite(pose) else { return }
        successCount += 1
        if firstSuccessSeconds == nil { firstSuccessSeconds = completionSeconds }

        if let previous = previousMapPose {
            translations.append(simd_distance(Self.translation(previous), Self.translation(pose)))
            rotations.append(Self.rotationDifferenceDegrees(previous, pose))
        }
        previousMapPose = pose

        let currentCamera = cameraPosition.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
            .flatMap { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite ? $0 : nil }
        if let currentCamera, let previousCameraPosition {
            testedTravelMeters += simd_distance(previousCameraPosition, currentCamera)
        }
        previousCameraPosition = currentCamera
    }

    func report(mapID: Int, userID: Int, date: Date = Date()) -> ImmersalLocalizationQualityReport {
        ImmersalLocalizationQualityReport(mapID: mapID, userID: userID, date: date,
                                          duration: duration,
                                          attemptCount: latencies.count, successCount: successCount,
                                          successRate: latencies.isEmpty ? 0 : Double(successCount) / Double(latencies.count),
                                          firstSuccessSeconds: firstSuccessSeconds,
                                          medianLatencySeconds: Self.percentile(latencies, 0.5),
                                          p95LatencySeconds: Self.percentile(latencies, 0.95),
                                          medianTranslationDeltaMeters: Self.percentile(translations, 0.5),
                                          p95TranslationDeltaMeters: Self.percentile(translations, 0.95),
                                          medianRotationDeltaDegrees: Self.percentile(rotations, 0.5),
                                          p95RotationDeltaDegrees: Self.percentile(rotations, 0.95),
                                          testedTravelMeters: testedTravelMeters)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Double(sorted.count - 1) * fraction
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - Double(lower))
    }

    private static func isFinite(_ pose: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { column in (0..<4).allSatisfy { row in pose[column][row].isFinite } }
    }

    private static func translation(_ pose: simd_float4x4) -> SIMD3<Double> {
        SIMD3(Double(pose.columns.3.x), Double(pose.columns.3.y), Double(pose.columns.3.z))
    }

    private static func rotationDifferenceDegrees(_ first: simd_float4x4, _ second: simd_float4x4) -> Double {
        // Double precision and |dot| make quaternion sign irrelevant, preserve
        // the short arc across ±180°, and keep acos inside its numeric domain.
        func quaternion(_ pose: simd_float4x4) -> simd_quatd {
            let rotation = simd_double3x3(columns: (
                SIMD3(Double(pose[0][0]), Double(pose[0][1]), Double(pose[0][2])),
                SIMD3(Double(pose[1][0]), Double(pose[1][1]), Double(pose[1][2])),
                SIMD3(Double(pose[2][0]), Double(pose[2][1]), Double(pose[2][2]))))
            return simd_normalize(simd_quatd(rotation))
        }
        let dot = abs(simd_dot(quaternion(first).vector, quaternion(second).vector))
        return 2 * acos(min(1, max(0, dot))) * 180 / .pi
    }
}
