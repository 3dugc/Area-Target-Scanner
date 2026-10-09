import XCTest
import simd
@testable import AreaTargetScanner

@MainActor
final class ImmersalLocalizationSessionTests: XCTestCase {
    private var clockNow = 0.0
    private let fingerprint = String(repeating: "a", count: 64)

    override func setUpWithError() throws { clockNow = 0 }

    func testFirstVisualResultRemainsCandidateButCountsAsRawSDKSuccess() async throws {
        let session = makeSession(ImmersalSessionEngine())
        defer { session.stop() }
        await start(session)
        await session.process(try query(sequence: 0, timestamp: 10))
        XCTAssertEqual(session.alignmentState, .candidate)
        XCTAssertNil(session.worldFromMap)
        XCTAssertNil(session.markerInMap)
        XCTAssertNil(session.confidence)
        XCTAssertEqual(session.report?.attemptCount, 1)
        XCTAssertEqual(session.report?.successCount, 1)
        XCTAssertEqual(session.evaluationReport?.successCount, 1)
        XCTAssertEqual(session.evaluationReport?.identity.engineVersion, ImmersalLocalizationSession.engineVersion)
        XCTAssertEqual(session.evaluationReport?.identity.buildConfiguration,
            LocalizationCoreMetadata.immersalLiveBuildConfiguration(base: nil))
    }

    func testCapturedCameraAndImmersalAxesComposeOnceBeforeConfirmation() async throws {
        let result = match(position: SIMD3(1, 2, 3))
        let session = makeSession(ImmersalSessionEngine(results: [result, result]))
        defer { session.stop() }
        await start(session)
        var camera = matrix_identity_float4x4
        camera.columns.3 = SIMD4(5, 2, -3, 1)
        await session.process(try query(sequence: 0, timestamp: 10, camera: camera))
        await session.process(try query(sequence: 1, timestamp: 11.5, camera: camera))
        let actual = try XCTUnwrap(session.worldFromMap)
        XCTAssertEqual(actual.columns.3, SIMD4(4, 4, 0, 1))
        XCTAssertEqual(actual.columns.0.x, 1)
        XCTAssertEqual(actual.columns.1.y, -1)
        XCTAssertEqual(actual.columns.2.z, -1)
        XCTAssertEqual(session.alignmentState, .confirmed)
        XCTAssertNotNil(session.markerInMap)
        XCTAssertEqual(session.confidence, 42)
        XCTAssertEqual(session.report?.successCount, 2)
    }

    func testFailureDegradesBrieflyWithoutInflatingRawSDKOrEvaluationCounts() async throws {
        let session = makeSession(ImmersalSessionEngine(results: [match(), match(), nil]))
        defer { session.stop() }
        await start(session)
        for index in 0..<3 {
            await session.process(try query(sequence: index, timestamp: 10 + Double(index) * 1.5))
        }
        XCTAssertEqual(session.alignmentState, .degraded)
        XCTAssertNotNil(session.worldFromMap)
        XCTAssertNil(session.confidence, "A held pose must not present an old SDK confidence as fresh")
        XCTAssertEqual(session.report?.attemptCount, 3)
        XCTAssertEqual(session.report?.successCount, 2)
        XCTAssertEqual(session.evaluationReport?.attemptCount, 3)
        XCTAssertEqual(session.evaluationReport?.successCount, 2)
        clockNow = 14.5001
        session.checkAlignmentExpiry()
        XCTAssertEqual(session.alignmentState, .lost)
        XCTAssertNil(session.worldFromMap)
        XCTAssertEqual(session.report?.successCount, 2)
        XCTAssertEqual(session.evaluationReport?.attemptCount, 3)
    }

    func testPerFrameExpiryHidesTheOldPoseWhileTheSDKIsStillBusy() async throws {
        let engine = ImmersalSessionEngine(holdFrames: true)
        let session = makeSession(engine)
        defer { session.stop(); engine.releaseAll() }
        await start(session)
        for index in 0..<2 {
            let frame = try query(sequence: index, timestamp: 10 + Double(index) * 1.5)
            let operation = Task { await session.process(frame) }
            await waitUntil { engine.frameCount == index + 1 }
            engine.releaseFrame(index: index, result: match())
            await operation.value
        }
        XCTAssertNotNil(session.worldFromMap)
        let frame = try query(sequence: 2, timestamp: 13)
        let operation = Task { await session.process(frame) }
        await waitUntil { engine.frameCount == 3 }
        clockNow = 14.5001
        session.checkAlignmentExpiry()
        XCTAssertNil(session.worldFromMap)
        XCTAssertNil(session.confidence)
        XCTAssertEqual(session.report?.attemptCount, 2, "The pending SDK request has not produced a new attempt result")
        engine.releaseFrame(index: 2, result: nil)
        await operation.value
        XCTAssertEqual(session.report?.attemptCount, 3)
        XCTAssertEqual(session.report?.successCount, 2)
    }

    func testSameRunLateResultIsMeasuredButCannotCreateVisibleAlignment() async throws {
        let engine = ImmersalSessionEngine(holdFrames: true)
        let session = makeSession(engine)
        defer { session.stop(); engine.releaseAll() }
        await start(session)
        let frame = try query(sequence: 0, timestamp: 10)
        let operation = Task { await session.process(frame) }
        await waitUntil { engine.frameCount == 1 }
        clockNow = 14
        engine.releaseFrame(index: 0, result: match())
        await operation.value
        XCTAssertEqual(session.report?.successCount, 1)
        XCTAssertEqual(session.evaluationReport?.successCount, 1)
        XCTAssertEqual(session.evaluationReport?.p95LatencySeconds, 4)
        // No alignment has ever been confirmed; rejecting this first late result keeps initialization.
        XCTAssertEqual(session.alignmentState, .searching)
        XCTAssertNil(session.worldFromMap)
        XCTAssertNil(session.confidence)
    }

    func testMapChangeRequiresNewConfirmationAndClearsPreviousMarker() async throws {
        let session = makeSession(ImmersalSessionEngine())
        defer { session.stop() }
        await start(session)
        await session.process(try query(sequence: 0, timestamp: 10))
        await session.process(try query(sequence: 1, timestamp: 11.5))
        XCTAssertNotNil(session.worldFromMap)
        session.stop()
        await start(session, mapID: 2)
        await session.process(try query(sequence: 0, timestamp: 20))
        XCTAssertEqual(session.evaluationReport?.identity.assetID, "2/2")
        XCTAssertEqual(session.report?.successCount, 1)
        XCTAssertEqual(session.alignmentState, .candidate)
        XCTAssertNil(session.worldFromMap)
        XCTAssertNil(session.markerInMap)
    }

    func testTrackingInterruptionClearsAlignmentAndKeepsMeasuredReport() async throws {
        let session = makeSession(ImmersalSessionEngine())
        defer { session.stop() }
        await start(session)
        session.trackingChanged(isNormal: true)
        await session.process(try query(sequence: 0, timestamp: 10))
        await session.process(try query(sequence: 1, timestamp: 11.5))
        session.trackingChanged(isNormal: false)
        XCTAssertFalse(session.isRunning)
        XCTAssertNil(session.worldFromMap)
        XCTAssertNil(session.markerInMap)
        XCTAssertEqual(session.report?.successCount, 2)
        XCTAssertEqual(session.evaluationReport?.successCount, 2)
        XCTAssertTrue(session.status.contains("追踪"))
    }

    func testOldRunCompletionCannotConfirmOrOverwriteTheNewMap() async throws {
        let engine = ImmersalSessionEngine(holdFrames: true)
        let session = makeSession(engine)
        defer { session.stop(); engine.releaseAll() }
        await start(session)
        let oldFrame = try query(sequence: 0, timestamp: 10)
        let oldOperation = Task { await session.process(oldFrame) }
        await waitUntil { engine.frameCount == 1 }
        session.stop()
        await start(session, mapID: 2)
        let newFrame = try query(sequence: 0, timestamp: 100)
        let newOperation = Task { await session.process(newFrame) }
        await waitUntil { engine.frameCount == 2 }
        engine.releaseFrame(index: 1, result: match())
        await newOperation.value
        engine.releaseFrame(index: 0, result: match(position: SIMD3(100, 0, 0)))
        await oldOperation.value
        XCTAssertEqual(session.report?.attemptCount, 1)
        XCTAssertEqual(session.evaluationReport?.identity.assetID, "2/2")
        XCTAssertEqual(session.alignmentState, .candidate)
        XCTAssertNil(session.worldFromMap)
        let confirming = try query(sequence: 1, timestamp: 101.5)
        let confirmingOperation = Task { await session.process(confirming) }
        await waitUntil { engine.frameCount == 3 }
        engine.releaseFrame(index: 2, result: match())
        await confirmingOperation.value
        XCTAssertEqual(session.alignmentState, .confirmed)
        XCTAssertEqual(session.worldFromMap?.columns.3.x, 0)
    }

    func testRepeatedSequenceAndReversedCaptureAreNotNewSDKAttempts() async throws {
        let engine = ImmersalSessionEngine()
        let session = makeSession(engine)
        defer { session.stop() }
        await start(session)
        await session.process(try query(sequence: 0, timestamp: 10))
        await session.process(try query(sequence: 0, timestamp: 11.5))
        await session.process(try query(sequence: 1, timestamp: 9))
        XCTAssertEqual(engine.frameCount, 1)
        XCTAssertEqual(session.report?.attemptCount, 1)
        await session.process(try query(sequence: 1, timestamp: 11.5))
        XCTAssertEqual(session.alignmentState, .confirmed)
        XCTAssertEqual(engine.frameCount, 2)
    }

    private func makeSession(_ engine: ImmersalSessionEngine) -> ImmersalLocalizationSession {
        ImmersalLocalizationSession(engine: engine, requestCamera: { true }, runSession: { _ in }, now: { self.clockNow })
    }

    private func start(_ session: ImmersalLocalizationSession, mapID: Int = 1) async {
        session.start(url: URL(fileURLWithPath: "/synthetic-immersal-map.bytes"), mapID: mapID, userID: 2,
            sourceFingerprint: fingerprint)
        await waitUntil { !session.isLoading }
        XCTAssertTrue(session.isRunning)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 { if condition() { return }; try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTFail("Immersal session did not reach the expected state", file: file, line: line)
    }

    private func query(sequence: Int, timestamp: Double, camera: simd_float4x4 = matrix_identity_float4x4) throws -> LocalizationQueryFrame {
        clockNow = max(clockNow, timestamp)
        return try .init(sequence: sequence, timestamp: timestamp, pixels: Data([1]), width: 1, height: 1,
            intrinsics: SIMD4(1, 1, 0, 0), worldFromCamera: camera)
    }

    private func match(position: SIMD3<Float> = .zero) -> ImmersalLocalizationResult {
        .init(position: position, rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), confidence: 42)
    }
}

private final class ImmersalSessionEngine: ImmersalOfflineLocalizing, @unchecked Sendable {
    private let lock = NSLock()
    private let results: [ImmersalLocalizationResult?]
    private let holdFrames: Bool
    private var pending: [CheckedContinuation<ImmersalLocalizationResult?, Never>?] = []
    private var frames = 0
    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return frames }
    init(results: [ImmersalLocalizationResult?] = [], holdFrames: Bool = false) {
        self.results = results; self.holdFrames = holdFrames
    }
    func load(url: URL) async throws -> Int { 100 }
    func localize(pixels: Data, width: Int, height: Int, intrinsics: SIMD4<Float>) async -> ImmersalLocalizationResult? {
        await withCheckedContinuation { continuation in
            lock.lock(); let index = frames; frames += 1
            if holdFrames { pending.append(continuation); lock.unlock() }
            else {
                let result = results.isEmpty ? ImmersalLocalizationResult(position: .zero,
                    rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), confidence: 42)
                    : (results.indices.contains(index) ? results[index] : nil)
                lock.unlock(); continuation.resume(returning: result)
            }
        }
    }
    func close() {}
    func releaseFrame(index: Int, result: ImmersalLocalizationResult?) {
        lock.lock()
        guard pending.indices.contains(index) else { lock.unlock(); return }
        let continuation = pending[index]; pending[index] = nil; lock.unlock()
        continuation?.resume(returning: result)
    }
    func releaseAll() {
        lock.lock(); let remaining = pending.compactMap { $0 }
        pending = pending.map { _ in nil }; lock.unlock()
        remaining.forEach { $0.resume(returning: nil) }
    }
}
