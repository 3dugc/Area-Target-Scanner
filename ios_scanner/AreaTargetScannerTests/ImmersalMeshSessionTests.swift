import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import AreaTargetScanner

/// Integrates persisted calibration frames, OBJ loading, and session lifecycle
/// with an in-memory localization engine. No camera session or SDK is started.
@MainActor
final class ImmersalMeshSessionTests: XCTestCase {
    private var root: URL!
    private var scan: URL!
    private var mapURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ImmersalMeshSession-\(UUID().uuidString)")
        scan = root.appendingPathComponent("scan_20260930_091600")
        mapURL = root.appendingPathComponent("fixture.bytes")
        try FileManager.default.createDirectory(at: scan.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: mapURL)
        try writeScanFixture()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testThreeCalibrationFramesPrepareMeshWithoutBecomingFieldTestSamples() async throws {
        let engine = MeshSessionFakeEngine()
        var cameraRequests = 0
        var cameraRuns = 0
        let vm = ImmersalLocalizationSession(engine: engine,
            requestCamera: { cameraRequests += 1; return true }, runSession: { _ in cameraRuns += 1 })
        defer { vm.stop(); engine.releasePending() }
        vm.start(url: mapURL, mapID: 123, userID: 7, scanDirectory: scan)
        await waitUntil { !vm.isLoading }

        XCTAssertTrue(vm.isRunning)
        XCTAssertEqual(cameraRequests, 1)
        XCTAssertEqual(cameraRuns, 1)
        XCTAssertEqual(engine.loadedURLs, [mapURL, mapURL], "Calibration must be followed by a fresh native map reload before field evaluation")
        XCTAssertEqual(engine.calls.count, 3)
        XCTAssertTrue(engine.calls.allSatisfy { $0.width == 3 && $0.height == 2 && $0.pixels.count == 6 })
        XCTAssertTrue(engine.calls.allSatisfy { $0.intrinsics == SIMD4<Float>(2, 2, 1, 1) })
        XCTAssertEqual(vm.pointCount, 120)
        XCTAssertNotNil(vm.scanMesh)
        let alignment = try XCTUnwrap(vm.mapFromScan)
        XCTAssertEqual(alignment.columns.3.x, 5, accuracy: 0.0001)
        XCTAssertEqual(alignment.columns.3.y, 0, accuracy: 0.0001)
        XCTAssertEqual(alignment.columns.3.z, 0, accuracy: 0.0001)
        XCTAssertEqual(alignment.columns.0.x, 1, accuracy: 0.0001)
        XCTAssertEqual(alignment.columns.1.y, 1, accuracy: 0.0001)
        XCTAssertEqual(alignment.columns.2.z, 1, accuracy: 0.0001)
        XCTAssertTrue(vm.meshStatus.contains("网格已就绪"))
        XCTAssertTrue(vm.meshStatus.contains("3 张"))
        XCTAssertNil(vm.report, "Reusing three original scan images must not create a field-test report or count as new attempts")
        XCTAssertNil(vm.worldFromMap, "Calibration aligns the old scan to the map, not the current AR tracking world")
        XCTAssertNil(vm.markerInMap)
        XCTAssertNil(vm.confidence)
    }

    func testUnmatchedCalibrationAllowsFieldTestingWithAnExplanationAndNoMesh() async {
        let engine = MeshSessionFakeEngine()
        engine.returnMatches = false
        var cameraRuns = 0
        let vm = ImmersalLocalizationSession(engine: engine, requestCamera: { true }, runSession: { _ in cameraRuns += 1 })
        defer { vm.stop(); engine.releasePending() }
        vm.start(url: mapURL, mapID: 123, userID: 7, scanDirectory: scan)
        await waitUntil { !vm.isLoading }

        XCTAssertTrue(vm.isRunning)
        XCTAssertEqual(cameraRuns, 1)
        XCTAssertEqual(engine.calls.count, 3)
        XCTAssertNil(vm.scanMesh)
        XCTAssertNil(vm.mapFromScan)
        XCTAssertNil(vm.report)
        XCTAssertTrue(vm.meshStatus.contains("有效定位不足"), vm.meshStatus)
        XCTAssertTrue(vm.meshStatus.contains("仍可进行定位测试"), vm.meshStatus)
    }

    func testMissingScanDirectoryDoesNotBlockFieldTesting() async {
        let engine = MeshSessionFakeEngine()
        var cameraRuns = 0
        let vm = ImmersalLocalizationSession(engine: engine, requestCamera: { true }, runSession: { _ in cameraRuns += 1 })
        defer { vm.stop(); engine.releasePending() }
        vm.start(url: mapURL, mapID: 123, userID: 7, scanDirectory: root.appendingPathComponent("missing_scan"))
        await waitUntil { !vm.isLoading }

        XCTAssertTrue(vm.isRunning)
        XCTAssertEqual(cameraRuns, 1)
        XCTAssertEqual(engine.loadedURLs.count, 1)
        XCTAssertTrue(engine.calls.isEmpty)
        XCTAssertNil(vm.scanMesh)
        XCTAssertNil(vm.mapFromScan)
        XCTAssertNil(vm.report)
        XCTAssertTrue(vm.meshStatus.contains("仍可进行定位测试"), vm.meshStatus)
    }

    func testMissingOBJDoesNotBlockFieldTestingOrUseCalibrationAsNewAttempts() async throws {
        try FileManager.default.removeItem(at: scan.appendingPathComponent("model.obj"))
        let engine = MeshSessionFakeEngine()
        var cameraRuns = 0
        let vm = ImmersalLocalizationSession(engine: engine, requestCamera: { true }, runSession: { _ in cameraRuns += 1 })
        defer { vm.stop(); engine.releasePending() }
        vm.start(url: mapURL, mapID: 123, userID: 7, scanDirectory: scan)
        await waitUntil { !vm.isLoading }

        XCTAssertTrue(vm.isRunning)
        XCTAssertEqual(cameraRuns, 1)
        XCTAssertTrue(engine.calls.isEmpty, "Missing geometry should not spend localization calls on a mesh that cannot be displayed")
        XCTAssertNil(vm.scanMesh)
        XCTAssertNil(vm.mapFromScan)
        XCTAssertNil(vm.report)
        XCTAssertTrue(vm.meshStatus.contains("model.obj"), vm.meshStatus)
        XCTAssertTrue(vm.meshStatus.contains("仍可进行定位测试"), vm.meshStatus)
    }

    func testStoppedPendingCalibrationCannotPublishLateMeshOrStartCamera() async {
        let engine = MeshSessionFakeEngine()
        engine.holdFirstLocalization = true
        var cameraRequests = 0
        var cameraRuns = 0
        let vm = ImmersalLocalizationSession(engine: engine,
            requestCamera: { cameraRequests += 1; return true }, runSession: { _ in cameraRuns += 1 })
        defer { vm.stop(); engine.releasePending() }
        vm.start(url: mapURL, mapID: 123, userID: 7, scanDirectory: scan)
        await waitUntil { engine.hasPendingLocalization }
        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.isRunning)
        XCTAssertEqual(engine.calls.count, 1)
        XCTAssertEqual(cameraRuns, 0)
        XCTAssertNil(vm.report)

        vm.stop(message: "测试已取消")
        let stoppedMeshStatus = vm.meshStatus
        engine.releasePending()
        await waitUntil { engine.returnedLocalizations == 1 }
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(vm.isRunning)
        XCTAssertEqual(cameraRequests, 1)
        XCTAssertEqual(cameraRuns, 0)
        XCTAssertEqual(engine.calls.count, 1, "A stopped generation must not localize the remaining calibration frames")
        XCTAssertEqual(engine.closeCount, 1)
        XCTAssertNil(vm.scanMesh)
        XCTAssertNil(vm.mapFromScan)
        XCTAssertNil(vm.worldFromMap)
        XCTAssertNil(vm.report)
        XCTAssertEqual(vm.status, "测试已取消")
        XCTAssertEqual(vm.meshStatus, stoppedMeshStatus)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The offline calibration did not reach its expected state before timeout", file: file, line: line)
    }

    private func writeScanFixture() throws {
        let image = try png()
        let frames: [[String: Any]] = try (0..<3).map { index in
            try image.write(to: scan.appendingPathComponent("images/frame_\(index).png"))
            let pose: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, Double(index), 0, 0, 1]
            return ["index": index, "imageFile": "images/frame_\(index).png", "transform": pose,
                    "image": ["width": 3, "height": 2],
                    "intrinsics": ["fx": 2, "fy": 2, "cx": 1, "cy": 1],
                    "imageOrientation": "landscapeRight", "run": 7]
        }
        let manifest: [String: Any] = ["schemaVersion": 1, "coordinateSystem": "arkit-world",
                                       "matrixLayout": "arkit-column-major", "units": "meters", "frames": frames]
        try JSONSerialization.data(withJSONObject: manifest).write(to: scan.appendingPathComponent("manifest.json"))
        try "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"
            .write(to: scan.appendingPathComponent("model.obj"), atomically: true, encoding: .utf8)
    }

    private func png() throws -> Data {
        let pixels: [UInt8] = [0, 0, 0, 255, 255, 255, 0, 0, 0,
                               255, 255, 255, 0, 0, 0, 255, 255, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 9,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [], provider: provider,
                                        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@MainActor
private final class MeshSessionFakeEngine: ImmersalOfflineLocalizing {
    struct Call {
        let pixels: Data
        let width: Int
        let height: Int
        let intrinsics: SIMD4<Float>
    }
    var returnMatches = true
    var holdFirstLocalization = false
    private(set) var loadedURLs: [URL] = []
    private(set) var calls: [Call] = []
    private(set) var closeCount = 0
    private(set) var returnedLocalizations = 0
    private var pending: CheckedContinuation<ImmersalLocalizationResult?, Never>?
    var hasPendingLocalization: Bool { pending != nil }

    func load(url: URL) async throws -> Int { loadedURLs.append(url); return 120 }

    func localize(pixels: Data, width: Int, height: Int, intrinsics: SIMD4<Float>) async -> ImmersalLocalizationResult? {
        let index = calls.count
        calls.append(Call(pixels: pixels, width: width, height: height, intrinsics: intrinsics))
        let result: ImmersalLocalizationResult?
        if holdFirstLocalization && index == 0 {
            result = await withCheckedContinuation { pending = $0 }
        } else {
            result = returnMatches ? match(index: index) : nil
        }
        returnedLocalizations += 1
        return result
    }

    // The production session closes its engine synchronously on MainActor.
    nonisolated func close() { MainActor.assumeIsolated { closeCount += 1 } }

    func releasePending() {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: returnMatches ? match(index: 0) : nil)
    }

    private func match(index: Int) -> ImmersalLocalizationResult {
        ImmersalLocalizationResult(position: SIMD3(Float(5 + index), 0, 0),
                                   rotation: simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0)), confidence: 100)
    }
}
