import XCTest
import simd
@testable import AreaTargetScanner

@MainActor
final class LocalizationComparisonTests: XCTestCase {
    func testEveryAttemptExportsPairedEvidenceIncludingFailures() async throws {
        let area = FakeReplay(provider: .areaTarget); area.failures = [1]
        let immersal = FakeReplay(provider: .immersal)
        let result = try await LocalizationComparisonRunner().run(frames: try (0..<3).map { try frame($0) }, engines: [area, immersal])
        let attempts = try XCTUnwrap(result.attempts)
        XCTAssertEqual(attempts.count, 6)
        XCTAssertEqual(attempts.map(\.sequence), [0,1,2,0,1,2])
        XCTAssertEqual(attempts.map(\.poseReturned), [true,false,true,true,true,true])
        XCTAssertEqual(attempts.prefix(3).map(\.captureOffsetSeconds), attempts.suffix(3).map(\.captureOffsetSeconds))
        XCTAssertTrue(attempts.allSatisfy { $0.latencySeconds.isFinite && $0.latencySeconds >= 0 })
    }

    func testBothEnginesReceiveExactlySameImmutableFramesAndFailures() async throws {
        let frames = try (0..<22).map { try frame($0) }
        let area = FakeReplay(provider: .areaTarget)
        let immersal = FakeReplay(provider: .immersal)
        area.failures = [3, 6]; immersal.failures = [3]
        let runner = LocalizationComparisonRunner()
        let report = try await runner.run(frames: frames, engines: [area, immersal])
        XCTAssertEqual(area.inputs, immersal.inputs)
        XCTAssertEqual(area.inputs.count, 22)
        XCTAssertEqual(report.results.map(\.attemptCount), [22,22])
        XCTAssertEqual(report.results.map(\.successCount), [20,21])
        XCTAssertEqual(report.executionOrder, [.areaTarget,.immersal])
        XCTAssertEqual(area.prepares, 1); XCTAssertEqual(immersal.prepares, 1)
        XCTAssertGreaterThanOrEqual(area.closes, 1); XCTAssertGreaterThanOrEqual(immersal.closes, 1)
    }
    func testUnknownOrDifferentSourceCannotBePresentedAsPairedComparison() async throws {
        let frames = [try frame(0)]
        let runner = LocalizationComparisonRunner()
        do { _ = try await runner.run(frames: frames, engines: [
            FakeReplay(provider: .areaTarget), FakeReplay(provider: .immersal, fingerprint: String(repeating: "b", count: 64))
        ]); XCTFail("different scan accepted") } catch {}
        do { _ = try await runner.run(frames: frames, engines: [
            FakeReplay(provider: .areaTarget), FakeReplay(provider: .immersal, fingerprint: nil)
        ]); XCTFail("unknown scan accepted") } catch {}
    }
    func testCalibrationFailureKeepsRawRecognitionButSuppressesScore() async throws {
        let area = FakeReplay(provider: .areaTarget)
        let immersal = FakeReplay(provider: .immersal); immersal.aligned = false
        let result = try await LocalizationComparisonRunner().run(frames: try (0..<22).map {try frame($0)}, engines: [area, immersal])
        XCTAssertEqual(result.results[1].successCount, 22)
        XCTAssertNil(result.results[1].score)
        XCTAssertEqual(result.results[1].eligibility, .missingCommonAlignment)
    }
    func testCancelRejectsLateEngineResultAndClosesBoth() async throws {
        let runner = LocalizationComparisonRunner()
        let area = FakeReplay(provider: .areaTarget); area.suspend = true
        let immersal = FakeReplay(provider: .immersal)
        let task = Task { try await runner.run(frames: [try frame(0)], engines: [area, immersal]) }
        for _ in 0..<1000 where area.pending == nil { await Task.yield() }
        guard area.pending != nil else {
            runner.cancel()
            _ = try? await task.value
            XCTFail("engine was not invoked"); return
        }
        runner.cancel()
        area.pending?.resume(returning: matrix_identity_float4x4); area.pending = nil
        do { _ = try await task.value; XCTFail("stale result accepted") } catch {}
        XCTAssertTrue(immersal.inputs.isEmpty)
        XCTAssertFalse(runner.isRunning)
        XCTAssertGreaterThanOrEqual(area.closes, 1)
    }
    func testRecorderBoundsIntervalAndDenseInput() throws {
        var recorder = LocalizationQueryRecorder()
        XCTAssertTrue(recorder.append(try frame(0), trackingNormal: true))
        XCTAssertFalse(recorder.append(try frame(0, time: 0.5), trackingNormal: true))
        XCTAssertFalse(recorder.append(try frame(1), trackingNormal: false))
        for n in 1..<32 { XCTAssertTrue(recorder.append(try frame(n), trackingNormal: true)) }
        XCTAssertFalse(recorder.append(try frame(32), trackingNormal: true))
        XCTAssertEqual(recorder.frames.count, 32)
        XCTAssertTrue(recorder.isFull)
        XCTAssertThrowsError(try LocalizationQueryFrame(sequence: 0, timestamp: 1, pixels: Data([1]), width: 2,
            height: 2, intrinsics: SIMD4(2,2,1,1), worldFromCamera: matrix_identity_float4x4))
    }
    func testCanceledOldCompletionCannotCloseReusedEnginesInNewRun() async throws {
        let runner = LocalizationComparisonRunner()
        let area = FakeReplay(provider: .areaTarget); area.suspend = true
        let immersal = FakeReplay(provider: .immersal)
        let frames = [try frame(0)]
        let old = Task { try await runner.run(frames: frames, engines: [area, immersal]) }
        for _ in 0..<1000 where area.pending == nil { await Task.yield() }
        let oldPending = try XCTUnwrap(area.pending)
        runner.cancel(); area.suspend = false; immersal.suspend = true
        let newer = Task { try await runner.run(frames: frames, engines: [area, immersal]) }
        for _ in 0..<1000 where immersal.pending == nil { await Task.yield() }
        let newPending = try XCTUnwrap(immersal.pending)
        let closes = immersal.closes
        oldPending.resume(returning: matrix_identity_float4x4)
        do { _ = try await old.value; XCTFail("abandoned run accepted") } catch {}
        XCTAssertTrue(runner.isRunning)
        XCTAssertEqual(immersal.closes, closes)
        newPending.resume(returning: matrix_identity_float4x4)
        _ = try await newer.value
        XCTAssertFalse(runner.isRunning)
    }
    func testOneSharedResizePreservesIntrinsicsAndPixelIdentity() throws {
        let raw = Data((0..<3840*2).map { UInt8($0 % 251) })
        let frame = try LocalizationQueryFrame(sequence: 1, timestamp: 3, pixels: raw, width: 3840, height: 2,
            intrinsics: SIMD4(2000,2000,1920,1), worldFromCamera: matrix_identity_float4x4)
        XCTAssertEqual(frame.width, 1920); XCTAssertEqual(frame.height, 1)
        XCTAssertEqual(frame.pixels.count, 1920)
        XCTAssertEqual(frame.intrinsics, SIMD4(1000,1000,960,0.5))
        XCTAssertEqual(frame.pixels[9], raw[18])
    }
    func testHistoryIsBoundToExactMapPairAndEngineConfiguration() async throws {
        let report = try await LocalizationComparisonRunner().run(frames: [try frame(0)],
            engines: [FakeReplay(provider: .areaTarget), FakeReplay(provider: .immersal)])
        let ids = report.results.map(\.identity)
        XCTAssertTrue(report.matches(identities: ids))
        let original = ids[0]
        let changes: [LocalizationAssetIdentity] = [
            .init(provider: original.provider, assetID: "rebuilt-map", sourceFingerprint: original.sourceFingerprint, engineVersion: original.engineVersion),
            .init(provider: original.provider, assetID: original.assetID, sourceFingerprint: original.sourceFingerprint, engineVersion: "new-engine"),
            .init(provider: original.provider, assetID: original.assetID, sourceFingerprint: original.sourceFingerprint, engineVersion: original.engineVersion, assetDigest: String(repeating: "c", count: 64)),
            .init(provider: original.provider, assetID: original.assetID, sourceFingerprint: original.sourceFingerprint, engineVersion: original.engineVersion, buildConfiguration: "changed-profile")
        ]
        for changed in changes {
            XCTAssertFalse(report.matches(identities: [changed, ids[1]]), "The same source scan does not make a changed map or configuration the same tested asset")
        }
        XCTAssertFalse(report.matches(identities: ids.reversed()))
    }
    private func frame(_ n: Int, time: Double? = nil) throws -> LocalizationQueryFrame {
        var pose = matrix_identity_float4x4; pose.columns.3.x = Float(n) * 0.2
        return try LocalizationQueryFrame(sequence: n, timestamp: time ?? Double(n) * 1.5,
            pixels: Data([UInt8(n % 255),2,3,4]), width: 2, height: 2,
            intrinsics: SIMD4(2,2,1,1), worldFromCamera: pose)
    }
}

@MainActor
private final class FakeReplay: LocalizationReplayEngine {
    let identity: LocalizationAssetIdentity
    var inputs: [String] = []
    var failures = Set<Int>()
    var prepares = 0
    var closes = 0
    var aligned = true
    var suspend = false
    var pending: CheckedContinuation<simd_float4x4?, Never>?
    init(provider: LocalizationProvider, fingerprint: String? = String(repeating: "a", count: 64)) {
        identity = .init(provider: provider, assetID: provider.rawValue, sourceFingerprint: fingerprint, engineVersion: "fixture")
    }
    func prepare() async throws -> Bool { prepares += 1; return aligned }
    func localize(frame: LocalizationQueryFrame) async -> simd_float4x4? {
        inputs.append("\(frame.sequence):\(frame.timestamp):\(frame.pixels.base64EncodedString()):\(frame.intrinsics)")
        if suspend { return await withCheckedContinuation { pending = $0 } }
        return failures.contains(frame.sequence) ? nil : matrix_identity_float4x4
    }
    func close() { closes += 1 }
}
