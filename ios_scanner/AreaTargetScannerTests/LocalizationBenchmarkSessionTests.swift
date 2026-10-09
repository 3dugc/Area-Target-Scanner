import XCTest
import simd
import CoreVideo
@testable import AreaTargetScanner

@MainActor
final class LocalizationBenchmarkSessionTests: XCTestCase {
    private let isolationRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalizationBenchmarkSessionTests-\(UUID().uuidString)", isDirectory: true)
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: isolationRoot)
        try super.tearDownWithError()
    }

    func testInvalidSourceCannotRequestCameraOrStartCapture() {
        var requested = false
        let session = LocalizationBenchmarkSession(
            recordingStore: LocalizationRecordingStore(rootDirectory: isolationRoot.appendingPathComponent("recordings")),
            reportStore: LocalizationReportStore(rootDirectory: isolationRoot.appendingPathComponent("reports")),
            requestCamera: { requested = true; return true }, runSession: { _ in XCTFail("AR session started") })
        session.start(sourceFingerprint: "unknown")
        XCTAssertFalse(requested)
        XCTAssertEqual(session.stage, .idle)
        XCTAssertNil(session.selectedRecording)
    }
    func testPermissionDenialKeepsIdleWithoutRecording() async {
        let session = LocalizationBenchmarkSession(
            recordingStore: LocalizationRecordingStore(rootDirectory: isolationRoot.appendingPathComponent("recordings")),
            reportStore: LocalizationReportStore(rootDirectory: isolationRoot.appendingPathComponent("reports")),
            requestCamera: { false }, runSession: { _ in XCTFail("AR session started") })
        session.start(sourceFingerprint: String(repeating: "a", count: 64))
        for _ in 0..<1000 where session.stage == .preparing { await Task.yield() }
        XCTAssertEqual(session.stage, .idle)
        XCTAssertTrue(session.status.contains("相机"))
    }
    func testLatePermissionGrantAfterCancellationCannotRestartCamera() async throws {
        var permission: CheckedContinuation<Bool, Never>?
        var runCount = 0
        let session = LocalizationBenchmarkSession(
            recordingStore: LocalizationRecordingStore(rootDirectory: isolationRoot.appendingPathComponent("recordings")),
            reportStore: LocalizationReportStore(rootDirectory: isolationRoot.appendingPathComponent("reports")),
            requestCamera: { await withCheckedContinuation { permission = $0 } }, runSession: { _ in runCount += 1 })
        session.start(sourceFingerprint: String(repeating: "a", count: 64))
        for _ in 0..<1000 where permission == nil { await Task.yield() }
        let pending = try XCTUnwrap(permission)
        session.cancel(); pending.resume(returning: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(session.stage, .idle)
        XCTAssertEqual(runCount, 0)
    }
    func testCaptureIsIndependentOfEitherEngineAndRespectsSampleInterval() async throws {
        var runCount = 0
        let session = LocalizationBenchmarkSession(
            recordingStore: LocalizationRecordingStore(rootDirectory: isolationRoot.appendingPathComponent("recordings")),
            reportStore: LocalizationReportStore(rootDirectory: isolationRoot.appendingPathComponent("reports")),
            requestCamera: { true }, runSession: { _ in runCount += 1 })
        session.start(sourceFingerprint: String(repeating: "a", count: 64))
        for _ in 0..<1000 where session.stage == .preparing { await Task.yield() }
        XCTAssertEqual(session.stage, .capturing)
        XCTAssertEqual(runCount, 1)
        let first = try frame(sequence: 0, time: 5)
        session.record(first, trackingNormal: true)
        session.record(try frame(sequence: 1, time: 6), trackingNormal: true)
        XCTAssertEqual(session.frameCount, 1)
        session.record(try frame(sequence: 1, time: 7), trackingNormal: true)
        XCTAssertEqual(session.frameCount, 2)
        XCTAssertEqual(session.duration, 2)
        session.cancel()
        XCTAssertNil(session.report)
        XCTAssertEqual(session.stage, .idle)
    }
    func testNoValidVideoDoesNotCreateRecordingOrReport() async {
        let session = LocalizationBenchmarkSession(
            recordingStore: LocalizationRecordingStore(rootDirectory: isolationRoot.appendingPathComponent("recordings")),
            reportStore: LocalizationReportStore(rootDirectory: isolationRoot.appendingPathComponent("reports")),
            requestCamera: { true }, runSession: { _ in })
        session.start(sourceFingerprint: String(repeating: "a", count: 64))
        for _ in 0..<1000 where session.stage == .preparing { await Task.yield() }
        session.finishCapture()
        XCTAssertEqual(session.stage, .idle)
        XCTAssertNil(session.selectedRecording)
        XCTAssertNil(session.reportURL)
    }
    func testSavedVideoReplaysSameFramesAndRestoresExactPairReport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordings = LocalizationRecordingStore(rootDirectory: directory.appendingPathComponent("recordings"))
        let reports = LocalizationReportStore(rootDirectory: directory.appendingPathComponent("reports"))
        let source = String(repeating: "a", count: 64)
        let coordinator = LocalizationBenchmarkSession(recordingStore: recordings, reportStore: reports, requestCamera: { true }, runSession: { _ in })
        coordinator.start(sourceFingerprint: source)
        try await wait { coordinator.stage == .capturing }
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        for index in 0..<22 {
            try coordinator.appendVideoFrame(pixelBuffer: pixel, timestamp: Double(index) * 2)
            var pose = matrix_identity_float4x4; pose.columns.3.x = Float(index) * 0.2
            let query = try LocalizationQueryFrame(sequence: index, timestamp: Double(index) * 2, pixels: Data([UInt8(index)]), width: 1, height: 1,
                intrinsics: SIMD4(1,1,0,0), worldFromCamera: pose)
            coordinator.record(query, trackingNormal: true)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        coordinator.finishCapture()
        try await wait { coordinator.stage != .saving }
        XCTAssertEqual(coordinator.stage, .ready, coordinator.status)
        let recording = try XCTUnwrap(coordinator.selectedRecording)
        XCTAssertEqual(recording.frameCount, 22)
        XCTAssertNotNil(coordinator.videoURL)
        XCTAssertNil(coordinator.report) // recording itself does not start either engine
        let area = BenchmarkEngine(.areaTarget, source: source), immersal = BenchmarkEngine(.immersal, source: source)
        coordinator.run(engines: [area, immersal])
        try await wait { coordinator.stage != .replaying }
        XCTAssertEqual(coordinator.stage, .finished, coordinator.status)
        let measured = try XCTUnwrap(coordinator.report)
        XCTAssertEqual(measured.queryFingerprint, recording.inputDigest)
        XCTAssertEqual(measured.recording?.id, recording.id)
        XCTAssertEqual(area.pixels, immersal.pixels)
        XCTAssertEqual(area.pixels.count, 22)
        XCTAssertEqual(measured.results.map(\.score), [100,100])
        XCTAssertNotNil(coordinator.reportURL, coordinator.status)
        XCTAssertNotNil(coordinator.markdownURL, coordinator.status)
        XCTAssertNotNil(measured.analysis)
        let restored = LocalizationBenchmarkSession(recordingStore: recordings, reportStore: reports, requestCamera: { XCTFail("restoring asked camera"); return false }, runSession: { _ in })
        restored.refresh(sourceFingerprint: source, identities: [area.identity, immersal.identity])
        try await wait { restored.report != nil }
        XCTAssertEqual(restored.report?.id, measured.id)
        XCTAssertEqual(restored.selectedRecording?.id, recording.id)
        // A Markdown publication failure must not prevent selecting or replaying
        // a verified recording with its existing JSON result.
        let exportDirectory = directory.appendingPathComponent("reports/comparisons")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: exportDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exportDirectory.path) }
        let readonly = LocalizationBenchmarkSession(recordingStore: recordings, reportStore: reports, requestCamera: { false }, runSession: { _ in })
        readonly.refresh(sourceFingerprint: source, identities: [area.identity, immersal.identity])
        try await wait { readonly.selectedRecording != nil }
        XCTAssertEqual(readonly.selectedRecording?.id, recording.id)
        XCTAssertEqual(readonly.report?.id, measured.id)
        XCTAssertNil(readonly.markdownURL)
        readonly.run(engines: [BenchmarkEngine(.areaTarget, source: source), BenchmarkEngine(.immersal, source: source)])
        try await wait { readonly.stage != .replaying }
        XCTAssertEqual(readonly.stage, .finished, readonly.status)
        XCTAssertEqual(readonly.report?.results.map(\.score), [100,100])
        coordinator.cancel(); restored.cancel(); readonly.cancel()
    }

    func testCapacityFailureAllowsDeletingOldRecordingWithoutDiscardingPendingCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageDirectory = directory.appendingPathComponent("recordings")
        let recordings = LocalizationRecordingStore(rootDirectory: packageDirectory)
        let coordinator = LocalizationBenchmarkSession(recordingStore: recordings, reportStore: .init(rootDirectory: directory.appendingPathComponent("reports")),
            requestCamera: { true }, runSession: { _ in })
        let source = String(repeating: "a", count: 64)
        try await captureOneFrame(coordinator, source: source)
        coordinator.finishCapture(); try await wait { coordinator.stage != .saving }
        let original = try XCTUnwrap(coordinator.selectedRecording, coordinator.status)
        try await captureOneFrame(coordinator, source: String(repeating: "b", count: 64))
        let padding = packageDirectory.appendingPathComponent("quota-fixture.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: padding.path, contents: Data()))
        let sparse = try FileHandle(forWritingTo: padding)
        try sparse.truncate(atOffset: UInt64(LocalizationRecordingStore.maximumTotalBytes)); try sparse.close()
        coordinator.stopForInterruption()
        try await wait { coordinator.stage != .saving }
        XCTAssertTrue(coordinator.canRetrySave, coordinator.status)
        XCTAssertTrue(coordinator.recordings.isEmpty)
        XCTAssertEqual(coordinator.otherRecordings.map(\.id), [original.id])
        coordinator.delete(original)
        try await wait { coordinator.stage != .saving }
        XCTAssertTrue(coordinator.canRetrySave, "Deleting an old record discarded the current unsaved capture")
        XCTAssertTrue(coordinator.recordings.isEmpty)
        XCTAssertTrue(coordinator.otherRecordings.isEmpty)
        try FileManager.default.removeItem(at: padding)
        coordinator.retrySave(); try await wait { coordinator.stage != .saving }
        let saved = try XCTUnwrap(coordinator.selectedRecording, coordinator.status)
        XCTAssertNotEqual(saved.id, original.id)
        XCTAssertEqual(saved.context.captureEndReason, "trackingInterrupted")
        XCTAssertEqual(saved.frameCount, 1)
        XCTAssertEqual(coordinator.stage, .ready)
        coordinator.cancel()
    }
    private func captureOneFrame(_ coordinator: LocalizationBenchmarkSession, source: String) async throws {
        coordinator.start(sourceFingerprint: source); try await wait { coordinator.stage == .capturing }
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil,64,48,kCVPixelFormatType_32BGRA,nil,&pixel), kCVReturnSuccess)
        try coordinator.appendVideoFrame(pixelBuffer: XCTUnwrap(pixel), timestamp: 0)
        coordinator.record(try frame(sequence: 0,time: 0), trackingNormal: true)
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    private func wait(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("session did not finish expected transition")
    }
    private func frame(sequence: Int, time: Double) throws -> LocalizationQueryFrame {
        try .init(sequence: sequence, timestamp: time, pixels: Data([1]), width: 1, height: 1,
                  intrinsics: SIMD4(1,1,0,0), worldFromCamera: matrix_identity_float4x4)
    }
}

@MainActor private final class BenchmarkEngine: LocalizationReplayEngine {
    let identity: LocalizationAssetIdentity
    var pixels: [Data] = []
    init(_ provider: LocalizationProvider, source: String) { identity = .init(provider: provider, assetID: provider.rawValue, sourceFingerprint: source, engineVersion: "fixture") }
    func prepare() async throws -> Bool { true }
    func localize(frame: LocalizationQueryFrame) async -> simd_float4x4? {
        pixels.append(frame.pixels); return simd_inverse(frame.worldFromCamera)
    }
    func close() {}
}
