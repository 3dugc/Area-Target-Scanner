import XCTest
import ARKit
import SceneKit
import simd
@testable import AreaTargetScanner

@MainActor
final class AreaTargetLocalizationSessionTests: XCTestCase {
    private var root: URL!
    private var asset: AreaTargetSavedAsset!
    private let fingerprint = String(repeating: "a", count: 64)
    private var clockNow = 0.0

    func testRecoveryModeDefaultsToStandardAndIsCapturedForTheWholeRun() async throws {
        let engine = AreaSessionEngine()
        let session = makeSession(engine)
        defer { session.stop() }
        XCTAssertEqual(session.recognitionMode, .standard)
        var selected = AreaTargetRecognitionMode.enhanced
        session.start(asset: asset, sourceFingerprint: fingerprint, recognitionMode: selected)
        selected = .standard
        await waitUntil { session.isRunning }
        XCTAssertEqual(engine.configuredModes, [.enhanced])
        session.start(asset: asset, sourceFingerprint: fingerprint, recognitionMode: selected)
        await session.process(try query(sequence: 0, timestamp: 10))
        XCTAssertEqual(session.report?.identity.areaTargetRecognitionMode, .enhanced)
        XCTAssertEqual(session.recognitionMode, .enhanced)
        session.stop()
        session.start(asset: asset, sourceFingerprint: fingerprint, recognitionMode: selected)
        await waitUntil { session.isRunning }
        await session.process(try query(sequence: 0, timestamp: 20))
        XCTAssertEqual(engine.configuredModes, [.enhanced, .standard])
        XCTAssertEqual(session.report?.identity.areaTargetRecognitionMode, .standard)
    }

    func testUnsupportedEnhancedModeCannotStartCameraOrProduceEnhancedReport() async {
        let engine = AreaSessionEngine(); engine.rejectEnhanced = true
        var cameraRuns = 0
        let session = AreaTargetLocalizationSession(engine: engine, requestCamera: { true }, runSession: { _ in cameraRuns += 1 })
        session.start(asset: asset, sourceFingerprint: fingerprint, recognitionMode: .enhanced)
        await waitUntil { !session.isLoading }
        XCTAssertFalse(session.isRunning); XCTAssertNil(session.report)
        XCTAssertEqual(cameraRuns, 0); XCTAssertEqual(engine.closeCount, 1)
        XCTAssertEqual(engine.frameCount, 0); XCTAssertTrue(session.status.contains("不支持增强识别"))
    }

    override func setUpWithError() throws {
        clockNow = 0
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaTargetSession-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        asset = AreaTargetSavedAsset(jobID: UUID().uuidString.lowercased(), bundleURL: root.appendingPathComponent("bundle.zip"),
            directoryURL: root, modelURL: root.appendingPathComponent("optimized.glb"),
            featuresURL: root.appendingPathComponent("features.db"), manifestURL: root.appendingPathComponent("manifest.json"), savedAt: Date())
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCameraDenialDoesNotLoadFeaturesOrRunARSession() async {
        let engine = AreaSessionEngine()
        let session = AreaTargetLocalizationSession(engine: engine, requestCamera: { false }, runSession: { _ in XCTFail("Camera denied") })
        session.start(asset: asset, sourceFingerprint: fingerprint)
        await waitUntil { !session.isLoading }
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(engine.loadedURLs.isEmpty)
        XCTAssertTrue(session.status.contains("相机"))
        XCTAssertNil(session.report)
    }

    func testFeaturesLoadWithoutOriginalScanStartsWithNoInventedReport() async {
        let engine = AreaSessionEngine()
        var cameraRuns = 0
        let session = AreaTargetLocalizationSession(engine: engine, requestCamera: { true }, runSession: { _ in cameraRuns += 1 })
        defer { session.stop() }
        session.start(asset: asset, sourceFingerprint: fingerprint)
        await waitUntil { !session.isLoading }
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(engine.loadedURLs, [asset.featuresURL])
        XCTAssertEqual(session.pointCount, 120)
        XCTAssertEqual(cameraRuns, 1)
        XCTAssertNil(session.report)
        XCTAssertNil(session.scanMesh)
        XCTAssertTrue(session.meshStatus.contains("原扫描"))
    }

    func testStoppedLateLoadCannotPublishOrCloseTheNewRun() async {
        let engine = AreaSessionEngine(holdLoads: true)
        var cameraRuns = 0
        let session = AreaTargetLocalizationSession(engine: engine, requestCamera: { true }, runSession: { _ in cameraRuns += 1 })
        defer { session.stop(); engine.releaseAll() }
        session.start(asset: asset, sourceFingerprint: fingerprint)
        await waitUntil { engine.loadedURLs.count == 1 }
        session.stop()
        session.start(asset: asset, sourceFingerprint: fingerprint)
        await waitUntil { engine.loadedURLs.count == 2 }
        engine.releaseLoad(index: 1, count: 20)
        await waitUntil { session.isRunning }
        engine.releaseLoad(index: 0, count: 10)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(session.pointCount, 20)
        XCTAssertEqual(cameraRuns, 1)
        XCTAssertEqual(engine.closeCount, 1)
    }

    func testStopSuppressesInFlightLocalizationAndPreservesNoFakeResult() async throws {
        let engine = AreaSessionEngine(holdFrames: true)
        let session = makeSession(engine)
        defer { session.stop(); engine.releaseAll() }
        await start(session)
        let frame = try query(sequence: 0, timestamp: 10)
        let operation = Task { await session.process(frame) }
        await waitUntil { engine.frameCount == 1 }
        session.stop()
        engine.releaseFrame(index: 0, result: match())
        await operation.value
        XCTAssertFalse(session.isRunning)
        XCTAssertNil(session.worldFromScan)
        XCTAssertNil(session.markerInScan)
        XCTAssertNil(session.report)
        XCTAssertEqual(engine.closeCount, 1)
    }

    func testNewRunIsNotPollutedByOldFrameCompletion() async throws {
        let engine = AreaSessionEngine(holdFrames: true)
        let session = makeSession(engine)
        defer { session.stop(); engine.releaseAll() }
        await start(session)
        let oldFrame = try query(sequence: 0, timestamp: 10)
        let oldOperation = Task { await session.process(oldFrame) }
        await waitUntil { engine.frameCount == 1 }
        session.stop()
        await start(session)
        let newFrame = try query(sequence: 0, timestamp: 100)
        let newOperation = Task { await session.process(newFrame) }
        await waitUntil { engine.frameCount == 2 }
        engine.releaseFrame(index: 1, result: match())
        await newOperation.value
        engine.releaseFrame(index: 0, result: match(x: 100))
        await oldOperation.value
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(session.report?.attemptCount, 1)
        XCTAssertEqual(session.report?.firstRecognitionCaptureOffset, 0)
        XCTAssertNil(session.worldFromScan, "The new run still needs its own second confirmation")
        let confirmingFrame = try query(sequence: 1, timestamp: 101.5)
        let confirmingOperation = Task { await session.process(confirmingFrame) }
        await waitUntil { engine.frameCount == 3 }
        engine.releaseFrame(index: 2, result: match())
        await confirmingOperation.value
        XCTAssertEqual(session.worldFromScan?.columns.3, SIMD4(0, 0, 0, 1))
    }

    func testThrottleAndOneInflightUseCaptureTimestamp() async throws {
        let engine = AreaSessionEngine(holdFrames: true)
        let session = makeSession(engine)
        defer { session.stop(); engine.releaseAll() }
        await start(session)
        let first = try query(sequence: 0, timestamp: 10)
        let firstOperation = Task { await session.process(first) }
        await waitUntil { engine.frameCount == 1 }
        await session.process(try query(sequence: 1, timestamp: 12))
        XCTAssertEqual(engine.frameCount, 1)
        engine.releaseFrame(index: 0, result: match())
        await firstOperation.value
        await session.process(try query(sequence: 1, timestamp: 11))
        XCTAssertEqual(engine.frameCount, 1)
        let second = try query(sequence: 1, timestamp: 11.5)
        let secondOperation = Task { await session.process(second) }
        await waitUntil { engine.frameCount == 2 }
        engine.releaseFrame(index: 1, result: nil)
        await secondOperation.value
        XCTAssertEqual(session.report?.attemptCount, 2)
        XCTAssertEqual(session.report?.captureDuration, 1.5)
    }

    func testNativeARCameraFromScanIsComposedOnceAtCaptureTime() async throws {
        let engine = AreaSessionEngine(results: [match(x: 1, y: 2, z: 3), match(x: 1, y: 2, z: 3)])
        let session = makeSession(engine)
        defer { session.stop() }
        await start(session)
        var camera = matrix_identity_float4x4
        camera.columns.3 = SIMD4(5, 2, -3, 1)
        await session.process(try query(sequence: 0, timestamp: 10, camera: camera))
        XCTAssertNil(session.worldFromScan)
        await session.process(try query(sequence: 1, timestamp: 11.5, camera: camera))
        XCTAssertEqual(session.worldFromScan?.columns.3, SIMD4(6, 4, 0, 1))
        XCTAssertEqual(session.worldFromScan?.columns.1.y, 1)
        XCTAssertEqual(session.worldFromScan?.columns.2.z, 1)
        XCTAssertNotNil(session.markerInScan)
        XCTAssertEqual(session.report?.successCount, 2)
        XCTAssertEqual(session.report?.identity.provider, .areaTarget)
        XCTAssertEqual(session.report?.identity.assetID, asset.jobID)
        XCTAssertEqual(session.report?.identity.sourceFingerprint, fingerprint)
        XCTAssertEqual(session.report?.identity.engineVersion, "area-target-core-2/recovery-3/final-geometry-1/opencv-5.0.0/no-ar-prior")
    }

    func testFirstVisualMatchDoesNotPublishAnUnconfirmedAlignment() async throws {
        let engine = AreaSessionEngine(results: [match()])
        let session = makeSession(engine)
        defer { session.stop() }
        await start(session)
        await session.process(try query(sequence: 0, timestamp: ProcessInfo.processInfo.systemUptime))
        XCTAssertEqual(session.report?.attemptCount, 1)
        XCTAssertEqual(session.report?.successCount, 1, "Raw recognition remains measurable before display confirmation")
        XCTAssertNil(session.worldFromScan, "One visual result must remain a candidate")
        XCTAssertNil(session.markerInScan, "A marker must wait for two consistent results")
    }

    func testVisualFailureUsesBoundedDegradationWithoutAddingRawSuccesses() async throws {
        let engine = AreaSessionEngine(results: [match(), match(), nil])
        let session = makeSession(engine)
        defer { session.stop() }
        await start(session)
        await session.process(try query(sequence: 0, timestamp: 10))
        await session.process(try query(sequence: 1, timestamp: 11.5))
        await session.process(try query(sequence: 2, timestamp: 13))
        XCTAssertEqual(session.alignmentState, .degraded)
        XCTAssertNotNil(session.worldFromScan)
        XCTAssertEqual(session.report?.attemptCount, 3)
        XCTAssertEqual(session.report?.successCount, 2)
        clockNow = 14.5001
        session.checkAlignmentExpiry()
        XCTAssertEqual(session.alignmentState, .lost)
        XCTAssertNil(session.worldFromScan)
        XCTAssertEqual(session.report?.attemptCount, 3, "ARKit display ticks are not visual attempts")
        XCTAssertEqual(session.report?.successCount, 2)
    }

    func testLateSameRunResultIsMeasuredRawButNeverDisplayed() async throws {
        let engine = AreaSessionEngine(holdFrames: true)
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
        XCTAssertEqual(session.report?.p95LatencySeconds, 4)
        // No alignment has ever been confirmed; rejecting this first late result keeps initialization.
        XCTAssertEqual(session.alignmentState, .searching)
        XCTAssertNil(session.worldFromScan)
        XCTAssertNil(session.markerInScan)
    }

    func testDisplaySmoothingDoesNotReplaceRawEvaluationPoses() async throws {
        let session = makeSession(AreaSessionEngine(results: [match(), match(x: 0.1), match(x: 0.2)]))
        defer { session.stop() }
        await start(session)
        for index in 0..<3 {
            await session.process(try query(sequence: index, timestamp: 10 + Double(index) * 1.5))
        }
        let displayed = try XCTUnwrap(session.worldFromScan?.columns.3.x)
        XCTAssertGreaterThanOrEqual(displayed, 0.1)
        XCTAssertLessThan(displayed, 0.2)
        XCTAssertEqual(try XCTUnwrap(session.report?.medianTranslationDeltaMeters), 0.1, accuracy: 1e-6)
        XCTAssertEqual(session.report?.successCount, 3)
    }

    func testRestartClearsOldMapConfirmationAndMarker() async throws {
        let session = makeSession(AreaSessionEngine())
        defer { session.stop() }
        await start(session)
        await session.process(try query(sequence: 0, timestamp: 10))
        await session.process(try query(sequence: 1, timestamp: 11.5))
        XCTAssertNotNil(session.worldFromScan)
        XCTAssertNotNil(session.markerInScan)
        session.stop()
        await start(session)
        await session.process(try query(sequence: 0, timestamp: 20))
        XCTAssertEqual(session.report?.successCount, 1)
        XCTAssertEqual(session.alignmentState, .candidate)
        XCTAssertNil(session.worldFromScan)
        XCTAssertNil(session.markerInScan)
    }

    func testFailedFramesCountTowardTravelAndSuccessRate() async throws {
        let results: [AreaTargetLocalizationResult?] = (0..<20).map { index in
            index.isMultiple(of: 2) ? match(x: -Float(index) * 0.2) : nil
        }
        let engine = AreaSessionEngine(results: results)
        let session = makeSession(engine)
        defer { session.stop() }
        await start(session)
        for index in 0..<20 {
            var camera = matrix_identity_float4x4; camera.columns.3.x = Float(index) * 0.2
            await session.process(try query(sequence: index, timestamp: Double(index) * 2, camera: camera))
        }
        XCTAssertEqual(session.report?.attemptCount, 20)
        XCTAssertEqual(session.report?.successCount, 10)
        XCTAssertEqual(session.report?.successRate, 0.5)
        XCTAssertEqual(try XCTUnwrap(session.report?.trackedTravelMeters), 3.8, accuracy: 1e-5)
        XCTAssertEqual(session.report?.score, 80)
        XCTAssertNil(session.worldFromScan, "Alternating failures never establish consecutive confirmation")
    }

    func testInvalidPoseIsCountedAsFailureAndNeverDisplayed() async throws {
        var invalid = matrix_identity_float4x4; invalid.columns.0.x = 2
        let engine = AreaSessionEngine(results: [.init(cameraFromScan: invalid, confidence: 1, matchedFeatures: 100)])
        let session = makeSession(engine)
        defer { session.stop() }
        await start(session)
        await session.process(try query(sequence: 0, timestamp: 10))
        XCTAssertEqual(session.report?.attemptCount, 1)
        XCTAssertEqual(session.report?.successCount, 0)
        XCTAssertNil(session.worldFromScan)
        XCTAssertNil(session.markerInScan)
    }

    func testChangedSourceFingerprintPreventsLoadingWrongMeshButAllowsLocalization() async {
        let engine = AreaSessionEngine()
        let counter = AreaSessionCounter()
        let session = AreaTargetLocalizationSession(engine: engine, requestCamera: { true }, runSession: { _ in },
            meshLoader: { _ in counter.increment(); return SCNNode() }, sourceFingerprint: { _ in String(repeating: "b", count: 64) })
        defer { session.stop() }
        session.start(asset: asset, sourceFingerprint: fingerprint, scanDirectory: root)
        await waitUntil { !session.isLoading }
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(counter.value, 0)
        XCTAssertNil(session.scanMesh)
        XCTAssertTrue(session.meshStatus.contains("不一致"))
    }

    func testMatchingSourceLoadsOriginalMeshOffMainWithoutCalibrationCalls() async {
        let engine = AreaSessionEngine()
        let mainThread = AreaSessionCounter()
        let fingerprint = self.fingerprint
        let session = AreaTargetLocalizationSession(engine: engine, requestCamera: { true }, runSession: { _ in },
            meshLoader: { _ in if Thread.isMainThread { mainThread.increment() }; return SCNNode() }, sourceFingerprint: { _ in fingerprint })
        defer { session.stop() }
        session.start(asset: asset, sourceFingerprint: fingerprint, scanDirectory: root)
        await waitUntil { !session.isLoading }
        XCTAssertTrue(session.isRunning)
        XCTAssertNotNil(session.scanMesh)
        XCTAssertEqual(mainThread.value, 0)
        XCTAssertEqual(engine.frameCount, 0, "Loading Area Target geometry must not warm the native retrieval state with training photos")
        XCTAssertNil(session.report)
    }

    func testMissingOriginalModelDoesNotBlockFeatureOnlyLocalization() async {
        let engine = AreaSessionEngine()
        let fingerprint = self.fingerprint
        let session = AreaTargetLocalizationSession(engine: engine, requestCamera: { true }, runSession: { _ in },
            meshLoader: { _ in throw ImmersalScanMeshLoader.LoadError.missingModel }, sourceFingerprint: { _ in fingerprint })
        defer { session.stop() }
        session.start(asset: asset, sourceFingerprint: fingerprint, scanDirectory: root)
        await waitUntil { !session.isLoading }
        XCTAssertTrue(session.isRunning)
        XCTAssertNil(session.scanMesh)
        XCTAssertTrue(session.meshStatus.contains("仍可"))
        XCTAssertEqual(engine.loadedURLs, [asset.featuresURL])
    }

    func testTrackingInterruptionEndsSegmentAndRetainsMeasuredReport() async throws {
        let session = makeSession(AreaSessionEngine())
        defer { session.stop() }
        await start(session)
        session.trackingChanged(isNormal: true)
        await session.process(try query(sequence: 0, timestamp: 10))
        session.trackingChanged(isNormal: false)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.report?.attemptCount, 1)
        XCTAssertNil(session.worldFromScan)
        XCTAssertNil(session.scanMesh)
        XCTAssertTrue(session.status.contains("追踪"))
    }

    func testBuildMetadataIsRecordedWithoutBackfillingLegacySource() async throws {
        let engine = AreaSessionEngine()
        let checkedSources = AreaSessionCounter()
        let fingerprint = self.fingerprint
        let session = AreaTargetLocalizationSession(engine: engine, requestCamera: { true }, runSession: { _ in },
            sourceFingerprint: { _ in checkedSources.increment(); return fingerprint })
        defer { session.stop() }
        let digest = String(repeating: "b", count: 64)
        session.start(asset: asset, sourceFingerprint: nil, scanDirectory: root,
            assetDigest: digest, buildConfiguration: "profile=fast;uv_unwrap=1")
        await waitUntil { !session.isLoading }
        for index in 0..<20 {
            var camera = matrix_identity_float4x4; camera.columns.3.x = Float(index) * 0.2
            await session.process(try query(sequence: index, timestamp: Double(index) * 2, camera: camera))
        }
        XCTAssertEqual(session.report?.attemptCount, 20)
        XCTAssertEqual(session.report?.successCount, 20)
        XCTAssertNil(session.report?.identity.sourceFingerprint)
        XCTAssertEqual(session.report?.identity.assetDigest, digest)
        XCTAssertEqual(session.report?.identity.buildConfiguration,
            LocalizationCoreMetadata.liveBuildConfiguration(base: "profile=fast;uv_unwrap=1"))
        XCTAssertEqual(session.report?.eligibility, .unknownProvenance)
        XCTAssertNil(session.report?.score)
        XCTAssertEqual(checkedSources.value, 0)
        XCTAssertNil(session.scanMesh)
    }

    func testRestartDoesNotPresentSavedResultsAsLive() {
        var evidence = LocalizationEvaluationAccumulator(identity: .init(provider: .areaTarget, assetID: "asset", sourceFingerprint: fingerprint))
        evidence.record(sequence: 0, captureTime: 0, latency: 0.2, cameraPosition: .zero,
            worldFromScan: matrix_identity_float4x4, commonAlignmentValid: true)
        let saved = evidence.report(date: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(AreaTargetReportPresentation.report(current: nil, saved: saved, isActive: false), saved)
        XCTAssertNil(AreaTargetReportPresentation.report(current: nil, saved: saved, isActive: true))
        evidence.record(sequence: 1, captureTime: 2, latency: 0.3, cameraPosition: SIMD3(1, 0, 0),
            worldFromScan: matrix_identity_float4x4, commonAlignmentValid: true)
        let current = evidence.report(date: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(AreaTargetReportPresentation.report(current: current, saved: saved, isActive: true), current)
    }

    private func makeSession(_ engine: AreaSessionEngine) -> AreaTargetLocalizationSession {
        AreaTargetLocalizationSession(engine: engine, requestCamera: { true }, runSession: { _ in }, now: { self.clockNow })
    }
    private func start(_ session: AreaTargetLocalizationSession) async {
        session.start(asset: asset, sourceFingerprint: fingerprint)
        await waitUntil { !session.isLoading }
    }
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 { if condition() { return }; try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTFail("Session did not reach expected state", file: file, line: line)
    }
    private func query(sequence: Int, timestamp: Double, camera: simd_float4x4 = matrix_identity_float4x4) throws -> LocalizationQueryFrame {
        clockNow = max(clockNow, timestamp)
        return try LocalizationQueryFrame(sequence: sequence, timestamp: timestamp, pixels: Data([1]), width: 1, height: 1,
            intrinsics: SIMD4(1, 1, 0, 0), worldFromCamera: camera)
    }
    private func match(x: Float = 0, y: Float = 0, z: Float = 0) -> AreaTargetLocalizationResult {
        var result = matrix_identity_float4x4; result.columns.3 = SIMD4(x, y, z, 1)
        return .init(cameraFromScan: result, confidence: 1, matchedFeatures: 120)
    }
}

private final class AreaSessionCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private final class AreaSessionEngine: AreaTargetOfflineLocalizing, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var closes = 0
    private var frames = 0
    private var modes: [AreaTargetRecognitionMode] = []
    var rejectEnhanced = false
    var configuredModes: [AreaTargetRecognitionMode] { lock.lock(); defer { lock.unlock() }; return modes }
    func configure(mode: AreaTargetRecognitionMode) async throws {
        let reject = recordMode(mode)
        if reject { throw AreaTargetRecognitionModeError.unsupported }
    }
    private func recordMode(_ mode: AreaTargetRecognitionMode) -> Bool {
        lock.lock(); defer { lock.unlock() }; modes.append(mode)
        return rejectEnhanced && mode == .enhanced
    }
    private let holdLoads: Bool
    private let holdFrames: Bool
    private let results: [AreaTargetLocalizationResult?]
    private var loads: [CheckedContinuation<Int, Error>?] = []
    private var pendingFrames: [CheckedContinuation<AreaTargetLocalizationResult?, Never>?] = []
    var loadedURLs: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }
    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return frames }
    init(holdLoads: Bool = false, holdFrames: Bool = false, results: [AreaTargetLocalizationResult?] = []) {
        self.holdLoads = holdLoads; self.holdFrames = holdFrames; self.results = results
    }
    func load(url: URL) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); urls.append(url)
            if holdLoads { loads.append(continuation); lock.unlock() }
            else { lock.unlock(); continuation.resume(returning: 120) }
        }
    }
    func localize(pixels: Data, width: Int, height: Int, intrinsics: SIMD4<Float>) async -> AreaTargetLocalizationResult? {
        await withCheckedContinuation { continuation in
            lock.lock(); let index = frames; frames += 1
            if holdFrames { pendingFrames.append(continuation); lock.unlock() }
            else {
                let result = results.isEmpty ? AreaTargetLocalizationResult(cameraFromScan: matrix_identity_float4x4, confidence: 1, matchedFeatures: 120)
                    : (results.indices.contains(index) ? results[index] : nil)
                lock.unlock(); continuation.resume(returning: result)
            }
        }
    }
    func close() { lock.lock(); closes += 1; lock.unlock() }
    func releaseLoad(index: Int, count: Int) {
        lock.lock(); let continuation = loads.indices.contains(index) ? loads[index] : nil
        if loads.indices.contains(index) { loads[index] = nil }; lock.unlock()
        continuation?.resume(returning: count)
    }
    func releaseFrame(index: Int, result: AreaTargetLocalizationResult?) {
        lock.lock(); let continuation = pendingFrames.indices.contains(index) ? pendingFrames[index] : nil
        if pendingFrames.indices.contains(index) { pendingFrames[index] = nil }; lock.unlock()
        continuation?.resume(returning: result)
    }
    func releaseAll() {
        lock.lock(); let loads = self.loads.compactMap { $0 }; let frames = pendingFrames.compactMap { $0 }
        self.loads = self.loads.map { _ in nil }; pendingFrames = pendingFrames.map { _ in nil }; lock.unlock()
        loads.forEach { $0.resume(throwing: CancellationError()) }; frames.forEach { $0.resume(returning: nil) }
    }
}
