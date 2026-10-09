import XCTest
import ARKit
import simd
@testable import AreaTargetScanner

@MainActor
final class LocalizationComparisonSessionTests: XCTestCase {
    private var root: URL!
    private var sessions: [LocalizationComparisonSession] = []
    private let source = String(repeating: "a", count: 64)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ComparisonSession-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        sessions.forEach { $0.cancel() }
        sessions = []
        try? FileManager.default.removeItem(at: root)
    }

    func testPermissionDenialDoesNotStartCameraOrPrepareEitherEngine() async throws {
        let camera = ComparisonCameraProbe()
        let (area, immersal) = engines()
        let session = makeSession(camera: camera, requestCamera: { camera.requests += 1; return false })
        session.start(engines: [area, immersal])
        try await eventually { camera.requests == 1 && session.stage == .idle }
        XCTAssertFalse(session.active)
        XCTAssertEqual(camera.starts, 0)
        XCTAssertEqual(area.prepares, 0)
        XCTAssertEqual(immersal.prepares, 0)
        XCTAssertNil(session.report)
        XCTAssertNil(session.reportURL)
    }

    func testLatePermissionFromCanceledGenerationCannotAffectNewCapture() async throws {
        let camera = ComparisonCameraProbe()
        let permission = ComparisonPermissionGate()
        let (area, immersal) = engines()
        let session = makeSession(camera: camera, requestCamera: { await permission.request() })
        defer { permission.resolve(false) }
        session.start(engines: [area, immersal])
        try await eventually { permission.pending != nil }
        session.cancel()
        session.start(engines: [area, immersal])
        try await eventually { session.stage == .capturing && permission.requests == 2 }
        permission.resolve(false)
        try await eventually { permission.resumedRequests == 1 }
        await settle()
        XCTAssertEqual(session.stage, .capturing)
        XCTAssertEqual(camera.starts, 1)
        XCTAssertNil(session.report)
        XCTAssertEqual(area.prepares, 0)
    }

    func testDifferentScanSourcesAreRejectedBeforeRequestingPermission() {
        let camera = ComparisonCameraProbe()
        let area = ComparisonSessionEngine(provider: .areaTarget, source: source)
        let immersal = ComparisonSessionEngine(provider: .immersal, source: String(repeating: "b", count: 64))
        let session = makeSession(camera: camera, requestCamera: { camera.requests += 1; return true })
        session.start(engines: [area, immersal])
        XCTAssertEqual(session.stage, .idle)
        XCTAssertEqual(camera.requests, 0)
        XCTAssertEqual(camera.starts, 0)
        XCTAssertFalse(session.active)
    }

    func testEmptyCaptureCannotProduceAnEvaluationReport() async throws {
        let camera = ComparisonCameraProbe()
        let (area, immersal) = engines()
        let session = makeSession(camera: camera)
        session.start(engines: [area, immersal])
        try await eventually { session.stage == .capturing }
        session.finishCapture()
        XCTAssertEqual(session.stage, .idle)
        XCTAssertNil(session.report)
        XCTAssertEqual(area.prepares, 0)
        XCTAssertEqual(immersal.prepares, 0)
    }

    func testTwentyTwoNormalFramesReplayIdenticallyAndPersistReport() async throws {
        let camera = ComparisonCameraProbe()
        let (area, immersal) = engines()
        area.failures = [4]
        immersal.failures = [4, 8]
        let store = LocalizationReportStore(rootDirectory: root.appendingPathComponent("reports"))
        let session = makeSession(camera: camera, store: store)
        session.start(engines: [area, immersal])
        try await eventually { session.stage == .capturing }
        for n in 0..<22 { session.record(try frame(n), trackingNormal: true) }
        XCTAssertEqual(session.frameCount, 22)
        XCTAssertEqual(session.duration, 31.5, accuracy: 0.0001)
        session.finishCapture()
        try await eventually { session.stage == .finished }
        let report = try XCTUnwrap(session.report)
        let url = try XCTUnwrap(session.reportURL)
        XCTAssertFalse(session.active)
        XCTAssertEqual(report.results.map(\.attemptCount), [22, 22])
        XCTAssertEqual(report.results.map(\.successCount), [21, 20])
        XCTAssertEqual(report.results.map(\.timingMode), [.recordedReplay, .recordedReplay])
        XCTAssertTrue(report.hasComparableScores)
        XCTAssertEqual(area.inputs, immersal.inputs)
        XCTAssertEqual(area.inputs.count, 22)
        XCTAssertEqual(area.inputs, try (0..<22).map { ComparisonFrameSnapshot(try frame($0)) })
        XCTAssertEqual(area.prepares, 1)
        XCTAssertEqual(immersal.prepares, 1)
        XCTAssertEqual(camera.starts, 1)
        XCTAssertEqual(try store.latestComparison(sourceFingerprint: source)?.id, report.id)
        XCTAssertEqual(try store.latestComparisonURL(sourceFingerprint: source), url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testTrackingLossDiscardsBatchAndNextCaptureHasOnlyNewFrames() async throws {
        let camera = ComparisonCameraProbe()
        let (area, immersal) = engines()
        let session = makeSession(camera: camera)
        session.start(engines: [area, immersal])
        try await eventually { session.stage == .capturing }
        session.record(try frame(0), trackingNormal: true)
        session.record(try frame(1), trackingNormal: true)
        session.record(try frame(2), trackingNormal: false)
        XCTAssertEqual(session.stage, .idle)
        XCTAssertEqual(session.frameCount, 0)
        XCTAssertEqual(session.duration, 0)
        XCTAssertNil(session.report)
        session.start(engines: [area, immersal])
        try await eventually { session.stage == .capturing }
        session.record(try frame(100), trackingNormal: true)
        session.finishCapture()
        try await eventually { session.stage == .finished }
        XCTAssertEqual(area.inputs.map(\.sequence), [100])
        XCTAssertEqual(immersal.inputs.map(\.sequence), [100])
        XCTAssertEqual(session.report?.results.map(\.attemptCount), [1, 1])
    }

    func testLimitedTrackingBeforeFirstNormalFrameDoesNotEnterBatch() async throws {
        let camera = ComparisonCameraProbe()
        let (area, immersal) = engines()
        let session = makeSession(camera: camera)
        session.start(engines: [area, immersal])
        try await eventually { session.stage == .capturing }
        session.record(try frame(0), trackingNormal: false)
        XCTAssertEqual(session.stage, .capturing)
        XCTAssertEqual(session.frameCount, 0)
        session.record(try frame(1), trackingNormal: true)
        session.finishCapture()
        try await eventually { session.stage == .finished }
        XCTAssertEqual(area.inputs.map(\.sequence), [1])
        XCTAssertEqual(immersal.inputs.map(\.sequence), [1])
    }

    func testThirtyTwoFramesAutomaticallyFinishCaptureAndReplay() async throws {
        let camera = ComparisonCameraProbe()
        let (area, immersal) = engines()
        let session = makeSession(camera: camera)
        session.start(engines: [area, immersal])
        try await eventually { session.stage == .capturing }
        for n in 0..<32 { session.record(try frame(n), trackingNormal: true) }
        XCTAssertEqual(session.stage, .replaying)
        try await eventually { session.stage == .finished }
        XCTAssertEqual(session.frameCount, 32)
        XCTAssertEqual(session.report?.results.map(\.attemptCount), [32, 32])
        XCTAssertEqual(area.inputs, immersal.inputs)
        XCTAssertEqual(area.inputs.count, 32)
    }

    func testFrameExceedingByteBudgetFinishesExistingTwentySevenFrameBatch() async throws {
        let camera = ComparisonCameraProbe()
        let (area, immersal) = engines()
        let session = makeSession(camera: camera)
        session.start(engines: [area, immersal])
        try await eventually { session.stage == .capturing }
        for n in 0..<27 { session.record(try frame(n, edge: 1920), trackingNormal: true) }
        XCTAssertEqual(session.stage, .capturing)
        XCTAssertEqual(session.frameCount, 27)
        session.record(try frame(27, edge: 1920), trackingNormal: true)
        XCTAssertEqual(session.stage, .replaying)
        try await eventually(timeout: 8) { session.stage == .finished }
        XCTAssertEqual(session.report?.results.map(\.attemptCount), [27, 27])
        XCTAssertEqual(area.inputs, immersal.inputs)
        XCTAssertEqual(area.inputs.map(\.sequence), Array(0..<27))
        XCTAssertLessThanOrEqual(area.inputs.reduce(0) { $0 + $1.pixels.count }, LocalizationQueryRecorder.maximumPixelBytes)
    }

    func testCanceledReplayCannotPublishLateReportOrRunSecondEngine() async throws {
        let camera = ComparisonCameraProbe()
        let (area, immersal) = engines()
        area.suspend = true
        let session = makeSession(camera: camera)
        defer { area.resolve(nil) }
        session.start(engines: [area, immersal])
        try await eventually { session.stage == .capturing }
        session.record(try frame(0), trackingNormal: true)
        session.finishCapture()
        try await eventually { area.pending != nil }
        session.cancel(message: "canceled fixture")
        area.resolve(matrix_identity_float4x4)
        try await eventually { area.returnedCount == 1 }
        await settle()
        XCTAssertEqual(session.stage, .idle)
        XCTAssertFalse(session.active)
        XCTAssertFalse(session.runner.isRunning)
        XCTAssertEqual(session.status, "canceled fixture")
        XCTAssertNil(session.report)
        XCTAssertNil(session.reportURL)
        XCTAssertTrue(immersal.inputs.isEmpty)
        XCTAssertEqual(immersal.prepares, 0)
        XCTAssertGreaterThanOrEqual(area.closes, 1)
        XCTAssertGreaterThanOrEqual(immersal.closes, 1)
    }

    func testFailedSaveRetainsReportAndCanRetryAfterRepairingDirectory() async throws {
        let camera = ComparisonCameraProbe()
        let (area, immersal) = engines()
        let blockedRoot = root.appendingPathComponent("blocked-root")
        try Data("ordinary file".utf8).write(to: blockedRoot)
        let store = LocalizationReportStore(rootDirectory: blockedRoot)
        let session = makeSession(camera: camera, store: store)
        session.start(engines: [area, immersal])
        try await eventually { session.stage == .capturing }
        for n in 0..<22 { session.record(try frame(n), trackingNormal: true) }
        session.finishCapture()
        try await eventually { session.stage == .finished }
        let report = try XCTUnwrap(session.report)
        XCTAssertNil(session.reportURL)
        let failedSave = await session.ensureReportSaved()
        XCTAssertFalse(failedSave)
        XCTAssertEqual(session.report?.id, report.id)
        XCTAssertNil(session.reportURL)
        try FileManager.default.removeItem(at: blockedRoot)
        try FileManager.default.createDirectory(at: blockedRoot, withIntermediateDirectories: false)
        let retry = await session.ensureReportSaved()
        XCTAssertTrue(retry)
        let savedURL = try XCTUnwrap(session.reportURL)
        XCTAssertEqual(try store.latestComparison(sourceFingerprint: source)?.id, report.id)
        let savedAgain = await session.ensureReportSaved()
        XCTAssertTrue(savedAgain)
        XCTAssertEqual(session.reportURL, savedURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: blockedRoot.appendingPathComponent("comparisons"),
            includingPropertiesForKeys: nil).count, 1)
    }

    private func makeSession(camera: ComparisonCameraProbe, requestCamera: (() async -> Bool)? = nil,
                             store: LocalizationReportStore? = nil) -> LocalizationComparisonSession {
        let instance = LocalizationComparisonSession(
            requestCamera: requestCamera ?? { camera.requests += 1; return true },
            runSession: { _ in camera.starts += 1 },
            store: store ?? LocalizationReportStore(rootDirectory: root.appendingPathComponent("reports")))
        sessions.append(instance)
        return instance
    }
    private func engines() -> (ComparisonSessionEngine, ComparisonSessionEngine) {
        (ComparisonSessionEngine(provider: .areaTarget, source: source), ComparisonSessionEngine(provider: .immersal, source: source))
    }
    private func frame(_ n: Int, edge: Int = 2) throws -> LocalizationQueryFrame {
        var camera = matrix_identity_float4x4
        camera.columns.3.x = Float(n) * 0.2
        return try .init(sequence: n, timestamp: Double(n) * 1.5,
            pixels: Data(repeating: UInt8(n % 251), count: edge * edge), width: edge, height: edge,
            intrinsics: SIMD4(Float(edge), Float(edge), Float(edge) / 2, Float(edge) / 2), worldFromCamera: camera)
    }
    private func eventually(timeout: Double = 5, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        if !condition() {
            XCTFail("session did not reach expected state", file: file, line: line)
            throw ComparisonSessionTestFailure.timeout
        }
    }
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

private enum ComparisonSessionTestFailure: Error { case timeout }
@MainActor
private final class ComparisonCameraProbe { var requests = 0; var starts = 0 }

@MainActor
private final class ComparisonPermissionGate {
    var requests = 0
    var resumedRequests = 0
    var pending: CheckedContinuation<Bool, Never>?
    func request() async -> Bool {
        requests += 1
        if requests > 1 { return true }
        let allowed = await withCheckedContinuation { pending = $0 }
        resumedRequests += 1
        return allowed
    }
    func resolve(_ allowed: Bool) {
        let waiting = pending; pending = nil
        waiting?.resume(returning: allowed)
    }
}

private struct ComparisonFrameSnapshot: Equatable {
    let sequence: Int
    let timestamp: Double
    let pixels: Data
    let width: Int
    let height: Int
    let intrinsics: SIMD4<Float>
    let camera: [Float]
    init(_ frame: LocalizationQueryFrame) {
        sequence = frame.sequence; timestamp = frame.timestamp; pixels = frame.pixels
        width = frame.width; height = frame.height; intrinsics = frame.intrinsics
        camera = (0..<4).flatMap { column in (0..<4).map { frame.worldFromCamera[column][$0] } }
    }
}

@MainActor
private final class ComparisonSessionEngine: LocalizationReplayEngine {
    let identity: LocalizationAssetIdentity
    var prepares = 0
    var closes = 0
    var inputs: [ComparisonFrameSnapshot] = []
    var failures = Set<Int>()
    var suspend = false
    var returnedCount = 0
    var pending: CheckedContinuation<simd_float4x4?, Never>?
    init(provider: LocalizationProvider, source: String) {
        identity = .init(provider: provider, assetID: provider.rawValue, sourceFingerprint: source, engineVersion: "fixture")
    }
    func prepare() async throws -> Bool { prepares += 1; return true }
    func localize(frame: LocalizationQueryFrame) async -> simd_float4x4? {
        inputs.append(.init(frame))
        let result: simd_float4x4?
        if suspend { result = await withCheckedContinuation { pending = $0 } }
        else { result = failures.contains(frame.sequence) ? nil : simd_inverse(frame.worldFromCamera) }
        returnedCount += 1
        return result
    }
    func close() { closes += 1 }
    func resolve(_ result: simd_float4x4?) {
        let waiting = pending; pending = nil
        waiting?.resume(returning: result)
    }
}
