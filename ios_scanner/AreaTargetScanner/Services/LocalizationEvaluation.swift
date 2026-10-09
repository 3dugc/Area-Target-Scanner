import Foundation
import simd

enum LocalizationProvider: String, Codable { case areaTarget, immersal }
enum LocalizationTimingMode: String, Codable { case live, recordedReplay }
enum LocalizationEvaluationEligibility: String, Codable {
    case eligible, insufficientSamples, noRecognition, unknownProvenance
    case missingCommonAlignment, insufficientSuccessfulPoses
}

struct LocalizationAssetIdentity: Codable, Equatable {
    let provider: LocalizationProvider
    let assetID: String
    let sourceFingerprint: String?
    let engineVersion: String?
    let assetDigest: String?
    let buildConfiguration: String?
    /// Nil preserves the identity of legacy reports that did not record a mode.
    let areaTargetRecognitionMode: AreaTargetRecognitionMode?

    init(provider: LocalizationProvider, assetID: String, sourceFingerprint: String? = nil, engineVersion: String? = nil,
         assetDigest: String? = nil, buildConfiguration: String? = nil,
         areaTargetRecognitionMode: AreaTargetRecognitionMode? = nil) {
        self.provider = provider; self.assetID = assetID
        self.sourceFingerprint = sourceFingerprint; self.engineVersion = engineVersion
        self.assetDigest = assetDigest; self.buildConfiguration = buildConfiguration
        self.areaTargetRecognitionMode = areaTargetRecognitionMode
    }
}

struct LocalizationEvaluationThresholds: Codable, Equatable {
    var minimumAttemptCount = 20
    var minimumDurationSeconds = 30.0
    var minimumTestedTravelMeters = 3.0
    var minimumSuccessRate = 0.8
    var maximumFirstSuccessSeconds = 10.0
    var maximumP95LatencySeconds = 3.0
    var maximumP95TranslationDeltaMeters = 0.25
    var maximumP95RotationDeltaDegrees = 5.0
}

struct LocalizationEvaluationReport: Codable, Equatable {
    let identity: LocalizationAssetIdentity
    let date: Date
    let timingMode: LocalizationTimingMode
    let scoreVersion: Int
    let thresholds: LocalizationEvaluationThresholds
    let attemptCount: Int
    let successCount: Int
    let successRate: Double
    let captureDuration: Double
    let trackedTravelMeters: Double
    let firstRecognitionCaptureOffset: Double?
    let cumulativeAlgorithmSecondsToFirstRecognition: Double?
    let firstRecognitionLatencySeconds: Double?
    let medianLatencySeconds: Double?
    let p95LatencySeconds: Double?
    let medianTranslationDeltaMeters: Double?
    let p95TranslationDeltaMeters: Double?
    let medianRotationDeltaDegrees: Double?
    let p95RotationDeltaDegrees: Double?
    let score: Int?
    let eligibility: LocalizationEvaluationEligibility

    /// A replay's recorded timeline is not its runtime response time.
    var firstRecognitionSeconds: Double? {
        switch timingMode {
        case .live:
            guard let offset = firstRecognitionCaptureOffset, let latency = firstRecognitionLatencySeconds else { return nil }
            return offset + latency
        case .recordedReplay: return cumulativeAlgorithmSecondsToFirstRecognition
        }
    }

    var sampleSufficient: Bool {
        attemptCount >= thresholds.minimumAttemptCount && captureDuration >= thresholds.minimumDurationSeconds &&
        trackedTravelMeters >= thresholds.minimumTestedTravelMeters
    }

    var summary: String {
        switch eligibility {
        case .insufficientSamples: return "样本不足，暂不评分"
        case .unknownProvenance: return "扫描来源尚未确认，暂不评分"
        case .noRecognition: return "本次未能识别此空间"
        case .missingCommonAlignment: return "原扫描坐标尚未确认，暂不评分"
        case .insufficientSuccessfulPoses: return "成功定位不足，暂不能评价稳定性"
        case .eligible: return performanceIssues.isEmpty ? "本次测试定位表现稳定" : "本次测试建议继续改进"
        }
    }

    var recommendations: [String] {
        switch eligibility {
        case .insufficientSamples:
            var missing: [String] = []
            if attemptCount < thresholds.minimumAttemptCount { missing.append("继续测试，累计至少 \(thresholds.minimumAttemptCount) 次有效算法调用。") }
            if captureDuration < thresholds.minimumDurationSeconds { missing.append("采集持续至少 \(number(thresholds.minimumDurationSeconds)) 秒的共同测试帧。") }
            if trackedTravelMeters < thresholds.minimumTestedTravelMeters { missing.append("保持正常相机跟踪，在共同测试帧间缓慢移动至少 \(number(thresholds.minimumTestedTravelMeters)) 米。") }
            return missing
        case .unknownProvenance:
            return ["核对资产来自同一份原扫描，补齐已验证的扫描指纹后再评分；当前仍可查看实际成功率和算法耗时。"]
        case .noRecognition:
            return ["核对所选资产与当前空间一致，对准扫描过且视觉特征明显的固定物体。", "检查光照和环境变化，必要时补采并重新建图；没有成功匹配，暂不能评价稳定性。"]
        case .missingCommonAlignment:
            return ["先确认地图与原扫描的坐标变换，再使用同一原扫描原点评价对齐变化；未经确认的地图坐标不能直接比较。"]
        case .insufficientSuccessfulPoses:
            return ["至少取得 2 次具有有效原扫描坐标的成功定位，才能测量相邻定位的稳定性。"]
        case .eligible:
            return performanceIssues.isEmpty ? ["在不同位置、朝向和光照下复测，确认本次表现能否重复。"] : performanceIssues
        }
    }

    var limitations: String {
        let timing = timingMode == .live
            ? "现场首次识别耗时包含成功帧相对首帧的采集时间和该次算法耗时，不含地图载入与校准。"
            : "回放采集时间来自固定的录制序列；首次识别耗时是截至首次成功的累计算法耗时，不代表现场实时响应。"
        return timing + "平移差和旋转差比较同一原扫描坐标下的相邻成功对齐，仅描述重复定位稳定性，不能代表真实定位精度。" +
            "走动距离统计全部具有有效 AR 相机位置的相邻测试帧，缺失位置会中断距离累计；它不是地图覆盖率。" +
            "跟踪重置后须开始新测试。两个引擎须使用同一份原扫描和相同测试帧；SDK 置信值不参与总分。" +
            "评分版本 1 的权重为成功率 40、算法延迟 20、平移稳定性 20、旋转稳定性 20；经验门槛结论与总分独立。"
    }

    private var performanceIssues: [String] {
        var issues: [String] = []
        if successRate < thresholds.minimumSuccessRate { issues.append("成功率低于 \(number(thresholds.minimumSuccessRate * 100))%，请在扫描过且特征明显的区域复测，必要时补充建图。") }
        if let firstRecognitionSeconds, firstRecognitionSeconds > thresholds.maximumFirstSuccessSeconds {
            let label = timingMode == .live ? "首次现场识别" : "首次回放识别的累计算法耗时"
            issues.append("\(label)超过 \(number(thresholds.maximumFirstSuccessSeconds)) 秒，请核对起始观察位置和设备负载。")
        }
        if let p95LatencySeconds, p95LatencySeconds > thresholds.maximumP95LatencySeconds { issues.append("P95 算法耗时超过 \(number(thresholds.maximumP95LatencySeconds)) 秒，请在相同设备负载下复测。") }
        if let p95TranslationDeltaMeters, p95TranslationDeltaMeters > thresholds.maximumP95TranslationDeltaMeters { issues.append("P95 对齐平移差超过 \(number(thresholds.maximumP95TranslationDeltaMeters)) 米，请对照真实边缘并检查相机跟踪。") }
        if let p95RotationDeltaDegrees, p95RotationDeltaDegrees > thresholds.maximumP95RotationDeltaDegrees { issues.append("P95 对齐旋转差超过 \(number(thresholds.maximumP95RotationDeltaDegrees))°，请降低移动速度并增加多朝向采样。") }
        return issues
    }

    private func number(_ value: Double) -> String { String(format: "%.4g", locale: Locale(identifier: "en_US_POSIX"), value) }
}

/// One uninterrupted AR tracking world, measured at a common original-scan origin.
/// The caller must verify provenance and common alignment; this accumulator never
/// infers accuracy from SDK confidence or uses failed localization to gate travel.
struct LocalizationEvaluationAccumulator {
    let identity: LocalizationAssetIdentity
    let timingMode: LocalizationTimingMode
    let thresholds: LocalizationEvaluationThresholds
    private var firstCaptureTime: Double?
    private var lastCaptureTime: Double?
    private var lastSequence: Int?
    private var algorithmSeconds = 0.0
    private var successCount = 0
    private var firstRecognitionCaptureOffset: Double?
    private var cumulativeAlgorithmSecondsToFirstRecognition: Double?
    private var firstRecognitionLatencySeconds: Double?
    private var latencies: [Double] = []
    private var translations: [Double] = []
    private var rotations: [Double] = []
    private var previousWorldFromScan: simd_float4x4?
    private var previousCameraPosition: SIMD3<Double>?
    private var trackedTravelMeters = 0.0
    private var allSuccessesHaveCommonAlignment = true

    init(identity: LocalizationAssetIdentity, timingMode: LocalizationTimingMode = .live,
         thresholds: LocalizationEvaluationThresholds = .init()) {
        self.identity = identity; self.timingMode = timingMode; self.thresholds = thresholds
    }

    @discardableResult
    mutating func record(sequence: Int, captureTime: Double, latency: Double, cameraPosition: SIMD3<Float>?,
                         worldFromScan: simd_float4x4?, commonAlignmentValid: Bool) -> Bool {
        let offset = captureTime - (firstCaptureTime ?? captureTime)
        let totalAlgorithmSeconds = algorithmSeconds + latency
        guard sequence >= 0, lastSequence.map({ sequence > $0 }) ?? true,
              captureTime.isFinite, captureTime >= 0, lastCaptureTime.map({ captureTime > $0 }) ?? true,
              latency.isFinite, latency >= 0, totalAlgorithmSeconds.isFinite, (offset + latency).isFinite else { return false }
        if firstCaptureTime == nil { firstCaptureTime = captureTime }
        lastCaptureTime = captureTime; lastSequence = sequence
        algorithmSeconds = totalAlgorithmSeconds
        latencies.append(latency)

        let camera = cameraPosition.flatMap { value -> SIMD3<Double>? in
            guard value.x.isFinite, value.y.isFinite, value.z.isFinite else { return nil }
            return SIMD3(Double(value.x), Double(value.y), Double(value.z))
        }
        if let camera, let previousCameraPosition { trackedTravelMeters += simd_distance(previousCameraPosition, camera) }
        previousCameraPosition = camera

        guard let pose = worldFromScan, Self.isRigid(pose) else { return true }
        successCount += 1
        if firstRecognitionCaptureOffset == nil {
            firstRecognitionCaptureOffset = offset
            cumulativeAlgorithmSecondsToFirstRecognition = algorithmSeconds
            firstRecognitionLatencySeconds = latency
        }
        guard commonAlignmentValid else {
            allSuccessesHaveCommonAlignment = false
            previousWorldFromScan = nil
            return true
        }
        if let previous = previousWorldFromScan {
            translations.append(simd_distance(Self.translation(previous), Self.translation(pose)))
            rotations.append(Self.rotationDifference(previous, pose))
        }
        previousWorldFromScan = pose
        return true
    }

    func report(date: Date = Date()) -> LocalizationEvaluationReport {
        let duration = (lastCaptureTime ?? 0) - (firstCaptureTime ?? 0)
        let rate = latencies.isEmpty ? 0 : Double(successCount) / Double(latencies.count)
        let p95Latency = Self.percentile(latencies, 0.95)
        let p95Translation = allSuccessesHaveCommonAlignment ? Self.percentile(translations, 0.95) : nil
        let p95Rotation = allSuccessesHaveCommonAlignment ? Self.percentile(rotations, 0.95) : nil
        let eligibility: LocalizationEvaluationEligibility
        let knownSource = !identity.assetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !(identity.sourceFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !knownSource { eligibility = .unknownProvenance }
        else if latencies.count < thresholds.minimumAttemptCount || duration < thresholds.minimumDurationSeconds || trackedTravelMeters < thresholds.minimumTestedTravelMeters {
            eligibility = .insufficientSamples
        } else if successCount == 0 { eligibility = .noRecognition }
        else if !allSuccessesHaveCommonAlignment { eligibility = .missingCommonAlignment }
        else if successCount < 2 { eligibility = .insufficientSuccessfulPoses }
        else { eligibility = .eligible }
        let score: Int?
        if eligibility == .noRecognition { score = 0 }
        else if eligibility == .eligible, let latency = p95Latency, let translation = p95Translation, let rotation = p95Rotation {
            // Frozen version-1 reference constants. Saved screening thresholds do
            // not silently change the meaning of a historical numeric score.
            func component(_ measured: Double, reference: Double) -> Double { measured == 0 ? 1 : min(1, reference / measured) }
            score = Int((40 * rate + 20 * component(latency, reference: 3) +
                20 * component(translation, reference: 0.25) + 20 * component(rotation, reference: 5)).rounded())
        } else { score = nil }
        return LocalizationEvaluationReport(identity: identity, date: date, timingMode: timingMode, scoreVersion: 1,
            thresholds: thresholds, attemptCount: latencies.count, successCount: successCount, successRate: rate, captureDuration: duration,
            trackedTravelMeters: trackedTravelMeters, firstRecognitionCaptureOffset: firstRecognitionCaptureOffset,
            cumulativeAlgorithmSecondsToFirstRecognition: cumulativeAlgorithmSecondsToFirstRecognition,
            firstRecognitionLatencySeconds: firstRecognitionLatencySeconds,
            medianLatencySeconds: Self.percentile(latencies, 0.5), p95LatencySeconds: p95Latency,
            medianTranslationDeltaMeters: allSuccessesHaveCommonAlignment ? Self.percentile(translations, 0.5) : nil,
            p95TranslationDeltaMeters: p95Translation,
            medianRotationDeltaDegrees: allSuccessesHaveCommonAlignment ? Self.percentile(rotations, 0.5) : nil,
            p95RotationDeltaDegrees: p95Rotation, score: score, eligibility: eligibility)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Double(sorted.count - 1) * fraction
        let lower = Int(rank.rounded(.down)), upper = Int(rank.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - Double(lower))
    }

    private static func translation(_ value: simd_float4x4) -> SIMD3<Double> { xyz(value.columns.3) }
    private static func xyz(_ value: SIMD4<Float>) -> SIMD3<Double> { SIMD3(Double(value.x), Double(value.y), Double(value.z)) }

    static func isRigid(_ value: simd_float4x4) -> Bool {
        guard (0..<4).allSatisfy({ column in (0..<4).allSatisfy { value[column][$0].isFinite } }),
              abs(value.columns.0.w) < 0.0001, abs(value.columns.1.w) < 0.0001,
              abs(value.columns.2.w) < 0.0001, abs(value.columns.3.w - 1) < 0.0001 else { return false }
        let x = xyz(value.columns.0), y = xyz(value.columns.1), z = xyz(value.columns.2)
        let tolerance = 0.001
        return abs(simd_length_squared(x) - 1) <= tolerance && abs(simd_length_squared(y) - 1) <= tolerance &&
            abs(simd_length_squared(z) - 1) <= tolerance && abs(simd_dot(x, y)) <= tolerance &&
            abs(simd_dot(y, z)) <= tolerance && abs(simd_dot(z, x)) <= tolerance &&
            abs(simd_dot(simd_cross(x, y), z) - 1) <= tolerance
    }

    private static func rotationDifference(_ first: simd_float4x4, _ second: simd_float4x4) -> Double {
        func quaternion(_ value: simd_float4x4) -> simd_quatd {
            simd_normalize(simd_quatd(simd_double3x3(columns: (xyz(value.columns.0), xyz(value.columns.1), xyz(value.columns.2)))))
        }
        let dot = abs(simd_dot(quaternion(first).vector, quaternion(second).vector))
        return 2 * acos(min(1, max(0, dot))) * 180 / .pi
    }
}
