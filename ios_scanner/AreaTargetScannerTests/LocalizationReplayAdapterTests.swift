import XCTest
import simd
@testable import AreaTargetScanner

@MainActor
final class LocalizationReplayAdapterTests: XCTestCase {
    func testAreaTargetReplaySharesTheLiveOpenCV5Identity() {
        let directory = URL(fileURLWithPath: "/synthetic-area-target", isDirectory: true)
        let source = String(repeating: "a", count: 64)
        let digest = String(repeating: "b", count: 64)
        let asset = AreaTargetSavedAsset(jobID: "synthetic-job", bundleURL: directory.appendingPathComponent("bundle.zip"),
            directoryURL: directory, modelURL: directory.appendingPathComponent("optimized.glb"),
            featuresURL: directory.appendingPathComponent("features.db"), manifestURL: directory.appendingPathComponent("manifest.json"), savedAt: Date())
        let identity = AreaTargetReplayAdapter.assetIdentity(asset: asset, sourceFingerprint: source,
            assetDigest: digest, buildConfiguration: "synthetic-profile")
        XCTAssertEqual(identity.engineVersion, "area-target-core-2/recovery-3/final-geometry-1/opencv-5.0.0/no-ar-prior")
        XCTAssertEqual(identity.engineVersion, AreaTargetLocalizationSession.engineVersion)
        XCTAssertEqual(identity.provider, .areaTarget)
        XCTAssertEqual(identity.sourceFingerprint, source)
        XCTAssertEqual(identity.assetDigest, digest)
        XCTAssertEqual(identity.buildConfiguration, "synthetic-profile")
        XCTAssertFalse(identity.buildConfiguration?.contains("display_core_session_api=") ?? false)
        XCTAssertEqual(identity.areaTargetRecognitionMode, .standard)
    }

    func testAreaReplayCapturesModeAndCannotMatchDifferentModeIdentity() async throws {
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        let asset = AreaTargetSavedAsset(jobID: "synthetic-job", bundleURL: root, directoryURL: root,
            modelURL: root, featuresURL: root, manifestURL: root, savedAt: Date())
        let engine = ModeReplayEngine()
        let adapter = AreaTargetReplayAdapter(asset: asset, sourceFingerprint: nil, recognitionMode: .enhanced, engine: engine)
        XCTAssertEqual(adapter.identity.areaTargetRecognitionMode, .enhanced)
        let prepared = try await adapter.prepare()
        XCTAssertTrue(prepared)
        XCTAssertEqual(engine.modes, [.enhanced]); XCTAssertEqual(engine.events, ["load", "mode:enhanced"])
        let standard = AreaTargetReplayAdapter.assetIdentity(asset: asset, sourceFingerprint: nil, assetDigest: nil, buildConfiguration: nil)
        XCTAssertNotEqual(adapter.identity, standard)
        adapter.close(); XCTAssertEqual(engine.closes, 1)
    }

    func testAreaReplayUnsupportedEnhancedPreparationFailsWithoutSilentFallback() async {
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        let asset = AreaTargetSavedAsset(jobID: "synthetic-job", bundleURL: root, directoryURL: root,
            modelURL: root, featuresURL: root, manifestURL: root, savedAt: Date())
        let engine = ModeReplayEngine(); engine.rejectEnhanced = true
        let adapter = AreaTargetReplayAdapter(asset: asset, sourceFingerprint: nil, recognitionMode: .enhanced, engine: engine)
        do { _ = try await adapter.prepare(); XCTFail("enhanced preparation falsely succeeded") }
        catch { XCTAssertEqual(error as? AreaTargetRecognitionModeError, .unsupported) }
        XCTAssertEqual(engine.closes, 1)
    }

    func testImmersalReplayRetainsItsSDKIdentityWhenAreaTargetUsesOpenCV5() {
        let source = String(repeating: "a", count: 64)
        let digest = String(repeating: "b", count: 64)
        var job = ImmersalMappingJob(id: UUID(), userID: 1, scanName: "synthetic", mapName: "map", createdAt: Date())
        job.sourceFingerprint = source; job.mapID = 7; job.frameCount = 32
        let identity = ImmersalReplayAdapter.assetIdentity(
            mapURL: URL(fileURLWithPath: "/synthetic/\(digest).bytes"), job: job)
        XCTAssertEqual(identity.engineVersion, ImmersalLocalizationSession.engineVersion)
        XCTAssertEqual(identity.engineVersion, "immersal-sdk-2.4.0/sha256:45fad535dcbf0139feb9b15dafe74c8315436db21a138271924e10e56d2fca8f/no-ar-prior")
        XCTAssertEqual(identity.provider, .immersal)
        XCTAssertEqual(identity.assetID, "1/7")
        XCTAssertEqual(identity.sourceFingerprint, source)
        XCTAssertEqual(identity.assetDigest, digest)
        XCTAssertFalse(identity.buildConfiguration?.contains("display_core_session_api=") ?? false)
        XCTAssertTrue(identity.buildConfiguration?.contains("calibration_core_api=") ?? false)
    }

    func testCanceledOldPreparationCannotReloadOrCloseNewRun() async throws {
        let engine = AdapterImmersalEngine()
        let source = String(repeating: "a", count: 64)
        var job = ImmersalMappingJob(id: UUID(), userID: 1, scanName: "missing", mapName: "map", createdAt: Date())
        job.sourceFingerprint = source; job.mapID = 7; job.phase = .done
        var pending: CheckedContinuation<String, Never>?
        var hashCalls = 0
        let adapter = ImmersalReplayAdapter(mapURL: URL(fileURLWithPath: "/synthetic-map.bytes"),
            job: job, scanDirectory: URL(fileURLWithPath: "/missing-synthetic-scan"), engine: engine,
            fingerprint: { _ in
                hashCalls += 1
                if hashCalls == 1 { return await withCheckedContinuation { pending = $0 } }
                return source
            })
        let old = Task { try await adapter.prepare() }
        for _ in 0..<1000 where pending == nil { await Task.yield() }
        let release = try XCTUnwrap(pending)
        adapter.close()
        _ = try await adapter.prepare()
        let reloads = engine.loads; let closes = engine.closes
        release.resume(returning: source)
        do { _ = try await old.value; XCTFail("old generation prepared") } catch {}
        XCTAssertEqual(engine.loads, reloads)
        XCTAssertEqual(engine.closes, closes)
        adapter.close()
    }
}

private final class ModeReplayEngine: AreaTargetOfflineLocalizing {
    var modes: [AreaTargetRecognitionMode] = [], events: [String] = []
    var closes = 0, rejectEnhanced = false
    func load(url: URL) async throws -> Int { events.append("load"); return 0 }
    func configure(mode: AreaTargetRecognitionMode) async throws {
        events.append("mode:\(mode.rawValue)"); modes.append(mode)
        if rejectEnhanced && mode == .enhanced { throw AreaTargetRecognitionModeError.unsupported }
    }
    func localize(pixels: Data, width: Int, height: Int, intrinsics: SIMD4<Float>) async -> AreaTargetLocalizationResult? { nil }
    func close() { closes += 1 }
}

@MainActor
private final class AdapterImmersalEngine: ImmersalOfflineLocalizing {
    var loads = 0; var closes = 0
    func load(url: URL) async throws -> Int { loads += 1; return 10 }
    func localize(pixels: Data, width: Int, height: Int, intrinsics: SIMD4<Float>) async -> ImmersalLocalizationResult? { nil }
    nonisolated func close() { MainActor.assumeIsolated { closes += 1 } }
}
