import XCTest
import simd
@testable import AreaTargetScanner

final class AreaTargetOfflineLocalizerTests: XCTestCase {
    func testRealNativeRecognizesSyntheticKnownPoseFromProductionSQLite() async throws {
        let directory = try Self.syntheticFixtureDirectory()
        let engine = AreaTargetOfflineLocalizer()
        let count = try await engine.load(url:directory.appendingPathComponent("features.db"))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("fixture.json"))) as? [String:Any])
        XCTAssertEqual(metadata["producerOpenCVVersion"] as? String, "5.0.0")
        XCTAssertEqual(count,metadata["featureCount"] as? Int)
        XCTAssertLessThanOrEqual(count,AreaTargetFeatureDatabase.maximumORBPerKeyframe)
        let pixels = try Data(contentsOf:directory.appendingPathComponent("query.gray8"))
        let result = await engine.localize(pixels:pixels,width:640,height:480,intrinsics:SIMD4(500,510,320,240))
        let found = try XCTUnwrap(result)
        XCTAssertGreaterThan(found.matchedFeatures,100)
        XCTAssertEqual(found.cameraFromScan.columns.3.x,0.15,accuracy:0.01)
        XCTAssertEqual(found.cameraFromScan.columns.3.y,-0.23,accuracy:0.01)
        XCTAssertEqual(found.cameraFromScan.columns.3.z,0.34,accuracy:0.01)
        XCTAssertEqual(found.cameraFromScan.columns.0.x,1,accuracy:0.01)
        XCTAssertEqual(found.cameraFromScan.columns.1.y,1,accuracy:0.01)
        XCTAssertEqual(found.cameraFromScan.columns.2.z,1,accuracy:0.01)
        let blank = await engine.localize(pixels:Data(repeating:0,count:640*480),width:640,height:480,intrinsics:SIMD4(500,510,320,240))
        XCTAssertNil(blank)
        engine.close(); await engine.waitUntilIdle()
    }
    func testSyntheticFixtureCacheNameIsContainedAndHostPathRemainsSupported() throws {
        let cache = URL(fileURLWithPath: "/test-app/Library/Caches", isDirectory: true)
        let device = try Self.syntheticFixtureDirectory(environment: [
            "AREA_TARGET_SYNTHETIC_FIXTURE_IN_CACHES": "AreaTargetNativeSmokeFixture",
            "AREA_TARGET_SYNTHETIC_FIXTURE_DIR": "/ignored-host-fixture"], cachesDirectory: cache)
        XCTAssertEqual(device.path, "/test-app/Library/Caches/AreaTargetNativeSmokeFixture")
        let host = try Self.syntheticFixtureDirectory(environment: ["AREA_TARGET_SYNTHETIC_FIXTURE_DIR": "/host/fixture"], cachesDirectory: cache)
        XCTAssertEqual(host.path, "/host/fixture")
        for invalid in ["", ".", "..", "../outside", "nested/path", "/absolute", "folder\\other", "folder name"] {
            XCTAssertThrowsError(try Self.syntheticFixtureDirectory(environment: [
                "AREA_TARGET_SYNTHETIC_FIXTURE_IN_CACHES": invalid,
                "AREA_TARGET_SYNTHETIC_FIXTURE_DIR": "/must-not-fall-back"], cachesDirectory: cache))
        }
    }

    private static func syntheticFixtureDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cachesDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    ) throws -> URL {
        if let name = environment["AREA_TARGET_SYNTHETIC_FIXTURE_IN_CACHES"] {
            guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$", options: .regularExpression) != nil,
                  let cachesDirectory else {
                throw NSError(domain: "AreaTargetDeviceSmoke", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Fixture cache location must be one simple directory name"])
            }
            return cachesDirectory.appendingPathComponent(name, isDirectory: true)
        }
        guard let path = environment["AREA_TARGET_SYNTHETIC_FIXTURE_DIR"], !path.isEmpty else {
            throw XCTSkip("Generate the official native fixture and set AREA_TARGET_SYNTHETIC_FIXTURE_DIR or AREA_TARGET_SYNTHETIC_FIXTURE_IN_CACHES")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func testRowMajorPosePreservesNativeARAxesAndDirection() throws {
        let pose = try XCTUnwrap(AreaTargetPose.cameraFromScan(rowMajor: [0,-1,0,2,1,0,0,3,0,0,1,-4,0,0,0,1]))
        XCTAssertEqual(pose.columns.0, SIMD4(0,1,0,0))
        XCTAssertEqual(pose.columns.1, SIMD4(-1,0,0,0))
        XCTAssertEqual(pose.columns.2, SIMD4(0,0,1,0))
        XCTAssertEqual(pose.columns.3, SIMD4(2,3,-4,1))
        var camera = matrix_identity_float4x4; camera.columns.3 = SIMD4(7,8,9,1)
        XCTAssertEqual((camera * pose).columns.3, SIMD4(9,11,5,1))
    }
    func testRejectsNonfiniteNonrigidAndWrongSizedNativePoses() {
        XCTAssertNil(AreaTargetPose.cameraFromScan(rowMajor: [1]))
        XCTAssertNil(AreaTargetPose.cameraFromScan(rowMajor: [.nan,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]))
        XCTAssertNil(AreaTargetPose.cameraFromScan(rowMajor: [2,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]))
        XCTAssertNil(AreaTargetPose.cameraFromScan(rowMajor: [1.002,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]))
    }
    func testLoadUsesVocabularyBeforeKeyframesAndFreshHandleOnReload() async throws {
        let fixture = try AreaTargetSQLiteFixture(akaze: true); defer { fixture.remove() }
        let backend = RecordingAreaTargetNative()
        let engine = AreaTargetOfflineLocalizer(native: backend)
        let loadedCount = try await engine.load(url: fixture.url)
        XCTAssertEqual(loadedCount, 2)
        XCTAssertEqual(backend.events, ["create","vocabulary","keyframe","akaze","build"])
        _ = try await engine.load(url: fixture.url)
        XCTAssertEqual(backend.events.suffix(6), ["destroy","create","vocabulary","keyframe","akaze","build"])
        XCTAssertFalse(backend.calledOnMain)
        engine.close()
        await engine.waitUntilIdle()
        XCTAssertEqual(backend.events.last, "destroy")
    }
    func testLoadsAllORBKeyframesBeforeOptionalAKAZE() async throws {
        let fixture = try AreaTargetSQLiteFixture(akaze:true); defer { fixture.remove() }
        try fixture.execute("INSERT INTO keyframes SELECT 8,pose,NULL FROM keyframes WHERE id=7; INSERT INTO features SELECT 2,8,x,y,x3d,y3d,z3d,descriptor FROM features WHERE id=1; INSERT INTO akaze_features SELECT 2,8,x,y,x3d,y3d,z3d,descriptor FROM akaze_features WHERE id=1;")
        let backend = RecordingAreaTargetNative(); let engine = AreaTargetOfflineLocalizer(native:backend)
        _ = try await engine.load(url:fixture.url)
        XCTAssertEqual(backend.events,["create","vocabulary","keyframe","keyframe","akaze","akaze","build"])
        engine.close(); await engine.waitUntilIdle()
    }
    func test100And500CapacityPassEveryKeyframeAndFeatureToNative() async throws {
        for count in [100, 500] {
            let fixture = try AreaTargetSQLiteFixture(akaze: true); defer { fixture.remove() }
            try fixture.populateCoverage(frameCount: count)
            let backend = RecordingAreaTargetNative(); let engine = AreaTargetOfflineLocalizer(native: backend)
            let loaded = try await engine.load(url: fixture.url)
            XCTAssertEqual(loaded, 200_000)
            XCTAssertEqual(backend.keyframeIDs, Array(8..<(8 + count)).map(Int32.init))
            XCTAssertEqual(backend.orbCount, 160_000)
            XCTAssertEqual(backend.akazeCount, 40_000)
            XCTAssertEqual(backend.events.filter { $0 == "keyframe" }.count, count)
            XCTAssertEqual(backend.events.filter { $0 == "akaze" }.count, count)
            engine.close(); await engine.waitUntilIdle()
        }
    }
    func testLinkedNativeAccepts100And500CapacityWithinExistingBudgets() async throws {
        for count in [100, 500] {
            let fixture = try AreaTargetSQLiteFixture(akaze: true); defer { fixture.remove() }
            try fixture.populateCoverage(frameCount: count)
            let engine = AreaTargetOfflineLocalizer()
            let loaded = try await engine.load(url: fixture.url)
            XCTAssertEqual(loaded, 200_000)
            engine.close(); await engine.waitUntilIdle()
        }
    }
    func testDenseGray8AndFiniteIntrinsicsRequiredBeforeNativeCall() async throws {
        let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
        let backend = RecordingAreaTargetNative(); let engine = AreaTargetOfflineLocalizer(native: backend)
        _ = try await engine.load(url: fixture.url)
        for (width,height,k) in [(0,1,SIMD4<Float>(1,1,0,0)),(2,2,SIMD4<Float>(1,1,0,0)),(1,1,SIMD4<Float>(.infinity,1,0,0)),(1,1,SIMD4<Float>(1,1,.nan,0)),(Int.max,2,SIMD4<Float>(1,1,0,0))] {
            let result = await engine.localize(pixels: Data([1]), width: width, height: height, intrinsics: k)
            XCTAssertNil(result)
        }
        XCTAssertFalse(backend.events.contains("process"))
        let result = await engine.localize(pixels: Data([1]),width:1,height:1,intrinsics:SIMD4(1,1,0,0))
        XCTAssertEqual(result?.matchedFeatures, 12)
        XCTAssertEqual(result?.cameraFromScan.columns.3, SIMD4(2,3,-4,1))
        engine.close(); await engine.waitUntilIdle()
    }
    func testCloseSuppressesInFlightResultAndNeverOverlapsDestroy() async throws {
        let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
        let backend = RecordingAreaTargetNative(); let engine = AreaTargetOfflineLocalizer(native: backend)
        _ = try await engine.load(url: fixture.url)
        backend.gate = DispatchSemaphore(value:0)
        let frame = Task { await engine.localize(pixels:Data([1]),width:1,height:1,intrinsics:SIMD4(1,1,0,0)) }
        await waitForNativeEntry(backend.entered)
        engine.close()
        backend.gate?.signal()
        let result = await frame.value
        XCTAssertNil(result)
        await engine.waitUntilIdle()
        XCTAssertEqual(backend.events.suffix(2), ["process","destroy"])
        XCTAssertFalse(backend.overlapped)
    }
    func testCancelledFrameIsSuppressed() async throws {
        let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
        let backend = RecordingAreaTargetNative(); let engine = AreaTargetOfflineLocalizer(native:backend)
        _ = try await engine.load(url:fixture.url)
        backend.gate = DispatchSemaphore(value:0)
        let frame = Task { await engine.localize(pixels:Data([1]),width:1,height:1,intrinsics:SIMD4(1,1,0,0)) }
        await waitForNativeEntry(backend.entered)
        frame.cancel(); backend.gate?.signal()
        let result = await frame.value; XCTAssertNil(result)
        engine.close(); await engine.waitUntilIdle()
    }
    func testCancelledLoadDestroysPartialHandleAndNextRunStartsFresh() async throws {
        let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
        let backend = RecordingAreaTargetNative(); let engine = AreaTargetOfflineLocalizer(native:backend)
        let gate = DispatchSemaphore(value:0); backend.createGate = gate
        let load = Task { try await engine.load(url:fixture.url) }
        await waitForNativeEntry(backend.created)
        load.cancel(); gate.signal()
        do { _ = try await load.value; XCTFail("Cancelled load returned success") } catch is CancellationError { } catch { XCTFail("Expected cancellation") }
        await engine.waitUntilIdle()
        XCTAssertEqual(backend.events,["create","destroy"])
        backend.createGate = nil
        _ = try await engine.load(url:fixture.url)
        XCTAssertEqual(backend.events.suffix(4),["create","vocabulary","keyframe","build"])
        engine.close(); await engine.waitUntilIdle()
    }
    func testLostInvalidConfidenceAndInsufficientInliersCannotBecomeSuccess() async throws {
        let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
        let backend = RecordingAreaTargetNative(); let engine = AreaTargetOfflineLocalizer(native:backend)
        _ = try await engine.load(url:fixture.url)
        let identity:[Float] = [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
        for result in [AreaTargetNativeFrameResult(state:2,pose:identity,confidence:1,matchedFeatures:12),
                       AreaTargetNativeFrameResult(state:1,pose:identity,confidence:.infinity,matchedFeatures:12),
                       AreaTargetNativeFrameResult(state:1,pose:identity,confidence:2,matchedFeatures:12),
                       AreaTargetNativeFrameResult(state:1,pose:identity,confidence:1,matchedFeatures:7)] {
            backend.frameResult = result
            let localized = await engine.localize(pixels:Data([1]),width:1,height:1,intrinsics:SIMD4(1,1,0,0))
            XCTAssertNil(localized)
        }
        XCTAssertEqual(backend.events.filter { $0 == "create" }.count,1,"A continuous run retains its native handle")
        engine.close(); await engine.waitUntilIdle()
    }
    func testFailedLoadCannotKeepPreviousMapUsable() async throws {
        let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
        let backend = RecordingAreaTargetNative(); let engine = AreaTargetOfflineLocalizer(native:backend)
        _ = try await engine.load(url:fixture.url)
        do { _ = try await engine.load(url:URL(fileURLWithPath:"/missing-area-target.db")); XCTFail("Expected invalid DB") } catch { }
        let result = await engine.localize(pixels:Data([1]),width:1,height:1,intrinsics:SIMD4(1,1,0,0))
        XCTAssertNil(result)
        XCTAssertEqual(backend.events.last,"destroy")
    }
}

private final class RecordingAreaTargetNative: AreaTargetNativeCalling, @unchecked Sendable {
    var events = [String]()
    var keyframeIDs = [Int32]()
    var orbCount = 0
    var akazeCount = 0
    var calledOnMain = false
    var overlapped = false
    var processing = false
    var gate: DispatchSemaphore?
    let entered = DispatchSemaphore(value:0)
    let created = DispatchSemaphore(value:0)
    var createGate: DispatchSemaphore?
    var frameResult = AreaTargetNativeFrameResult(state:1,pose:[0,-1,0,2,1,0,0,3,0,0,1,-4,0,0,0,1],confidence:0.24,matchedFeatures:12)
    private func record(_ event:String) { events.append(event); calledOnMain = calledOnMain || Thread.isMainThread }
    func create() -> UnsafeMutableRawPointer? { record("create"); created.signal(); createGate?.wait(); return UnsafeMutableRawPointer(bitPattern:1) }
    func destroy(_ handle:UnsafeMutableRawPointer) { record("destroy"); overlapped = overlapped || processing }
    func addVocabulary(_ handle:UnsafeMutableRawPointer, word:AreaTargetFeatureDatabase.VocabularyWord) -> Bool { record("vocabulary"); return true }
    func addKeyframe(_ handle:UnsafeMutableRawPointer, keyframe:AreaTargetFeatureDatabase.Keyframe) -> Bool { record("keyframe"); keyframeIDs.append(keyframe.id); orbCount += keyframe.orb.count; return true }
    func addAKAZE(_ handle:UnsafeMutableRawPointer, keyframe:AreaTargetFeatureDatabase.Keyframe) -> Bool { record("akaze"); akazeCount += keyframe.akaze?.count ?? 0; return true }
    func buildIndex(_ handle:UnsafeMutableRawPointer) -> Bool { record("build"); return true }
    func process(_ handle:UnsafeMutableRawPointer,pixels:Data,width:Int,height:Int,intrinsics:SIMD4<Float>) -> AreaTargetNativeFrameResult {
        processing = true; record("process"); entered.signal(); gate?.wait(); processing = false
        return frameResult
    }
}

private func waitForNativeEntry(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { semaphore.wait(); continuation.resume() }
    }
}
