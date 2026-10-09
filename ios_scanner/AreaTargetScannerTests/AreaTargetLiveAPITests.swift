import XCTest
import UIKit
import SwiftUI
import SQLite3
@testable import AreaTargetScanner

/// Explicit opt-in smoke: procedural images only, never a user's saved scan.
@MainActor
final class AreaTargetLiveAPITests: XCTestCase {
    func testLiveServiceCredentialFixtureRequiresBothValues() throws {
        for environment in [[:], ["AREA_TARGET_LIVE_USERNAME": "scanner"], ["AREA_TARGET_LIVE_PASSWORD": "fixture"],
                            ["AREA_TARGET_LIVE_USERNAME": " ", "AREA_TARGET_LIVE_PASSWORD": "fixture"]] {
            XCTAssertThrowsError(try liveServiceCredentials(environment))
        }
        let credential = try liveServiceCredentials(["AREA_TARGET_LIVE_USERNAME": " scanner ", "AREA_TARGET_LIVE_PASSWORD": " fixture "])
        XCTAssertEqual(credential.username, "scanner")
        XCTAssertEqual(credential.password, " fixture ", "Passwords must retain intentional spaces")
    }

    func testSyntheticScanUploadsProcessesAndDownloadsOnIOS() async throws {
        guard ProcessInfo.processInfo.environment["AREA_TARGET_LIVE_API"] == "1" else {
            throw XCTSkip("Enable the AreaTargetLiveSmoke scheme to run the authorized synthetic production smoke")
        }
        let credentials = try liveServiceCredentials(ProcessInfo.processInfo.environment)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaTargetLive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scan = root.appendingPathComponent("scan_synthetic")
        try makeSyntheticScan(scan)
        let tokens = AreaTargetKeychainStore(service: "com.areatarget.scanner.live-smoke.\(UUID().uuidString)")
        let store = AreaTargetAssetStore(rootDirectory: root.appendingPathComponent("assets"))
        let sessions = AreaTargetServiceKeychainStore(service: "com.areatarget.scanner.live-session.\(UUID().uuidString)")
        let serviceClient = AreaTargetAPIClient(sessionStore: sessions)
        let model = AreaTargetProcessingModel(api: serviceClient, jobStore: AreaTargetJobStore(url: root.appendingPathComponent("jobs.json")),
            tokenStore: tokens, assetStore: store, uploadDirectory: root.appendingPathComponent("uploads"))
        defer {
            model.setAppActive(false)
            for job in model.jobs { try? tokens.remove(jobID: job.id) }
            try? sessions.remove(origin: .current)
            try? FileManager.default.removeItem(at: root)
        }
        await model.signIn(username: credentials.username, password: credentials.password, origin: .current)
        _ = try XCTUnwrap(model.serviceSession(for: .current), model.authenticationMessage ?? "Service sign-in failed")
        await model.start(scanDirectory: scan, displayName: "合成场景 · 线上联调")
        let id = try XCTUnwrap(model.jobs.first?.id, model.message ?? "No journal")
        XCTAssertTrue(model.jobs.first!.accepted, model.message ?? "Upload failed")
        let preparation = try XCTUnwrap(model.jobs.first?.clientPreparation, "Live requirements must drive the client derivative")
        XCTAssertEqual(preparation.originalFrameCount, 100)
        XCTAssertEqual(preparation.selectedFrameCount, 80)
        XCTAssertEqual(preparation.selectedIndices.first, 0)
        XCTAssertEqual(preparation.selectedIndices.last, 99)
        XCTAssertEqual(preparation.processedPixelCount, 153_600_000)
        XCTAssertEqual(preparation.maximumOutputLongEdge, 1600)
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline, model.jobs.first?.phase == .processing {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await model.refresh(jobID: id)
        }
        XCTAssertEqual(model.jobs.first?.phase, .ready, model.message ?? model.jobs.first?.detail ?? "No result")
        await model.download(jobID: id)
        XCTAssertEqual(model.jobs.first?.phase, .downloaded, model.message ?? "Download failed")
        let saved = try XCTUnwrap(model.jobs.first?.savedAsset)
        let bundleManifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: saved.manifestURL)) as? [String: Any])
        let client = try XCTUnwrap(bundleManifest["clientPreparation"] as? [String: Any])
        let server = try XCTUnwrap(bundleManifest["scanPreparation"] as? [String: Any])
        XCTAssertEqual(client["originalFrameCount"] as? Int, 100)
        XCTAssertEqual(server["originalFrameCount"] as? Int, 80)
        XCTAssertEqual(server["resizedFrameCount"] as? Int, 0, "Server must avoid repeating client resizing")
        let verified = try await Task.detached { try store.asset(jobID: id) }.value
        XCTAssertEqual(verified, saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.bundleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.modelURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.featuresURL.path))
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(saved.featuresURL.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        func scalar(_ sql: String) throws -> String {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
        }
        XCTAssertEqual(try scalar("PRAGMA integrity_check"), "ok")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM keyframes"), "80")
        let featureCount = try XCTUnwrap(Int(scalar("SELECT COUNT(*) FROM features")))
        let vocabularyCount = try XCTUnwrap(Int(scalar("SELECT COUNT(*) FROM vocabulary")))
        XCTAssertGreaterThan(featureCount, 20)
        XCTAssertGreaterThan(vocabularyCount, 0)
        XCTAssertTrue(ScanSourceFingerprint.valid(model.jobs.first?.sourceFingerprint), "Upload must freeze the source identity for a later paired test")
        let native = AreaTargetOfflineLocalizer()
        defer { native.close() }
        let loadedFeatures = try await native.load(url: saved.featuresURL)
        XCTAssertEqual(loadedFeatures, featureCount, "The actual downloaded server database must load into the real iOS engine")
        native.close()
        await native.waitUntilIdle()
        print("LIVE_AREA_TARGET clientPrepared=100_to_80 pixels=153600000 serverResized=0")
        print("LIVE_AREA_TARGET nativeLoadedFeatures=\(loadedFeatures)")
        print("LIVE_AREA_TARGET features=\(featureCount) vocabulary=\(vocabularyCount)")
        print("LIVE_AREA_TARGET job=\(id) bytes=\(model.jobs.first!.remote!.result!.sizeBytes) sha256=\(model.jobs.first!.remote!.result!.sha256)")

        let host = UIHostingController(rootView: AreaTargetProcessingView(model: model, scanDirectory: scan,
            displayName: "合成场景 · 线上联调", settings: ScannerSettings(preferences: nil)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 350_000_000)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "area-target-live-ios-saved"
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
        window.rootViewController = nil
        await model.signOut(origin: .current)
    }

    /// Offline opt-in using the actual downloaded Hall result; this test makes no requests.
    func testDownloadedRealHallBundleSavesReopensAndLoadsNative() async throws {
        guard let path = ProcessInfo.processInfo.environment["AREA_TARGET_REAL_BUNDLE_DIR"], !path.isEmpty else {
            throw XCTSkip("Set AREA_TARGET_REAL_BUNDLE_DIR to the authorized Hall bundle and sanitized status DTO")
        }
        let input = URL(fileURLWithPath: path, isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard text.count <= 64 else { throw AreaTargetAPIError.invalidResponse }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw AreaTargetAPIError.invalidResponse }
            return date
        }
        let job = try decoder.decode(AreaTargetRemoteJob.self,
            from: Data(contentsOf: input.appendingPathComponent("status.json")))
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.progress, 100)
        XCTAssertEqual(job.stage, "completed")
        XCTAssertEqual(job.profile, "fast")
        XCTAssertTrue(job.uvUnwrap)
        XCTAssertNil(job.error)
        let result = try XCTUnwrap(job.result, "The real Hall job must contain its result descriptor")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaTargetRealHall-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        let store = AreaTargetAssetStore(rootDirectory: assets)
        let bundle = input.appendingPathComponent("bundle.zip")
        let saved = try await Task.detached {
            try store.save(downloadURL: bundle, jobID: job.jobID, result: result)
        }.value
        // Recreate the store so restoration must verify the persisted descriptor and bytes.
        let reopenedStore = AreaTargetAssetStore(rootDirectory: assets)
        let restored = try await Task.detached { try reopenedStore.asset(jobID: job.jobID) }.value
        let reopened = try XCTUnwrap(restored, "The real downloaded Hall asset must reopen")
        XCTAssertEqual(reopened, saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.bundleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.modelURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.featuresURL.path))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reopened.manifestURL)) as? [String: Any])
        let manifestKeyframes = try XCTUnwrap(manifest["keyframeCount"] as? Int)
        XCTAssertGreaterThan(manifestKeyframes, 0)
        XCTAssertLessThanOrEqual(manifestKeyframes, 77)
        let clientPreparation = try XCTUnwrap(manifest["clientPreparation"] as? [String: Any])
        let serverPreparation = try XCTUnwrap(manifest["scanPreparation"] as? [String: Any])
        for preparation in [clientPreparation, serverPreparation] {
            XCTAssertEqual(preparation["originalFrameCount"] as? Int, 77)
            XCTAssertEqual(preparation["selectedFrameCount"] as? Int, 77)
            XCTAssertEqual(preparation["selectedIndices"] as? [Int], Array(0..<77))
            XCTAssertEqual(preparation["processedPixelCount"] as? Int, 147_840_000)
        }
        XCTAssertEqual(serverPreparation["resizedFrameCount"] as? Int, 0)
        XCTAssertEqual(manifest["featureType"] as? String, "ORB")
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(reopened.featuresURL.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        XCTAssertEqual(openCode, SQLITE_OK)
        let connection = try XCTUnwrap(database, "The real feature database must open read-only")
        func scalar(_ sql: String) throws -> String {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            let prepared = try XCTUnwrap(statement, "The read-only count query must prepare")
            XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
            return String(cString: try XCTUnwrap(sqlite3_column_text(prepared, 0)))
        }
        XCTAssertEqual(try scalar("PRAGMA integrity_check"), "ok")
        let keyframes = try XCTUnwrap(Int(scalar("SELECT COUNT(*) FROM keyframes")))
        let orbFeatures = try XCTUnwrap(Int(scalar("SELECT COUNT(*) FROM features")))
        let vocabulary = try XCTUnwrap(Int(scalar("SELECT COUNT(*) FROM vocabulary")))
        let hasAKAZE = try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='akaze_features'") == "1"
        let akazeFeatures = hasAKAZE ? try XCTUnwrap(Int(scalar("SELECT COUNT(*) FROM akaze_features"))) : 0
        XCTAssertEqual(keyframes, manifestKeyframes)
        XCTAssertGreaterThan(keyframes, 0)
        XCTAssertLessThanOrEqual(keyframes, 77)
        XCTAssertGreaterThanOrEqual(orbFeatures, keyframes * 20)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM keyframes k WHERE (SELECT COUNT(*) FROM features f WHERE f.keyframe_id=k.id)<20"), "0")
        XCTAssertGreaterThan(vocabulary, 0)
        let featureCount = orbFeatures + akazeFeatures
        if let manifestFeatures = manifest["featureCount"] as? Int { XCTAssertEqual(featureCount, manifestFeatures) }
        let validated = try await Task.detached { try AreaTargetFeatureDatabase.load(url: reopened.featuresURL) }.value
        XCTAssertEqual(validated.keyframes.count, manifestKeyframes)
        XCTAssertEqual(validated.featureCount, featureCount)
        let native = AreaTargetOfflineLocalizer()
        defer { native.close() }
        let loadedFeatures = try await native.load(url: reopened.featuresURL)
        XCTAssertEqual(loadedFeatures, featureCount, "The actual Hall server database must load into the real iOS engine")
        native.close()
        await native.waitUntilIdle()
        print("REAL_HALL_AREA_TARGET reopened=true submittedFrames=77 validKeyframes=\(keyframes) features=\(featureCount) vocabulary=\(vocabulary) nativeLoadedFeatures=\(loadedFeatures)")
    }

    func testHallSnapshotRelativePathAcceptsPrivateVarEnumeratorAlias() throws {
        let root = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/fixture/Documents/scan_20260930_134646", isDirectory: true)
        let child = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/fixture/Documents/scan_20260930_134646/images/frame.jpg")
        XCTAssertEqual(try realHallRelativePath(child, in: root), "images/frame.jpg")
    }

    func testHallSnapshotRelativePathAcceptsReversePrivateVarAlias() throws {
        let root = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/fixture/Documents/scan_20260930_134646", isDirectory: true)
        let child = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/fixture/Documents/scan_20260930_134646/model.obj")
        XCTAssertEqual(try realHallRelativePath(child, in: root), "model.obj")
    }

    func testHallSnapshotRelativePathRejectsAnotherContainerOrPrefixSibling() throws {
        let root = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/fixture/Documents/scan_20260930_134646", isDirectory: true)
        for path in ["/private/var/mobile/Containers/Data/Application/other/Documents/scan_20260930_134646/images/frame.jpg",
            "/private/var/mobile/Containers/Data/Application/fixture/Documents/scan_20260930_134646-other/images/frame.jpg",
            "/private/var/mobile/Containers/Data/Application/fixture/Documents/scan_20260930_134646"] {
            XCTAssertThrowsError(try realHallRelativePath(URL(fileURLWithPath: path), in: root))
        }
    }

    func testHallSnapshotRelativePathPreservesNestedFileNameAndUnicodeComponents() throws {
        let root = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/fixture/Documents/scan_20260930_134646", isDirectory: true)
        let child = root.appendingPathComponent("images/大厅 frame 01.jpg")
        XCTAssertEqual(try realHallRelativePath(child, in: root), "images/大厅 frame 01.jpg")
    }

    func testExistingHallCompletionAcceptsOnlyTheAuthorizedCurrentSource() throws {
        let scan = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/fixture/Documents/scan_20260930_134646")
        var job = AreaTargetProcessingJob(id: "af13ab9f-ed0b-499e-b8eb-533288cfed65", scanDirectoryPath: scan.path,
            displayName: "测试大厅", createdAt: Date(), serverOrigin: .current)
        job.accepted = true; job.phase = .processing
        job.sourceFingerprint = "449a7e557d0963bf8f2dc0ff978da3f7c5ea7ee7caa9b4a2dac7eac7d348ae52"
        let alias = URL(fileURLWithPath: "/private" + scan.path)
        XCTAssertEqual(try realHallExistingJob(job.id, jobs: [job], scan: alias, fingerprint: job.sourceFingerprint!), job)
        job.phase = .downloaded
        XCTAssertEqual(try realHallExistingJob(job.id, jobs: [job], scan: scan, fingerprint: job.sourceFingerprint!), job)
    }

    func testExistingHallCompletionRejectsOtherIDsOriginsAndUnknownSources() throws {
        let scan = URL(fileURLWithPath: "/tmp/scan_20260930_134646")
        let id = "af13ab9f-ed0b-499e-b8eb-533288cfed65"
        let fingerprint = "449a7e557d0963bf8f2dc0ff978da3f7c5ea7ee7caa9b4a2dac7eac7d348ae52"
        for origin in [AreaTargetServerOrigin.current, .legacy] {
            var job = AreaTargetProcessingJob(id: id, scanDirectoryPath: scan.path,
                displayName: "测试大厅", createdAt: Date(), serverOrigin: origin)
            job.accepted = true; job.phase = .processing; job.sourceFingerprint = fingerprint
            if origin == .legacy {
                XCTAssertThrowsError(try realHallExistingJob(id, jobs: [job], scan: scan, fingerprint: fingerprint))
            } else {
                for value in [UUID().uuidString.lowercased(), id.uppercased(), "../../outside"] {
                    XCTAssertThrowsError(try realHallExistingJob(value, jobs: [job], scan: scan, fingerprint: fingerprint))
                }
                job.sourceFingerprint = nil
                XCTAssertThrowsError(try realHallExistingJob(id, jobs: [job], scan: scan, fingerprint: fingerprint))
                job.sourceFingerprint = String(repeating: "a", count: 64)
                XCTAssertThrowsError(try realHallExistingJob(id, jobs: [job], scan: scan, fingerprint: fingerprint))
            }
        }
    }

    func testExistingHallCompletionRejectsUnacceptedFailedOrDifferentScan() throws {
        let scan = URL(fileURLWithPath: "/tmp/scan_20260930_134646")
        let id = "af13ab9f-ed0b-499e-b8eb-533288cfed65"
        let fingerprint = "449a7e557d0963bf8f2dc0ff978da3f7c5ea7ee7caa9b4a2dac7eac7d348ae52"
        var job = AreaTargetProcessingJob(id: id, scanDirectoryPath: scan.path,
            displayName: "测试大厅", createdAt: Date(), serverOrigin: .current)
        job.sourceFingerprint = fingerprint
        XCTAssertThrowsError(try realHallExistingJob(id, jobs: [job], scan: scan, fingerprint: fingerprint))
        job.accepted = true; job.phase = .failed
        XCTAssertThrowsError(try realHallExistingJob(id, jobs: [job], scan: scan, fingerprint: fingerprint))
        job.phase = .processing
        XCTAssertThrowsError(try realHallExistingJob(id, jobs: [job], scan: URL(fileURLWithPath: "/tmp/scan_other"), fingerprint: fingerprint))
        XCTAssertThrowsError(try realHallExistingJob(id, jobs: [], scan: scan, fingerprint: fingerprint))
    }

    func testExistingHallCompletionAcceptsStandardContainerGUIDRelocation() throws {
        let old = "/var/mobile/Containers/Data/Application/F13FA810-E39F-4394-AC6F-7D5EA14E52B8/Documents/scan_20260930_134646"
        let current = "/private/var/mobile/Containers/Data/Application/B85B6D2A-EEE3-4F7B-B9DC-AC540AC57E5C/Documents/scan_20260930_134646"
        let fingerprint = "449a7e557d0963bf8f2dc0ff978da3f7c5ea7ee7caa9b4a2dac7eac7d348ae52"
        for (recorded, live) in [(old, current), (current, old)] {
            var job = AreaTargetProcessingJob(id: "af13ab9f-ed0b-499e-b8eb-533288cfed65", scanDirectoryPath: recorded,
                displayName: "测试大厅", createdAt: Date(), serverOrigin: .current)
            job.accepted = true; job.phase = .ready; job.sourceFingerprint = fingerprint
            XCTAssertEqual(try realHallExistingJob(job.id, jobs: [job], scan: URL(fileURLWithPath: live), fingerprint: fingerprint), job)
            XCTAssertThrowsError(try realHallRelativePath(URL(fileURLWithPath: live).appendingPathComponent("manifest.json"), in: job.scanDirectory),
                "Snapshot containment itself must continue to reject different containers")
        }
    }

    func testExistingHallCompletionRejectsNonstandardOrDifferentCaptureRelocation() throws {
        let current = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/B85B6D2A-EEE3-4F7B-B9DC-AC540AC57E5C/Documents/scan_20260930_134646")
        let fingerprint = "449a7e557d0963bf8f2dc0ff978da3f7c5ea7ee7caa9b4a2dac7eac7d348ae52"
        let old = "/var/mobile/Containers/Data/Application/F13FA810-E39F-4394-AC6F-7D5EA14E52B8/Documents/scan_20260930_134646"
        let unsafe = [old.replacingOccurrences(of: "Data/Application", with: "Bundle/Application"),
            old.replacingOccurrences(of: "mobile/Containers", with: "other/Containers"),
            old.replacingOccurrences(of: "/Documents/", with: "/Library/"),
            old.replacingOccurrences(of: "/Documents/", with: "/Documents/nested/"),
            old.replacingOccurrences(of: "scan_20260930_134646", with: "scan_20260930_134646-other"),
            old.replacingOccurrences(of: "F13FA810-E39F-4394-AC6F-7D5EA14E52B8", with: "not-a-uuid"),
            old.replacingOccurrences(of: "F13FA810-E39F-4394-AC6F-7D5EA14E52B8", with: "F13FA810E39F4394AC6F7D5EA14E52B8"),
            old.replacingOccurrences(of: "/Documents/", with: "/Library/../Documents/"),
            "/tmp/scan_20260930_134646"]
        for path in unsafe {
            var job = AreaTargetProcessingJob(id: "af13ab9f-ed0b-499e-b8eb-533288cfed65", scanDirectoryPath: path,
                displayName: "测试大厅", createdAt: Date(), serverOrigin: .current)
            job.accepted = true; job.phase = .ready; job.sourceFingerprint = fingerprint
            XCTAssertThrowsError(try realHallExistingJob(job.id, jobs: [job], scan: current, fingerprint: fingerprint), path)
        }
        var valid = AreaTargetProcessingJob(id: "af13ab9f-ed0b-499e-b8eb-533288cfed65", scanDirectoryPath: old,
            displayName: "测试大厅", createdAt: Date(), serverOrigin: .current)
        valid.accepted = true; valid.phase = .ready; valid.sourceFingerprint = fingerprint
        for path in [current.path.replacingOccurrences(of: "B85B6D2A-EEE3-4F7B-B9DC-AC540AC57E5C", with: "bad"),
            current.path.replacingOccurrences(of: "/Documents/", with: "/Documents/nested/"),
            current.path.replacingOccurrences(of: "scan_20260930_134646", with: "scan_other")] {
            XCTAssertThrowsError(try realHallExistingJob(valid.id, jobs: [valid], scan: URL(fileURLWithPath: path), fingerprint: fingerprint), path)
        }
    }

    /// Authorized opt-in: unchanged Hall source; optional persistence uses only the normal model flow.
    func testRealHallScanUploadsProcessesDownloadsAndLoadsNative() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AREA_TARGET_REAL_API"] == "1",
              let scanPath = environment["AREA_TARGET_REAL_SCAN_DIR"], !scanPath.isEmpty,
              let evidencePath = environment["AREA_TARGET_REAL_EVIDENCE_DIR"], !evidencePath.isEmpty else {
            throw XCTSkip("Enable AREA_TARGET_REAL_API and provide the authorized Hall source/evidence directories")
        }
        let credentials = try liveServiceCredentials(environment)
        func resolvedDirectory(_ path: String) throws -> URL {
            if path.hasPrefix("DOCUMENTS/") {
                let relative = String(path.dropFirst("DOCUMENTS/".count))
                guard AreaTargetFileSafety.safeRelativePath(relative) else { throw AreaTargetLocalError.missingScan }
                return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(relative, isDirectory: true).standardizedFileURL
            }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        let scan = try resolvedDirectory(scanPath)
        let evidence = try resolvedDirectory(evidencePath)
        let persist = environment["AREA_TARGET_REAL_API_PERSIST"] == "1"
        let existingID = environment["AREA_TARGET_REAL_EXISTING_JOB_ID"]
        if let existingID {
            guard persist, existingID == "af13ab9f-ed0b-499e-b8eb-533288cfed65" else {
                XCTFail("Existing-job completion requires persistent mode and the explicitly authorized job ID"); return
            }
        }
        guard scan.lastPathComponent.hasPrefix("scan_"),
              scan != evidence, !evidence.path.hasPrefix(scan.path + "/"),
              !scan.path.hasPrefix(evidence.path + "/") else {
            XCTFail("Use a scan_ source clone and a separate evidence directory"); return
        }
        for name in ["bundle.zip", "status.json", "summary.json"] {
            guard !FileManager.default.fileExists(atPath: evidence.appendingPathComponent(name).path) else {
                XCTFail("Existing Hall evidence must be preserved before another real run"); return
            }
        }
        let snapshot: @Sendable () throws -> (String, [String: String]) = {
            let fingerprint = try ScanSourceFingerprint.compute(directory: scan)
            guard let files = FileManager.default.enumerator(at: scan,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                throw AreaTargetLocalError.missingScan
            }
            var digests: [String: String] = [:]
            var pathPrefixReported = false
            for case let url as URL in files {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw AreaTargetLocalError.missingScan }
                if values.isRegularFile == true {
                    let relative = try realHallRelativePath(url, in: scan)
                    if !pathPrefixReported {
                        print("REAL_HALL_CLIENT snapshotURLPrefixMatched=\(url.path.hasPrefix(scan.path + "/"))")
                        pathPrefixReported = true
                    }
                    let value = try AreaTargetFileSafety.digest(AreaTargetFileSafety.safeFile(relative, in: scan),
                        maximum: AreaTargetFileSafety.maximumExpandedBytes)
                    digests[relative] = "\(value.size):\(value.sha256)"
                }
            }
            return (fingerprint, digests)
        }
        let before = try await Task.detached(operation: snapshot).value
        let expectedSource = "449a7e557d0963bf8f2dc0ff978da3f7c5ea7ee7caa9b4a2dac7eac7d348ae52"
        guard before.0 == expectedSource else {
            XCTFail("The supplied source is not the authorized, unchanged real Hall capture"); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaTargetRealHallFlow-" + UUID().uuidString)
        let assetRoot = root.appendingPathComponent("assets", isDirectory: true)
        let previousRecords = persist ? try AreaTargetJobStore().load() : []
        let model: AreaTargetProcessingModel
        let tokens: AreaTargetKeychainStore?
        let sessions: AreaTargetServiceKeychainStore?
        if persist {
            tokens = nil
            sessions = nil
            model = AreaTargetProcessingModel.shared
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let isolatedTokens = AreaTargetKeychainStore(service: "com.areatarget.scanner.real-hall-flow." + UUID().uuidString)
            tokens = isolatedTokens
            let isolatedSessions = AreaTargetServiceKeychainStore(service: "com.areatarget.scanner.real-hall-session." + UUID().uuidString)
            sessions = isolatedSessions
            model = AreaTargetProcessingModel(api: AreaTargetAPIClient(sessionStore: isolatedSessions),
                jobStore: AreaTargetJobStore(url: root.appendingPathComponent("jobs.json")),
                tokenStore: isolatedTokens, assetStore: AreaTargetAssetStore(rootDirectory: assetRoot),
                uploadDirectory: root.appendingPathComponent("uploads"))
        }
        let previousIDs = Set(model.jobs.map(\.id))
        defer {
            if let tokens {
                // Persistent QA shares the UI's owner and must not change its lifecycle.
                model.setAppActive(false)
                for job in model.jobs { try? tokens.remove(jobID: job.id) }
                try? sessions?.remove(origin: .current)
                try? FileManager.default.removeItem(at: root)
            }
        }
        await model.signIn(username: credentials.username, password: credentials.password, origin: .current)
        _ = try XCTUnwrap(model.serviceSession(for: .current), model.authenticationMessage ?? "Service sign-in failed")
        let accepted: AreaTargetProcessingJob
        if let existingID {
            guard !model.operationInProgress else {
                XCTFail("Allow the UI's current transfer to finish before completing the authorized existing task"); return
            }
            accepted = try realHallExistingJob(existingID, jobs: model.jobs, scan: scan, fingerprint: expectedSource)
            await model.refresh(jobID: existingID)
            print("REAL_HALL_CLIENT mode=existing_job_completion existingAccepted=true job=\(existingID)")
        } else {
            guard !model.jobs.contains(where: { $0.scanDirectoryPath == scan.path && $0.isPending }) else {
                XCTFail("Reconcile the existing pending Hall task before authorizing a fresh real submission"); return
            }
            await model.start(scanDirectory: scan, displayName: "测试大厅 · 授权完整联调")
            accepted = try XCTUnwrap(model.selectedJob.flatMap { $0.accepted ? $0 : nil }, model.message ?? "Real Hall upload was not accepted")
            guard !previousIDs.contains(accepted.id) else {
                XCTFail("Normal start must add a fresh task rather than replace an old identity"); return
            }
            print("REAL_HALL_CLIENT accepted=true job=\(accepted.id)")
        }
        XCTAssertEqual(accepted.serverOrigin, .current, "Real Hall work must stay on its explicitly selected current server")
        XCTAssertEqual(accepted.serverOrigin.baseURL.absoluteString, "https://at.3dugc.com")
        let id = accepted.id
        let protectedRecords = previousRecords.filter { $0.id != existingID }
        XCTAssertTrue(previousIDs.isSubset(of: Set(model.jobs.map(\.id))), "Existing production job identities must remain intact")
        let preparation = try XCTUnwrap(accepted.clientPreparation, "The real upload must use the public preparation requirements")
        XCTAssertEqual(preparation.originalFrameCount, 77)
        XCTAssertEqual(preparation.selectedFrameCount, 77)
        XCTAssertEqual(preparation.selectedIndices, Array(0..<77))
        XCTAssertEqual(preparation.processedPixelCount, 147_840_000)
        XCTAssertEqual(preparation.maximumOutputLongEdge, 1600)
        XCTAssertEqual(accepted.sourceFingerprint, expectedSource)
        let preparedSource = try await Task.detached(operation: snapshot).value
        XCTAssertEqual(preparedSource.0, before.0)
        XCTAssertEqual(preparedSource.1, before.1, "Preparing and uploading must preserve every source file byte")
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline, model.jobs.first(where: { $0.id == id })?.phase == .processing {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await model.refresh(jobID: id)
        }
        guard let finalPhase = model.jobs.first(where: { $0.id == id })?.phase,
              finalPhase == .ready || finalPhase == .downloaded else {
            XCTFail(model.message ?? model.jobs.first(where: { $0.id == id })?.detail ?? "The real Hall result did not become ready"); return
        }
        await model.download(jobID: id)
        let downloaded = try XCTUnwrap(model.jobs.first(where: { $0.id == id }).flatMap { $0.phase == .downloaded ? $0 : nil }, model.message ?? "Real Hall download failed")
        let persistedJobs = try (persist ? AreaTargetJobStore() : AreaTargetJobStore(url: root.appendingPathComponent("jobs.json"))).load()
        XCTAssertTrue(previousIDs.isSubset(of: Set(persistedJobs.map(\.id))), "Previously saved job identities must remain in the actual journal")
        XCTAssertEqual(persistedJobs.first(where: { $0.id == id })?.phase, .downloaded)
        for previous in protectedRecords {
            XCTAssertEqual(persistedJobs.first(where: { $0.id == previous.id }), previous,
                "Every pre-existing production journal record must remain equal")
        }
        let previousRecordsPreserved = protectedRecords.allSatisfy { previous in
            persistedJobs.first(where: { $0.id == previous.id }) == previous
        }
        let saved = try XCTUnwrap(downloaded.savedAsset)
        let remote = try XCTUnwrap(downloaded.remote)
        let result = try XCTUnwrap(remote.result)
        XCTAssertEqual(remote.status, .completed)
        XCTAssertNil(remote.error)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: saved.bundleURL, to: evidence.appendingPathComponent("bundle.zip"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(remote).write(to: evidence.appendingPathComponent("status.json"), options: .atomic)
        var summary: [String: Any] = ["job_id": id, "sourceFingerprint": expectedSource,
            "mode": existingID == nil ? "full_upload_workflow" : "existing_job_completion",
            "uploadedDuringThisRun": existingID == nil,
            "downloadWasAlreadyLocal": finalPhase == .downloaded,
            "intentionallyUpdatedJobIDs": existingID.map { [$0] } ?? [],
            "unchangedPreviousRecordCount": protectedRecords.count,
            "serverOrigin": downloaded.serverOrigin.rawValue,
            "serverBaseURL": downloaded.serverOrigin.baseURL.absoluteString,
            "previousServerOrigins": Dictionary(uniqueKeysWithValues: previousRecords.map { ($0.id, $0.serverOrigin.rawValue) }),
            "resultSizeBytes": result.sizeBytes, "resultSHA256": result.sha256,
            "nativeLoadVerified": false, "queryLocalizationVerified": false,
            "productionPersistence": persist, "previousJobCount": previousIDs.count,
            "sourceBytesUnchangedAfterUpload": preparedSource.1 == before.1,
            "previousJobIDsPreserved": previousIDs.isSubset(of: Set(persistedJobs.map(\.id))),
            "previousJobRecordsPreserved": previousRecordsPreserved,
            "changedPreviousJobIDs": protectedRecords.filter { previous in
                persistedJobs.first(where: { $0.id == previous.id }) != previous
            }.map(\.id)]
        func writeSummary() throws {
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence.appendingPathComponent("summary.json"), options: .atomic)
        }
        try writeSummary()
        let reopenedStore = persist ? AreaTargetAssetStore() : AreaTargetAssetStore(rootDirectory: assetRoot)
        let reopened = try await Task.detached { try reopenedStore.asset(jobID: id) }.value
        XCTAssertEqual(try XCTUnwrap(reopened), saved)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: saved.manifestURL)) as? [String: Any])
        let client = try XCTUnwrap(manifest["clientPreparation"] as? [String: Any])
        let server = try XCTUnwrap(manifest["scanPreparation"] as? [String: Any])
        XCTAssertEqual(client["originalFrameCount"] as? Int, 77)
        XCTAssertEqual(client["selectedFrameCount"] as? Int, 77)
        XCTAssertEqual(client["selectedIndices"] as? [Int], Array(0..<77))
        XCTAssertEqual(client["processedPixelCount"] as? Int, 147_840_000)
        XCTAssertEqual(server["originalFrameCount"] as? Int, 77)
        XCTAssertEqual(server["selectedFrameCount"] as? Int, 77)
        XCTAssertEqual(server["selectedIndices"] as? [Int], Array(0..<77))
        XCTAssertEqual(server["resizedFrameCount"] as? Int, 0)
        XCTAssertEqual(server["processedPixelCount"] as? Int, 147_840_000)
        let manifestKeyframes = try XCTUnwrap(manifest["keyframeCount"] as? Int)
        XCTAssertGreaterThan(manifestKeyframes, 0)
        XCTAssertLessThanOrEqual(manifestKeyframes, 77)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(saved.featuresURL.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        let connection = try XCTUnwrap(database)
        func scalar(_ sql: String) throws -> String {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            let prepared = try XCTUnwrap(statement)
            XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
            return String(cString: try XCTUnwrap(sqlite3_column_text(prepared, 0)))
        }
        XCTAssertEqual(try scalar("PRAGMA integrity_check"), "ok")
        let keyframes = try XCTUnwrap(Int(scalar("SELECT COUNT(*) FROM keyframes")))
        let features = try XCTUnwrap(Int(scalar("SELECT COUNT(*) FROM features")))
        let vocabulary = try XCTUnwrap(Int(scalar("SELECT COUNT(*) FROM vocabulary")))
        XCTAssertEqual(keyframes, manifestKeyframes)
        XCTAssertGreaterThan(keyframes, 0)
        XCTAssertLessThanOrEqual(keyframes, 77)
        XCTAssertGreaterThanOrEqual(features, keyframes * 20)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM keyframes k WHERE (SELECT COUNT(*) FROM features f WHERE f.keyframe_id=k.id)<20"), "0")
        XCTAssertGreaterThan(vocabulary, 0)
        let validated = try await Task.detached { try AreaTargetFeatureDatabase.load(url: saved.featuresURL) }.value
        XCTAssertEqual(validated.keyframes.count, keyframes)
        XCTAssertEqual(validated.featureCount, features)
        let native = AreaTargetOfflineLocalizer()
        defer { native.close() }
        let loadedFeatures = try await native.load(url: saved.featuresURL)
        XCTAssertEqual(loadedFeatures, features)
        native.close()
        await native.waitUntilIdle()
        let after = try await Task.detached(operation: snapshot).value
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1, "Original model, JPEGs and all metadata must retain their exact bytes")
        summary["submittedFrameCount"] = 77; summary["validKeyframeCount"] = keyframes
        summary["featureCount"] = features
        summary["vocabularyCount"] = vocabulary; summary["nativeLoadVerified"] = true
        XCTAssertTrue(previousIDs.isSubset(of: Set(model.jobs.map(\.id))), "Persisted prior jobs must remain present after download")
        summary["sourceBytesUnchanged"] = after.1 == before.1
        summary["previousJobIDsPreserved"] = previousIDs.isSubset(of: Set(persistedJobs.map(\.id)))
        summary["previousJobRecordsPreserved"] = previousRecordsPreserved
        summary["clientPreparation"] = client; summary["scanPreparation"] = server
        try writeSummary()
        print("REAL_HALL_CLIENT sourceFingerprint=\(expectedSource) job=\(id) bytes=\(result.sizeBytes) sha256=\(result.sha256) submittedFrames=77 validKeyframes=\(keyframes) features=\(features) vocabulary=\(vocabulary) nativeImportedFeatures=\(loadedFeatures)")
        if !persist { await model.signOut(origin: .current) }
    }

    private func makeSyntheticScan(_ directory: URL) throws {
        let images = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let vertices = [(-4.0,-3.0,-3.0),(4,-3,-3),(4,3,-3),(-4,3,-3),(-4,-3,-3.2),(4,-3,-3.2),(4,3,-3.2),(-4,3,-3.2)]
        let faces = [(1,2,3,4),(6,5,8,7),(5,1,4,8),(2,6,7,3),(4,3,7,8),(5,6,2,1)]
        var obj = vertices.map { "v \($0.0) \($0.1) \($0.2)" }
        for (a,b,c,d) in faces { obj.append("f \(a) \(b) \(c)"); obj.append("f \(a) \(c) \(d)") }
        try (obj.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("model.obj"), atomically: true, encoding: .utf8)
        var sourceImages: [Data] = []
        for index in 0..<3 {
            var seed = UInt64(1024 + index)
            var pixels = [UInt8](repeating: 255, count: 640 * 480 * 4)
            for pixel in 0..<(640 * 480) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let shade = UInt8(truncatingIfNeeded: seed >> 32)
                for channel in 0..<3 { pixels[pixel * 4 + channel] = shade }
            }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            let image = CGImage(width: 640, height: 480, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.opaque = true
            let large = UIGraphicsImageRenderer(size: CGSize(width: 1920, height: 1440), format: format).image { context in
                context.cgContext.interpolationQuality = .none
                UIImage(cgImage: image).draw(in: CGRect(x: 0, y: 0, width: 1920, height: 1440))
            }
            sourceImages.append(try XCTUnwrap(large.pngData()))
        }
        var frames: [[String: Any]] = []
        for index in 0..<100 {
            let filename = "images/frame_\(index).png"
            try sourceImages[index % 3].write(to: directory.appendingPathComponent(filename))
            frames.append(["index": index, "timestamp": Double(index + 1), "imageFile": filename,
                "transform": [1.0,0,0,0,0,1,0,0,0,0,1,0,Double(index % 3 - 1)*0.1,0,0,1],
                "imageOrientation": "landscapeRight", "image": ["width":1920,"height":1440],
                "intrinsics": ["fx":960.0,"fy":960.0,"cx":960.0,"cy":720.0]])
        }
        try JSONSerialization.data(withJSONObject: ["schemaVersion":1, "coordinateSystem":"arkit-world",
            "matrixLayout":"arkit-column-major", "units":"meters", "frames":frames])
            .write(to: directory.appendingPathComponent("manifest.json"))
    }
}

// Test-only source snapshot paths may arrive through Foundation's /var vs /private/var alias.
private func liveServiceCredentials(_ environment: [String: String]) throws -> (username: String, password: String) {
    guard let username = environment["AREA_TARGET_LIVE_USERNAME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !username.isEmpty, let password = environment["AREA_TARGET_LIVE_PASSWORD"], !password.isEmpty else {
        throw XCTSkip("Set AREA_TARGET_LIVE_USERNAME and AREA_TARGET_LIVE_PASSWORD for an explicitly enabled authenticated live smoke")
    }
    return (username, password)
}

private func realHallRelativePath(_ url: URL, in scan: URL) throws -> String {
    guard url.isFileURL, scan.isFileURL else { throw AreaTargetLocalError.missingScan }
    func components(_ value: URL) -> [String] {
        var result = value.standardizedFileURL.pathComponents
        if result.count >= 3, Array(result.prefix(3)) == ["/", "private", "var"] {
            result.remove(at: 1) // Foundation can enumerate the same iOS sandbox via either alias.
        }
        return result
    }
    let root = components(scan)
    let child = components(url)
    guard child.count > root.count, Array(child.prefix(root.count)) == root else {
        throw AreaTargetLocalError.missingScan
    }
    let relative = child.dropFirst(root.count).joined(separator: "/")
    guard AreaTargetFileSafety.safeRelativePath(relative) else { throw AreaTargetLocalError.missingScan }
    return relative
}

// No submission or cross-server fallback is authorized by the existing-job completion branch.
private func realHallExistingJob(_ id: String, jobs: [AreaTargetProcessingJob], scan: URL,
                                 fingerprint: String) throws -> AreaTargetProcessingJob {
    guard id == "af13ab9f-ed0b-499e-b8eb-533288cfed65", AreaTargetJobStore.validID(id),
          fingerprint == "449a7e557d0963bf8f2dc0ff978da3f7c5ea7ee7caa9b4a2dac7eac7d348ae52",
          let job = jobs.first(where: { $0.id == id }), job.serverOrigin == .current,
          job.accepted, [.processing, .ready, .downloaded].contains(job.phase),
          job.sourceFingerprint == fingerprint,
          realHallScanPathsMatch(job.scanDirectory, current: scan) else {
        throw AreaTargetLocalError.invalidJournal
    }
    return job
}

// App updates may relocate a preserved iOS data container; this exception is QA-only.
// The caller first verifies the authorized job/current server/full raw fingerprint.
private func realHallScanPathsMatch(_ recorded: URL, current: URL) -> Bool {
    func components(_ value: URL) -> [String]? {
        guard value.isFileURL, value.host == nil || value.host == "",
              value.query == nil, value.fragment == nil,
              !value.pathComponents.contains("."), !value.pathComponents.contains("..") else { return nil }
        var result = value.standardizedFileURL.pathComponents
        if Array(result.prefix(3)) == ["/", "private", "var"] { result.remove(at: 1) }
        return result
    }
    guard let old = components(recorded), let live = components(current) else { return false }
    if old == live { return true }
    let prefix = ["/", "var", "mobile", "Containers", "Data", "Application"]
    guard old.count == 9, live.count == 9,
          Array(old.prefix(6)) == prefix, Array(live.prefix(6)) == prefix,
          old[7] == "Documents", live[7] == "Documents",
          old[8] == live[8], old[8].hasPrefix("scan_"),
          UUID(uuidString: old[6])?.uuidString.lowercased() == old[6].lowercased(),
          UUID(uuidString: live[6])?.uuidString.lowercased() == live[6].lowercased() else { return false }
    return true // The only remaining differing component is the canonical container UUID.
}
