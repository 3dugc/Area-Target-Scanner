import XCTest
import simd
@testable import AreaTargetScanner

final class ImmersalOfflineTests: XCTestCase {
    func testPoseUsesCaptureTimeCameraAndFlipsCVBasis() throws {
        var camera = matrix_identity_float4x4
        camera.columns.3 = SIMD4<Float>(5, 2, -3, 1)
        let pose = try XCTUnwrap(ImmersalPose.worldFromMap(position: SIMD3(1, 2, 3),
            rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), worldFromCamera: camera))
        let cvCamera = pose.inverse * camera
        XCTAssertEqual(cvCamera.columns.0.x, 1, accuracy: 0.0001)
        XCTAssertEqual(cvCamera.columns.1.y, -1, accuracy: 0.0001)
        XCTAssertEqual(cvCamera.columns.2.z, -1, accuracy: 0.0001)
        XCTAssertEqual(cvCamera.columns.3.x, 1, accuracy: 0.0001)
        XCTAssertEqual(cvCamera.columns.3.z, 3, accuracy: 0.0001)
    }

    func testInvalidNativePoseCannotBecomeSuccess() {
        XCTAssertNil(ImmersalPose.worldFromMap(position: SIMD3(.nan, 0, 0), rotation: simd_quatf(), worldFromCamera: matrix_identity_float4x4))
        XCTAssertNil(ImmersalPose.worldFromMap(position: .zero, rotation: simd_quatf(vector: .zero), worldFromCamera: matrix_identity_float4x4))
    }

    func testGrayscaleRowsExcludePadding() throws {
        var input: [UInt8] = [1,2,3,99,99,4,5,6,99,99]
        let output = try input.withUnsafeMutableBytes { buffer in
            try ImmersalImagePacking.copyRows(base: buffer.baseAddress!, width: 3, height: 2, bytesPerRow: 5)
        }
        XCTAssertEqual(Array(output), [1,2,3,4,5,6])
    }

    func testInvalidStrideRejected() {
        var byte: UInt8 = 0
        XCTAssertThrowsError(try withUnsafePointer(to: &byte) {
            try ImmersalImagePacking.copyRows(base: $0, width: 3, height: 2, bytesPerRow: 2)
        })
    }
}

@MainActor
final class ImmersalSessionLifecycleTests: XCTestCase {
    func testCancelledLoadCompletionCannotCloseNewRun() async throws {
        let engine = GatedOfflineEngine()
        var runs = 0
        let model = ImmersalLocalizationSession(engine: engine, requestCamera: { true }, runSession: { _ in runs += 1 })
        let url = URL(fileURLWithPath: "/unused.bytes")
        model.start(url: url, mapID: 1, userID: 2)
        for _ in 0..<100 where engine.loads.count < 1 { await Task.yield() }
        XCTAssertEqual(engine.loads.count, 1)
        model.stop()
        model.start(url: url, mapID: 1, userID: 2)
        for _ in 0..<100 where engine.loads.count < 2 { await Task.yield() }
        XCTAssertEqual(engine.loads.count, 2)
        guard engine.loads.count == 2 else { return }
        engine.loads[1].resume(returning: 20)
        for _ in 0..<100 where !model.isRunning { await Task.yield() }
        engine.loads[0].resume(returning: 10)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.pointCount, 20)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(engine.closes, 1, "Old completion must not release the new map")
        model.stop()
    }

    func testCameraPermissionDeniedDoesNotLoadMapOrStartSession() async {
        let engine = GatedOfflineEngine()
        let model = ImmersalLocalizationSession(engine: engine, requestCamera: { false }, runSession: { _ in XCTFail("Camera denied") })
        model.start(url: URL(fileURLWithPath: "/unused.bytes"), mapID: 1, userID: 2)
        for _ in 0..<100 where model.isLoading { await Task.yield() }
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(engine.loads.isEmpty)
        XCTAssertTrue(model.status.contains("相机"))
    }
}

private final class GatedOfflineEngine: ImmersalOfflineLocalizing {
    var loads: [CheckedContinuation<Int, Error>] = []
    var closes = 0
    func load(url: URL) async throws -> Int {
        try await withCheckedThrowingContinuation { loads.append($0) }
    }
    func localize(pixels: Data, width: Int, height: Int, intrinsics: SIMD4<Float>) async -> ImmersalLocalizationResult? { nil }
    func close() { closes += 1 }
}
