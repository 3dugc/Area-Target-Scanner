import XCTest
import CryptoKit
import ZIPFoundation
@testable import AreaTargetScanner

@MainActor
final class AreaTargetProcessingModelTests: XCTestCase {
    private var root: URL!
    private var scan: URL!
    private var api: AreaFlowAPI!
    private var archive: AreaFlowArchive!
    private var journal: AreaFlowJournal!
    private var tokens: AreaFlowTokens!
    private var assets: AreaFlowAssets!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaFlow-\(UUID().uuidString)")
        scan = root.appendingPathComponent("scan_fixture")
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        api = AreaFlowAPI(root: root)
        archive = AreaFlowArchive(url: root.appendingPathComponent("upload.zip"))
        journal = AreaFlowJournal()
        tokens = AreaFlowTokens()
        assets = AreaFlowAssets(root: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func model() -> AreaTargetProcessingModel {
        AreaTargetProcessingModel(api: api, archiver: archive, jobStore: journal,
            tokenStore: tokens, assetStore: assets, pollInterval: 0.02, uploadDirectory: root.appendingPathComponent("uploads"))
    }

    func testSignedOutStartDoesNotCreateTaskTokenOrArchive() async throws {
        let client = AreaTargetAPIClient(sessionStore: AreaServiceTestSessions())
        let model = AreaTargetProcessingModel(api: client, archiver: archive, jobStore: journal,
            tokenStore: tokens, assetStore: assets, uploadDirectory: root.appendingPathComponent("uploads"))
        await model.start(scanDirectory: scan, displayName: "登录后上传")
        XCTAssertTrue(journal.jobs.isEmpty)
        XCTAssertTrue(tokens.values.isEmpty)
        XCTAssertEqual(archive.calls, 0)
        XCTAssertEqual(model.message, "服务登录已失效，请重新登录。")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.path))
    }

    func testSignInAndSignOutPreserveTaskIdentityAndPreventFurtherRequests() async throws {
        let authenticatedAPI = AreaFlowServiceAPI(base: api)
        let model = AreaTargetProcessingModel(api: authenticatedAPI, archiver: archive, jobStore: journal,
            tokenStore: tokens, assetStore: assets, uploadDirectory: root.appendingPathComponent("uploads"))
        await model.signIn(username: "scanner", password: "temporary password", origin: .current)
        XCTAssertEqual(model.serviceSession(for: .current)?.username, "scanner")
        XCTAssertFalse(model.isAuthenticating)
        XCTAssertNil(model.authenticationMessage)
        await model.start(scanDirectory: scan, displayName: "已登录上传")
        let id = try XCTUnwrap(model.selectedJobID)
        let taskToken = try XCTUnwrap(tokens.values[id])
        let before = await api.events.count
        await model.signOut(origin: .current)
        XCTAssertNil(model.serviceSession(for: .current))
        XCTAssertNil(authenticatedAPI.saved)
        await model.resume(jobID: id)
        let after = await api.events.count
        XCTAssertEqual(before, after)
        XCTAssertEqual(tokens.values[id], taskToken)
        XCTAssertEqual(model.jobs.first?.id, id)
        XCTAssertEqual(model.jobs.first?.phase, .processing)
    }

    func testUnknownKeychainStateDoesNotClaimLocalLogout() async throws {
        let sessions = AreaServiceTestSessions.authenticated()
        let client = AreaTargetAPIClient(sessionStore: sessions)
        let model = AreaTargetProcessingModel(api: client, archiver: archive, jobStore: journal,
            tokenStore: tokens, assetStore: assets, uploadDirectory: root.appendingPathComponent("uploads"))
        XCTAssertNotNil(model.serviceSession(for: .current))
        sessions.failLoads = true
        sessions.failRemovals = true
        await model.signOut(origin: .current)
        XCTAssertNotNil(model.serviceSession(for: .current), "Unknown Keychain state must retain the prior session until confirmed")
        XCTAssertEqual(model.authenticationMessage, AreaTargetAPIError.credentialStorage.localizedDescription)
        sessions.failLoads = false
        XCTAssertNotNil(try sessions.load(origin: .current))
    }

    func testRejectedServiceSessionStopsPollingAndPreservesPendingTask() async throws {
        let authenticatedAPI = AreaFlowServiceAPI(base: api)
        authenticatedAPI.saved = AreaFlowServiceAPI.fixtureSession
        let model = AreaTargetProcessingModel(api: authenticatedAPI, archiver: archive, jobStore: journal,
            tokenStore: tokens, assetStore: assets, pollInterval: 0.02, uploadDirectory: root.appendingPathComponent("uploads"))
        await model.start(scanDirectory: scan, displayName: "服务会话失效")
        let id = try XCTUnwrap(model.selectedJobID)
        authenticatedAPI.rejectStatus = true
        model.setAppActive(true)
        defer { model.setAppActive(false) }
        for _ in 0..<100 {
            if model.serviceSession(for: .current) == nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let failures = authenticatedAPI.statusCalls
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(authenticatedAPI.statusCalls, failures, "An expired service session must stop foreground polling")
        XCTAssertNil(model.serviceSession(for: .current))
        XCTAssertEqual(model.jobs.first?.id, id)
        XCTAssertEqual(model.jobs.first?.phase, .processing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.path))
        XCTAssertEqual(model.message, "服务登录已失效，请重新登录。")
    }

    func testProductionUIAndPersistentQAResolveTheSameOwner() {
        let ui = AreaTargetProcessingModel.shared
        let persistentQA = AreaTargetProcessingModel.shared
        XCTAssertTrue(ui === persistentQA, "UI and persistent QA must share one journal-writing owner")
        XCTAssertFalse(model() === ui, "Explicit injected/isolated models remain independent")
    }

    func testSharedConsumersKeepPendingGuardAndDownloadedJobsInOneJournal() async throws {
        let ui = model()
        let persistentQA = ui
        await persistentQA.start(scanDirectory: scan, displayName: "QA")
        let firstID = try XCTUnwrap(persistentQA.selectedJobID)
        await ui.start(scanDirectory: scan, displayName: "UI duplicate")
        XCTAssertEqual(ui.selectedJobID, firstID)
        XCTAssertEqual(journal.jobs.count, 1, "The UI must see QA's pending source immediately")
        await api.setRemoteStatus(.completed)
        await persistentQA.refresh(jobID: firstID)
        await persistentQA.download(jobID: firstID)
        let first = try XCTUnwrap(journal.jobs.first)
        XCTAssertEqual(first.phase, .downloaded)
        let otherScan = root.appendingPathComponent("scan_other")
        try FileManager.default.createDirectory(at: otherScan, withIntermediateDirectories: true)
        await ui.start(scanDirectory: otherScan, displayName: "UI new task")
        let secondID = try XCTUnwrap(ui.selectedJobID)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(Set(journal.jobs.map(\.id)), Set([firstID, secondID]))
        XCTAssertEqual(journal.jobs.first(where: { $0.id == firstID }), first,
            "A later UI save must retain the completed QA record")
        XCTAssertEqual(persistentQA.jobs, ui.jobs)
        let events = await api.events
        XCTAssertEqual(events.filter { $0.0 == "submit" }.count, 2)
    }

    func testLegacyJournalRestoreDoesNotRewriteUnchangedRecords() async throws {
        let store = AreaTargetJobStore(url: root.appendingPathComponent("legacy/jobs.json"))
        var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "旧服务器失败任务", createdAt: Date(timeIntervalSince1970: 100))
        job.phase = .failed
        try store.save([job])
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url))
        let originalBytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try originalBytes.write(to: store.url)
        let model = AreaTargetProcessingModel(api: api, archiver: archive, jobStore: store,
            tokenStore: tokens, assetStore: assets, uploadDirectory: root.appendingPathComponent("uploads"))
        for _ in 0..<200 {
            if !model.isRestoringAssets { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(model.isRestoringAssets)
        XCTAssertEqual(try Data(contentsOf: store.url), originalBytes, "Domain migration must not rewrite unchanged legacy records on restoration")
        XCTAssertEqual(try store.load(), [job])
        let events = await api.events
        XCTAssertTrue(events.isEmpty, "Restoration must be offline")
    }

    func testNewTasksPersistCurrentServerOrigin() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "新服务器")
        let job = try XCTUnwrap(journal.jobs.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        XCTAssertEqual(object["serverOrigin"] as? String, "current")
    }

    func testUnknownServerOriginFailsClosedWhenReadingJournal() throws {
        let job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "未知来源", createdAt: Date())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        for origin in ["unknown", "https://evil.test", "current?token=secret"] {
            object["serverOrigin"] = origin
            let bytes = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(AreaTargetProcessingJob.self, from: bytes))
        }
    }

    func testMixedOriginsKeepRequirementsRetryStatusAndDownloadOnTheirOwnServer() async throws {
        let legacyAPI = AreaFlowAPI(root: root)
        let legacyScan = root.appendingPathComponent("scan_legacy")
        try FileManager.default.createDirectory(at: legacyScan, withIntermediateDirectories: true)
        var legacy = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: legacyScan.path,
            displayName: "旧上传", createdAt: Date(timeIntervalSince1970: 10))
        legacy.phase = .paused
        journal.jobs = [legacy]
        tokens.values[legacy.id] = String(repeating: "b", count: 64)
        await legacyAPI.setRejectBeforeAccepting(true)
        await api.setRejectBeforeAccepting(true)
        let model = AreaTargetProcessingModel(api: api, legacyAPI: legacyAPI, archiver: archive, jobStore: journal,
            tokenStore: tokens, assetStore: assets, uploadDirectory: root.appendingPathComponent("uploads"))
        await model.start(scanDirectory: scan, displayName: "新上传")
        let current = try XCTUnwrap(model.selectedJob)
        XCTAssertEqual(current.serverOrigin, .current)
        XCTAssertEqual(model.jobs.first(where: { $0.id == legacy.id })?.serverOrigin, .legacy)
        await model.resume(jobID: legacy.id)
        XCTAssertEqual(model.jobs.first(where: { $0.id == legacy.id })?.phase, .paused)
        await api.setRejectBeforeAccepting(false)
        await legacyAPI.setRejectBeforeAccepting(false)
        await model.resume(jobID: legacy.id)
        await model.resume(jobID: current.id)
        await api.setRemoteStatus(.completed)
        await legacyAPI.setRemoteStatus(.completed)
        for id in [legacy.id, current.id] {
            await model.refresh(jobID: id)
            await model.download(jobID: id)
            XCTAssertEqual(model.jobs.first(where: { $0.id == id })?.phase, .downloaded)
        }
        let currentEvents = await api.events
        let legacyEvents = await legacyAPI.events
        XCTAssertEqual(currentEvents.map { $0.0 }, ["submit", "status", "submit", "status", "status", "download"])
        XCTAssertEqual(legacyEvents.map { $0.0 }, ["status", "submit", "status", "submit", "status", "status", "download"])
        XCTAssertTrue(currentEvents.allSatisfy { $0.1 == current.id && $0.2 == tokens.values[current.id] })
        XCTAssertTrue(legacyEvents.allSatisfy { $0.1 == legacy.id && $0.2 == tokens.values[legacy.id] })
        let currentRequirements = await api.requirementsCallCount()
        let legacyRequirements = await legacyAPI.requirementsCallCount()
        XCTAssertEqual(currentRequirements, 1)
        XCTAssertEqual(legacyRequirements, 1)
        XCTAssertEqual(archive.calls, 2, "Both retries reuse their separately frozen ZIP")
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(journal.jobs)) as? [[String: Any]])
        XCTAssertNil(objects.first(where: { $0["id"] as? String == legacy.id })?["serverOrigin"], "Do not backfill legacy records")
        XCTAssertEqual(objects.first(where: { $0["id"] as? String == current.id })?["serverOrigin"] as? String, "current")
    }

    func testAcceptedLegacyNotFoundCannotFallbackToCurrentServer() async throws {
        let legacyAPI = AreaFlowAPI(root: root)
        var legacy = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "旧已接收", createdAt: Date())
        legacy.accepted = true; legacy.phase = .processing
        journal.jobs = [legacy]; tokens.values[legacy.id] = String(repeating: "b", count: 64)
        let model = AreaTargetProcessingModel(api: api, legacyAPI: legacyAPI, archiver: archive, jobStore: journal,
            tokenStore: tokens, assetStore: assets, uploadDirectory: root.appendingPathComponent("uploads"))
        await model.resume(jobID: legacy.id)
        XCTAssertEqual(model.jobs.first?.phase, .failed)
        let currentEvents = await api.events
        let legacyEvents = await legacyAPI.events
        XCTAssertTrue(currentEvents.isEmpty)
        XCTAssertEqual(legacyEvents.map { $0.0 }, ["status"])
        XCTAssertEqual(archive.calls, 0)
    }

    func testDownloadedAssetsRestoreForBothOriginsWithoutAnyNetworkOrCredential() async throws {
        let legacyAPI = AreaFlowAPI(root: root)
        for origin in AreaTargetServerOrigin.allCases {
            var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
                displayName: "本机资产", createdAt: Date(), serverOrigin: origin == .current ? .current : nil)
            let directory = root.appendingPathComponent(job.id)
            let asset = AreaTargetSavedAsset(jobID: job.id, bundleURL: directory.appendingPathComponent("asset.zip"), directoryURL: directory,
                modelURL: directory.appendingPathComponent("optimized.glb"), featuresURL: directory.appendingPathComponent("features.db"),
                manifestURL: directory.appendingPathComponent("manifest.json"), savedAt: Date())
            job.phase = .downloaded; job.savedAsset = asset
            journal.jobs.append(job); assets.values[job.id] = asset
        }
        let original = journal.jobs
        let model = AreaTargetProcessingModel(api: api, legacyAPI: legacyAPI, archiver: archive, jobStore: journal,
            tokenStore: tokens, assetStore: assets, uploadDirectory: root.appendingPathComponent("uploads"))
        for _ in 0..<200 {
            if !model.isRestoringAssets { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        for job in original {
            await model.resume(jobID: job.id)
            await model.refresh(jobID: job.id)
            await model.download(jobID: job.id)
            XCTAssertEqual(model.jobs.first(where: { $0.id == job.id })?.savedAsset, job.savedAsset)
            XCTAssertEqual(model.jobs.first(where: { $0.id == job.id })?.serverOrigin, job.serverOrigin)
        }
        let currentEvents = await api.events
        let legacyEvents = await legacyAPI.events
        XCTAssertTrue(currentEvents.isEmpty); XCTAssertTrue(legacyEvents.isEmpty)
        XCTAssertTrue(tokens.values.isEmpty)
    }

    func testFetchedRequirementsReachArchiveAndPreparationIsFrozenInJournal() async throws {
        let requirements = try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: Data(#"{"schemaVersion":1,"policy":"mobile-scan-preparation-v1","policyVersion":1,"profiles":{"fast":{"maxFrames":80,"maximumLongEdge":1600,"maximumTotalPixels":200000000}},"safety":{"maximumRequestBytes":536870912,"maximumExpandedBytes":524288000,"maximumArchiveEntries":10000,"maximumSourceFrameCount":10000,"maximumImagePixels":32000000,"maximumImageDimension":8192,"maximumMetadataBytes":8388608}}"#.utf8))
        await api.setRequirements(requirements)
        let preparation = AreaTargetClientPreparation(schemaVersion: 1, policy: "mobile-scan-preparation-v1", policyVersion: 1,
            profile: "fast", preparedBy: "client", originalFrameCount: 120, selectedFrameCount: 2, selectedIndices: [0, 119],
            processedPixelCount: 3_840_000, resizedFrameCount: 2, maximumOutputLongEdge: 1600, scaleDigest: String(repeating: "d", count: 64))
        archive.preparation = preparation
        let model = model()
        await model.start(scanDirectory: scan, displayName: "完整原扫描")
        let requestCount = await api.requirementsCallCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(archive.requirementsSeen, requirements)
        XCTAssertEqual(model.jobs.first?.clientPreparation, preparation)
        XCTAssertEqual(journal.jobs.first?.clientPreparation, preparation)
        XCTAssertEqual(model.jobs.first?.phase, .processing)
    }

    func testRequirementsFailureFallsBackToRawAndImmutableRetryDoesNotRefetch() async throws {
        await api.setRejectBeforeAccepting(true)
        let model = model()
        await model.start(scanDirectory: scan, displayName: "完整原扫描")
        let id = try XCTUnwrap(model.jobs.first?.id)
        let requestCount = await api.requirementsCallCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertNil(archive.requirementsSeen)
        XCTAssertNil(model.jobs.first?.clientPreparation)
        XCTAssertEqual(model.jobs.first?.phase, .paused)
        await api.setRejectBeforeAccepting(false)
        await model.resume(jobID: id)
        let retryRequestCount = await api.requirementsCallCount()
        XCTAssertEqual(retryRequestCount, 1)
        XCTAssertEqual(archive.calls, 1)
        XCTAssertEqual(model.jobs.first?.phase, .processing)
    }

    func testCancellationWhileFetchingRequirementsDoesNotPrepareOrSubmit() async throws {
        await api.setHoldRequirements(true)
        let model = model()
        let task = Task { await model.start(scanDirectory: scan, displayName: "完整原扫描") }
        for _ in 0..<200 {
            if await api.requirementsCallCount() > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        model.pause(); await task.value
        XCTAssertEqual(archive.calls, 0)
        let eventCount = await api.events.count
        XCTAssertEqual(eventCount, 0)
        XCTAssertEqual(model.jobs.first?.phase, .paused)
        XCTAssertTrue(model.deletionBlocked(scanPath: scan.path))
    }

    func testUploadProcessingDownloadPersistsLocalAssetAndTaskIdentity() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "一楼大厅")
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(job.phase, .processing)
        XCTAssertEqual(job.displayName, "一楼大厅")
        XCTAssertEqual(journal.jobs.first?.id, job.id)
        XCTAssertEqual(tokens.values[job.id]?.count, 64)
        XCTAssertFalse(model.deletionBlocked(scanPath: scan.path), "Accepted server work no longer needs the source directory")
        await api.setRemoteStatus(.completed)
        await model.refresh(jobID: job.id)
        XCTAssertEqual(model.jobs.first?.phase, .ready)
        await model.download(jobID: job.id)
        let saved = try XCTUnwrap(model.jobs.first?.savedAsset)
        XCTAssertEqual(model.jobs.first?.phase, .downloaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.bundleURL.path))
        XCTAssertEqual(journal.jobs.first?.savedAsset?.bundleURL, saved.bundleURL)
        let events = await api.events
        XCTAssertEqual(events.map { $0.0 }, ["submit", "status", "status", "download"])
        XCTAssertTrue(events.allSatisfy { $0.1 == job.id && $0.2 == tokens.values[job.id] })
    }

    func testLostUploadResponseRecoversKnownIDWithoutSubmittingAgain() async throws {
        await api.setLostResponse(true)
        let model = model()
        await model.start(scanDirectory: scan, displayName: "走廊")
        let id = try XCTUnwrap(model.jobs.first?.id)
        XCTAssertEqual(model.jobs.first?.phase, .submissionUnknown)
        XCTAssertTrue(model.deletionBlocked(scanPath: scan.path))
        let restored = self.model()
        await restored.resume(jobID: id)
        XCTAssertEqual(restored.jobs.first?.id, id)
        XCTAssertEqual(restored.jobs.first?.phase, .processing)
        let events = await api.events
        XCTAssertEqual(events.map { $0.0 }, ["submit", "status"])
        XCTAssertEqual(Set(events.map { $0.1 }), [id])
    }

    func testRejectedUploadCanRetrySameArchiveAndIdentityAfterReconciliation() async throws {
        await api.setRejectBeforeAccepting(true)
        let model = model()
        await model.start(scanDirectory: scan, displayName: "测试")
        let id = try XCTUnwrap(model.jobs.first?.id)
        XCTAssertEqual(model.jobs.first?.phase, .paused)
        await api.setRejectBeforeAccepting(false)
        await model.resume(jobID: id)
        XCTAssertEqual(model.jobs.first?.id, id)
        XCTAssertEqual(model.jobs.first?.phase, .processing)
        XCTAssertEqual(archive.calls, 1, "Retry must use the immutable archive")
        let events = await api.events
        XCTAssertEqual(events.map { $0.0 }, ["submit", "status", "submit"])
        XCTAssertEqual(Set(events.map { $0.1 }), [id])
    }

    func testChangedArchiveIsNotRetriedUnderTheOldSubmissionIdentity() async throws {
        await api.setRejectBeforeAccepting(true)
        let model = model()
        await model.start(scanDirectory: scan, displayName: "测试")
        let id = try XCTUnwrap(model.jobs.first?.id)
        try Data("changed".utf8).write(to: XCTUnwrap(model.jobs.first?.archiveURL))
        await api.setRejectBeforeAccepting(false)
        await model.resume(jobID: id)
        XCTAssertNotNil(model.message)
        let events = await api.events
        XCTAssertEqual(events.filter { $0.0 == "submit" }.count, 1)
        XCTAssertEqual(model.jobs.first?.phase, .failed)
    }

    func testJournalFailurePreventsArchiveAndNetworkSideEffects() async throws {
        journal.failWrites = true
        let model = model()
        await model.start(scanDirectory: scan, displayName: "测试")
        XCTAssertNotNil(model.message)
        XCTAssertEqual(archive.calls, 0)
        let events = await api.events
        XCTAssertTrue(events.isEmpty)
    }

    func testTokenFailurePreventsJournalAndNetworkSubmission() async throws {
        tokens.failWrites = true
        let model = model()
        await model.start(scanDirectory: scan, displayName: "测试")
        XCTAssertTrue(journal.jobs.isEmpty)
        XCTAssertNotNil(model.message)
        let events = await api.events
        XCTAssertTrue(events.isEmpty)
    }

    func testExistingPendingTaskIsSelectedInsteadOfDuplicatingAnUpload() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "测试")
        let id = try XCTUnwrap(model.jobs.first?.id)
        await model.start(scanDirectory: scan, displayName: "同一场景")
        XCTAssertEqual(model.selectedJobID, id)
        XCTAssertEqual(model.jobs.count, 1)
        let events = await api.events
        XCTAssertEqual(events.filter { $0.0 == "submit" }.count, 1)
    }

    func testBackgroundCancelsLocalUploadAndPreservesReconcilableTask() async throws {
        await api.setHoldUpload(true)
        let model = model()
        model.setAppActive(true)
        let operation = Task { await model.start(scanDirectory: self.scan, displayName: "测试") }
        for _ in 0..<200 {
            if model.jobs.first?.phase == .uploading { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(model.operationInProgress)
        model.setAppActive(false)
        await operation.value
        XCTAssertFalse(model.operationInProgress)
        XCTAssertEqual(model.jobs.first?.phase, .submissionUnknown)
        XCTAssertTrue(model.deletionBlocked(scanPath: scan.path))
        XCTAssertNotNil(journal.jobs.first?.id)
        XCTAssertNotNil(tokens.values[journal.jobs.first!.id])
    }

    func testPollingOnlyRunsWhileActiveAndReachesDownloadReadyState() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "测试")
        await api.setRemoteStatus(.completed)
        model.setAppActive(true)
        for _ in 0..<200 {
            if model.jobs.first?.phase == .ready { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(model.jobs.first?.phase, .ready)
        model.setAppActive(false)
        let before = await api.events.count
        try await Task.sleep(nanoseconds: 60_000_000)
        let after = await api.events.count
        XCTAssertEqual(before, after)
    }

    func testExpiredResultDoesNotErasePreviouslyVerifiedAsset() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "测试")
        let id = try XCTUnwrap(model.jobs.first?.id)
        await api.setRemoteStatus(.completed)
        await model.refresh(jobID: id)
        await model.download(jobID: id)
        let saved = try XCTUnwrap(model.jobs.first?.savedAsset)
        await api.setExpired(true)
        await model.download(jobID: id)
        XCTAssertEqual(model.jobs.first?.savedAsset, saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.bundleURL.path))
        XCTAssertEqual(model.jobs.first?.phase, .downloaded)
    }

    func testCancellationDuringAssetPublicationKeepsCommittedAssetDownloadableAndShareable() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "测试")
        let id = try XCTUnwrap(model.jobs.first?.id)
        await api.setRemoteStatus(.completed)
        await model.refresh(jobID: id)

        let published = expectation(description: "Asset store published its verified bundle")
        let releaseSave = DispatchSemaphore(value: 0)
        defer { releaseSave.signal() }
        assets.afterPublishing = {
            published.fulfill()
            _ = releaseSave.wait(timeout: .now() + 5)
        }
        let operation = Task { await model.download(jobID: id) }
        await fulfillment(of: [published], timeout: 5)
        XCTAssertTrue(model.operationInProgress)
        model.pause()
        releaseSave.signal()
        await operation.value

        let saved = try XCTUnwrap(assets.values[id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.bundleURL.path))
        XCTAssertEqual(model.jobs.first?.phase, .downloaded)
        XCTAssertEqual(model.jobs.first?.savedAsset, saved)
        XCTAssertEqual(journal.jobs.first?.phase, .downloaded)
        XCTAssertEqual(journal.jobs.first?.savedAsset, saved)
        XCTAssertEqual(model.selectedJob?.savedAsset?.bundleURL, saved.bundleURL, "Sharing must use the committed local bundle")
        XCTAssertFalse(model.operationInProgress)
        XCTAssertNil(model.message)

        await api.setExpired(true)
        let before = await api.events.count
        await model.download(jobID: id)
        let after = await api.events.count
        XCTAssertEqual(before, after, "A committed local asset remains available after the cloud result expires")
        XCTAssertEqual(model.jobs.first?.phase, .downloaded)
        XCTAssertEqual(model.jobs.first?.savedAsset, saved)
    }

    func testInterruptedServerJobShowsFailureAndAllowsExplicitNewSubmission() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "测试")
        let oldID = try XCTUnwrap(model.jobs.first?.id)
        await api.setRemoteStatus(.failed)
        await model.refresh(jobID: oldID)
        XCTAssertEqual(model.jobs.first?.phase, .failed)
        XCTAssertFalse(model.deletionBlocked(scanPath: scan.path))
        await api.setRemoteStatus(.queued)
        await model.start(scanDirectory: scan, displayName: "重新处理")
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertNotEqual(model.selectedJobID, oldID)
    }

    func testServerFailureMessagesDistinguishInvalidScanWithoutExposingDiagnostics() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "测试大厅")
        let id = try XCTUnwrap(model.jobs.first?.id)
        let cases: [(code: String, retryable: Bool, detail: String)] = [
            ("processing_failed", true, "服务器未能完成处理，请稍后重新提交。"),
            ("invalid_scan", false, "云端检测到扫描数据无效，请检查模型、图像和相机数据后重新提交。"),
            ("processing_interrupted", false, "服务器处理已中断，请重新提交任务。"),
            ("future_server_failure", true, "服务器未能完成处理，请稍后重新提交。")
        ]
        for value in cases {
            let problem = AreaTargetAPIProblem(code: value.code, message: "Internal server diagnostics must remain hidden", retryable: value.retryable)
            await api.setRemoteProblem(problem)
            await api.setRemoteStatus(.failed)
            await model.refresh(jobID: id)
            let job = try XCTUnwrap(model.jobs.first)
            XCTAssertEqual(job.phase, .failed, value.code)
            XCTAssertEqual(job.detail, value.detail, value.code)
            XCTAssertFalse(job.detail.contains(problem.message), value.code)
            XCTAssertEqual(job.remote?.error, problem, "Preserve the structured API problem for reconciliation")
            XCTAssertEqual(journal.jobs.first?.remote?.error, problem)
            XCTAssertTrue(FileManager.default.fileExists(atPath: scan.path))
        }
    }

    func testMissingTokenCannotUploadOrQueryAndKeepsSourceProtected() async throws {
        await api.setLostResponse(true)
        let model = model()
        await model.start(scanDirectory: scan, displayName: "测试")
        let id = try XCTUnwrap(model.jobs.first?.id)
        tokens.values.removeAll()
        let before = await api.events.count
        await model.resume(jobID: id)
        let after = await api.events.count
        XCTAssertEqual(before, after)
        XCTAssertNotNil(model.message)
        XCTAssertTrue(model.deletionBlocked(scanPath: scan.path))
    }

    func testMissingOrExpiredDownloadBecomesTerminalAndAllowsNewTask() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "测试")
        let oldID = try XCTUnwrap(model.jobs.first?.id)
        await api.setRemoteStatus(.completed)
        await model.refresh(jobID: oldID)
        await api.setExpired(true)
        await model.download(jobID: oldID)
        XCTAssertEqual(model.jobs.first?.phase, .failed)
        await api.setExpired(false)
        await model.start(scanDirectory: scan, displayName: "重新处理")
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertNotEqual(model.selectedJobID, oldID)
    }

    func testRejectedArchiveIsDurableAndAcceptedArchiveIsRemoved() async throws {
        await api.setRejectBeforeAccepting(true)
        let model = model()
        await model.start(scanDirectory: scan, displayName: "测试")
        let job = try XCTUnwrap(model.jobs.first)
        let path = try XCTUnwrap(job.archiveURL)
        XCTAssertEqual(path.deletingLastPathComponent(), root.appendingPathComponent("uploads"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        await api.setRejectBeforeAccepting(false)
        await model.resume(jobID: job.id)
        XCTAssertTrue(model.jobs.first!.accepted)
        XCTAssertNil(model.jobs.first?.archiveURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testCorruptLocalAssetDoesNotBlockOtherUploads() async throws {
        var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: root.appendingPathComponent("scan_other").path,
            displayName: "旧资产", createdAt: Date())
        job.accepted = true; job.phase = .downloaded
        journal.jobs = [job]
        assets.corruptID = job.id
        let model = model()
        await model.start(scanDirectory: scan, displayName: "新扫描")
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertTrue(model.jobs.first!.accepted)
        XCTAssertEqual(model.jobs.first { $0.id == job.id }?.phase, .ready)
    }

    func testArchiveCancellationPreservesResumeAndSourceProtection() async throws {
        archive.error = .cancelled
        let model = model()
        await model.start(scanDirectory: scan, displayName: "测试")
        XCTAssertEqual(model.jobs.first?.phase, .paused)
        XCTAssertTrue(model.deletionBlocked(scanPath: scan.path))
        XCTAssertNil(model.message)
        let events = await api.events
        XCTAssertTrue(events.isEmpty)
        archive.error = nil
        await model.resume(jobID: try XCTUnwrap(model.jobs.first?.id))
        XCTAssertEqual(model.jobs.first?.phase, .processing)
    }

    func testFirstLostResponseIsAutomaticallyReconciledInForeground() async throws {
        await api.setLostResponse(true)
        let model = model()
        model.setAppActive(true)
        defer { model.setAppActive(false) }
        await model.start(scanDirectory: scan, displayName: "测试")
        for _ in 0..<200 {
            if model.jobs.first?.phase == .processing { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(model.jobs.first?.phase, .processing)
        let events = await api.events
        XCTAssertEqual(events.filter { $0.0 == "submit" }.count, 1)
        XCTAssertTrue(events.contains { $0.0 == "status" })
    }

    func testJournalIsAtomicCredentialFreeAndRejectsInvalidIdentity() throws {
        let store = AreaTargetJobStore(url: root.appendingPathComponent("persist/jobs.json"))
        let job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "测试", createdAt: Date())
        try store.save([job])
        XCTAssertEqual(try store.load(), [job])
        let bytes = try Data(contentsOf: store.url)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("token"))
        var corrupt = job
        corrupt.id = "../../outside"
        XCTAssertThrowsError(try store.save([corrupt]))
        XCTAssertEqual(try store.load(), [job], "Rejecting invalid data must preserve the earlier journal")
    }
}

final class AreaFlowJournal: AreaTargetJobStoring {
    var jobs: [AreaTargetProcessingJob] = []
    var failWrites = false
    func load() throws -> [AreaTargetProcessingJob] { jobs }
    func save(_ jobs: [AreaTargetProcessingJob]) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        self.jobs = jobs
    }
}

final class AreaFlowTokens: AreaTargetTokenStoring {
    var values: [String: String] = [:]
    var failWrites = false
    func token(jobID: String) throws -> String? { values[jobID] }
    func save(_ token: String, jobID: String) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        values[jobID] = token
    }
    func remove(jobID: String) throws { values.removeValue(forKey: jobID) }
}

final class AreaFlowArchive: AreaTargetArchiving, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var count = 0
    var error: AreaTargetScanArchive.ArchiveError?
    var preparation: AreaTargetClientPreparation?
    private var capturedRequirements: AreaTargetProcessingRequirements?
    var requirementsSeen: AreaTargetProcessingRequirements? { lock.lock(); defer { lock.unlock() }; return capturedRequirements }
    func archive(scanDirectory: URL, uvUnwrap: Bool, profile: String, requirements: AreaTargetProcessingRequirements?,
                 progress: @escaping @Sendable (String) -> Void, isCancelled: @escaping @Sendable () -> Bool) throws -> URL {
        lock.lock(); capturedRequirements = requirements; lock.unlock()
        return try archive(scanDirectory: scanDirectory, uvUnwrap: uvUnwrap, progress: progress, isCancelled: isCancelled)
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    init(url: URL) { self.url = url }
    func archive(scanDirectory: URL, uvUnwrap: Bool, progress: @escaping @Sendable (String) -> Void,
                 isCancelled: @escaping @Sendable () -> Bool) throws -> URL {
        lock.lock(); count += 1; lock.unlock()
        if let error { throw error }
        if isCancelled() { throw CancellationError() }
        progress("正在打包扫描数据…")
        if let preparation {
            try? FileManager.default.removeItem(at: url)
            let archive = try Archive(url: url, accessMode: .create)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preparation))
            let bytes = try JSONSerialization.data(withJSONObject: ["clientPreparation": object])
            try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(bytes.count)) { position, count in
                bytes.subdata(in: Int(position)..<min(bytes.count, Int(position) + count))
            }
        } else { try Data("immutable archive".utf8).write(to: url) }
        return url
    }
}

final class AreaFlowAssets: AreaTargetAssetStoring {
    let root: URL
    var corruptID: String?
    var values: [String: AreaTargetSavedAsset] = [:]
    var afterPublishing: (() -> Void)?
    init(root: URL) { self.root = root }
    func save(downloadURL: URL, jobID: String, result: AreaTargetResult) throws -> AreaTargetSavedAsset {
        let directory = root.appendingPathComponent(jobID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bundle = directory.appendingPathComponent("asset_bundle.zip")
        try FileManager.default.copyItem(at: downloadURL, to: bundle)
        let asset = AreaTargetSavedAsset(jobID: jobID, bundleURL: bundle, directoryURL: directory,
            modelURL: directory.appendingPathComponent("optimized.glb"),
            featuresURL: directory.appendingPathComponent("features.db"),
            manifestURL: directory.appendingPathComponent("manifest.json"), savedAt: Date())
        values[jobID] = asset
        afterPublishing?()
        return asset
    }
    func asset(jobID: String) throws -> AreaTargetSavedAsset? {
        if jobID == corruptID { throw AreaTargetAPIError.invalidResult("fixture corruption") }
        return values[jobID]
    }
}

actor AreaFlowAPI: AreaTargetAPI {
    let root: URL
    var events: [(String, String, String)] = []
    var requirements: AreaTargetProcessingRequirements?
    var requirementsCalls = 0
    var holdRequirements = false
    func setRequirements(_ value: AreaTargetProcessingRequirements?) { requirements = value }
    func setHoldRequirements(_ value: Bool) { holdRequirements = value }
    func requirementsCallCount() -> Int { requirementsCalls }
    func fetchProcessingRequirements() async throws -> AreaTargetProcessingRequirements {
        requirementsCalls += 1
        if holdRequirements { try await Task.sleep(nanoseconds: 30_000_000_000) }
        guard let requirements else { throw AreaTargetAPIError.transport("requirements offline") }
        return requirements
    }
    var accepted: Set<String> = []
    var remoteStatus: AreaTargetRemoteStatus = .queued
    var remoteProblem: AreaTargetAPIProblem?
    var lostResponse = false
    var rejectBeforeAccepting = false
    var holdUpload = false
    var expired = false
    init(root: URL) { self.root = root }
    func setRemoteStatus(_ value: AreaTargetRemoteStatus) { remoteStatus = value }
    func setRemoteProblem(_ value: AreaTargetAPIProblem) { remoteProblem = value }
    func setLostResponse(_ value: Bool) { lostResponse = value }
    func setRejectBeforeAccepting(_ value: Bool) { rejectBeforeAccepting = value }
    func setHoldUpload(_ value: Bool) { holdUpload = value }
    func setExpired(_ value: Bool) { expired = value }
    func submit(archiveURL: URL, jobID: String, token: String, profile: String, uvUnwrap: Bool,
                progress: @escaping @Sendable (Double) -> Void) async throws -> AreaTargetRemoteJob {
        events.append(("submit", jobID, token))
        if holdUpload { try await Task.sleep(nanoseconds: 30_000_000_000) }
        if rejectBeforeAccepting {
            throw AreaTargetAPIError.server(statusCode: 429,
                problem: .init(code: "queue_full", message: "队列已满", retryable: true), retryAfter: 10)
        }
        accepted.insert(jobID)
        progress(1)
        if lostResponse { throw AreaTargetAPIError.transport("网络连接中断") }
        return remote(jobID: jobID)
    }
    func status(jobID: String, token: String) async throws -> AreaTargetRemoteJob {
        events.append(("status", jobID, token))
        if !accepted.contains(jobID) {
            throw AreaTargetAPIError.server(statusCode: 404,
                problem: .init(code: "job_not_found", message: "任务不存在", retryable: false), retryAfter: nil)
        }
        if expired {
            throw AreaTargetAPIError.server(statusCode: 410,
                problem: .init(code: "result_expired", message: "结果已过期", retryable: false), retryAfter: nil)
        }
        return remote(jobID: jobID)
    }
    func download(jobID: String, token: String, result: AreaTargetResult,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        events.append(("download", jobID, token))
        progress(1)
        let file = root.appendingPathComponent("download-\(UUID().uuidString).zip")
        try Data("verified by asset store".utf8).write(to: file)
        return file
    }
    private func remote(jobID: String) -> AreaTargetRemoteJob {
        let result = AreaTargetResult(format: "area-target-bundle", filename: "asset_bundle_\(jobID).zip",
            sizeBytes: 100, sha256: String(repeating: "a", count: 64),
            url: "/api/v1/jobs/\(jobID)/result", expiresAt: Date().addingTimeInterval(86400))
        return AreaTargetRemoteJob(jobID: jobID, status: remoteStatus, progress: remoteStatus == .completed ? 100 : 0,
            stage: remoteStatus == .completed ? "completed" : remoteStatus == .failed ? "failed" : "queued",
            message: remoteStatus == .completed ? "完成" : "等待处理", profile: "fast", uvUnwrap: true,
            createdAt: Date(), finishedAt: remoteStatus == .completed || remoteStatus == .failed ? Date() : nil,
            expiresAt: remoteStatus == .completed ? result.expiresAt : nil,
            error: remoteStatus == .failed ? (remoteProblem ?? .init(code: "processing_interrupted", message: "服务重启中断了任务，请重新提交", retryable: true)) : nil,
            result: remoteStatus == .completed ? result : nil)
    }
}

final class AreaFlowServiceAPI: AreaTargetAPI {
    let base: AreaFlowAPI
    var saved: AreaTargetServiceSession?
    var rejectStatus = false
    var statusCalls = 0
    var requiresServiceAuthentication: Bool { true }
    static var fixtureSession: AreaTargetServiceSession {
        AreaTargetServiceSession(token: String(repeating: "b", count: 64), username: "scanner",
            expiresAt: Date().addingTimeInterval(3600), csrfToken: String(repeating: "c", count: 64))
    }
    init(base: AreaFlowAPI) { self.base = base }
    func savedServiceSession() throws -> AreaTargetServiceSession? { saved }
    func signIn(username: String, password: String) async throws -> AreaTargetServiceSession {
        saved = Self.fixtureSession
        return saved!
    }
    func validateServiceSession() async throws -> AreaTargetServiceSession? { saved }
    func signOut() async throws { saved = nil }
    func fetchProcessingRequirements() async throws -> AreaTargetProcessingRequirements { try await base.fetchProcessingRequirements() }
    func submit(archiveURL: URL, jobID: String, token: String, profile: String, uvUnwrap: Bool,
                progress: @escaping @Sendable (Double) -> Void) async throws -> AreaTargetRemoteJob {
        try await base.submit(archiveURL: archiveURL, jobID: jobID, token: token, profile: profile, uvUnwrap: uvUnwrap, progress: progress)
    }
    func status(jobID: String, token: String) async throws -> AreaTargetRemoteJob {
        statusCalls += 1
        if rejectStatus {
            saved = nil
            throw AreaTargetAPIError.server(statusCode: 401,
                problem: .init(code: "authentication_required", message: "Please sign in", retryable: false), retryAfter: nil)
        }
        return try await base.status(jobID: jobID, token: token)
    }
    func download(jobID: String, token: String, result: AreaTargetResult,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await base.download(jobID: jobID, token: token, result: result, progress: progress)
    }
}
