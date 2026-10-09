import XCTest
import simd
@testable import AreaTargetScanner

final class LocalizationEvaluationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_730_960)
    private var identity: LocalizationAssetIdentity {
        .init(provider: .areaTarget, assetID: "fixture-job", sourceFingerprint: String(repeating: "a", count: 64))
    }

    func testAssetIdentityKeepsProviderAndOptionalProvenance() throws {
        let legacy = LocalizationAssetIdentity(provider: .immersal, assetID: "7:123")
        XCTAssertNil(legacy.sourceFingerprint)
        XCTAssertNil(legacy.engineVersion)
        XCTAssertEqual(try JSONDecoder().decode(LocalizationAssetIdentity.self, from: JSONEncoder().encode(legacy)), legacy)
    }

    func testEmptyRunHasNoInventedStatisticsOrScore() {
        let report = LocalizationEvaluationAccumulator(identity: identity).report(date: date)
        XCTAssertEqual(report.attemptCount, 0)
        XCTAssertEqual(report.successCount, 0)
        XCTAssertEqual(report.captureDuration, 0)
        XCTAssertEqual(report.trackedTravelMeters, 0)
        XCTAssertNil(report.firstRecognitionCaptureOffset)
        XCTAssertNil(report.cumulativeAlgorithmSecondsToFirstRecognition)
        XCTAssertNil(report.p95LatencySeconds)
        XCTAssertNil(report.p95TranslationDeltaMeters)
        XCTAssertNil(report.p95RotationDeltaDegrees)
        XCTAssertNil(report.score)
        XCTAssertEqual(report.eligibility, .insufficientSamples)
        XCTAssertTrue(report.summary.contains("样本不足"))
    }

    func testAllSuccessesWithAdequateCommonCaptureReceiveOneHundred() {
        let report = sufficientRun().report(date: date)
        XCTAssertEqual(report.attemptCount, 20)
        XCTAssertEqual(report.successCount, 20)
        XCTAssertEqual(report.successRate, 1)
        XCTAssertEqual(report.captureDuration, 38)
        XCTAssertEqual(report.trackedTravelMeters, 3.8, accuracy: 1e-6)
        XCTAssertEqual(report.score, 100)
        XCTAssertEqual(report.eligibility, .eligible)
        XCTAssertTrue(report.summary.contains("稳定"))
    }

    func testAdequateFailedCaptureScoresZeroAndStillCountsTrackedTravel() {
        let report = sufficientRun(success: { _ in false }).report(date: date)
        XCTAssertEqual(report.attemptCount, 20)
        XCTAssertEqual(report.successCount, 0)
        XCTAssertEqual(report.trackedTravelMeters, 3.8, accuracy: 1e-6)
        XCTAssertEqual(report.p95LatencySeconds, 1)
        XCTAssertEqual(report.score, 0)
        XCTAssertEqual(report.eligibility, .noRecognition)
        XCTAssertTrue(report.summary.contains("未能识别"))
        XCTAssertNil(report.p95TranslationDeltaMeters)
    }

    func testAttemptDurationAndAllFrameTravelAreRequiredTogether() {
        for value in [sufficientRun(count: 19), sufficientRun(interval: 1), sufficientRun(step: 0.1)] {
            let report = value.report(date: date)
            XCTAssertNil(report.score)
            XCTAssertEqual(report.eligibility, .insufficientSamples)
        }
    }

    func testMissingCameraPositionBreaksTravelAcrossUnknownSegment() {
        var accumulator = LocalizationEvaluationAccumulator(identity: identity)
        record(&accumulator, sequence: 0, capture: 0, camera: SIMD3(0, 0, 0))
        record(&accumulator, sequence: 1, capture: 2, camera: nil)
        record(&accumulator, sequence: 2, capture: 4, camera: SIMD3(10, 0, 0))
        record(&accumulator, sequence: 3, capture: 6, camera: SIMD3(11, 0, 0))
        XCTAssertEqual(accumulator.report().trackedTravelMeters, 1)
    }

    func testFailureFramesContributeToCommonTravelAndLatencyDenominator() throws {
        var accumulator = LocalizationEvaluationAccumulator(identity: identity)
        record(&accumulator, sequence: 0, capture: 10, latency: 1, camera: SIMD3(0, 0, 0), pose: pose())
        record(&accumulator, sequence: 1, capture: 12, latency: 4, camera: SIMD3(0, 3, 0), pose: nil)
        record(&accumulator, sequence: 2, capture: 14, latency: 2, camera: SIMD3(0, 3, 4), pose: pose(x: 1))
        let report = accumulator.report()
        XCTAssertEqual(report.attemptCount, 3)
        XCTAssertEqual(report.successCount, 2)
        XCTAssertEqual(report.successRate, 2.0 / 3.0)
        XCTAssertEqual(report.trackedTravelMeters, 7)
        XCTAssertEqual(try XCTUnwrap(report.medianLatencySeconds), 2)
        XCTAssertEqual(try XCTUnwrap(report.p95LatencySeconds), 3.8, accuracy: 1e-10)
        XCTAssertEqual(report.p95TranslationDeltaMeters, 1)
    }

    func testCaptureOffsetAndCumulativeAlgorithmTimeRemainSeparateInBothModes() {
        for mode in [LocalizationTimingMode.live, .recordedReplay] {
            var accumulator = LocalizationEvaluationAccumulator(identity: identity, timingMode: mode)
            record(&accumulator, sequence: 0, capture: 100, latency: 4, pose: nil)
            record(&accumulator, sequence: 1, capture: 110, latency: 2, pose: pose())
            record(&accumulator, sequence: 2, capture: 130, latency: 20, pose: nil)
            let report = accumulator.report()
            XCTAssertEqual(report.timingMode, mode)
            XCTAssertEqual(report.captureDuration, 30, "Inference time cannot stretch the frozen capture timeline")
            XCTAssertEqual(report.firstRecognitionCaptureOffset, 10)
            XCTAssertEqual(report.cumulativeAlgorithmSecondsToFirstRecognition, 6)
            XCTAssertEqual(report.firstRecognitionLatencySeconds, 2)
            XCTAssertEqual(report.firstRecognitionSeconds, mode == .live ? 12 : 6)
            if mode == .recordedReplay { XCTAssertTrue(report.limitations.contains("回放")) }
        }
    }

    func testInvalidClocksAndNonincreasingSequencesAreExcludedBeforeAnyMetrics() {
        var accumulator = LocalizationEvaluationAccumulator(identity: identity)
        for (sequence, capture, latency) in [(0, Double.nan, 1.0), (0, -1, 1), (0, 1, -.infinity), (0, 1, -1)] {
            XCTAssertFalse(record(&accumulator, sequence: sequence, capture: capture, latency: latency))
        }
        XCTAssertTrue(record(&accumulator, sequence: 0, capture: 10, latency: 1))
        XCTAssertFalse(record(&accumulator, sequence: 0, capture: 11, latency: 1))
        XCTAssertFalse(record(&accumulator, sequence: 1, capture: 9, latency: 1))
        XCTAssertFalse(record(&accumulator, sequence: 1, capture: 10, latency: 1))
        XCTAssertTrue(record(&accumulator, sequence: 1, capture: 12, latency: 1))
        XCTAssertEqual(accumulator.report().attemptCount, 2)
        XCTAssertEqual(accumulator.report().captureDuration, 2)
    }

    func testOverflowingAlgorithmTimeIsExcludedAndJSONStaysFinite() throws {
        var accumulator = LocalizationEvaluationAccumulator(identity: identity)
        XCTAssertTrue(record(&accumulator, sequence: 0, capture: 0, latency: .greatestFiniteMagnitude, pose: nil))
        XCTAssertFalse(record(&accumulator, sequence: 1, capture: 2, latency: .greatestFiniteMagnitude, pose: pose()))
        let report = accumulator.report()
        XCTAssertEqual(report.attemptCount, 1)
        XCTAssertEqual(report.successCount, 0)
        XCTAssertNoThrow(try JSONEncoder().encode(report))
    }

    func testMissingNonfiniteScaleShearReflectionAndProjectivePosesCountAsFailures() throws {
        var nan = pose(); nan.columns.3.x = .nan
        var scale = pose(); scale.columns.0.x = 2
        var shear = pose(); shear.columns.1.x = 0.3
        var reflection = pose(); reflection.columns.2.z = -1
        var projective = pose(); projective.columns.0.w = 0.2
        var accumulator = LocalizationEvaluationAccumulator(identity: identity)
        for (index, invalid) in [nil, nan, scale, shear, reflection, projective].enumerated() {
            record(&accumulator, sequence: index, capture: Double(index) * 2, pose: invalid)
        }
        let report = accumulator.report()
        XCTAssertEqual(report.attemptCount, 6)
        XCTAssertEqual(report.successCount, 0)
        XCTAssertNil(report.firstRecognitionCaptureOffset)
        XCTAssertNoThrow(try JSONEncoder().encode(report))
    }

    func testNonfiniteCameraPositionBreaksTravelWithoutRejectingTheEngineCall() {
        var accumulator = LocalizationEvaluationAccumulator(identity: identity)
        record(&accumulator, sequence: 0, capture: 0, camera: SIMD3(0, 0, 0))
        record(&accumulator, sequence: 1, capture: 2, camera: SIMD3(.infinity, 0, 0))
        record(&accumulator, sequence: 2, capture: 4, camera: SIMD3(30, 0, 0))
        XCTAssertEqual(accumulator.report().attemptCount, 3)
        XCTAssertEqual(accumulator.report().trackedTravelMeters, 0)
    }

    func testMeasuredPercentilesUseLinearInterpolationAndSkipFailedPoseDeltas() throws {
        var accumulator = LocalizationEvaluationAccumulator(identity: identity)
        record(&accumulator, sequence: 0, capture: 0, latency: 1, pose: pose(x: 0, degrees: 0))
        record(&accumulator, sequence: 1, capture: 2, latency: 4, pose: nil)
        record(&accumulator, sequence: 2, capture: 4, latency: 2, pose: pose(x: 1, degrees: 10))
        record(&accumulator, sequence: 3, capture: 6, latency: 3, pose: pose(x: 4, degrees: 40))
        let report = accumulator.report()
        XCTAssertEqual(report.medianLatencySeconds, 2.5)
        XCTAssertEqual(try XCTUnwrap(report.p95LatencySeconds), 3.85, accuracy: 1e-10)
        XCTAssertEqual(report.medianTranslationDeltaMeters, 2)
        XCTAssertEqual(try XCTUnwrap(report.p95TranslationDeltaMeters), 2.9, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(report.medianRotationDeltaDegrees), 20, accuracy: 0.002)
        XCTAssertEqual(try XCTUnwrap(report.p95RotationDeltaDegrees), 29, accuracy: 0.002)
    }

    func testRotationWraparoundAndQuaternionSignsUseTheShortestArc() throws {
        var accumulator = LocalizationEvaluationAccumulator(identity: identity)
        record(&accumulator, sequence: 0, capture: 0, pose: pose(degrees: 179))
        record(&accumulator, sequence: 1, capture: 2, pose: pose(degrees: -179))
        XCTAssertEqual(try XCTUnwrap(accumulator.report().p95RotationDeltaDegrees), 2, accuracy: 0.003)
        var same = LocalizationEvaluationAccumulator(identity: identity)
        let q = simd_quatf(angle: 1.2, axis: SIMD3(0, 1, 0))
        record(&same, sequence: 0, capture: 0, pose: simd_float4x4(q))
        record(&same, sequence: 1, capture: 2, pose: simd_float4x4(simd_quatf(vector: -q.vector)))
        XCTAssertEqual(try XCTUnwrap(same.report().p95RotationDeltaDegrees), 0, accuracy: 0.003)
    }

    func testDifferentMapOriginsBecomeComparableOnlyAfterCommonScanComposition() throws {
        var native = LocalizationEvaluationAccumulator(identity: identity)
        var vendor = LocalizationEvaluationAccumulator(identity: .init(provider: .immersal, assetID: "7:123", sourceFingerprint: identity.sourceFingerprint))
        let mapFromScan = pose(x: 50, degrees: 40)
        for index in 0..<20 {
            let worldFromScan = pose(x: Float(index) * 0.01, degrees: Float(index) * 0.1)
            let worldFromMap = worldFromScan * mapFromScan.inverse
            record(&native, sequence: index, capture: Double(index) * 2, camera: SIMD3(Float(index) * 0.2, 0, 0), pose: worldFromScan)
            record(&vendor, sequence: index, capture: Double(index) * 2, camera: SIMD3(Float(index) * 0.2, 0, 0), pose: worldFromMap * mapFromScan)
        }
        XCTAssertEqual(native.report().score, vendor.report().score)
        XCTAssertEqual(try XCTUnwrap(native.report().p95TranslationDeltaMeters), try XCTUnwrap(vendor.report().p95TranslationDeltaMeters), accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(native.report().p95RotationDeltaDegrees), try XCTUnwrap(vendor.report().p95RotationDeltaDegrees), accuracy: 0.01)
    }

    func testEightyPercentSuccessAtReferenceThresholdsScoresNinetyTwo() {
        let report = sufficientRun(success: { $0 < 16 }, latency: 3, poseStep: 0.25, degreesStep: 5).report()
        XCTAssertEqual(report.successRate, 0.8)
        XCTAssertEqual(report.score, 92)
    }

    func testMeasuredZeroPoseChangesReceiveFullComponentPoints() {
        let report = sufficientRun(success: { $0.isMultiple(of: 2) }).report()
        XCTAssertEqual(report.p95TranslationDeltaMeters, 0)
        XCTAssertEqual(report.p95RotationDeltaDegrees, 0)
        XCTAssertEqual(report.score, 80)
        XCTAssertTrue(report.summary.contains("改进"), "A numeric score cannot override the minimum success-rate rule")
        XCTAssertTrue(report.recommendations.joined().contains("成功率"))
    }

    func testSingleSuccessfulPoseCannotInventAStabilityScore() {
        let report = sufficientRun(success: { $0 == 0 }).report()
        XCTAssertEqual(report.successCount, 1)
        XCTAssertNil(report.p95TranslationDeltaMeters)
        XCTAssertNil(report.score)
        XCTAssertEqual(report.eligibility, .insufficientSuccessfulPoses)
    }

    func testMissingCommonCalibrationPreventsScoringEvenWithManyMatches() {
        let report = sufficientRun(commonAlignmentValid: false).report()
        XCTAssertEqual(report.successCount, 20)
        XCTAssertNil(report.score)
        XCTAssertNil(report.p95TranslationDeltaMeters)
        XCTAssertEqual(report.eligibility, .missingCommonAlignment)
        XCTAssertTrue(report.recommendations.joined().contains("坐标"))
    }

    func testUnknownProvenanceCannotReceiveAPerformanceScore() {
        for fingerprint in [nil, "", "   "] as [String?] {
            let unknown = LocalizationAssetIdentity(provider: .areaTarget, assetID: "legacy", sourceFingerprint: fingerprint)
            let report = sufficientRun(identity: unknown).report()
            XCTAssertNil(report.score)
            XCTAssertEqual(report.eligibility, .unknownProvenance)
        }
    }

    func testUnknownProvenancePreventsEvenZeroScoresAndKeepsRawFailures() {
        let unknown = LocalizationAssetIdentity(provider: .immersal, assetID: "legacy")
        let report = sufficientRun(identity: unknown, success: { _ in false }).report()
        XCTAssertEqual(report.attemptCount, 20)
        XCTAssertEqual(report.successCount, 0)
        XCTAssertEqual(report.p95LatencySeconds, 1)
        XCTAssertNil(report.score)
        XCTAssertEqual(report.eligibility, .unknownProvenance)
    }

    func testModeSpecificFirstRecognitionThresholdDoesNotConfuseReplayWithCaptureTime() {
        for mode in [LocalizationTimingMode.live, .recordedReplay] {
            let report = sufficientRun(timingMode: mode, interval: 10, success: { $0 > 0 }, latency: 0.1).report()
            XCTAssertEqual(report.firstRecognitionCaptureOffset, 10)
            XCTAssertEqual(report.cumulativeAlgorithmSecondsToFirstRecognition, 0.2)
            XCTAssertEqual(report.firstRecognitionSeconds, mode == .live ? 10.1 : 0.2)
            XCTAssertTrue(report.summary.contains(mode == .live ? "改进" : "稳定"))
            XCTAssertEqual(report.recommendations.joined().contains("首次"), mode == .live)
        }
    }

    func testOneUncalibratedSuccessDoesNotJoinUnrelatedOriginsIntoStability() {
        var accumulator = sufficientRun(count: 19)
        record(&accumulator, sequence: 19, capture: 38, camera: SIMD3(3.8, 0, 0), pose: pose(x: 100), commonAlignmentValid: false)
        let report = accumulator.report()
        XCTAssertEqual(report.successCount, 20)
        XCTAssertNil(report.score)
        XCTAssertEqual(report.eligibility, .missingCommonAlignment)
    }

    func testThresholdsVersionAndBothTimingModesRoundTripWithoutPrivateFrameData() throws {
        var thresholds = LocalizationEvaluationThresholds()
        thresholds.maximumP95LatencySeconds = 0.5
        let id = LocalizationAssetIdentity(provider: .areaTarget, assetID: "fixture", sourceFingerprint: identity.sourceFingerprint, engineVersion: "native-test-1")
        let report = sufficientRun(identity: id, timingMode: .recordedReplay, thresholds: thresholds).report(date: date)
        XCTAssertEqual(report.scoreVersion, 1)
        XCTAssertEqual(report.score, 100, "Version 1 weights use the frozen reference constants; screening uses actual saved thresholds")
        XCTAssertTrue(report.summary.contains("改进"))
        XCTAssertEqual(report.thresholds, thresholds)
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(LocalizationEvaluationReport.self, from: data), report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["identity"])
        XCTAssertNotNil(object["thresholds"])
        for name in ["pixels", "cameraPosition", "worldFromScan", "token", "gps", "confidence"] { XCTAssertNil(object[name]) }
        XCTAssertTrue(report.limitations.contains("真实定位精度"))
    }

    private func sufficientRun(identity: LocalizationAssetIdentity? = nil, timingMode: LocalizationTimingMode = .live,
                               thresholds: LocalizationEvaluationThresholds = .init(), count: Int = 20,
                               interval: Double = 2, step: Float = 0.2, success: (Int) -> Bool = { _ in true },
                               latency: Double = 1, poseStep: Float = 0, degreesStep: Float = 0,
                               commonAlignmentValid: Bool = true) -> LocalizationEvaluationAccumulator {
        var accumulator = LocalizationEvaluationAccumulator(identity: identity ?? self.identity, timingMode: timingMode, thresholds: thresholds)
        for index in 0..<count {
            record(&accumulator, sequence: index, capture: Double(index) * interval, latency: latency,
                   camera: SIMD3(Float(index) * step, 0, 0),
                   pose: success(index) ? pose(x: Float(index) * poseStep, degrees: Float(index) * degreesStep) : nil,
                   commonAlignmentValid: commonAlignmentValid)
        }
        return accumulator
    }

    @discardableResult
    private func record(_ accumulator: inout LocalizationEvaluationAccumulator, sequence: Int, capture: Double,
                        latency: Double = 1, camera: SIMD3<Float>? = .zero,
                        pose: simd_float4x4? = matrix_identity_float4x4, commonAlignmentValid: Bool = true) -> Bool {
        accumulator.record(sequence: sequence, captureTime: capture, latency: latency,
                           cameraPosition: camera, worldFromScan: pose, commonAlignmentValid: commonAlignmentValid)
    }

    private func pose(x: Float = 0, degrees: Float = 0) -> simd_float4x4 {
        var result = simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0)))
        result.columns.3 = SIMD4(x, 0, 0, 1)
        return result
    }
}
