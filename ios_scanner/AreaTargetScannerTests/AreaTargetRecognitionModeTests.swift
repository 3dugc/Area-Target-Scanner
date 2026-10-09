import XCTest
import simd
@testable import AreaTargetScanner

final class AreaTargetRecognitionModeTests: XCTestCase {
    func testModeIdentityRoundTripCannotMixStandardEnhancedOrLegacy() throws {
        let standard = LocalizationAssetIdentity(provider: .areaTarget, assetID: "map", areaTargetRecognitionMode: .standard)
        let enhanced = LocalizationAssetIdentity(provider: .areaTarget, assetID: "map", areaTargetRecognitionMode: .enhanced)
        XCTAssertNotEqual(standard, enhanced)
        XCTAssertEqual(try JSONDecoder().decode(LocalizationAssetIdentity.self, from: JSONEncoder().encode(enhanced)), enhanced)
        let legacy = try JSONDecoder().decode(LocalizationAssetIdentity.self, from: Data(#"{"provider":"areaTarget","assetID":"map"}"#.utf8))
        XCTAssertNil(legacy.areaTargetRecognitionMode)
        XCTAssertNotEqual(legacy, standard); XCTAssertNotEqual(legacy, enhanced)
    }
    func testDefaultLoadExplicitlyAppliesStandardBeforeProcessing() async throws {
        let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
        let native = ModeRecordingNative(); let engine = AreaTargetOfflineLocalizer(native: native)
        _ = try await engine.load(url: fixture.url)
        _ = await frame(engine)
        XCTAssertEqual(native.events.prefix(2), ["create", "mode:standard"])
        XCTAssertEqual(native.processModes, [.standard])
        XCTAssertFalse(native.calledOnMain)
        engine.close(); await engine.waitUntilIdle()
    }
    func testEnhancedModePropagatesToLoadedHandleAndSurvivesReload() async throws {
        let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
        let native = ModeRecordingNative(); let engine = AreaTargetOfflineLocalizer(native: native)
        defer { engine.close() }
        _ = try await engine.load(url: fixture.url)
        try await engine.configure(mode: .enhanced)
        _ = await frame(engine)
        _ = try await engine.load(url: fixture.url)
        _ = await frame(engine)
        XCTAssertEqual(native.processModes, [.enhanced, .enhanced])
        XCTAssertEqual(native.createdHandles.count, 2)
        XCTAssertEqual(native.events.filter { $0 == "mode:enhanced" }.count, 2)
        XCTAssertFalse(native.calledOnMain)
    }
    func testConfigureBeforeLoadAppliesEnhancedToFreshHandle() async throws {
        let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
        let native = ModeRecordingNative(); let engine = AreaTargetOfflineLocalizer(native: native)
        try await engine.configure(mode: .enhanced)
        _ = try await engine.load(url: fixture.url)
        _ = await frame(engine)
        XCTAssertEqual(native.events.prefix(2), ["create", "mode:enhanced"])
        XCTAssertEqual(native.processModes, [.enhanced])
        engine.close(); await engine.waitUntilIdle()
    }
    func testModeIsPerEngineAndCanReturnToStandard() async throws {
        let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
        let a = ModeRecordingNative(), b = ModeRecordingNative()
        let first = AreaTargetOfflineLocalizer(native: a), second = AreaTargetOfflineLocalizer(native: b)
        _ = try await first.load(url: fixture.url); _ = try await second.load(url: fixture.url)
        try await first.configure(mode: .enhanced)
        _ = await frame(first); _ = await frame(second)
        try await first.configure(mode: .standard); _ = await frame(first)
        XCTAssertEqual(a.processModes, [.enhanced, .standard]); XCTAssertEqual(b.processModes, [.standard])
        first.close(); second.close(); await first.waitUntilIdle()
    }
    func testFailedNativeConfigurationClosesHandleAndCannotProcessAsEnhanced() async throws {
        let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
        let native = ModeRecordingNative(); let engine = AreaTargetOfflineLocalizer(native: native)
        _ = try await engine.load(url: fixture.url)
        native.rejectEnhanced = true
        do { try await engine.configure(mode: .enhanced); XCTFail("unsupported enhanced configuration succeeded") }
        catch { XCTAssertEqual(error as? AreaTargetRecognitionModeError, .configurationFailed) }
        let result = await frame(engine)
        XCTAssertNil(result); XCTAssertTrue(native.processModes.isEmpty)
        XCTAssertEqual(native.events.last, "destroy")
        engine.close(); await engine.waitUntilIdle()
    }
    func testOldProtocolEngineCannotSilentlyAcceptEnhanced() async throws {
        let engine: AreaTargetOfflineLocalizing = StandardOnlyEngine()
        try await engine.configure(mode: .standard)
        do { try await engine.configure(mode: .enhanced); XCTFail("default implementation mislabeled enhanced") }
        catch { XCTAssertEqual(error as? AreaTargetRecognitionModeError, .unsupported) }
    }
    private func frame(_ engine: AreaTargetOfflineLocalizer) async -> AreaTargetLocalizationResult? {
        await engine.localize(pixels: Data([1]), width: 1, height: 1, intrinsics: SIMD4(1, 1, 0, 0))
    }
}

private final class ModeRecordingNative: AreaTargetNativeCalling {
    var events: [String] = [], processModes: [AreaTargetRecognitionMode] = []
    var createdHandles: [UnsafeMutableRawPointer] = []
    var mode = AreaTargetRecognitionMode.standard
    var rejectEnhanced = false, calledOnMain = false
    private func record(_ value: String) { events.append(value); calledOnMain = calledOnMain || Thread.isMainThread }
    func create() -> UnsafeMutableRawPointer? {
        record("create"); let handle = UnsafeMutableRawPointer(bitPattern: createdHandles.count + 1)!
        createdHandles.append(handle); mode = .standard; return handle
    }
    func destroy(_ handle: UnsafeMutableRawPointer) { record("destroy") }
    func setRecoveryMode(_ handle: UnsafeMutableRawPointer, mode: AreaTargetRecognitionMode) -> Bool {
        record("mode:\(mode.rawValue)"); if rejectEnhanced && mode == .enhanced { return false }
        self.mode = mode; return true
    }
    func addVocabulary(_ handle: UnsafeMutableRawPointer, word: AreaTargetFeatureDatabase.VocabularyWord) -> Bool { true }
    func addKeyframe(_ handle: UnsafeMutableRawPointer, keyframe: AreaTargetFeatureDatabase.Keyframe) -> Bool { true }
    func addAKAZE(_ handle: UnsafeMutableRawPointer, keyframe: AreaTargetFeatureDatabase.Keyframe) -> Bool { true }
    func buildIndex(_ handle: UnsafeMutableRawPointer) -> Bool { true }
    func process(_ handle: UnsafeMutableRawPointer, pixels: Data, width: Int, height: Int, intrinsics: SIMD4<Float>) -> AreaTargetNativeFrameResult {
        record("process"); processModes.append(mode)
        return .init(state: 1, pose: [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1], confidence: 1, matchedFeatures: 12)
    }
}
private final class StandardOnlyEngine: AreaTargetOfflineLocalizing {
    func load(url: URL) async throws -> Int { 0 }
    func localize(pixels: Data, width: Int, height: Int, intrinsics: SIMD4<Float>) async -> AreaTargetLocalizationResult? { nil }
    func close() {}
}
