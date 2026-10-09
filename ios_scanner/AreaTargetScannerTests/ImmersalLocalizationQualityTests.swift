import XCTest
import simd
@testable import AreaTargetScanner

final class ImmersalLocalizationQualityTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_730_960)

    func testEmptySessionHasNoInventedSuccessLatencyOrPoseStatistics() {
        let result = report(ImmersalLocalizationQualityAccumulator())
        XCTAssertEqual(result.mapID, 123)
        XCTAssertEqual(result.userID, 7)
        XCTAssertEqual(result.date, date)
        XCTAssertEqual(result.duration, 0)
        XCTAssertEqual(result.attemptCount, 0)
        XCTAssertEqual(result.successCount, 0)
        XCTAssertEqual(result.successRate, 0)
        XCTAssertNil(result.firstSuccessSeconds)
        XCTAssertNil(result.medianLatencySeconds)
        XCTAssertNil(result.p95LatencySeconds)
        XCTAssertNil(result.medianTranslationDeltaMeters)
        XCTAssertNil(result.p95RotationDeltaDegrees)
        XCTAssertEqual(result.testedTravelMeters, 0)
        XCTAssertFalse(result.sampleSufficient)
        XCTAssertEqual(result.qualitySummary, "样本不足，暂不评价地图表现")
    }

    func testFirstEligibleAttemptDefinesTimeZeroAndLatencyIncludesFailures() throws {
        var accumulator = ImmersalLocalizationQualityAccumulator()
        accumulator.record(success: false, elapsed: 50, latency: 4)
        accumulator.record(success: true, elapsed: 54, latency: 1, worldFromMap: matrix_identity_float4x4)
        accumulator.record(success: false, elapsed: 59, latency: 2)
        accumulator.record(success: true, elapsed: 60, latency: 3, worldFromMap: matrix_identity_float4x4)
        let result = report(accumulator)
        XCTAssertEqual(result.duration, 13)
        XCTAssertEqual(result.firstSuccessSeconds, 5)
        XCTAssertEqual(result.attemptCount, 4)
        XCTAssertEqual(result.successCount, 2)
        XCTAssertEqual(result.successRate, 0.5)
        XCTAssertEqual(try XCTUnwrap(result.medianLatencySeconds), 2.5, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(result.p95LatencySeconds), 3.85, accuracy: 1e-10)
    }

    func testSingleSuccessIncludesResultLatencyAndHasNoAdjacentPoseDelta() {
        var accumulator = ImmersalLocalizationQualityAccumulator()
        accumulator.record(success: true, elapsed: 18, latency: 0.7,
                           worldFromMap: pose(x: 4), cameraPosition: SIMD3(3, 0, 0))
        let result = report(accumulator)
        XCTAssertEqual(result.firstSuccessSeconds, 0.7)
        XCTAssertEqual(result.duration, 0.7, accuracy: 1e-10)
        XCTAssertEqual(result.medianLatencySeconds, 0.7)
        XCTAssertEqual(result.p95LatencySeconds, 0.7)
        XCTAssertNil(result.medianTranslationDeltaMeters)
        XCTAssertNil(result.medianRotationDeltaDegrees)
        XCTAssertEqual(result.testedTravelMeters, 0)
    }

    func testAdjacentSuccessfulPosesIgnoreFailedAttemptAndUseInterpolatedPercentiles() throws {
        var accumulator = ImmersalLocalizationQualityAccumulator()
        accumulator.record(success: true, elapsed: 0, latency: 1,
                           worldFromMap: pose(x: 0, degrees: 0), cameraPosition: SIMD3(0, 0, 0))
        accumulator.record(success: false, elapsed: 1, latency: 1,
                           worldFromMap: pose(x: 100, degrees: 90), cameraPosition: SIMD3(100, 0, 0))
        accumulator.record(success: true, elapsed: 2, latency: 1,
                           worldFromMap: pose(x: 1, degrees: 10), cameraPosition: SIMD3(0, 3, 0))
        accumulator.record(success: true, elapsed: 3, latency: 1,
                           worldFromMap: pose(x: 4, degrees: 40), cameraPosition: SIMD3(0, 3, 4))
        let result = report(accumulator)
        XCTAssertEqual(try XCTUnwrap(result.medianTranslationDeltaMeters), 2, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(result.p95TranslationDeltaMeters), 2.9, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(result.medianRotationDeltaDegrees), 20, accuracy: 0.002)
        XCTAssertEqual(try XCTUnwrap(result.p95RotationDeltaDegrees), 29, accuracy: 0.002)
        XCTAssertEqual(result.testedTravelMeters, 7, accuracy: 1e-6)
        XCTAssertEqual(result.successCount, 3)
    }

    func testRotationNear180DegreesAndWraparoundUseShortestRelativeAngle() throws {
        var nearHalfTurn = ImmersalLocalizationQualityAccumulator()
        nearHalfTurn.record(success: true, elapsed: 0, latency: 1, worldFromMap: pose(degrees: 0))
        nearHalfTurn.record(success: true, elapsed: 1, latency: 1, worldFromMap: pose(degrees: 179.999))
        XCTAssertEqual(try XCTUnwrap(report(nearHalfTurn).p95RotationDeltaDegrees), 179.999, accuracy: 0.003)

        var wraparound = ImmersalLocalizationQualityAccumulator()
        wraparound.record(success: true, elapsed: 0, latency: 1, worldFromMap: pose(degrees: 179))
        wraparound.record(success: true, elapsed: 1, latency: 1, worldFromMap: pose(degrees: -179))
        XCTAssertEqual(try XCTUnwrap(report(wraparound).p95RotationDeltaDegrees), 2, accuracy: 0.003)
    }

    func testNonfiniteOrMissingSuccessPoseCountsAsFailureAndNeverPollutesJSON() throws {
        var accumulator = ImmersalLocalizationQualityAccumulator()
        var nonfiniteTranslation = matrix_identity_float4x4
        nonfiniteTranslation.columns.3.x = .infinity
        var nonfiniteRotation = matrix_identity_float4x4
        nonfiniteRotation.columns.0.y = .nan
        accumulator.record(success: true, elapsed: 0, latency: 1, worldFromMap: nonfiniteTranslation)
        accumulator.record(success: true, elapsed: 1, latency: 1, worldFromMap: nonfiniteRotation)
        accumulator.record(success: true, elapsed: 2, latency: 1)
        accumulator.record(success: true, elapsed: 3, latency: 1,
                           worldFromMap: matrix_identity_float4x4, cameraPosition: SIMD3(.nan, 0, 0))
        let result = report(accumulator)
        XCTAssertEqual(result.attemptCount, 4)
        XCTAssertEqual(result.successCount, 1)
        XCTAssertEqual(result.firstSuccessSeconds, 4)
        XCTAssertEqual(result.testedTravelMeters, 0)
        XCTAssertNoThrow(try JSONEncoder().encode(result))
    }

    func testInvalidTimingAndOutOfOrderAttemptAreRejectedBeforeCounting() {
        var accumulator = ImmersalLocalizationQualityAccumulator()
        accumulator.record(success: false, elapsed: .nan, latency: 1)
        accumulator.record(success: false, elapsed: -1, latency: 1)
        accumulator.record(success: false, elapsed: 5, latency: -.infinity)
        accumulator.record(success: false, elapsed: 5, latency: -1)
        accumulator.record(success: false, elapsed: 8, latency: 1)
        accumulator.record(success: false, elapsed: 7, latency: 1)
        accumulator.record(success: false, elapsed: 9, latency: 2)
        let result = report(accumulator)
        XCTAssertEqual(result.attemptCount, 2)
        XCTAssertEqual(result.duration, 3)
        XCTAssertEqual(result.medianLatencySeconds, 1.5)
    }

    func testDurationIncludesLatestCompletionWhenLaterAttemptFinishesSooner() {
        var accumulator = ImmersalLocalizationQualityAccumulator()
        accumulator.record(success: false, elapsed: 20, latency: 5)
        accumulator.record(success: true, elapsed: 21, latency: 1, worldFromMap: pose())
        let result = report(accumulator)
        XCTAssertEqual(result.duration, 5)
        XCTAssertEqual(result.firstSuccessSeconds, 2)
    }

    func testNonfiniteCompletionTimeIsRejectedBeforeCounting() {
        var accumulator = ImmersalLocalizationQualityAccumulator()
        accumulator.record(success: true, elapsed: .greatestFiniteMagnitude,
                           latency: .greatestFiniteMagnitude, worldFromMap: pose())
        XCTAssertEqual(report(accumulator).attemptCount, 0)
    }

    func testMissingCameraPositionDoesNotInventTravelAcrossUnknownInterval() {
        var accumulator = ImmersalLocalizationQualityAccumulator()
        accumulator.record(success: true, elapsed: 0, latency: 1,
                           worldFromMap: pose(), cameraPosition: SIMD3(0, 0, 0))
        accumulator.record(success: true, elapsed: 1, latency: 1, worldFromMap: pose())
        accumulator.record(success: true, elapsed: 2, latency: 1,
                           worldFromMap: pose(), cameraPosition: SIMD3(5, 0, 0))
        XCTAssertEqual(report(accumulator).testedTravelMeters, 0)
    }

    func testSampleSufficiencyRequiresAttemptsDurationAndSuccessfulTravelTogether() {
        XCTAssertFalse(report(samples(count: 19, duration: 40, travel: 4)).sampleSufficient)
        XCTAssertFalse(report(samples(count: 20, duration: 29, travel: 4)).sampleSufficient)
        XCTAssertFalse(report(samples(count: 20, duration: 30, travel: 2.9)).sampleSufficient)
        let enough = report(samples(count: 20, duration: 30, travel: 3))
        XCTAssertTrue(enough.sampleSufficient)
        XCTAssertEqual(enough.qualitySummary, "本次测试定位表现稳定")
    }

    func testLowSuccessRateAndUnstableTransformProduceSpecificTransparentRecommendations() {
        var accumulator = ImmersalLocalizationQualityAccumulator()
        for index in 0..<20 {
            accumulator.record(success: index.isMultiple(of: 2), elapsed: Double(index) * 2, latency: 4,
                               worldFromMap: pose(x: Float(index), degrees: Float(index) * 10),
                               cameraPosition: SIMD3(Float(index), 0, 0))
        }
        let result = report(accumulator)
        XCTAssertTrue(result.sampleSufficient)
        XCTAssertEqual(result.qualitySummary, "本次测试建议继续改进")
        let advice = result.recommendations.joined(separator: " ")
        XCTAssertTrue(advice.contains("成功率"))
        XCTAssertTrue(advice.contains("延迟"))
        XCTAssertTrue(advice.contains("平移"))
        XCTAssertTrue(advice.contains("旋转"))
        XCTAssertTrue(result.thresholdsSummary.contains("20"))
        XCTAssertTrue(result.thresholdsSummary.contains("30"))
        XCTAssertTrue(result.thresholdsSummary.contains("3 米"))
        XCTAssertTrue(result.metricLimitations.contains("真实定位精度"))
        XCTAssertTrue(result.metricLimitations.contains("覆盖率"))
        XCTAssertFalse(result.metricLimitations.contains("T_ARWorld_Map"), "Product copy must describe the measured alignment rather than an implementation variable")
    }

    func testEnoughAttemptsWithoutSuccessExplainsNoRecognitionAndRecoverySteps() {
        var accumulator = ImmersalLocalizationQualityAccumulator()
        for index in 0..<20 {
            accumulator.record(success: false, elapsed: Double(index) * 2, latency: 1)
        }
        let result = report(accumulator)
        XCTAssertFalse(result.sampleSufficient, "Zero matches cannot support a stability assessment")
        XCTAssertEqual(result.qualitySummary, "本次未能识别此空间")
        let advice = result.recommendations.joined(separator: " ")
        for topic in ["原地图", "光照", "已扫描位置", "补采"] {
            XCTAssertTrue(advice.contains(topic), "Recovery guidance must address \(topic)")
        }
        XCTAssertFalse(advice.contains("累计位移达到"), "A session with no matches cannot satisfy a matched-travel instruction")
    }

    func testBriefFailureOnlySessionsRemainInsufficientBeforeAttemptAndDurationThresholds() {
        for (count, interval) in [(19, 2.0), (20, 0.5)] {
            var accumulator = ImmersalLocalizationQualityAccumulator()
            for index in 0..<count {
                accumulator.record(success: false, elapsed: Double(index) * interval, latency: 1)
            }
            XCTAssertEqual(report(accumulator).qualitySummary, "样本不足，暂不评价地图表现")
        }
    }

    func testFreshAccumulatorAfterTrackingResetDoesNotCompareAcrossCoordinateWorlds() {
        var oldSession = samples(count: 20, duration: 40, travel: 4)
        oldSession.record(success: true, elapsed: 42, latency: 1, worldFromMap: pose(x: 100))
        var restarted = ImmersalLocalizationQualityAccumulator()
        restarted.record(success: true, elapsed: 100, latency: 0.5,
                         worldFromMap: pose(x: -200), cameraPosition: SIMD3(-50, 0, 0))
        let result = report(restarted)
        XCTAssertEqual(result.attemptCount, 1)
        XCTAssertEqual(result.duration, 0.5)
        XCTAssertEqual(result.firstSuccessSeconds, 0.5)
        XCTAssertEqual(result.testedTravelMeters, 0)
        XCTAssertNil(result.p95TranslationDeltaMeters)
        XCTAssertFalse(result.sampleSufficient)
    }

    func testReportCodableRoundTripContainsOnlyMeasuredNumbersAndMetadata() throws {
        let expected = report(samples(count: 20, duration: 30, travel: 3))
        let data = try JSONEncoder().encode(expected)
        XCTAssertEqual(try JSONDecoder().decode(ImmersalLocalizationQualityReport.self, from: data), expected)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["mapID"] as? Int, 123)
        XCTAssertEqual(object["userID"] as? Int, 7)
        XCTAssertNil(object["worldFromMap"])
        XCTAssertNil(object["cameraPosition"])
        XCTAssertNil(object["token"])
    }

    private func report(_ accumulator: ImmersalLocalizationQualityAccumulator) -> ImmersalLocalizationQualityReport {
        accumulator.report(mapID: 123, userID: 7, date: date)
    }

    private func samples(count: Int, duration: Double, travel: Float) -> ImmersalLocalizationQualityAccumulator {
        var accumulator = ImmersalLocalizationQualityAccumulator()
        for index in 0..<count {
            let fraction = Double(index) / Double(max(1, count - 1))
            accumulator.record(success: true, elapsed: fraction * max(0, duration - 1), latency: 1,
                               worldFromMap: pose(), cameraPosition: SIMD3(Float(fraction) * travel, 0, 0))
        }
        return accumulator
    }

    private func pose(x: Float = 0, degrees: Float = 0) -> simd_float4x4 {
        var value = simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0)))
        value.columns.3 = SIMD4(x, 0, 0, 1)
        return value
    }
}
