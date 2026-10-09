import XCTest
import simd
#if canImport(UIKit)
import UIKit
import SwiftUI
import Vision
#endif
@testable import AreaTargetScanner

final class LocalizationBenchmarkAnalysisTests: XCTestCase {
    func testPairedReplayComparesMeasuredValuesAndFrozenScoreContributions() throws {
        let report = fixture()
        let analysis = LocalizationBenchmarkAnalysis(comparison: report)
        let rate = try metric(.successRate, in: analysis)
        XCTAssertEqual(try XCTUnwrap(rate.areaTargetValue), 80, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(rate.immersalValue), 90, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(rate.delta), -10, accuracy: 0.0001)
        XCTAssertEqual(rate.deltaUnit, "百分点")
        XCTAssertEqual(rate.direction, .immersalBetter)
        let latency = try metric(.p95LatencySeconds, in: analysis)
        XCTAssertEqual(latency.delta, 5)
        XCTAssertEqual(latency.areaTargetToImmersalRatio, 6)
        XCTAssertEqual(latency.direction, .immersalBetter)
        XCTAssertEqual(try metric(.firstRecognitionSeconds, in: analysis).areaTargetValue, 24)
        XCTAssertEqual(try metric(.firstSuccessCaptureOffset, in: analysis).areaTargetValue, 6)
        XCTAssertEqual(try metric(.firstSuccessLatencySeconds, in: analysis).areaTargetValue, 6)
        XCTAssertEqual(try metric(.score, in: analysis).areaTargetValue, 82)
        XCTAssertEqual(analysis.scoreContributions.map(\.maximumPoints), [40, 20, 20, 20])
        XCTAssertEqual(analysis.scoreContributions.compactMap(\.areaTargetPoints), [32, 10, 20, 20])
        XCTAssertEqual(analysis.scoreContributions.compactMap(\.immersalPoints), [36, 20, 20, 20])
        XCTAssertTrue(analysis.scoresComparable)
        XCTAssertFalse(analysis.promotionEligible)
        XCTAssertEqual(analysis.commonSuccessfulFrameCount, 16)
        XCTAssertEqual(analysis.pairedTraceStatus, .measured)
        let decoded = try JSONDecoder().decode(LocalizationBenchmarkAnalysis.self, from: JSONEncoder().encode(analysis))
        XCTAssertEqual(decoded, analysis)
    }

    func testMissingAlignmentSuppressesScoreButKeepsRawRecognitionAndLatency() throws {
        let analysis = LocalizationBenchmarkAnalysis(comparison: fixture(aligned: false))
        XCTAssertFalse(analysis.scoresComparable)
        XCTAssertNil(try metric(.score, in: analysis).areaTargetValue)
        XCTAssertNil(try metric(.p95TranslationDeltaMeters, in: analysis).areaTargetValue)
        XCTAssertEqual(try metric(.p95TranslationDeltaMeters, in: analysis).status, .notMeasured)
        XCTAssertEqual(try metric(.successRate, in: analysis).areaTargetValue, 80)
        XCTAssertEqual(try metric(.p95LatencySeconds, in: analysis).areaTargetValue, 6)
        XCTAssertTrue(analysis.scoreContributions.allSatisfy { $0.areaTargetPoints == nil })
        XCTAssertTrue(analysis.recommendations.contains { $0.id == "score-gate" })
    }

    func testInsufficientSampleDoesNotInventScoresAndMissingTraceStaysUnmeasured() throws {
        let analysis = LocalizationBenchmarkAnalysis(comparison: fixture(count: 2, traced: false))
        XCTAssertNil(try metric(.score, in: analysis).delta)
        XCTAssertEqual(try metric(.score, in: analysis).direction, .notComparable)
        XCTAssertFalse(analysis.scoresComparable)
        XCTAssertNil(analysis.commonSuccessfulFrameCount)
        XCTAssertEqual(analysis.pairedTraceStatus, .notMeasured)
        XCTAssertTrue(analysis.traces.allSatisfy { $0.longestFailureStreak == nil && $0.failureStreaks == nil })
        for key in [LocalizationBenchmarkMetricKey.absoluteAccuracy, .falseRecognitionRate, .sdkConfidence, .cpuUsage, .memoryUsage, .powerUsage] {
            let unmeasured = try metric(key, in: analysis)
            XCTAssertNil(unmeasured.areaTargetValue)
            XCTAssertNil(unmeasured.immersalValue)
            XCTAssertEqual(unmeasured.status, .notMeasured)
        }
    }

    func testFailureStreakRecoveryUsesBothRecordedTimeAndAlgorithmTime() throws {
        let analysis = LocalizationBenchmarkAnalysis(comparison: fixture())
        let trace = try XCTUnwrap(analysis.traces.first { $0.provider == .areaTarget })
        XCTAssertEqual(trace.longestFailureStreak, 3)
        XCTAssertEqual(trace.failureStreakCount, 2)
        XCTAssertEqual(trace.recoveredFailureStreakCount, 2)
        XCTAssertEqual(trace.unrecoveredFailureStreakCount, 0)
        XCTAssertEqual(trace.maximumRecoveryCaptureSeconds, 6)
        XCTAssertEqual(trace.maximumRecoveryAlgorithmSeconds, 24)
        let streaks = try XCTUnwrap(trace.failureStreaks)
        XCTAssertEqual(streaks[0].startSequence, 0)
        XCTAssertEqual(streaks[0].endSequence, 2)
        XCTAssertEqual(streaks[0].recoverySequence, 3)
        XCTAssertEqual(streaks[1].failedFrameCount, 1)
        XCTAssertTrue(analysis.recommendations.contains { $0.id == "failure-streak" })
    }

    func testAllFailedReplayKeepsZeroScoreAndOpenRecoveryUnmeasured() throws {
        let report = fixture(areaFailures: Set(0..<20), immersalFailures: Set(0..<20))
        let analysis = LocalizationBenchmarkAnalysis(comparison: report)
        let trace = try XCTUnwrap(analysis.traces.first { $0.provider == .areaTarget })
        XCTAssertEqual(trace.longestFailureStreak, 20)
        XCTAssertEqual(trace.recoveredFailureStreakCount, 0)
        XCTAssertEqual(trace.unrecoveredFailureStreakCount, 1)
        XCTAssertNil(trace.maximumRecoveryCaptureSeconds)
        XCTAssertNil(trace.maximumRecoveryAlgorithmSeconds)
        XCTAssertEqual(analysis.commonSuccessfulFrameCount, 0)
        XCTAssertEqual(try metric(.score, in: analysis).areaTargetValue, 0)
        XCTAssertEqual(try metric(.score, in: analysis).direction, .equal)
        XCTAssertTrue(analysis.scoreContributions.allSatisfy { $0.areaTargetPoints == 0 && $0.immersalPoints == 0 })
        XCTAssertTrue(analysis.recommendations.contains { $0.id == "recognition" })
    }

    func testRatioWithZeroDenominatorAndEqualValuesDoesNotDivideByZero() throws {
        let analysis = LocalizationBenchmarkAnalysis(comparison: fixture(areaLatency: 0, immersalLatency: 0))
        let value = try metric(.p95LatencySeconds, in: analysis)
        XCTAssertEqual(value.delta, 0)
        XCTAssertNil(value.areaTargetToImmersalRatio)
        XCTAssertEqual(value.direction, .equal)
        XCTAssertEqual(value.status, .measured)
        let faster = LocalizationBenchmarkAnalysis(comparison: fixture(areaLatency: 1, immersalLatency: 6))
        XCTAssertEqual(try metric(.p95LatencySeconds, in: faster).direction, .areaTargetBetter)
    }

    func testTraceMismatchDoesNotPresentInventedCommonFramesOrRecovery() throws {
        var report = fixture()
        var attempts = try XCTUnwrap(report.attempts)
        attempts.append(attempts[0])
        report.attempts = attempts
        let analysis = LocalizationBenchmarkAnalysis(comparison: report)
        XCTAssertEqual(analysis.pairedTraceStatus, .invalid)
        XCTAssertNil(analysis.commonSuccessfulFrameCount)
        XCTAssertFalse(analysis.scoresComparable)
        XCTAssertEqual(try metric(.p95LatencySeconds, in: analysis).direction, .notComparable)
        XCTAssertNil(analysis.traces.first { $0.provider == .areaTarget }?.longestFailureStreak)
        XCTAssertNotNil(analysis.traces.first { $0.provider == .immersal }?.longestFailureStreak)
    }

    func testDifferentTraceFrameTimesCannotClaimPairedSuccessfulCount() throws {
        var report = fixture()
        report.attempts = report.attempts?.map { item in
            LocalizationReplayAttempt(provider: item.provider, sequence: item.sequence,
                captureOffsetSeconds: item.captureOffsetSeconds + (item.provider == .immersal ? 1 : 0),
                latencySeconds: item.latencySeconds, poseReturned: item.poseReturned)
        }
        let analysis = LocalizationBenchmarkAnalysis(comparison: report)
        XCTAssertEqual(analysis.pairedTraceStatus, .unpaired)
        XCTAssertNil(analysis.commonSuccessfulFrameCount)
        XCTAssertFalse(analysis.scoresComparable)
    }

    func testMarkdownIncludesExactValuesIdentityGateUnmeasuredFieldsAndActionableEvidence() throws {
        let report = fixture()
        let analysis = LocalizationBenchmarkAnalysis(comparison: report)
        let markdown = analysis.markdown(comparison: report)
        XCTAssertTrue(markdown.contains("areaTarget-map"))
        XCTAssertTrue(markdown.contains("immersal-map"))
        XCTAssertTrue(markdown.contains(report.queryFingerprint))
        XCTAssertTrue(markdown.contains("Area Target → Immersal"))
        XCTAssertTrue(markdown.contains("82"))
        XCTAssertTrue(markdown.contains("40/20/20/20"))
        XCTAssertTrue(markdown.contains("not_measured"))
        XCTAssertTrue(markdown.contains("promotionEligible: false"))
        XCTAssertTrue(markdown.contains("独立真值"))
        XCTAssertTrue(markdown.contains("证据："))
        XCTAssertTrue(markdown.contains("待验证假设："))
        XCTAssertTrue(markdown.contains("下一次实验："))
        XCTAssertTrue(markdown.contains("验收标准："))
        XCTAssertTrue(markdown.contains("| 序号 | 引擎 | 采集偏移 (s) | 算法耗时 (s) | 返回姿态 |"))
        XCTAssertTrue(markdown.contains("| 0 | Area Target | 0.0 | 6.0 | false |"))
        XCTAssertTrue(analysis.recommendations.allSatisfy {
            !$0.evidence.isEmpty && !$0.hypothesis.isEmpty && !$0.nextExperiment.isEmpty && !$0.acceptanceCriterion.isEmpty
        })
    }

    func testMarkdownPreservesRecordingAndRuntimeIdentityWithoutInferringAnotherCollection() {
        var report = fixture()
        let recordingID = UUID()
        report.recording = .init(id: recordingID, date: Date(timeIntervalSince1970: 0),
            sourceFingerprint: report.sourceFingerprint, inputDigest: report.queryFingerprint,
            frameCount: 20, duration: 38, context: .init(deviceModel: "fixture-phone", systemVersion: "fixture-os",
                appVersion: "2", appBuild: "3", previewDroppedFrames: 4))
        report.runtimeContext = .init(deviceModel: "fixture-phone", systemVersion: "fixture-os",
            appVersion: "2", appBuild: "3", thermalState: "serious")
        let markdown = LocalizationBenchmarkAnalysis(comparison: report).markdown(comparison: report)
        XCTAssertTrue(markdown.contains(recordingID.uuidString))
        XCTAssertTrue(markdown.contains("fixture-phone"))
        XCTAssertTrue(markdown.contains("serious"))
        XCTAssertTrue(markdown.contains("预览丢帧：4"))
        XCTAssertTrue(markdown.contains("dense-gray8"))
        XCTAssertTrue(markdown.contains("nearest-neighbor-once-before-replay"))
        XCTAssertTrue(markdown.contains("不构成新增独立采集"))
    }

    func testThresholdChangesDoNotChangeVersionOneScoreContributions() {
        var thresholds = LocalizationEvaluationThresholds()
        thresholds.maximumP95LatencySeconds = 99
        thresholds.maximumP95TranslationDeltaMeters = 99
        thresholds.maximumP95RotationDeltaDegrees = 99
        let analysis = LocalizationBenchmarkAnalysis(comparison: fixture(thresholds: thresholds))
        XCTAssertEqual(analysis.scoreContributions.compactMap(\.areaTargetPoints), [32, 10, 20, 20])
        XCTAssertEqual(analysis.scoreContributions.compactMap(\.reference), [3, 0.25, 5])
    }

    #if canImport(UIKit)
    @MainActor
    func testPhoneReportSnapshotsForManualReview() async throws {
        let scenarios: [(String, CGFloat, ContentSizeCategory, LocalizationComparisonReport, [String], Bool)] = [
            ("320pt-comparable", 320, .large, fixture(), ["同帧结果分析", "位姿返回率", "82", "96"], false),
            ("320pt-accessibility", 320, .accessibilityExtraExtraExtraLarge, fixture(), ["同帧结果分析", "Area", "82"], false),
            ("390pt-insufficient-missing-traces", 390, .large, fixture(count: 2, traced: false),
                ["同帧结果分析", "本次证据不足", "暂不评分"], true)
        ]
        for (name, width, category, report, expected, showMissingTraces) in scenarios {
            try await attachPhoneReport(
                ScrollView {
                    LocalizationBenchmarkAnalysisView(comparison: report).padding(12)
                }
                .frame(width: width, height: 844)
                .background(Color(uiColor: .systemGroupedBackground)),
                name: name, width: width, category: category, expected: expected, showMissingTraces: showMissingTraces)
        }
    }

    /// ScrollView has UIKit-backed content that ImageRenderer can omit. Mount
    /// the actual report in a native window and assert visible pixels with OCR.
    @MainActor
    private func attachPhoneReport<V: View>(_ view: V, name: String, width: CGFloat, category: ContentSizeCategory,
        expected: [String], showMissingTraces: Bool) async throws {
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: view
            .environment(\.scenePhase, .active)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.sizeCategory, category))
        let bounds = CGRect(x: 0, y: 0, width: width, height: 844)
        let window = UIWindow(frame: bounds)
        host.overrideUserInterfaceStyle = .light; window.overrideUserInterfaceStyle = .light
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        host.view.frame = bounds
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 350_000_000)
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func screenshot() -> UIImage {
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                rendered = host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(rendered, "The native \(name) report must finish rendering.")
            return image
        }
        var image = screenshot()
        var recognized = try recognizedPhoneContents(image)
        let headerEvidence = XCTAttachment(string: recognized)
        headerEvidence.name = "benchmark-analysis-\(name)-initial-visible-text"
        headerEvidence.lifetime = .keepAlways; add(headerEvidence)
        for value in expected {
            XCTAssertTrue(normalizedPhoneText(recognized).contains(normalizedPhoneText(value)),
                "\(name) must visibly render \(value). Recognized pixels: \(recognized)")
        }
        if showMissingTraces {
            let scroll = try XCTUnwrap(reportScrollView(in: host.view), "The report must have a real scrollable viewport.")
            let maximum = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            for offset in stride(from: CGFloat(0), through: maximum, by: bounds.height * 0.6) {
                scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                host.view.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 80_000_000)
                image = screenshot(); recognized = try recognizedPhoneContents(image)
                if normalizedPhoneText(recognized).contains("逐帧记录未测量") { break }
            }
            for value in ["共同成功帧", "逐帧记录未测量"] {
                XCTAssertTrue(normalizedPhoneText(recognized).contains(value),
                    "\(name) must visibly preserve the missing-trace warning. Recognized pixels: \(recognized)")
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "benchmark-analysis-\(name)"
        attachment.lifetime = .keepAlways; add(attachment)
        let evidence = XCTAttachment(string: recognized)
        evidence.name = "benchmark-analysis-\(name)-recognized-text"
        evidence.lifetime = .keepAlways; add(evidence)
    }

    private func recognizedPhoneContents(_ image: UIImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage), options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func normalizedPhoneText(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    @MainActor
    private func reportScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
        return view.subviews.lazy.compactMap { self.reportScrollView(in: $0) }.first
    }
    #endif

    private func metric(_ key: LocalizationBenchmarkMetricKey, in analysis: LocalizationBenchmarkAnalysis) throws -> LocalizationBenchmarkMetricComparison {
        try XCTUnwrap(analysis.metrics.first { $0.key == key })
    }

    private func fixture(count: Int = 20, aligned: Bool = true, traced: Bool = true,
                         areaFailures: Set<Int> = [0, 1, 2, 10], immersalFailures: Set<Int> = [0, 1],
                         areaLatency: Double = 6, immersalLatency: Double = 1,
                         thresholds: LocalizationEvaluationThresholds = .init()) -> LocalizationComparisonReport {
        let source = String(repeating: "a", count: 64)
        var results: [LocalizationEvaluationReport] = []
        var attempts: [LocalizationReplayAttempt] = []
        for provider in [LocalizationProvider.areaTarget, .immersal] {
            let failures = provider == .areaTarget ? areaFailures : immersalFailures
            let latency = provider == .areaTarget ? areaLatency : immersalLatency
            let identity = LocalizationAssetIdentity(provider: provider, assetID: "\(provider.rawValue)-map",
                sourceFingerprint: source, engineVersion: "fixture-v1", assetDigest: String(repeating: "b", count: 64),
                buildConfiguration: "fixture-config")
            var accumulator = LocalizationEvaluationAccumulator(identity: identity, timingMode: .recordedReplay, thresholds: thresholds)
            for sequence in 0..<count {
                var alignment = matrix_identity_float4x4
                alignment.columns.3.x = Float(sequence) * 0.02
                let success = !failures.contains(sequence)
                accumulator.record(sequence: sequence, captureTime: Double(sequence) * 2, latency: latency,
                    cameraPosition: SIMD3(Float(sequence) * 0.2, 0, 0), worldFromScan: success ? alignment : nil,
                    commonAlignmentValid: aligned)
                attempts.append(.init(provider: provider, sequence: sequence, captureOffsetSeconds: Double(sequence) * 2,
                    latencySeconds: latency, poseReturned: success))
            }
            results.append(accumulator.report(date: Date(timeIntervalSince1970: 0)))
        }
        var report = LocalizationComparisonReport(id: UUID(), date: Date(timeIntervalSince1970: 0),
            queryFingerprint: String(repeating: "c", count: 64), sourceFingerprint: source,
            executionOrder: [.areaTarget, .immersal], results: results)
        report.attempts = traced ? attempts : nil
        return report
    }
}
