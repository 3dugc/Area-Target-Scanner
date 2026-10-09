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

    func testNewJobPersistsDefaultDisabledMapCLAHE() throws {
        let job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(),
            scanDirectoryPath: scan.path, displayName: "默认关闭光照增强", createdAt: Date())
        let encoded = try JSONEncoder().encode(job)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(document["mapCLAHE"] as? Bool, false,
            "New jobs must persist the default disabled map CLAHE option before submission")
    }

    func testDisabledMapCLAHEKeepsHistoricalBuildIdentityAndRestoresReports() throws {
        let job = AreaTargetProcessingJob(id: "original-map", scanDirectoryPath: scan.path,
            displayName: "原关闭地图", createdAt: Date(timeIntervalSince1970: 1))
        let oldConfiguration = "profile=quality;uv_unwrap=1;client_preparation=unrecorded"
        XCTAssertEqual(Array(job.localizationBuildConfiguration.utf8), Array(oldConfiguration.utf8))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        document.removeValue(forKey: "mapCLAHE")
        let historical = try JSONDecoder().decode(AreaTargetProcessingJob.self,
            from: JSONSerialization.data(withJSONObject: document))
        XCTAssertFalse(historical.mapCLAHE)
        XCTAssertEqual(Array(historical.localizationBuildConfiguration.utf8), Array(oldConfiguration.utf8))
        func identity(_ configuration: String) -> LocalizationAssetIdentity {
            LocalizationAssetIdentity(provider: .areaTarget, assetID: job.id,
                sourceFingerprint: String(repeating: "a", count: 64), engineVersion: "existing-engine",
                assetDigest: String(repeating: "b", count: 64),
                buildConfiguration: LocalizationCoreMetadata.liveBuildConfiguration(base: configuration))
        }
        let oldReport = LocalizationEvaluationAccumulator(identity: identity(oldConfiguration))
            .report(date: Date(timeIntervalSince1970: 2))
        let reportDirectory = root.appendingPathComponent("existing-map-reports", isDirectory: true)
        _ = try LocalizationReportStore(rootDirectory: reportDirectory).save(report: oldReport)
        let restored = LocalizationReportStore(rootDirectory: reportDirectory)
        XCTAssertEqual(try restored.latest(identity: identity(job.localizationBuildConfiguration)), oldReport)
        XCTAssertEqual(try restored.latest(identity: identity(historical.localizationBuildConfiguration)), oldReport)
        var enabled = job
        enabled.mapCLAHE = true
        let enabledConfiguration = oldConfiguration + ";map_clahe=1;map_clahe_clip_limit=2.0;map_clahe_tile_grid=8x8"
        XCTAssertEqual(enabled.localizationBuildConfiguration, enabledConfiguration)
        XCTAssertNotEqual(identity(enabled.localizationBuildConfiguration), oldReport.identity)
        XCTAssertNil(try restored.latest(identity: identity(enabled.localizationBuildConfiguration)))
    }

    private func setMapCLAHECapability(_ enabled: Bool) async {
        var requirements = AreaFlowAPI.legacyRequirements
        requirements.mapCLAHESupported = enabled
        await api.setRequirements(requirements)
    }

    func testMapCLAHEIdentityPreservesExactHistoricalV1V2BytesWhenDisabled() throws {
        let v1 = try JSONDecoder().decode(AreaTargetClientPreparation.self, from: Data(#"{"schemaVersion":1,"policy":"mobile-scan-preparation-v1","policyVersion":1,"profile":"fast","preparedBy":"client","originalFrameCount":120,"selectedFrameCount":2,"selectedIndices":[0,119],"processedPixelCount":3840000,"resizedFrameCount":2,"maximumOutputLongEdge":1600,"scaleDigest":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}"#.utf8))
        let v2 = AreaTargetClientPreparation(schemaVersion: 1, policy: "mobile-scan-preparation-v2", policyVersion: 2,
            profile: "fast", preparedBy: "client", originalFrameCount: 2, selectedFrameCount: 2, selectedIndices: [0, 1],
            processedPixelCount: 20_000, resizedFrameCount: 0, maximumOutputLongEdge: 100, scaleDigest: String(repeating: "d", count: 64),
            receivedFrameCount: 2, capacityTier: 100, selectionVersion: "upload-all-v2",
            selectionDigest: try AreaTargetClientPreparation.uploadSelectionDigest(capacityTier: 100, indices: [0, 1]),
            criticalFrameProtection: .init(version: "critical-frame-protection-v1", riskVersion: "gray-quality-risk-v1", protectedIndices: [1], candidateFrameCount: 1))
        for preparation in [nil, v1, v2] as [AreaTargetClientPreparation?] {
            var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
                displayName: "原关闭地图", createdAt: Date())
            job.clientPreparation = preparation
            job.profile = "fast"
            let historical = "profile=fast;uv_unwrap=1;" + (preparation?.identityConfiguration ?? "client_preparation=unrecorded")
            XCTAssertEqual(Array(job.localizationBuildConfiguration.utf8), Array(historical.utf8))
            job.mapCLAHE = true
            XCTAssertEqual(job.localizationBuildConfiguration,
                historical + ";map_clahe=1;map_clahe_clip_limit=2.0;map_clahe_tile_grid=8x8")
            job.mapCLAHE = false
            XCTAssertEqual(Array(job.localizationBuildConfiguration.utf8), Array(historical.utf8))
        }
    }

    func testMapCLAHEJournalReopenPreservesFrozenFlagRemoteEchoAndStoppedOrigin() throws {
        let url = root.appendingPathComponent("persist/map-jobs.json")
        var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "增强地图", createdAt: Date(timeIntervalSince1970: 1), serverOrigin: .current)
        job.profile = "fast"
        job.mapCLAHE = true
        job.phase = .stopped
        job.accepted = true
        job.remote = .init(jobID: job.id, status: .queued, progress: 0, stage: "queued", message: "等待处理",
            profile: "fast", uvUnwrap: true, mapCLAHE: true, createdAt: job.createdAt, finishedAt: nil,
            expiresAt: nil, error: nil, result: nil)
        try AreaTargetJobStore(url: url).save([job])
        XCTAssertEqual(try AreaTargetJobStore(url: url).load(), [job])
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        records[0].removeValue(forKey: "mapCLAHE")
        var remote = try XCTUnwrap(records[0]["remote"] as? [String: Any])
        remote.removeValue(forKey: "map_clahe")
        records[0]["remote"] = remote
        let historicalBytes = try JSONSerialization.data(withJSONObject: records)
        try historicalBytes.write(to: url)
        let restored = try XCTUnwrap(AreaTargetJobStore(url: url).load().first)
        XCTAssertFalse(restored.mapCLAHE)
        XCTAssertEqual(restored.remote?.mapCLAHE, false)
        XCTAssertEqual(restored.phase, .stopped)
        XCTAssertEqual(restored.serverOrigin, .current)
        XCTAssertEqual(try Data(contentsOf: url), historicalBytes, "Reading old records must preserve their stored bytes")
        for invalid in [NSNull(), 0, 1, "true"] as [Any] {
            records[0]["mapCLAHE"] = invalid
            let bytes = try JSONSerialization.data(withJSONObject: records)
            try bytes.write(to: url)
            XCTAssertThrowsError(try AreaTargetJobStore(url: url).load())
            XCTAssertEqual(try Data(contentsOf: url), bytes, "Rejected records remain available for diagnosis")
        }
    }

    func testHistoricalJobMissingMapCLAHEDecodesDisabledAndRejectsNullOrNonBoolean() throws {
        var original = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(),
            scanDirectoryPath: scan.path, displayName: "历史地图", createdAt: Date())
        original.profile = "fast"; original.uvUnwrap = false
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "mapCLAHE")
        let historical = try JSONDecoder().decode(AreaTargetProcessingJob.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(historical.mapCLAHE)
        XCTAssertEqual(historical.profile, "fast")
        XCTAssertFalse(historical.uvUnwrap)
        for invalid in [NSNull(), 0, 1, "true"] as [Any] {
            object["mapCLAHE"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(AreaTargetProcessingJob.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testNewTaskDefaultsToDisabledMapCLAHEAcrossJournalAndSubmission() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "默认光照增强关闭")
        let job = try XCTUnwrap(model.selectedJob)
        XCTAssertFalse(job.mapCLAHE)
        XCTAssertEqual(journal.jobs.first?.mapCLAHE, false)
        XCTAssertEqual(job.remote?.mapCLAHE, false)
        XCTAssertFalse(job.localizationBuildConfiguration.contains("map_clahe"),
            "Default off preserves the pre-option localization report identity")
        let submitted = await api.submittedMapCLAHE
        XCTAssertEqual(submitted, [false])
        XCTAssertEqual(job.phase, .processing, "Missing server capability must remain compatible with default off")
    }

    func testEnabledMapCLAHEFreezesJournalAndSubmissionWithoutChangingProfileOrUV() async throws {
        await setMapCLAHECapability(true)
        let model = model()
        await model.start(scanDirectory: scan, displayName: "光照增强", mapCLAHE: true)
        let job = try XCTUnwrap(model.selectedJob)
        XCTAssertTrue(job.mapCLAHE)
        XCTAssertEqual(journal.jobs.first?.mapCLAHE, true)
        XCTAssertEqual(job.remote?.mapCLAHE, true)
        XCTAssertEqual(job.profile, "quality")
        XCTAssertTrue(job.uvUnwrap)
        XCTAssertEqual(archive.profilesSeen, ["quality"])
        XCTAssertEqual(archive.uvUnwrapSeen, [true])
        XCTAssertTrue(job.localizationBuildConfiguration.contains("map_clahe=1"))
        let submitted = await api.submittedMapCLAHE
        XCTAssertEqual(submitted, [true])
        XCTAssertEqual(job.phase, .processing)
    }

    func testUnsupportedMapCLAHEStopsBeforeArchivingAndKeepsRequestedSelection() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "旧云端", mapCLAHE: true)
        let job = try XCTUnwrap(model.selectedJob)
        XCTAssertTrue(job.mapCLAHE)
        XCTAssertEqual(job.phase, .failed)
        XCTAssertFalse(job.accepted)
        XCTAssertNil(job.archiveURL)
        XCTAssertEqual(archive.calls, 0)
        let submitted = await api.submittedMapCLAHE
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertTrue(model.message?.contains("光照增强") == true)
        XCTAssertTrue(model.message?.contains("不支持") == true)
        XCTAssertTrue(model.message?.contains("服务支持后重新建图") == true)
    }

    func testPendingTaskKeepsFrozenMapCLAHEChoiceWhenAnotherIsRequested() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "默认关闭任务")
        let original = try XCTUnwrap(model.selectedJob)
        await model.start(scanDirectory: scan, displayName: "启用请求", mapCLAHE: true)
        XCTAssertEqual(model.selectedJobID, original.id)
        XCTAssertEqual(model.jobs, [original])
        XCTAssertEqual(archive.calls, 1)
        XCTAssertTrue(model.message?.contains("光照增强已关闭") == true)
        let submitted = await api.submittedMapCLAHE
        XCTAssertEqual(submitted, [false])
    }

    func testPausedEnabledMapCLAHEResumesSameArchiveAndRechecksCapability() async throws {
        await setMapCLAHECapability(true)
        await api.setRejectBeforeAccepting(true)
        let initial = model()
        await initial.start(scanDirectory: scan, displayName: "增强重传", mapCLAHE: true)
        let original = try XCTUnwrap(initial.selectedJob)
        let zip = try XCTUnwrap(original.archiveURL)
        XCTAssertEqual(original.phase, .paused)
        let before = await api.requirementsCallCount()
        XCTAssertEqual(before, 1)
        let restored = model()
        await api.setRejectBeforeAccepting(false)
        await restored.resume(jobID: original.id)
        XCTAssertEqual(restored.selectedJob?.id, original.id)
        XCTAssertEqual(restored.selectedJob?.mapCLAHE, true)
        XCTAssertEqual(restored.selectedJob?.remote?.mapCLAHE, true)
        XCTAssertEqual(restored.selectedJob?.phase, .processing)
        XCTAssertEqual(restored.selectedJob?.localizationBuildConfiguration, original.localizationBuildConfiguration)
        XCTAssertEqual(archive.calls, 1, "An enabled resume must reuse the original prepared ZIP")
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path), "The accepted upload archive is released normally")
        let after = await api.requirementsCallCount()
        XCTAssertEqual(after, 2, "Cached archives still require a fresh capability check before resubmission")
        let submitted = await api.submittedMapCLAHE
        XCTAssertEqual(submitted, [true, true])
    }

    func testCachedEnabledArchiveCannotResubmitAfterCapabilityDisappears() async throws {
        await setMapCLAHECapability(true)
        await api.setRejectBeforeAccepting(true)
        let initial = model()
        await initial.start(scanDirectory: scan, displayName: "增强能力变化", mapCLAHE: true)
        let original = try XCTUnwrap(initial.selectedJob)
        let zip = try XCTUnwrap(original.archiveURL)
        let restored = model()
        await setMapCLAHECapability(false)
        await api.setRejectBeforeAccepting(false)
        await restored.resume(jobID: original.id)
        XCTAssertEqual(restored.selectedJob?.mapCLAHE, true)
        XCTAssertEqual(restored.selectedJob?.phase, .failed)
        XCTAssertEqual(restored.selectedJob?.archiveURL, zip)
        XCTAssertEqual(restored.selectedJob?.archiveSHA256, original.archiveSHA256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
        XCTAssertEqual(archive.calls, 1)
        let submitted = await api.submittedMapCLAHE
        XCTAssertEqual(submitted, [true], "No second submission and no silent default-off fallback")
        let count = await api.requirementsCallCount()
        XCTAssertEqual(count, 2)
    }

    func testAcceptedEnabledTaskReconcilesFrozenFlagWithoutUploadingAgain() async throws {
        await setMapCLAHECapability(true)
        await api.setLostResponse(true)
        let model = model()
        await model.start(scanDirectory: scan, displayName: "增强上传响应丢失", mapCLAHE: true)
        let id = try XCTUnwrap(model.selectedJobID)
        XCTAssertEqual(model.selectedJob?.phase, .submissionUnknown)
        await setMapCLAHECapability(false)
        await model.resume(jobID: id)
        XCTAssertEqual(model.selectedJob?.phase, .processing)
        XCTAssertEqual(model.selectedJob?.mapCLAHE, true)
        XCTAssertEqual(model.selectedJob?.remote?.mapCLAHE, true)
        let submitted = await api.submittedMapCLAHE
        XCTAssertEqual(submitted, [true])
        let count = await api.requirementsCallCount()
        XCTAssertEqual(count, 1, "An already accepted server job is reconciled rather than resubmitted")
    }

    func testMapCLAHERebuildCreatesNewTaskAndRetainsDisabledMap() async throws {
        await setMapCLAHECapability(true)
        let model = model()
        await model.start(scanDirectory: scan, displayName: "原关闭地图")
        let oldID = try XCTUnwrap(model.selectedJobID)
        await api.setRemoteStatus(.completed)
        await model.refresh(jobID: oldID)
        await model.download(jobID: oldID)
        let original = try XCTUnwrap(model.selectedJob)
        let asset = try XCTUnwrap(original.savedAsset)
        await api.setRemoteStatus(.queued)
        await model.start(scanDirectory: scan, displayName: "新增强地图", mapCLAHE: true)
        let rebuilt = try XCTUnwrap(model.selectedJob)
        XCTAssertNotEqual(rebuilt.id, oldID)
        XCTAssertTrue(rebuilt.mapCLAHE)
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertEqual(model.jobs.first(where: { $0.id == oldID }), original)
        XCTAssertEqual(journal.jobs.first(where: { $0.id == oldID }), original)
        XCTAssertEqual(assets.values[oldID], asset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.bundleURL.path))
        let submitted = await api.submittedMapCLAHE
        XCTAssertEqual(submitted, [false, true])
    }

    func testRefreshRejectsRemoteMapCLAHEDifferentFromFrozenTask() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "配置回显")
        let original = try XCTUnwrap(model.selectedJob)
        await api.setRemoteMapCLAHEOverride(true)
        await api.setRemoteStatus(.completed)
        await model.refresh(jobID: original.id)
        let rejected = try XCTUnwrap(model.selectedJob)
        XCTAssertEqual(rejected.detail, "云端返回的信息无法验证，请稍后查询状态。")
        XCTAssertEqual(model.message, rejected.detail)
        XCTAssertNotEqual(rejected.detail, original.detail)
        var frozen = original
        frozen.detail = rejected.detail
        XCTAssertEqual(rejected, frozen,
            "Only the error detail may change; frozen options, phase, remote, archive and asset remain untouched")
    }

    func testSubmitMismatchKeepsArchiveAndUnacceptedFrozenTask() async throws {
        await api.setRemoteMapCLAHEOverride(true)
        let model = model()
        await model.start(scanDirectory: scan, displayName: "关闭选项回显错误")
        let job = try XCTUnwrap(model.selectedJob)
        XCTAssertFalse(job.mapCLAHE)
        XCTAssertFalse(job.accepted)
        XCTAssertNil(job.remote)
        XCTAssertEqual(job.phase, .submissionUnknown)
        let zip = try XCTUnwrap(job.archiveURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
        XCTAssertNotNil(job.archiveSHA256)
        XCTAssertEqual(journal.jobs.first?.mapCLAHE, false)
    }

    func testResumeMismatchDoesNotReconcileOrResubmitAcceptedEnabledTask() async throws {
        await setMapCLAHECapability(true)
        await api.setLostResponse(true)
        let model = model()
        await model.start(scanDirectory: scan, displayName: "增强回显错误", mapCLAHE: true)
        let original = try XCTUnwrap(model.selectedJob)
        await api.setRemoteMapCLAHEOverride(false)
        await model.resume(jobID: original.id)
        XCTAssertEqual(model.selectedJob, original)
        XCTAssertNotNil(model.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(original.archiveURL).path))
        let submitted = await api.submittedMapCLAHE
        XCTAssertEqual(submitted, [true])
    }

    func testDownloadMismatchDoesNotPublishAssetOrAcceptDifferentMap() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "原关闭任务")
        let original = try XCTUnwrap(model.selectedJob)
        await api.setRemoteStatus(.completed)
        await api.setRemoteMapCLAHEOverride(true)
        await model.download(jobID: original.id)
        XCTAssertFalse(try XCTUnwrap(model.selectedJob).mapCLAHE)
        XCTAssertEqual(model.selectedJob?.remote, original.remote)
        XCTAssertNil(model.selectedJob?.savedAsset)
        XCTAssertTrue(assets.values.isEmpty)
        let events = await api.events
        XCTAssertFalse(events.contains { $0.0 == "download" })
    }

    func testRefreshAlsoRejectsProfileAndUVChangedFromFrozenTask() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "原配置")
        let original = try XCTUnwrap(model.selectedJob)
        await api.setRemoteProfileOverride(original.profile == "quality" ? "fast" : "quality")
        await model.refresh(jobID: original.id)
        XCTAssertEqual(model.selectedJob?.profile, original.profile)
        XCTAssertEqual(model.selectedJob?.remote, original.remote)
        await api.setRemoteProfileOverride(nil)
        await api.setRemoteUVUnwrapOverride(false)
        await model.refresh(jobID: original.id)
        XCTAssertEqual(model.selectedJob?.uvUnwrap, true)
        XCTAssertEqual(model.selectedJob?.remote, original.remote)
    }

    func testStoppedFrozenTaskAllowsNewExplicitSettingsWithoutChangingOldJournal() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "原快速无纹理任务", profile: .fast, uvUnwrap: false)
        let first = try XCTUnwrap(model.selectedJob)
        model.stopLocalTracking(jobID: first.id)
        let stopped = try XCTUnwrap(model.selectedJob)
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertEqual(stopped.profile, "fast")
        XCTAssertFalse(stopped.uvUnwrap)
        XCTAssertFalse(stopped.mapCLAHE)
        XCTAssertFalse(model.deletionBlocked(scanPath: scan.path))
        await model.start(scanDirectory: scan, displayName: "新质量任务", profile: .quality, uvUnwrap: true)
        let replacement = try XCTUnwrap(model.selectedJob)
        XCTAssertNotEqual(replacement.id, first.id)
        XCTAssertEqual(replacement.profile, "quality")
        XCTAssertTrue(replacement.uvUnwrap)
        XCTAssertFalse(replacement.mapCLAHE)
        XCTAssertEqual(model.jobs.first(where: { $0.id == first.id }), stopped)
        XCTAssertEqual(journal.jobs.first(where: { $0.id == first.id }), stopped)
        XCTAssertEqual(archive.profilesSeen, ["fast", "quality"])
        XCTAssertEqual(archive.uvUnwrapSeen, [false, true])
        let profiles = await api.submittedProfiles
        XCTAssertEqual(profiles, ["fast", "quality"])
    }

    func testNewTaskDefaultsToQualityAcrossJournalArchiveAndSubmission() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "默认质量建图")
        let job = try XCTUnwrap(model.selectedJob)
        XCTAssertEqual(job.profile, "quality")
        XCTAssertTrue(job.uvUnwrap)
        XCTAssertEqual(journal.jobs.first?.profile, "quality")
        XCTAssertEqual(journal.jobs.first?.uvUnwrap, true)
        XCTAssertEqual(archive.profilesSeen, ["quality"])
        XCTAssertEqual(archive.uvUnwrapSeen, [true])
        let profiles = await api.submittedProfiles
        XCTAssertEqual(profiles, ["quality"])
        let uvUnwrap = await api.submittedUVUnwrap
        XCTAssertEqual(uvUnwrap, [true])
        XCTAssertEqual(job.remote?.profile, "quality")
        XCTAssertEqual(job.remote?.uvUnwrap, true)
        XCTAssertEqual(job.phase, .processing)
    }

    func testExplicitUVUnwrapFalseReachesJournalArchiveAndSubmission() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "关闭 UV 展开", uvUnwrap: false)
        let job = try XCTUnwrap(model.selectedJob)
        XCTAssertFalse(job.uvUnwrap)
        XCTAssertEqual(job.profile, "quality")
        XCTAssertEqual(journal.jobs.first?.uvUnwrap, false)
        XCTAssertEqual(archive.uvUnwrapSeen, [false])
        let uvUnwrap = await api.submittedUVUnwrap
        XCTAssertEqual(uvUnwrap, [false])
        XCTAssertEqual(job.remote?.uvUnwrap, false)
        XCTAssertTrue(job.localizationBuildConfiguration.contains("uv_unwrap=0"))
        XCTAssertEqual(job.phase, .processing)
    }

    func testPendingTaskKeepsFrozenUVWhenChangedSettingIsRequested() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "原开启 UV 任务")
        let original = try XCTUnwrap(model.selectedJob)
        let token = try XCTUnwrap(tokens.values[original.id])
        await model.start(scanDirectory: scan, displayName: "关闭 UV 展开", uvUnwrap: false)
        XCTAssertEqual(model.selectedJobID, original.id)
        XCTAssertEqual(model.jobs, [original])
        XCTAssertEqual(tokens.values[original.id], token)
        XCTAssertEqual(tokens.values.count, 1)
        XCTAssertEqual(archive.calls, 1)
        let uvUnwrap = await api.submittedUVUnwrap
        XCTAssertEqual(uvUnwrap, [true])
        XCTAssertTrue(model.message?.contains("已有未完成任务") == true)
        XCTAssertTrue(model.message?.contains("UV 与纹理重建已开启") == true)
    }

    func testRestoredPausedFalseUVTaskResumesSameArchiveAndSetting() async throws {
        await api.setRejectBeforeAccepting(true)
        let originalModel = model()
        await originalModel.start(scanDirectory: scan, displayName: "关闭 UV 的暂停任务", uvUnwrap: false)
        let original = try XCTUnwrap(originalModel.selectedJob)
        let token = try XCTUnwrap(tokens.values[original.id])
        let zip = try XCTUnwrap(original.archiveURL)
        XCTAssertEqual(original.phase, .paused)
        XCTAssertFalse(original.uvUnwrap)
        let restored = model()
        await restored.start(scanDirectory: scan, displayName: "默认开启 UV")
        XCTAssertEqual(restored.selectedJobID, original.id)
        XCTAssertEqual(restored.selectedJob?.uvUnwrap, false)
        XCTAssertEqual(restored.selectedJob?.archiveURL, zip)
        XCTAssertEqual(restored.selectedJob?.archiveSHA256, original.archiveSHA256)
        XCTAssertTrue(restored.message?.contains("UV 与纹理重建已关闭") == true)
        await api.setRejectBeforeAccepting(false)
        await restored.resume(jobID: original.id)
        XCTAssertEqual(restored.jobs.count, 1)
        XCTAssertEqual(restored.selectedJob?.uvUnwrap, false)
        XCTAssertEqual(restored.selectedJob?.remote?.uvUnwrap, false)
        XCTAssertEqual(restored.selectedJob?.phase, .processing)
        XCTAssertEqual(restored.selectedJob?.localizationBuildConfiguration, original.localizationBuildConfiguration)
        XCTAssertEqual(tokens.values[original.id], token)
        XCTAssertEqual(archive.uvUnwrapSeen, [false], "Resuming must reuse the original ZIP and UV setting")
        let uvUnwrap = await api.submittedUVUnwrap
        XCTAssertEqual(uvUnwrap, [false, false])
        let events = await api.events
        XCTAssertTrue(events.allSatisfy { $0.1 == original.id && $0.2 == token })
    }

    func testDownloadedTrueUVMapIsRetainedWhenNewTaskDisablesUV() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "开启 UV 的旧地图")
        let firstID = try XCTUnwrap(model.selectedJobID)
        await api.setRemoteStatus(.completed)
        await model.refresh(jobID: firstID)
        await model.download(jobID: firstID)
        let original = try XCTUnwrap(model.selectedJob)
        let asset = try XCTUnwrap(original.savedAsset)
        XCTAssertEqual(original.phase, .downloaded)
        XCTAssertTrue(original.uvUnwrap)
        await api.setRemoteStatus(.queued)
        await model.start(scanDirectory: scan, displayName: "关闭 UV 的新地图", uvUnwrap: false)
        let rebuilt = try XCTUnwrap(model.selectedJob)
        XCTAssertNotEqual(rebuilt.id, firstID)
        XCTAssertFalse(rebuilt.uvUnwrap)
        XCTAssertEqual(rebuilt.remote?.uvUnwrap, false)
        XCTAssertEqual(rebuilt.phase, .processing)
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertEqual(model.jobs.first(where: { $0.id == firstID }), original)
        XCTAssertEqual(journal.jobs.first(where: { $0.id == firstID }), original)
        XCTAssertEqual(assets.values[firstID], asset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.bundleURL.path))
        let uvUnwrap = await api.submittedUVUnwrap
        XCTAssertEqual(uvUnwrap, [true, false])
        XCTAssertEqual(archive.uvUnwrapSeen, [true, false])
    }

    func testFalseUVTaskRejectsRemoteTrueConfiguration() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "关闭 UV 配置核对", uvUnwrap: false)
        let original = try XCTUnwrap(model.selectedJob)
        XCTAssertFalse(original.uvUnwrap)
        await api.setRemoteUVUnwrapOverride(true)
        await api.setRemoteStatus(.completed)
        await model.refresh(jobID: original.id)
        let job = try XCTUnwrap(model.selectedJob)
        XCTAssertFalse(job.uvUnwrap)
        XCTAssertEqual(job.phase, .processing)
        XCTAssertEqual(job.remote, original.remote)
        XCTAssertNil(job.savedAsset)
        XCTAssertEqual(model.message, AreaTargetAPIError.invalidResponse.localizedDescription)
    }

    func testJournalRoundTripKeepsExplicitUVChoices() throws {
        let store = AreaTargetJobStore(url: root.appendingPathComponent("persist/uv-jobs.json"))
        let enabled = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "开启 UV", createdAt: Date(timeIntervalSince1970: 100))
        var disabled = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "关闭 UV", createdAt: Date(timeIntervalSince1970: 200))
        disabled.uvUnwrap = false
        try store.save([enabled, disabled])
        XCTAssertEqual(try store.load(), [enabled, disabled])
        XCTAssertEqual(try store.load().map(\.uvUnwrap), [true, false])
    }

    func testExplicitFastReachesJournalArchiveAndSubmission() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "快速建图", profile: .fast)
        let job = try XCTUnwrap(model.selectedJob)
        XCTAssertEqual(job.profile, "fast")
        XCTAssertEqual(journal.jobs.first?.profile, "fast")
        XCTAssertEqual(archive.profilesSeen, ["fast"])
        let profiles = await api.submittedProfiles
        XCTAssertEqual(profiles, ["fast"])
        XCTAssertEqual(job.remote?.profile, "fast")
        XCTAssertEqual(job.phase, .processing)
    }

    func testPendingFastTaskKeepsFrozenProfileWhenQualityIsRequested() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "原快速任务", profile: .fast)
        let original = try XCTUnwrap(model.selectedJob)
        let token = try XCTUnwrap(tokens.values[original.id])
        await model.start(scanDirectory: scan, displayName: "质量建图", profile: .quality)
        XCTAssertEqual(model.selectedJobID, original.id)
        XCTAssertEqual(model.jobs, [original])
        XCTAssertEqual(tokens.values[original.id], token)
        XCTAssertEqual(tokens.values.count, 1)
        XCTAssertEqual(archive.calls, 1)
        let profiles = await api.submittedProfiles
        XCTAssertEqual(profiles, ["fast"])
        XCTAssertTrue(model.message?.contains("Fast") == true)
        XCTAssertTrue(model.message?.contains("已有未完成任务") == true)
    }

    func testRestoredPausedFastTaskResumesSameArchiveIdentityAndProfile() async throws {
        await api.setRejectBeforeAccepting(true)
        let originalModel = model()
        await originalModel.start(scanDirectory: scan, displayName: "暂停的快速任务", profile: .fast)
        let original = try XCTUnwrap(originalModel.selectedJob)
        let token = try XCTUnwrap(tokens.values[original.id])
        let zip = try XCTUnwrap(original.archiveURL)
        XCTAssertEqual(original.phase, .paused)
        let restored = model()
        await restored.start(scanDirectory: scan, displayName: "质量建图", profile: .quality)
        XCTAssertEqual(restored.selectedJobID, original.id)
        XCTAssertEqual(restored.selectedJob?.profile, "fast")
        XCTAssertEqual(restored.selectedJob?.archiveURL, zip)
        XCTAssertEqual(restored.selectedJob?.archiveSHA256, original.archiveSHA256)
        await api.setRejectBeforeAccepting(false)
        await restored.resume(jobID: original.id)
        XCTAssertEqual(restored.jobs.count, 1)
        XCTAssertEqual(restored.selectedJob?.profile, "fast")
        XCTAssertEqual(restored.selectedJob?.remote?.profile, "fast")
        XCTAssertEqual(restored.selectedJob?.phase, .processing)
        XCTAssertEqual(restored.selectedJob?.localizationBuildConfiguration, original.localizationBuildConfiguration)
        XCTAssertEqual(tokens.values[original.id], token)
        XCTAssertEqual(archive.profilesSeen, ["fast"], "Resuming must reuse the frozen ZIP")
        let profiles = await api.submittedProfiles
        XCTAssertEqual(profiles, ["fast", "fast"])
        let events = await api.events
        XCTAssertTrue(events.allSatisfy { $0.1 == original.id && $0.2 == token })
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path), "Accepted upload releases its retained ZIP")
    }

    func testHistoricalFastJournalIsNotMigratedToQualityBeforeResume() async throws {
        let store = AreaTargetJobStore(url: root.appendingPathComponent("legacy/profile-jobs.json"))
        var historical = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "历史快速任务", createdAt: Date(timeIntervalSince1970: 100))
        historical.profile = "fast"
        historical.phase = .paused
        try store.save([historical])
        let bytes = try Data(contentsOf: store.url)
        tokens.values[historical.id] = String(repeating: "b", count: 64)
        let model = AreaTargetProcessingModel(api: api, archiver: archive, jobStore: store,
            tokenStore: tokens, assetStore: assets, uploadDirectory: root.appendingPathComponent("uploads"))
        await model.start(scanDirectory: scan, displayName: "默认质量任务")
        XCTAssertEqual(model.selectedJobID, historical.id)
        XCTAssertEqual(model.selectedJob?.profile, "fast")
        XCTAssertEqual(try Data(contentsOf: store.url), bytes, "Restoration and selection must retain the historical journal")
        await model.resume(jobID: historical.id)
        XCTAssertEqual(model.selectedJob?.profile, "fast")
        XCTAssertEqual(model.selectedJob?.remote?.profile, "fast")
        XCTAssertEqual(archive.profilesSeen, ["fast"])
        XCTAssertEqual(try store.load().first?.profile, "fast")
    }

    func testDownloadedFastMapIsRetainedWhenRebuildingWithQuality() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "快速地图", profile: .fast)
        let firstID = try XCTUnwrap(model.selectedJobID)
        await api.setRemoteStatus(.completed)
        await model.refresh(jobID: firstID)
        await model.download(jobID: firstID)
        let original = try XCTUnwrap(model.selectedJob)
        let asset = try XCTUnwrap(original.savedAsset)
        XCTAssertEqual(original.phase, .downloaded)
        await api.setRemoteStatus(.queued)
        await model.start(scanDirectory: scan, displayName: "质量地图")
        let rebuilt = try XCTUnwrap(model.selectedJob)
        XCTAssertNotEqual(rebuilt.id, firstID)
        XCTAssertEqual(rebuilt.profile, "quality")
        XCTAssertEqual(rebuilt.phase, .processing)
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertEqual(model.jobs.first(where: { $0.id == firstID }), original)
        XCTAssertEqual(journal.jobs.first(where: { $0.id == firstID }), original)
        XCTAssertEqual(assets.values[firstID], asset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.bundleURL.path))
        let profiles = await api.submittedProfiles
        XCTAssertEqual(profiles, ["fast", "quality"])
        XCTAssertEqual(archive.profilesSeen, ["fast", "quality"])
    }

    func testQualityDoesNotFallBackToFastWhenCloudRequirementsLackQuality() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AreaFlowAPI.legacyRequirements)) as? [String: Any])
        var profiles = try XCTUnwrap(object["profiles"] as? [String: Any])
        profiles.removeValue(forKey: "quality")
        object["profiles"] = profiles
        await api.setRequirements(try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: JSONSerialization.data(withJSONObject: object)))
        let model = model()
        await model.start(scanDirectory: scan, displayName: "质量建图")
        XCTAssertEqual(model.selectedJob?.profile, "quality")
        XCTAssertEqual(model.selectedJob?.phase, .failed)
        XCTAssertTrue(model.selectedJob?.detail.contains("未提供 Quality") == true)
        XCTAssertEqual(model.message, model.selectedJob?.detail)
        XCTAssertNil(model.selectedJob?.archiveURL)
        XCTAssertEqual(archive.calls, 0)
        let submitted = await api.submittedProfiles
        XCTAssertTrue(submitted.isEmpty)
    }

    func testUnsupportedQualityTaskAllowsExplicitFastNewTaskAndKeepsOriginal() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AreaFlowAPI.legacyRequirements)) as? [String: Any])
        var profiles = try XCTUnwrap(object["profiles"] as? [String: Any])
        profiles.removeValue(forKey: "quality")
        object["profiles"] = profiles
        await api.setRequirements(try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: JSONSerialization.data(withJSONObject: object)))
        let model = model()
        await model.start(scanDirectory: scan, displayName: "未提供的质量建图")
        let original = try XCTUnwrap(model.selectedJob)
        XCTAssertEqual(original.phase, .failed)
        XCTAssertEqual(original.profile, "quality")
        await model.start(scanDirectory: scan, displayName: "选择快速建图", profile: .fast)
        let fast = try XCTUnwrap(model.selectedJob)
        XCTAssertNotEqual(fast.id, original.id)
        XCTAssertEqual(fast.profile, "fast")
        XCTAssertEqual(fast.phase, .processing)
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertEqual(model.jobs.first(where: { $0.id == original.id }), original)
        XCTAssertEqual(journal.jobs.first(where: { $0.id == original.id }), original)
        XCTAssertEqual(archive.profilesSeen, ["fast"])
        let submitted = await api.submittedProfiles
        XCTAssertEqual(submitted, ["fast"])
    }

    func testInvalidQualityPolicyRemainsPausedWithoutSilentFastFallback() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AreaFlowAPI.legacyRequirements)) as? [String: Any])
        var profiles = try XCTUnwrap(object["profiles"] as? [String: Any])
        var quality = try XCTUnwrap(profiles["quality"] as? [String: Any])
        quality["maxFrames"] = 0
        profiles["quality"] = quality
        object["profiles"] = profiles
        await api.setRequirements(try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: JSONSerialization.data(withJSONObject: object)))
        let model = model()
        await model.start(scanDirectory: scan, displayName: "等待有效质量策略")
        XCTAssertEqual(model.selectedJob?.profile, "quality")
        XCTAssertEqual(model.selectedJob?.phase, .paused)
        XCTAssertNil(model.selectedJob?.archiveURL)
        XCTAssertEqual(archive.calls, 0)
        let submitted = await api.submittedProfiles
        XCTAssertTrue(submitted.isEmpty)
    }

    func testJournalRoundTripKeepsEachTasksExplicitProfile() throws {
        let store = AreaTargetJobStore(url: root.appendingPathComponent("persist/profile-jobs.json"))
        var fast = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "Fast 地图", createdAt: Date(timeIntervalSince1970: 100))
        fast.profile = "fast"
        let quality = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "Quality 地图", createdAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(quality.profile, "quality")
        try store.save([fast, quality])
        XCTAssertEqual(try store.load(), [fast, quality])
        XCTAssertEqual(try store.load().map(\.profile), ["fast", "quality"])
    }

    func testRefreshRejectsRemoteProfileDifferentFromFrozenTask() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "处理模式核对")
        let original = try XCTUnwrap(model.selectedJob)
        await api.setRemoteProfileOverride(original.profile == "fast" ? "quality" : "fast")
        await api.setRemoteStatus(.completed)
        await model.refresh(jobID: original.id)
        let job = try XCTUnwrap(model.selectedJob)
        XCTAssertEqual(job.profile, original.profile)
        XCTAssertEqual(job.phase, .processing)
        XCTAssertEqual(job.remote, original.remote)
        XCTAssertNil(job.savedAsset)
        XCTAssertEqual(model.message, AreaTargetAPIError.invalidResponse.localizedDescription)
    }

    func testRefreshRejectsRemoteUVUnwrapDifferentFromFrozenTask() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "纹理配置核对")
        let original = try XCTUnwrap(model.selectedJob)
        await api.setRemoteUVUnwrapOverride(!original.uvUnwrap)
        await api.setRemoteStatus(.completed)
        await model.refresh(jobID: original.id)
        let job = try XCTUnwrap(model.selectedJob)
        XCTAssertEqual(job.uvUnwrap, original.uvUnwrap)
        XCTAssertEqual(job.phase, .processing)
        XCTAssertEqual(job.remote, original.remote)
        XCTAssertNil(job.savedAsset)
        XCTAssertEqual(model.message, AreaTargetAPIError.invalidResponse.localizedDescription)
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

    func testPauseKeepsOriginalScanProtectedUntilAnExplicitLocalStop() throws {
        var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "暂停后保留原扫描", createdAt: Date(), serverOrigin: .current)
        job.phase = .paused
        journal.jobs = [job]
        let model = model()
        model.pause()
        XCTAssertTrue(model.deletionBlocked(scanPath: scan.path), "Pausing must preserve the original data needed for a safe retry")
        XCTAssertEqual(model.jobs.first?.phase, .paused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.path))
    }

    func testStoppedLocalTaskRestoresWithoutProtectingSourceOrSendingRequests() async throws {
        var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "已停止本机跟踪", createdAt: Date(), serverOrigin: .current)
        job.phase = .paused
        let data = try JSONEncoder().encode([job])
        var documents = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        documents[0]["phase"] = "stopped"
        documents[0]["detail"] = "已停止本机跟踪。原扫描和已下载资产保留，可以重新处理。云端任务可能仍会继续。"
        let store = AreaTargetJobStore(url: root.appendingPathComponent("stopped-jobs.json"))
        try JSONSerialization.data(withJSONObject: documents).write(to: store.url)
        try tokens.save(String(repeating: "a", count: 64), jobID: job.id)
        let model = AreaTargetProcessingModel(api: api, archiver: archive, jobStore: store,
            tokenStore: tokens, assetStore: assets, pollInterval: 0.02, uploadDirectory: root.appendingPathComponent("uploads"))
        XCTAssertEqual(model.jobs.first?.phase.rawValue, "stopped", "A stopped local task must remain readable in history instead of invalidating the journal")
        XCTAssertFalse(model.deletionBlocked(scanPath: scan.path), "Stopping local tracking must release the scan's deletion guard")
        model.setAppActive(true)
        defer { model.setAppActive(false) }
        await model.resume(jobID: job.id)
        await model.refresh(jobID: job.id)
        await model.download(jobID: job.id)
        try await Task.sleep(nanoseconds: 60_000_000)
        let events = await api.events
        XCTAssertTrue(events.isEmpty, "A restored stopped task must not resume, query, download, or submit automatically")
        XCTAssertEqual(model.jobs.first?.phase.rawValue, "stopped")
        XCTAssertEqual(tokens.values[job.id], String(repeating: "a", count: 64))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.path))
    }

    func testSignInPreservesTheOriginallySelectedScanAndTask() async throws {
        let otherScan = root.appendingPathComponent("scan_other")
        try FileManager.default.createDirectory(at: otherScan, withIntermediateDirectories: true)
        var original = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "原选场景", createdAt: Date(timeIntervalSince1970: 100), serverOrigin: .current)
        original.phase = .paused
        var other = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: otherScan.path,
            displayName: "另一场景", createdAt: Date(timeIntervalSince1970: 200), serverOrigin: .current)
        other.phase = .paused
        journal.jobs = [original, other]
        let authenticatedAPI = AreaFlowServiceAPI(base: api)
        let model = AreaTargetProcessingModel(api: authenticatedAPI, archiver: archive, jobStore: journal,
            tokenStore: tokens, assetStore: assets, uploadDirectory: root.appendingPathComponent("uploads"))
        model.selectJob(original.id)
        await model.signIn(username: "scanner", password: "temporary password", origin: .current)
        XCTAssertEqual(model.selectedJobID, original.id)
        XCTAssertEqual(model.selectedJob?.scanDirectoryPath, scan.path)
        XCTAssertEqual(model.job(for: scan.path)?.displayName, "原选场景")
        XCTAssertEqual(Set(model.jobs.map(\.id)), Set([original.id, other.id]))
        let events = await api.events
        XCTAssertTrue(events.isEmpty, "Signing in must not silently upload or switch the selected scan")
    }

    func testStoppingPausedTaskReleasesGuardAndKeepsSourceIdentityAndArchive() async throws {
        var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "待处理场景", createdAt: Date(), serverOrigin: .current)
        job.phase = .paused
        job.archivePath = archive.url.path
        try Data("immutable upload copy".utf8).write(to: archive.url)
        journal.jobs = [job]
        try tokens.save(String(repeating: "a", count: 64), jobID: job.id)
        let model = model()
        XCTAssertTrue(try XCTUnwrap(model.sourceProtectionReason(scanPath: scan.path)).contains("待处理场景"))
        model.stopLocalTracking(jobID: job.id)
        XCTAssertEqual(model.jobs.first?.phase.rawValue, "stopped")
        XCTAssertEqual(journal.jobs.first?.phase.rawValue, "stopped")
        XCTAssertFalse(model.deletionBlocked(scanPath: scan.path))
        XCTAssertNil(model.sourceProtectionReason(scanPath: scan.path))
        XCTAssertEqual(model.jobs.first?.id, job.id)
        XCTAssertEqual(tokens.values[job.id], String(repeating: "a", count: 64))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.url.path))
        let events = await api.events
        XCTAssertTrue(events.isEmpty, "Stopping local tracking must not send remote cancellation or other mutations")
    }

    func testStoppedTaskCanCreateANewTaskForTheSameOriginalScan() async throws {
        await api.setRejectBeforeAccepting(true)
        let model = model()
        await model.start(scanDirectory: scan, displayName: "同一场景")
        let oldID = try XCTUnwrap(model.selectedJobID)
        let oldToken = try XCTUnwrap(tokens.values[oldID])
        XCTAssertTrue(model.deletionBlocked(scanPath: scan.path))
        model.stopLocalTracking(jobID: oldID)
        await api.setRejectBeforeAccepting(false)
        await model.start(scanDirectory: scan, displayName: "同一场景")
        let newID = try XCTUnwrap(model.selectedJobID)
        XCTAssertNotEqual(newID, oldID, "Explicitly processing again must create a new submission identity")
        XCTAssertEqual(model.jobs.first(where: { $0.id == oldID })?.phase.rawValue, "stopped")
        XCTAssertEqual(model.jobs.first(where: { $0.id == newID })?.phase, .processing)
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertEqual(tokens.values[oldID], oldToken)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.path))
        let events = await api.events
        XCTAssertEqual(events.filter { $0.0 == "submit" }.map { $0.1 }, [oldID, newID])
    }

    func testStopDuringTransferIsRejectedUntilLocalPauseHasFinished() async throws {
        await api.setHoldUpload(true)
        let uploadHeld = expectation(description: "The upload request is waiting for its response")
        await api.setOnUploadHeld { uploadHeld.fulfill() }
        let model = model()
        let upload = Task { await model.start(scanDirectory: scan, displayName: "正在上传") }
        defer { model.pause(); upload.cancel() }
        await fulfillment(of: [uploadHeld], timeout: 5)
        let selectedJobID = model.selectedJobID
        if selectedJobID == nil {
            model.pause()
            upload.cancel()
            await api.setHoldUpload(false)
            await upload.value
        }
        let id = try XCTUnwrap(selectedJobID)
        XCTAssertTrue(model.operationInProgress)
        model.stopLocalTracking(jobID: id)
        XCTAssertEqual(model.jobs.first?.phase, .uploading)
        XCTAssertTrue(model.deletionBlocked(scanPath: scan.path))
        model.pause()
        await upload.value
        XCTAssertFalse(model.operationInProgress)
        model.stopLocalTracking(jobID: id)
        XCTAssertEqual(model.jobs.first?.phase.rawValue, "stopped")
        XCTAssertFalse(model.deletionBlocked(scanPath: scan.path))
    }

    func testStopPersistenceFailureKeepsTaskAndSourceProtected() async throws {
        var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "不能丢失进度", createdAt: Date(), serverOrigin: .current)
        job.phase = .paused
        journal.jobs = [job]
        let model = model()
        journal.failWrites = true
        model.stopLocalTracking(jobID: job.id)
        XCTAssertEqual(model.jobs.first?.phase, .paused)
        XCTAssertEqual(journal.jobs.first?.phase, .paused)
        XCTAssertTrue(model.deletionBlocked(scanPath: scan.path))
        XCTAssertNotNil(model.sourceProtectionReason(scanPath: scan.path))
        XCTAssertEqual(model.message, AreaTargetLocalError.diskPersistence.localizedDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.path))
        let events = await api.events
        XCTAssertTrue(events.isEmpty)
    }

    func testLateStatusResponseCannotReviveAStoppedLocalTask() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "停止后迟到的状态")
        let id = try XCTUnwrap(model.selectedJobID)
        await api.setHoldStatus(true)
        let refresh = Task { await model.refresh(jobID: id) }
        for _ in 0..<100 {
            if await api.events.contains(where: { $0.0 == "status" }) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        model.stopLocalTracking(jobID: id)
        await api.setRemoteStatus(.completed)
        await api.setHoldStatus(false)
        await refresh.value
        XCTAssertEqual(model.jobs.first?.phase.rawValue, "stopped")
        XCTAssertEqual(journal.jobs.first?.phase.rawValue, "stopped")
        XCTAssertFalse(model.deletionBlocked(scanPath: scan.path))
        XCTAssertNil(model.jobs.first?.savedAsset)
    }

    func testOlderProcessingStatusCannotRegressDownloadedAssetAfterNewerCompletion() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "乱序状态回包")
        let id = try XCTUnwrap(model.selectedJobID)
        await api.setRemoteStatus(.processing)
        await api.setHoldNextStatusSnapshot(true)
        let oldStatusHeld = expectation(description: "The older processing response has been captured")
        await api.setOnStatusHeld { oldStatusHeld.fulfill() }
        let oldRefresh = Task { await model.refresh(jobID: id) }
        await fulfillment(of: [oldStatusHeld], timeout: 5)

        await api.setRemoteStatus(.completed)
        await model.refresh(jobID: id)
        XCTAssertEqual(model.jobs.first?.phase, .ready)
        await model.download(jobID: id)
        let downloaded = model.jobs.first
        XCTAssertEqual(downloaded?.phase, .downloaded)
        XCTAssertNotNil(downloaded?.savedAsset)

        await api.setHoldNextStatusSnapshot(false)
        await oldRefresh.value
        XCTAssertEqual(model.jobs.first, downloaded, "An older status must not replace a verified downloaded record")
        XCTAssertEqual(journal.jobs.first, downloaded)
        XCTAssertNil(model.message)
    }

    func testDownloadStatusSupersedesAnOlderProcessingRefresh() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "下载完成后不回退")
        let id = try XCTUnwrap(model.selectedJobID)
        await api.setRemoteStatus(.processing)
        await api.setHoldNextStatusSnapshot(true)
        let oldStatusHeld = expectation(description: "The processing refresh is waiting while download proceeds")
        await api.setOnStatusHeld { oldStatusHeld.fulfill() }
        let oldRefresh = Task { await model.refresh(jobID: id) }
        await fulfillment(of: [oldStatusHeld], timeout: 5)

        await api.setRemoteStatus(.completed)
        await model.download(jobID: id)
        let downloaded = model.jobs.first
        XCTAssertEqual(downloaded?.phase, .downloaded)
        XCTAssertNotNil(downloaded?.savedAsset)
        await api.setHoldNextStatusSnapshot(false)
        await oldRefresh.value
        XCTAssertEqual(model.jobs.first, downloaded, "The download's newer status must supersede an in-flight refresh")
        XCTAssertEqual(journal.jobs.first, downloaded)
        XCTAssertNil(model.message)
    }

    func testOlderExpiredStatusCannotOverrideANewerCompletedResult() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "迟到的过期回包")
        let id = try XCTUnwrap(model.selectedJobID)
        await api.setExpired(true)
        await api.setHoldNextStatusSnapshot(true)
        let oldStatusHeld = expectation(description: "The older expired response has been captured")
        await api.setOnStatusHeld { oldStatusHeld.fulfill() }
        let oldRefresh = Task { await model.refresh(jobID: id) }
        await fulfillment(of: [oldStatusHeld], timeout: 5)

        await api.setExpired(false)
        await api.setRemoteStatus(.completed)
        await model.refresh(jobID: id)
        let completed = model.jobs.first
        XCTAssertEqual(completed?.phase, .ready)
        await api.setHoldNextStatusSnapshot(false)
        await oldRefresh.value
        XCTAssertEqual(model.jobs.first, completed, "An obsolete error must not fail a newer completed result")
        XCTAssertEqual(journal.jobs.first, completed)
        XCTAssertNil(model.message)
    }

    func testRefreshCannotSupersedeExplicitResumeOfAnUnacceptedTask() async throws {
        var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "后台刷新不能丢掉手动重试", createdAt: Date(), serverOrigin: .current)
        job.phase = .submissionUnknown
        journal.jobs = [job]
        let token = String(repeating: "a", count: 64)
        try tokens.save(token, jobID: job.id)
        let model = model()
        XCTAssertTrue(model.deletionBlocked(scanPath: scan.path))
        await api.setHoldNextStatusSnapshot(true)
        let resumeStatusHeld = expectation(description: "Explicit resume captured its job-not-found response")
        await api.setOnStatusHeld { resumeStatusHeld.fulfill() }
        let resume = Task { await model.resume(jobID: job.id) }
        await fulfillment(of: [resumeStatusHeld], timeout: 5)

        await model.refresh(jobID: job.id)
        XCTAssertEqual(model.jobs.first?.phase, .submissionUnknown)
        XCTAssertTrue(model.deletionBlocked(scanPath: scan.path))
        await api.setHoldNextStatusSnapshot(false)
        await resume.value

        XCTAssertEqual(model.jobs.first?.id, job.id)
        XCTAssertEqual(model.jobs.first?.phase, .processing)
        XCTAssertEqual(model.jobs.first?.accepted, true)
        XCTAssertEqual(journal.jobs.first?.phase, .processing)
        XCTAssertEqual(archive.calls, 1)
        let events = await api.events
        XCTAssertEqual(events.map { $0.0 }, ["status", "submit"], "Refresh must yield while explicit resume reconciles the task")
        XCTAssertTrue(events.allSatisfy { $0.1 == job.id && $0.2 == token }, "Retry must retain the durable job ID and capability")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.path))
        XCTAssertNil(model.message)
    }

    func testLateMissingStatusCannotResubmitAfterLocalStop() async throws {
        var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "停止后不重传旧任务", createdAt: Date(), serverOrigin: .current)
        job.phase = .paused
        journal.jobs = [job]
        try tokens.save(String(repeating: "a", count: 64), jobID: job.id)
        let model = model()
        await api.setHoldStatus(true)
        let statusHeld = expectation(description: "The missing status request is waiting for its response")
        await api.setOnStatusHeld { statusHeld.fulfill() }
        let resume = Task { await model.resume(jobID: job.id) }
        await fulfillment(of: [statusHeld], timeout: 5)
        model.stopLocalTracking(jobID: job.id)
        await api.setHoldStatus(false)
        await resume.value
        XCTAssertEqual(model.jobs.first?.phase, .stopped)
        XCTAssertEqual(journal.jobs.first?.phase, .stopped)
        XCTAssertFalse(model.deletionBlocked(scanPath: scan.path))
        let events = await api.events
        XCTAssertEqual(events.map { $0.0 }, ["status"], "A late 404 must not resubmit a stopped local task")
        XCTAssertEqual(archive.calls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.path))
    }

    func testStoppingDoesNotChangeAnAlreadyDownloadedAsset() async throws {
        let model = model()
        await model.start(scanDirectory: scan, displayName: "已下载结果")
        let id = try XCTUnwrap(model.selectedJobID)
        await api.setRemoteStatus(.completed)
        await model.refresh(jobID: id)
        await model.download(jobID: id)
        let saved = try XCTUnwrap(model.jobs.first?.savedAsset)
        let record = try XCTUnwrap(model.jobs.first)
        model.stopLocalTracking(jobID: id)
        XCTAssertEqual(model.jobs.first, record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.bundleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.path))
    }

    func testRestoringAssetsDoesNotRestartStoppedLocalTracking() async throws {
        var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "保留已下载资产", createdAt: Date(), serverOrigin: .current)
        job.phase = .stopped
        let bundle = root.appendingPathComponent("saved-result.zip")
        try Data("previously verified asset".utf8).write(to: bundle)
        let saved = AreaTargetSavedAsset(jobID: job.id, bundleURL: bundle, directoryURL: root,
            modelURL: root.appendingPathComponent("model.glb"), featuresURL: root.appendingPathComponent("features.db"),
            manifestURL: root.appendingPathComponent("manifest.json"), savedAt: Date())
        job.savedAsset = saved
        journal.jobs = [job]
        assets.values[job.id] = saved
        let model = model()
        for _ in 0..<100 {
            if !model.isRestoringAssets { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(model.jobs.first?.phase, .stopped)
        XCTAssertEqual(model.jobs.first?.savedAsset, saved)
        XCTAssertFalse(model.deletionBlocked(scanPath: scan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
        let events = await api.events
        XCTAssertTrue(events.isEmpty)
    }

    func testProductionUIAndPersistentQAResolveTheSameOwner() throws {
        #if targetEnvironment(simulator)
        let ui = AreaTargetProcessingModel.shared
        let persistentQA = AreaTargetProcessingModel.shared
        XCTAssertTrue(ui === persistentQA, "UI and persistent QA must share one journal-writing owner")
        XCTAssertFalse(model() === ui, "Explicit injected/isolated models remain independent")
        #else
        throw XCTSkip("Avoid starting the production persistent owner and restoring real device jobs during unit tests")
        #endif
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
        job.profile = "fast"
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
        legacy.profile = "fast"
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
        await model.start(scanDirectory: scan, displayName: "完整原扫描", profile: .fast)
        let requestCount = await api.requirementsCallCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(archive.requirementsSeen, requirements)
        XCTAssertEqual(model.jobs.first?.clientPreparation, preparation)
        XCTAssertEqual(journal.jobs.first?.clientPreparation, preparation)
        XCTAssertEqual(model.jobs.first?.phase, .processing)
    }

    func testRequirementsFailurePreservesRetryWithoutCreatingAmbiguousRawUpload() async throws {
        await api.setRequirements(nil)
        let model = model()
        await model.start(scanDirectory: scan, displayName: "完整原扫描")
        let id = try XCTUnwrap(model.jobs.first?.id)
        let requestCount = await api.requirementsCallCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertNil(archive.requirementsSeen)
        XCTAssertNil(model.jobs.first?.clientPreparation)
        XCTAssertEqual(model.jobs.first?.phase, .paused)
        XCTAssertEqual(archive.calls, 0)
        XCTAssertNil(model.jobs.first?.archiveURL)
        let events = await api.events
        let submissions = events.filter { $0.0 == "submit" }
        XCTAssertTrue(submissions.isEmpty)
        await api.setRequirements(AreaFlowAPI.legacyRequirements)
        await model.resume(jobID: id)
        let retryRequestCount = await api.requirementsCallCount()
        XCTAssertEqual(retryRequestCount, 2)
        XCTAssertEqual(archive.calls, 1)
        XCTAssertEqual(model.jobs.first?.phase, .processing)
    }

    func testKnownUnsupportedV2QueriesLegacyRequirementsAndDisplaysActualCapacity() async throws {
        await api.setRequirementsPolicyError(.server(statusCode: 400,
            problem: .init(code: "unsupported_preparation_policy", message: "Unsupported policy", retryable: false), retryAfter: nil))
        let model = model(); await model.start(scanDirectory: scan, displayName: "旧服务器扫描")
        let count = await api.requirementsCallCount()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(archive.requirementsSeen, AreaFlowAPI.legacyRequirements)
        XCTAssertTrue(journal.details.contains { $0.contains("旧") && $0.contains("80") })
        XCTAssertEqual(model.jobs.first?.phase, .processing)
    }

    func testUnknownRequirementsDoNotProduceRawUpload() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AreaFlowAPI.legacyRequirements)) as? [String: Any])
        object["policy"] = "future-policy"
        await api.setRequirements(try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: JSONSerialization.data(withJSONObject: object)))
        let model = model(); await model.start(scanDirectory: scan, displayName: "未知策略")
        XCTAssertEqual(model.jobs.first?.phase, .paused)
        XCTAssertEqual(archive.calls, 0)
        XCTAssertNil(model.jobs.first?.archiveURL)
    }

    func testNewTaskRequestsV2AndDisplaysReturnedLegacyCapacityWhilePreparing() async throws {
        let requirements = try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: Data(#"{"schemaVersion":1,"policy":"mobile-scan-preparation-v1","policyVersion":1,"profiles":{"fast":{"maxFrames":80,"maximumLongEdge":1600,"maximumTotalPixels":200000000}},"safety":{"maximumRequestBytes":536870912,"maximumExpandedBytes":524288000,"maximumArchiveEntries":10000,"maximumSourceFrameCount":10000,"maximumImagePixels":32000000,"maximumImageDimension":8192,"maximumMetadataBytes":8388608}}"#.utf8))
        await api.setRequirements(requirements)
        await model().start(scanDirectory: scan, displayName: "旧服务器扫描", profile: .fast)
        let requested = await api.requestedPreparationPolicy()
        XCTAssertEqual(requested, "mobile-scan-preparation-v2")
        XCTAssertTrue(journal.details.contains { $0.contains("80") && $0.contains("旧") })
        XCTAssertEqual(archive.requirementsSeen, requirements)
    }

    func testHistoricalPreparationDecodesWithoutV2FieldsAndKeepsExactIdentity() throws {
        let bytes = Data(#"{"schemaVersion":1,"policy":"mobile-scan-preparation-v1","policyVersion":1,"profile":"fast","preparedBy":"client","originalFrameCount":120,"selectedFrameCount":2,"selectedIndices":[0,119],"processedPixelCount":3840000,"resizedFrameCount":2,"maximumOutputLongEdge":1600,"scaleDigest":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}"#.utf8)
        let value = try JSONDecoder().decode(AreaTargetClientPreparation.self, from: bytes)
        XCTAssertEqual(value.identityConfiguration, "preparation_schema=1;policy=mobile-scan-preparation-v1;policy_version=1;profile=fast;prepared_by=client;original_frames=120;selected_frames=2;scale_sha256=" + String(repeating: "d", count: 64))
    }

    func testV2PreparationAndIdentityRemainFrozenWhenRetryRequirementsChange() async throws {
        var object: [String: Any] = ["schemaVersion": 1, "policy": "mobile-scan-preparation-v2", "policyVersion": 2,
            "capacityTier": 100, "profiles": ["fast": ["maxFrames": 100, "maximumLongEdge": 1600, "minimumLongEdge": 1024, "maximumTotalPixels": 200_000_000]],
            "safety": ["maximumRequestBytes": 536870912, "maximumExpandedBytes": 524288000, "maximumArchiveEntries": 10000,
                "maximumSourceFrameCount": 10000, "maximumImagePixels": 32000000, "maximumImageDimension": 8192, "maximumMetadataBytes": 8388608]]
        let requirements = try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: JSONSerialization.data(withJSONObject: object))
        await api.setRequirements(requirements)
        let digest = try AreaTargetClientPreparation.uploadSelectionDigest(capacityTier: 100, indices: [0, 1])
        let preparation = AreaTargetClientPreparation(schemaVersion: 1, policy: "mobile-scan-preparation-v2", policyVersion: 2,
            profile: "fast", preparedBy: "client", originalFrameCount: 2, selectedFrameCount: 2, selectedIndices: [0, 1],
            processedPixelCount: 20_000, resizedFrameCount: 0, maximumOutputLongEdge: 100, scaleDigest: String(repeating: "d", count: 64),
            receivedFrameCount: 2, capacityTier: 100, selectionVersion: "upload-all-v2", selectionDigest: digest)
        archive.preparation = preparation
        await api.setRejectBeforeAccepting(true)
        let model = model(); await model.start(scanDirectory: scan, displayName: "全帧扫描", profile: .fast)
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(job.phase, .paused)
        XCTAssertEqual(job.clientPreparation, preparation)
        XCTAssertTrue(job.localizationBuildConfiguration.contains("capacity_tier=100;selection_sha256=" + digest))
        let zipDigest = job.archiveSHA256
        object["capacityTier"] = 500
        object["profiles"] = ["fast": ["maxFrames": 500, "maximumLongEdge": 1600, "minimumLongEdge": 1024, "maximumTotalPixels": 600_000_000]]
        await api.setRequirements(try JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: JSONSerialization.data(withJSONObject: object)))
        await model.resume(jobID: job.id)
        let count = await api.requirementsCallCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(archive.calls, 1)
        XCTAssertEqual(model.jobs.first?.archiveSHA256, zipDigest)
        XCTAssertEqual(model.jobs.first?.clientPreparation, preparation)
        XCTAssertEqual(model.jobs.first?.localizationBuildConfiguration, job.localizationBuildConfiguration)
    }

    func testCriticalProtectionIdentityIsOptionalAndFrozenAcrossSavedZIPRetry() async throws {
        let digest = try AreaTargetClientPreparation.uploadSelectionDigest(capacityTier: 100, indices: [0, 1])
        var preparation = AreaTargetClientPreparation(schemaVersion: 1, policy: "mobile-scan-preparation-v2", policyVersion: 2,
            profile: "fast", preparedBy: "client", originalFrameCount: 2, selectedFrameCount: 2, selectedIndices: [0, 1],
            processedPixelCount: 20_000, resizedFrameCount: 0, maximumOutputLongEdge: 100, scaleDigest: String(repeating: "d", count: 64),
            receivedFrameCount: 2, capacityTier: 100, selectionVersion: "upload-all-v2", selectionDigest: digest)
        let legacyIdentity = "preparation_schema=1;policy=mobile-scan-preparation-v2;policy_version=2;profile=fast;prepared_by=client;original_frames=2;selected_frames=2;scale_sha256=" + String(repeating: "d", count: 64) + ";capacity_tier=100;selection_sha256=" + digest
        XCTAssertEqual(preparation.identityConfiguration, legacyIdentity)
        preparation.criticalFrameProtection = .init(version: "critical-frame-protection-v1", riskVersion: "gray-quality-risk-v1", protectedIndices: [1], candidateFrameCount: 2)
        XCTAssertEqual(preparation.identityConfiguration, legacyIdentity + ";critical_frame_protection=critical-frame-protection-v1;critical_frame_risk=gray-quality-risk-v1;protected_indices=1;candidate_frames=2")
        archive.preparation = preparation
        await api.setRejectBeforeAccepting(true)
        let model = model(); await model.start(scanDirectory: scan, displayName: "保护扫描", profile: .fast)
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(job.clientPreparation, preparation)
        await api.setRequirements(AreaFlowAPI.legacyRequirements)
        await model.resume(jobID: job.id)
        let count = await api.requirementsCallCount()
        XCTAssertEqual(count, 1); XCTAssertEqual(archive.calls, 1)
        XCTAssertEqual(model.jobs.first?.clientPreparation, preparation)
        XCTAssertEqual(model.jobs.first?.archiveSHA256, job.archiveSHA256)
        XCTAssertEqual(model.jobs.first?.localizationBuildConfiguration, job.localizationBuildConfiguration)
        var changed = preparation
        changed.criticalFrameProtection = .init(version: "critical-frame-protection-v1", riskVersion: "gray-quality-risk-v1", protectedIndices: [0], candidateFrameCount: 2)
        XCTAssertNotEqual(changed.identityConfiguration, preparation.identityConfiguration)
        changed.criticalFrameProtection = .init(version: "critical-frame-protection-v1", riskVersion: "gray-quality-risk-v1", protectedIndices: [1], candidateFrameCount: 1)
        XCTAssertNotEqual(changed.identityConfiguration, preparation.identityConfiguration)
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
        let uploadHeld = expectation(description: "The upload request is waiting for its response")
        await api.setOnUploadHeld { uploadHeld.fulfill() }
        let model = model()
        model.setAppActive(true)
        let operation = Task { await model.start(scanDirectory: self.scan, displayName: "测试") }
        defer { model.pause(); operation.cancel() }
        await fulfillment(of: [uploadHeld], timeout: 5)
        if model.selectedJobID == nil {
            model.pause()
            operation.cancel()
            await api.setHoldUpload(false)
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
        await model.start(scanDirectory: scan, displayName: "测试", profile: .fast)
        let oldID = try XCTUnwrap(model.jobs.first?.id)
        await api.setRemoteStatus(.failed)
        await model.refresh(jobID: oldID)
        XCTAssertEqual(model.jobs.first?.phase, .failed)
        XCTAssertFalse(model.deletionBlocked(scanPath: scan.path))
        let original = try XCTUnwrap(model.selectedJob)
        await api.setRemoteStatus(.queued)
        await model.start(scanDirectory: scan, displayName: "重新处理")
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertNotEqual(model.selectedJobID, oldID)
        XCTAssertEqual(model.selectedJob?.profile, "quality")
        XCTAssertEqual(model.jobs.first(where: { $0.id == oldID }), original)
        let profiles = await api.submittedProfiles
        XCTAssertEqual(profiles, ["fast", "quality"])
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

    func testJournalRejectsIntegralFloatAndBooleanProtectionTokensWithoutChangingStoredBytes() throws {
        let store = AreaTargetJobStore(url: root.appendingPathComponent("persist/critical-jobs.json"))
        var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "保护任务", createdAt: Date())
        job.profile = "fast"
        job.clientPreparation = .init(schemaVersion: 1, policy: "mobile-scan-preparation-v2", policyVersion: 2,
            profile: "fast", preparedBy: "client", originalFrameCount: 2, selectedFrameCount: 2, selectedIndices: [0, 1],
            processedPixelCount: 20_000, resizedFrameCount: 0, maximumOutputLongEdge: 100, scaleDigest: String(repeating: "a", count: 64),
            receivedFrameCount: 2, capacityTier: 100, selectionVersion: "upload-all-v2",
            selectionDigest: try AreaTargetClientPreparation.uploadSelectionDigest(capacityTier: 100, indices: [0, 1]),
            criticalFrameProtection: .init(version: "critical-frame-protection-v1", riskVersion: "gray-quality-risk-v1", protectedIndices: [1], candidateFrameCount: 1))
        try store.save([job]); XCTAssertEqual(try store.load(), [job])
        let original = String(decoding: try Data(contentsOf: store.url), as: UTF8.self)
        for (old, new) in [("\"candidateFrameCount\":1", "\"candidateFrameCount\":1.0"),
            ("\"candidateFrameCount\":1", "\"candidateFrameCount\":true"),
            ("\"protectedIndices\":[1]", "\"protectedIndices\":[1.0]"),
            ("\"protectedIndices\":[1]", "\"protectedIndices\":[true]")] {
            let altered = Data(original.replacingOccurrences(of: old, with: new).utf8)
            XCTAssertNotEqual(altered, Data(original.utf8))
            try altered.write(to: store.url)
            XCTAssertThrowsError(try store.load(), new)
            XCTAssertEqual(try Data(contentsOf: store.url), altered, "Rejected journal is retained for diagnosis")
        }
    }
}

final class AreaFlowJournal: AreaTargetJobStoring {
    var jobs: [AreaTargetProcessingJob] = []
    var details: [String] = []
    var failWrites = false
    func load() throws -> [AreaTargetProcessingJob] { jobs }
    func save(_ jobs: [AreaTargetProcessingJob]) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        self.jobs = jobs
        details.append(contentsOf: jobs.map(\.detail))
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
    private var capturedProfiles: [String] = []
    private var capturedUVUnwrap: [Bool] = []
    var profilesSeen: [String] { lock.lock(); defer { lock.unlock() }; return capturedProfiles }
    var uvUnwrapSeen: [Bool] { lock.lock(); defer { lock.unlock() }; return capturedUVUnwrap }
    var requirementsSeen: AreaTargetProcessingRequirements? { lock.lock(); defer { lock.unlock() }; return capturedRequirements }
    func archive(scanDirectory: URL, uvUnwrap: Bool, profile: String, requirements: AreaTargetProcessingRequirements?,
                 progress: @escaping @Sendable (String) -> Void, isCancelled: @escaping @Sendable () -> Bool) throws -> URL {
        lock.lock(); capturedRequirements = requirements; capturedProfiles.append(profile); lock.unlock()
        return try archive(scanDirectory: scanDirectory, uvUnwrap: uvUnwrap, progress: progress, isCancelled: isCancelled)
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    init(url: URL) { self.url = url }
    func archive(scanDirectory: URL, uvUnwrap: Bool, progress: @escaping @Sendable (String) -> Void,
                 isCancelled: @escaping @Sendable () -> Bool) throws -> URL {
        lock.lock(); count += 1; capturedUVUnwrap.append(uvUnwrap); lock.unlock()
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
    static var legacyRequirements: AreaTargetProcessingRequirements {
        try! JSONDecoder().decode(AreaTargetProcessingRequirements.self, from: Data(#"{"schemaVersion":1,"policy":"mobile-scan-preparation-v1","policyVersion":1,"profiles":{"fast":{"maxFrames":80,"maximumLongEdge":1600,"maximumTotalPixels":200000000},"quality":{"maxFrames":80,"maximumLongEdge":1600,"maximumTotalPixels":200000000}},"safety":{"maximumRequestBytes":536870912,"maximumExpandedBytes":524288000,"maximumArchiveEntries":10000,"maximumSourceFrameCount":10000,"maximumImagePixels":32000000,"maximumImageDimension":8192,"maximumMetadataBytes":8388608}}"#.utf8))
    }
    let root: URL
    var events: [(String, String, String)] = []
    var submittedProfiles: [String] = []
    var submittedUVUnwrap: [Bool] = []
    var submittedMapCLAHE: [Bool] = []
    private var jobProfiles: [String: String] = [:]
    private var jobUVUnwrap: [String: Bool] = [:]
    private var jobMapCLAHE: [String: Bool] = [:]
    var requirements: AreaTargetProcessingRequirements?
    var requirementsCalls = 0
    var requestedPolicy: String?
    var requirementsPolicyError: AreaTargetAPIError?
    func setRequirementsPolicyError(_ value: AreaTargetAPIError?) { requirementsPolicyError = value }
    var holdRequirements = false
    func setRequirements(_ value: AreaTargetProcessingRequirements?) { requirements = value }
    func setHoldRequirements(_ value: Bool) { holdRequirements = value }
    func requirementsCallCount() -> Int { requirementsCalls }
    func requestedPreparationPolicy() -> String? { requestedPolicy }
    func fetchProcessingRequirements(policy: String) async throws -> AreaTargetProcessingRequirements {
        requestedPolicy = policy
        if let requirementsPolicyError { requirementsCalls += 1; throw requirementsPolicyError }
        return try await fetchProcessingRequirements()
    }
    func fetchProcessingRequirements() async throws -> AreaTargetProcessingRequirements {
        requirementsCalls += 1
        if holdRequirements { try await Task.sleep(nanoseconds: 30_000_000_000) }
        guard let requirements else { throw AreaTargetAPIError.transport("requirements offline") }
        return requirements
    }
    func setRemoteMapCLAHEOverride(_ value: Bool?) { remoteMapCLAHEOverride = value }
    func setRemoteProfileOverride(_ value: String?) { remoteProfileOverride = value }
    func setRemoteUVUnwrapOverride(_ value: Bool?) { remoteUVUnwrapOverride = value }
    var accepted: Set<String> = []

    var remoteStatus: AreaTargetRemoteStatus = .queued
    var remoteProblem: AreaTargetAPIProblem?
    var remoteProfileOverride: String?
    var remoteUVUnwrapOverride: Bool?
    var remoteMapCLAHEOverride: Bool?
    var lostResponse = false
    var rejectBeforeAccepting = false
    var holdUpload = false
    private var onUploadHeld: (@Sendable () -> Void)?
    func setOnUploadHeld(_ callback: @escaping @Sendable () -> Void) { onUploadHeld = callback }
    var expired = false
    private var holdStatus = false
    private var statusContinuation: CheckedContinuation<Void, Never>?
    private var holdNextStatusSnapshot = false
    private var statusSnapshotContinuation: CheckedContinuation<Void, Never>?
    private var onStatusHeld: (@Sendable () -> Void)?
    func setOnStatusHeld(_ callback: @escaping @Sendable () -> Void) { onStatusHeld = callback }
    func setHoldStatus(_ value: Bool) {
        holdStatus = value
        if !value { statusContinuation?.resume(); statusContinuation = nil }
    }
    func setHoldNextStatusSnapshot(_ value: Bool) {
        holdNextStatusSnapshot = value
        if !value { statusSnapshotContinuation?.resume(); statusSnapshotContinuation = nil }
    }
    init(root: URL) { self.root = root; requirements = Self.legacyRequirements }
    func setRemoteStatus(_ value: AreaTargetRemoteStatus) { remoteStatus = value }
    func setRemoteProblem(_ value: AreaTargetAPIProblem) { remoteProblem = value }
    func setLostResponse(_ value: Bool) { lostResponse = value }
    func setRejectBeforeAccepting(_ value: Bool) { rejectBeforeAccepting = value }
    func setHoldUpload(_ value: Bool) { holdUpload = value }
    func setExpired(_ value: Bool) { expired = value }
    func submit(archiveURL: URL, jobID: String, token: String, profile: String, uvUnwrap: Bool, mapCLAHE: Bool = false,
                progress: @escaping @Sendable (Double) -> Void) async throws -> AreaTargetRemoteJob {
        events.append(("submit", jobID, token))
        submittedProfiles.append(profile)
        submittedUVUnwrap.append(uvUnwrap)
        submittedMapCLAHE.append(mapCLAHE)
        jobProfiles[jobID] = profile
        jobUVUnwrap[jobID] = uvUnwrap
        jobMapCLAHE[jobID] = mapCLAHE

        if holdUpload {
            onUploadHeld?()
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
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
        if holdNextStatusSnapshot {
            holdNextStatusSnapshot = false
            let snapshot = Result { try statusSnapshot(jobID: jobID) }
            await withCheckedContinuation {
                statusSnapshotContinuation = $0
                onStatusHeld?()
            }
            return try snapshot.get()
        }
        if holdStatus {
            await withCheckedContinuation {
                statusContinuation = $0
                onStatusHeld?()
            }
        }
        return try statusSnapshot(jobID: jobID)
    }
    private func statusSnapshot(jobID: String) throws -> AreaTargetRemoteJob {
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
            message: remoteStatus == .completed ? "完成" : "等待处理", profile: remoteProfileOverride ?? jobProfiles[jobID] ?? "fast", uvUnwrap: remoteUVUnwrapOverride ?? jobUVUnwrap[jobID] ?? true,
            mapCLAHE: remoteMapCLAHEOverride ?? jobMapCLAHE[jobID] ?? false,
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
    func submit(archiveURL: URL, jobID: String, token: String, profile: String, uvUnwrap: Bool, mapCLAHE: Bool = false,
                progress: @escaping @Sendable (Double) -> Void) async throws -> AreaTargetRemoteJob {
        try await base.submit(archiveURL: archiveURL, jobID: jobID, token: token, profile: profile, uvUnwrap: uvUnwrap, mapCLAHE: mapCLAHE, progress: progress)
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
