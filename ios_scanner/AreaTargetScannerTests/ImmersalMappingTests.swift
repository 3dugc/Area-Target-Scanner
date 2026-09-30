import XCTest
import SwiftUI
@testable import AreaTargetScanner

@MainActor
final class ImmersalMappingTests: XCTestCase {
    private var root: URL!
    private var api: MappingFakeAPI!
    private var credentials: MappingMemoryCredentials!
    private var store: ImmersalJobStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scan_fixture"), withIntermediateDirectories: true)
        api = MappingFakeAPI()
        credentials = MappingMemoryCredentials()
        store = ImmersalJobStore(url: root.appendingPathComponent("jobs.json"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func model() -> ImmersalMappingModel {
        ImmersalMappingModel(api: api, credentials: credentials, store: store,
                            frames: MappingFakeFrames(), documentsDirectory: root)
    }
    private func start(_ vm: ImmersalMappingModel) {
        vm.start(scanDirectory: root.appendingPathComponent("scan_fixture"), mapName: "MyMap")
    }
    private func wait(_ vm: ImmersalMappingModel) async {
        for _ in 0..<300 {
            if !vm.isBusy { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Operation failed to finish")
    }

    func testDisplayNameHidesOnlyThisJobsGeneratedSuffix() {
        let id = UUID()
        let suffix = id.uuidString.replacingOccurrences(of: "-", with: "")
        let job = ImmersalMappingJob(id: id, userID: 7, scanName: "scan_fixture",
                                    mapName: "MyMap" + suffix, createdAt: Date())
        XCTAssertEqual(job.displayName, "MyMap")
        let otherSuffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let imported = ImmersalMappingJob(id: id, userID: 7, scanName: "scan_fixture",
                                         mapName: "MyMap" + otherSuffix, createdAt: Date())
        XCTAssertEqual(imported.displayName, imported.mapName)
    }

    func testGuidedStagesDistinguishPreparationConfirmedUploadAndCloudConstruction() {
        var job = ImmersalMappingJob(id: UUID(), userID: 7, scanName: "scan_fixture", mapName: "MyMap", createdAt: Date())
        job.frameCount = 57
        XCTAssertEqual(job.stage, .preparation)
        job.uploadedCount = 12
        XCTAssertEqual(job.stage, .upload)
        job.phase = .workspaceConflict
        XCTAssertEqual(job.stage, .preparation, "A conflict requires preparation again before clearing")
        job.phase = .uploading
        XCTAssertEqual(job.stage, .upload)
        job.phase = .constructionUncertain
        XCTAssertEqual(job.stage, .construction, "Unknown submission must stay in the build stage, never offer a new upload")
        job.phase = .done
        XCTAssertEqual(job.stage, .construction)
    }

    /// Render the real SwiftUI screen with a local journal and fake API. Attachments are
    /// exported from xcresult for visual inspection; this never uses a live account.
    func testGuidedUploadScreenRendersWorkspaceAndProgressFixtures() async throws {
        let directory = root.appendingPathComponent("scan_20260930_091611")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var job = ImmersalMappingJob(id: UUID(), userID: 7, scanName: directory.lastPathComponent,
                                    mapName: "MyScan", createdAt: Date())
        job.frameCount = 57
        job.phase = .workspaceConflict
        job.workspaceImageCount = 4
        try store.save([job])
        try await attachScreen(model: model(), directory: directory, name: "guided-workspace-light", style: .light)
        try await attachScreen(model: model(), directory: directory, name: "guided-workspace-dark", style: .dark)
        try await attachScreen(model: model(), directory: directory, name: "guided-workspace-accessibility", style: .light,
                               sizeCategory: .accessibilityExtraLarge)
        job.uploadedCount = 12; job.phase = .uploading
        // Restore converts interrupted uploading to paused, which exercises the same
        // confirmed progress display with its explicit resume action.
        try store.save([job])
        try await attachScreen(model: model(), directory: directory, name: "guided-upload-paused", style: .light)
        job.phase = .pending; job.mapID = 123; job.uploadedCount = 57
        try store.save([job])
        try await attachScreen(model: model(), directory: directory, name: "guided-construction", style: .light)
        XCTAssertTrue(api.events.isEmpty, "Rendering must not upload or query a live service")
    }

    func testOccupiedWorkspaceAutomaticallyDisplaysNativeConfirmation() async throws {
        api.imageCount = 4
        let vm = ImmersalMappingModel(api: api, credentials: credentials, store: store,
                                     frames: MappingFakeFrames(frameCount: 57), documentsDirectory: root)
        try await attachScreen(model: vm, directory: root.appendingPathComponent("scan_fixture"),
                               name: "guided-native-clear-confirmation", style: .light, startUpload: true)
        XCTAssertEqual(api.events, ["status"])
        XCTAssertEqual(vm.workspaceConfirmation?.frameCount, 57)
        vm.cancelWorkspaceConfirmation()
        XCTAssertFalse(api.events.contains("clear"))
    }

    private func attachScreen(model: ImmersalMappingModel, directory: URL, name: String,
                              style: UIUserInterfaceStyle, sizeCategory: ContentSizeCategory = .large,
                              startUpload: Bool = false) async throws {
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: ImmersalMappingView(model: model, scanDirectory: directory)
            .environment(\.sizeCategory, sizeCategory))
        host.overrideUserInterfaceStyle = style
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let window = UIWindow(frame: bounds)
        if startUpload {
            // UIKit can present a controller in an unattached test window, but
            // window snapshots need the application's foreground scene.
            window.windowScene = try XCTUnwrap(previousWindow?.windowScene)
            window.frame = bounds
        }
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        host.view.frame = bounds
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        if startUpload {
            model.start(scanDirectory: directory, mapName: "MyScan")
            await wait(model)
            try await Task.sleep(nanoseconds: 300_000_000)
            var presented: UIViewController = host
            while let next = presented.presentedViewController { presented = next }
            let alert = try XCTUnwrap(presented as? UIAlertController, "Workspace confirmation must actually be presented")
            XCTAssertTrue(alert.message?.contains("4 张") == true)
            XCTAssertTrue(alert.message?.contains("57 帧") == true)
            XCTAssertTrue(alert.actions.contains { $0.title == "清空并上传 57 帧" })
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            if startUpload { rendered = window.drawHierarchy(in: bounds, afterScreenUpdates: true) }
            else { rendered = host.view.drawHierarchy(in: bounds, afterScreenUpdates: true) }
        }
        XCTAssertTrue(rendered, "The native screen must render successfully before attaching it")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLoginSavesTokenRestoresNextLaunchAndLogoutClears() async throws {
        credentials.value = nil
        let vm = model()
        XCTAssertFalse(vm.isLoggedIn)
        vm.login(email: "person@example.com", password: "secret")
        await wait(vm)
        XCTAssertTrue(vm.isLoggedIn)
        XCTAssertEqual(credentials.value?.token, "test-token")
        let relaunched = model()
        XCTAssertTrue(relaunched.isLoggedIn)
        relaunched.logout()
        XCTAssertNil(credentials.value)
        XCTAssertFalse(relaunched.isLoggedIn)
    }

    func testUploadsEveryFrameThenConstructsOnceAndPersistsNoCredentials() async throws {
        let vm = model()
        start(vm)
        start(vm)
        await wait(vm)
        XCTAssertEqual(api.events, ["status", "capture", "capture", "status", "construct"])
        XCTAssertEqual(vm.jobs.count, 1)
        XCTAssertEqual(vm.jobs[0].uploadedCount, 2)
        XCTAssertEqual(vm.jobs[0].mapID, 123)
        XCTAssertEqual(vm.jobs[0].phase, .pending)
        let json = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(json.contains("test-token"))
        XCTAssertFalse(json.contains("password"))
        XCTAssertEqual(model().jobs.first?.mapID, 123)
        api.remoteStatus = "done"
        await vm.refreshJobs()
        XCTAssertEqual(vm.jobs[0].phase, .done)
    }

    func testOccupiedWorkspaceRequiresExplicitClearConfirmation() async throws {
        api.imageCount = 4
        let vm = model()
        start(vm)
        await wait(vm)
        XCTAssertEqual(vm.jobs[0].phase, .workspaceConflict)
        XCTAssertEqual(api.events, ["status"])
        vm.restartAfterClearingWorkspace(jobID: vm.jobs[0].id)
        await wait(vm)
        XCTAssertEqual(api.events.filter { $0 == "clear" }.count, 1)
        XCTAssertEqual(vm.jobs[0].mapID, 123)
    }

    func testOccupiedWorkspaceAutomaticallyPresentsActualCountsAndPersistsThem() async throws {
        api.imageCount = 4
        let vm = model()
        start(vm)
        await wait(vm)
        let prompt = try XCTUnwrap(vm.workspaceConfirmation)
        XCTAssertEqual(prompt.jobID, vm.jobs[0].id)
        XCTAssertEqual(prompt.userID, 7)
        XCTAssertEqual(prompt.imageCount, 4)
        XCTAssertEqual(prompt.frameCount, 2)
        XCTAssertTrue(prompt.message.contains("4 张"))
        XCTAssertTrue(prompt.message.contains("2 帧"))
        XCTAssertTrue(vm.jobs[0].message?.contains("4 张") == true)
        XCTAssertEqual(api.events, ["status"])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [[String: Any]]
        XCTAssertEqual(json[0]["workspaceImageCount"] as? Int, 4)
        XCTAssertTrue(model().jobs[0].message?.contains("4 张") == true)
    }

    func testCancelConfirmationPreservesJobAndRequiresFreshConfirmationToRestart() async throws {
        api.imageCount = 4
        let vm = model()
        start(vm)
        await wait(vm)
        let job = vm.jobs[0]
        vm.cancelWorkspaceConfirmation()
        vm.restartAfterClearingWorkspace(jobID: job.id)
        await wait(vm)
        XCTAssertNil(vm.workspaceConfirmation)
        XCTAssertEqual(vm.jobs[0], job)
        XCTAssertEqual(api.events, ["status"])
        XCTAssertTrue(vm.blocksDeletion(of: root.appendingPathComponent("scan_fixture").path))
        api.imageCount = 5
        vm.requestWorkspaceRestart(jobID: job.id)
        await wait(vm)
        XCTAssertEqual(vm.workspaceConfirmation?.imageCount, 5)
        XCTAssertEqual(api.events, ["status", "status"])
        vm.restartAfterClearingWorkspace(jobID: job.id)
        await wait(vm)
        XCTAssertEqual(api.events, ["status", "status", "status", "clear", "status", "capture", "capture", "status", "construct"])
        XCTAssertEqual(vm.jobs[0].mapID, 123)
        XCTAssertNil(vm.workspaceConfirmation)
    }

    func testWorkspaceCountChangingAfterConfirmationRequiresAnotherConfirmation() async throws {
        api.imageCount = 4
        let vm = model()
        start(vm)
        await wait(vm)
        api.imageCount = 6
        vm.restartAfterClearingWorkspace(jobID: vm.jobs[0].id)
        await wait(vm)
        XCTAssertEqual(api.events, ["status", "status"])
        XCTAssertEqual(vm.workspaceConfirmation?.imageCount, 6)
        XCTAssertNil(vm.jobs[0].mapID)
        vm.restartAfterClearingWorkspace(jobID: vm.jobs[0].id)
        await wait(vm)
        XCTAssertEqual(api.events.filter { $0 == "clear" }.count, 1)
        XCTAssertEqual(vm.jobs[0].mapID, 123)
    }

    func testRepeatedConfirmationStartsOnlyOneClearAndConstruction() async throws {
        api.imageCount = 4
        let vm = model()
        start(vm)
        start(vm)
        await wait(vm)
        let id = try XCTUnwrap(vm.workspaceConfirmation?.jobID)
        vm.restartAfterClearingWorkspace(jobID: id)
        vm.restartAfterClearingWorkspace(jobID: id)
        vm.requestWorkspaceRestart(jobID: id)
        await wait(vm)
        XCTAssertEqual(vm.jobs.count, 1)
        XCTAssertEqual(api.events, ["status", "status", "clear", "status", "capture", "capture", "status", "construct"])
    }

    func testOldWorkspaceConflictJournalRefreshesActualCountWithoutClearing() async throws {
        var job = ImmersalMappingJob(id: UUID(), userID: 7, scanName: "scan_fixture", mapName: "UniqueMap", createdAt: Date())
        job.frameCount = 2; job.phase = .workspaceConflict
        let encoded = try JSONEncoder().encode([job])
        var json = try JSONSerialization.jsonObject(with: encoded) as! [[String: Any]]
        json[0].removeValue(forKey: "workspaceImageCount")
        try JSONSerialization.data(withJSONObject: json).write(to: store.url)
        api.imageCount = 9
        let vm = model()
        XCTAssertNil(vm.errorMessage)
        XCTAssertNil(vm.workspaceConfirmation)
        vm.requestWorkspaceRestart(jobID: job.id)
        await wait(vm)
        XCTAssertEqual(vm.workspaceConfirmation?.imageCount, 9)
        XCTAssertEqual(vm.workspaceConfirmation?.frameCount, 2)
        XCTAssertEqual(api.events, ["status"])
    }

    func testBackgroundAndLogoutInvalidateOutstandingConfirmation() async throws {
        api.imageCount = 4
        let vm = model()
        start(vm)
        await wait(vm)
        let id = vm.jobs[0].id
        XCTAssertNotNil(vm.workspaceConfirmation)
        vm.setAppActive(false)
        XCTAssertNil(vm.workspaceConfirmation)
        vm.setAppActive(true)
        vm.restartAfterClearingWorkspace(jobID: id)
        await wait(vm)
        XCTAssertEqual(api.events, ["status"])
        vm.requestWorkspaceRestart(jobID: id)
        await wait(vm)
        XCTAssertNotNil(vm.workspaceConfirmation)
        vm.logout()
        vm.restartAfterClearingWorkspace(jobID: id)
        XCTAssertNil(vm.workspaceConfirmation)
        XCTAssertEqual(api.events, ["status", "status"])
    }

    func testAbandonInvalidatesOutstandingConfirmation() async {
        api.imageCount = 4
        let vm = model()
        start(vm)
        await wait(vm)
        let id = vm.jobs[0].id
        vm.abandon(jobID: id)
        XCTAssertNil(vm.workspaceConfirmation)
        vm.restartAfterClearingWorkspace(jobID: id)
        await wait(vm)
        XCTAssertEqual(api.events, ["status"])
        XCTAssertEqual(vm.jobs[0].phase, .abandoned)
    }

    func testLateWorkspaceStatusAfterLogoutCannotPresentOrClear() async throws {
        api.imageCount = 4
        let vm = model()
        start(vm)
        await wait(vm)
        vm.cancelWorkspaceConfirmation()
        api.statusSuspended = true
        vm.requestWorkspaceRestart(jobID: vm.jobs[0].id)
        for _ in 0..<300 {
            if api.releaseStatus != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(api.releaseStatus)
        vm.logout()
        api.releaseStatus?()
        await Task.yield()
        XCTAssertNil(vm.workspaceConfirmation)
        XCTAssertFalse(api.events.contains("clear"))
        XCTAssertFalse(api.events.contains("capture"))
    }

    func testUncertainCaptureNeedsFreshPromptAndPreservesIntentOnCancel() async throws {
        api.captureFailure = URLError(.timedOut)
        let vm = model()
        start(vm)
        await wait(vm)
        let job = vm.jobs[0]
        XCTAssertNil(vm.workspaceConfirmation)
        vm.restartAfterClearingWorkspace(jobID: job.id)
        await wait(vm)
        XCTAssertFalse(api.events.contains("clear"))
        vm.requestWorkspaceRestart(jobID: job.id)
        await wait(vm)
        XCTAssertEqual(vm.workspaceConfirmation?.imageCount, 1)
        XCTAssertEqual(vm.jobs[0].phase, .captureUncertain)
        XCTAssertEqual(vm.jobs[0].pendingOperation, .capture)
        vm.cancelWorkspaceConfirmation()
        XCTAssertEqual(vm.jobs[0].pendingOperation, .capture)
        XCTAssertFalse(vm.jobs[0].canResume)
    }

    func testCapacityErrorDoesNotClearOrUpload() async {
        api.imageMax = 1
        let vm = model()
        start(vm)
        await wait(vm)
        XCTAssertEqual(api.events, ["status"])
        XCTAssertNil(vm.jobs[0].mapID)
        XCTAssertNotNil(vm.errorMessage)
    }

    func testCaptureLostResponseIsNotBlindlyRetriedAfterRestart() async throws {
        api.captureFailure = URLError(.timedOut)
        let vm = model()
        start(vm)
        await wait(vm)
        XCTAssertEqual(vm.jobs[0].phase, .captureUncertain)
        XCTAssertEqual(api.events.filter { $0 == "capture" }.count, 1)
        let restored = model()
        restored.resume(jobID: vm.jobs[0].id)
        await wait(restored)
        XCTAssertEqual(api.events.filter { $0 == "capture" }.count, 1)
        XCTAssertFalse(api.events.contains("construct"))
    }

    func testConstructLostResponseReconcilesByUniqueNameWithoutResubmitting() async throws {
        api.constructFailure = URLError(.timedOut)
        let vm = model()
        start(vm)
        await wait(vm)
        XCTAssertEqual(vm.jobs[0].phase, .constructionUncertain)
        let restored = model()
        await restored.refreshJobs()
        XCTAssertEqual(restored.jobs[0].mapID, 123)
        XCTAssertEqual(api.events.filter { $0 == "construct" }.count, 1)
    }

    func testInvalidTokenClearsCredentialAndAccountMismatchNeverUploads() async {
        api.statusFailure = ImmersalAPIError.authentication
        let vm = model()
        start(vm)
        await wait(vm)
        XCTAssertFalse(vm.isLoggedIn)
        XCTAssertNil(credentials.value)
        XCTAssertFalse(api.events.contains("capture"))
        credentials.value = ImmersalCredential(email: "other@example.com", userID: 8, token: "other")
        api.statusFailure = nil
        let other = model()
        XCTAssertTrue(other.jobs.isEmpty)
        other.resume(jobID: vm.jobs.first?.id ?? UUID())
        await wait(other)
        XCTAssertFalse(api.events.contains("capture"))
    }

    func testPauseDuringCaptureAndLogoutSuppressLateCallbacks() async {
        api.captureSuspended = true
        let vm = model()
        start(vm)
        for _ in 0..<300 {
            if api.events.contains("capture") { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(vm.blocksDeletion(of: root.appendingPathComponent("scan_fixture").path))
        vm.logout()
        api.releaseCapture?()
        await wait(vm)
        XCTAssertFalse(vm.isLoggedIn)
        XCTAssertFalse(api.events.contains("construct"))
        credentials.value = ImmersalCredential(email: "person@example.com", userID: 7, token: "test-token")
        XCTAssertEqual(model().jobs.first?.phase, .captureUncertain)
    }

    func testDeletingScanIsBlockedWhileTaskNeedsSource() async {
        api.imageCount = 1
        let vm = model()
        start(vm)
        await wait(vm)
        XCTAssertTrue(vm.blocksDeletion(of: root.appendingPathComponent("scan_fixture").path))
        vm.abandon(jobID: vm.jobs[0].id)
        XCTAssertFalse(vm.blocksDeletion(of: root.appendingPathComponent("scan_fixture").path))
    }

    func testAccountIdentityMismatchStopsBeforeAnyRemoteMutation() async {
        api.userID = 8
        let vm = model()
        start(vm)
        await wait(vm)
        XCTAssertEqual(api.events, ["status"])
        XCTAssertFalse(vm.isLoggedIn)
    }

    func testBackgroundPausesBeforeUploadAndExplicitResumeCompletes() async {
        api.statusSuspended = true
        let vm = model()
        start(vm)
        for _ in 0..<300 {
            if api.releaseStatus != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(api.releaseStatus)
        vm.setAppActive(false)
        api.releaseStatus?()
        await Task.yield()
        XCTAssertEqual(vm.jobs[0].phase, .paused)
        XCTAssertFalse(api.events.contains("capture"))
        api.statusSuspended = false
        vm.setAppActive(true)
        vm.resume(jobID: vm.jobs[0].id)
        await wait(vm)
        XCTAssertEqual(vm.jobs[0].mapID, 123)
    }

    func testClearLostResponseRequiresAnotherExplicitConfirmation() async {
        api.imageCount = 4
        let vm = model()
        start(vm)
        await wait(vm)
        api.clearFailure = URLError(.timedOut)
        vm.restartAfterClearingWorkspace(jobID: vm.jobs[0].id)
        await wait(vm)
        XCTAssertEqual(vm.jobs[0].phase, .captureUncertain)
        vm.resume(jobID: vm.jobs[0].id)
        XCTAssertEqual(api.events.filter { $0 == "clear" }.count, 1)
        XCTAssertFalse(api.events.contains("capture"))
    }

    func testJournalWriteFailureStopsBeforeAnyNetworkRequest() async throws {
        let file = root.appendingPathComponent("notADirectory")
        try Data([1]).write(to: file)
        let badStore = ImmersalJobStore(url: file.appendingPathComponent("jobs.json"))
        let vm = ImmersalMappingModel(api: api, credentials: credentials, store: badStore,
                                     frames: MappingFakeFrames(), documentsDirectory: root)
        start(vm)
        await wait(vm)
        XCTAssertTrue(api.events.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
    }

    func testCorruptJournalBlocksUploadInsteadOfForgettingCloudProgress() async throws {
        try Data("broken".utf8).write(to: store.url)
        let vm = model()
        start(vm)
        await wait(vm)
        XCTAssertTrue(api.events.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.blocksDeletion(of: root.appendingPathComponent("scan_fixture").path))
    }

    func testInterruptedCaptureIntentRecoversAsUncertainWithoutResending() async throws {
        var job = ImmersalMappingJob(id: UUID(), userID: 7, scanName: "scan_fixture", mapName: "UniqueMap", createdAt: Date())
        job.frameCount = 2; job.phase = .uploading; job.pendingOperation = .capture
        try store.save([job])
        let vm = model()
        XCTAssertEqual(vm.jobs.first?.phase, .captureUncertain)
        vm.resume(jobID: job.id)
        await wait(vm)
        XCTAssertTrue(api.events.isEmpty)
    }

    func testInvalidJournalCountersAreRejected() throws {
        var job = ImmersalMappingJob(id: UUID(), userID: 7, scanName: "scan_fixture", mapName: "UniqueMap", createdAt: Date())
        job.frameCount = 1; job.uploadedCount = 2
        try store.save([job])
        XCTAssertThrowsError(try store.load())
    }

    func testNegativeWorkspaceCountInJournalIsRejected() throws {
        var job = ImmersalMappingJob(id: UUID(), userID: 7, scanName: "scan_fixture", mapName: "UniqueMap", createdAt: Date())
        job.workspaceImageCount = -1
        try store.save([job])
        XCTAssertThrowsError(try store.load())
    }

    func testOldPromptCannotConfirmOrDismissReplacementPrompt() async throws {
        api.imageCount = 4
        let vm = model()
        start(vm)
        await wait(vm)
        let old = try XCTUnwrap(vm.workspaceConfirmation)
        api.imageCount = 6
        vm.restartAfterClearingWorkspace(jobID: old.jobID, confirmation: old)
        await wait(vm)
        let replacement = try XCTUnwrap(vm.workspaceConfirmation)
        XCTAssertNotEqual(old.id, replacement.id)
        vm.cancelWorkspaceConfirmation(old)
        vm.restartAfterClearingWorkspace(jobID: old.jobID, confirmation: old)
        await wait(vm)
        XCTAssertEqual(vm.workspaceConfirmation, replacement)
        XCTAssertEqual(api.events, ["status", "status"])
        vm.restartAfterClearingWorkspace(jobID: replacement.jobID, confirmation: replacement)
        await wait(vm)
        XCTAssertEqual(vm.jobs[0].mapID, 123)
        XCTAssertEqual(api.events.filter { $0 == "clear" }.count, 1)
    }

    func testConstructDatabaseFailureDoesNotPermitBlindResubmission() async {
        api.constructFailure = ImmersalAPIError.rejected("limit")
        let vm = model()
        start(vm)
        await wait(vm)
        XCTAssertEqual(vm.jobs[0].phase, .constructionUncertain)
        vm.resume(jobID: vm.jobs[0].id)
        await wait(vm)
        XCTAssertEqual(api.events.filter { $0 == "construct" }.count, 1)
    }

    func testUnconfirmedConstructionCanBeExplicitlyAbandonedWithoutResubmitting() async {
        api.constructFailure = URLError(.timedOut)
        let vm = model()
        start(vm)
        await wait(vm)
        api.remoteName = nil // Request did not reach the server; no map can be reconciled.
        let restored = model()
        await restored.refreshJobs()
        let job = restored.jobs[0]
        XCTAssertEqual(job.phase, .constructionUncertain)
        restored.abandon(jobID: job.id)
        XCTAssertEqual(restored.jobs[0].phase, .abandoned)
        XCTAssertFalse(restored.blocksDeletion(of: root.appendingPathComponent("scan_fixture").path))
        XCTAssertNotNil(restored.jobs[0].message)
        XCTAssertEqual(api.events.filter { $0 == "construct" }.count, 1)
        XCTAssertFalse(api.events.contains("clear"))
        XCTAssertEqual(model().jobs[0].phase, .abandoned)
    }

    func testPollingAuthFailureCancelsConcurrentUploadBeforeItsResponseCanAdvance() async {
        let vm = model()
        start(vm)
        await wait(vm)
        api.jobsSuspended = true
        api.jobsFailure = ImmersalAPIError.authentication
        let polling = Task { await vm.refreshJobs() }
        for _ in 0..<300 {
            if api.releaseJobs != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(api.releaseJobs)
        api.statusSuspended = true
        start(vm)
        for _ in 0..<300 {
            if api.releaseStatus != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(api.releaseStatus)
        api.releaseJobs?()
        await polling.value
        XCTAssertFalse(vm.isBusy, "Authentication expiry must cancel the in-flight upload")
        XCTAssertFalse(vm.isLoggedIn)
        // Cleanup also keeps the RED test from crashing on a stale status response.
        vm.pause()
        api.releaseStatus?()
        await Task.yield()
        XCTAssertEqual(api.events.filter { $0 == "capture" }.count, 2)
        XCTAssertEqual(api.events.filter { $0 == "construct" }.count, 1)
    }

    func testPreflightFailureBeforeClearPreservesEarlierUncertainCapture() async throws {
        api.captureFailure = URLError(.timedOut)
        let vm = model()
        start(vm)
        await wait(vm)
        let id = vm.jobs[0].id
        vm.requestWorkspaceRestart(jobID: id)
        await wait(vm)
        XCTAssertNotNil(vm.workspaceConfirmation)
        api.statusFailure = ImmersalAPIError.authentication
        vm.restartAfterClearingWorkspace(jobID: id)
        await wait(vm)
        let stored = try XCTUnwrap(store.load().first)
        XCTAssertEqual(stored.phase, .captureUncertain)
        XCTAssertEqual(stored.pendingOperation, .capture)
        XCTAssertFalse(stored.canResume)
        XCTAssertFalse(api.events.contains("clear"))
    }

    func testCapacityFailureBeforeClearPreservesEarlierUncertainCapture() async {
        api.captureFailure = URLError(.timedOut)
        let vm = model()
        start(vm)
        await wait(vm)
        vm.requestWorkspaceRestart(jobID: vm.jobs[0].id)
        await wait(vm)
        XCTAssertNotNil(vm.workspaceConfirmation)
        api.imageMax = 1
        vm.restartAfterClearingWorkspace(jobID: vm.jobs[0].id)
        await wait(vm)
        XCTAssertEqual(vm.jobs[0].phase, .captureUncertain)
        XCTAssertEqual(vm.jobs[0].pendingOperation, .capture)
        XCTAssertFalse(vm.jobs[0].canResume)
        XCTAssertFalse(api.events.contains("clear"))
    }
}

private final class MappingMemoryCredentials: ImmersalCredentialStoring {
    var value: ImmersalCredential? = ImmersalCredential(email: "person@example.com", userID: 7, token: "test-token")
    func load() throws -> ImmersalCredential? { value }
    func save(_ credential: ImmersalCredential) throws { value = credential }
    func clear() throws { value = nil }
}

private struct MappingFakeFrames: ImmersalFramePreparing {
    var frameCount = 2
    func prepareUpload(scanDirectory: URL, isCancelled: () -> Bool) throws -> ImmersalUploadScan {
        ImmersalUploadScan(frameCount: frameCount, fingerprint: "fixture") { index, cancelled in
            if cancelled() { throw CancellationError() }
            return ImmersalUploadFrame(png: Data([1, 2]), metadata: Data("{\"index\":\(index)}".utf8))
        }
    }
}

private final class MappingFakeAPI: ImmersalAPI {
    var events: [String] = []
    var imageCount = 0
    var imageMax = 100
    var userID = 7
    var clearFailure: Error?
    var statusSuspended = false
    var releaseStatus: (() -> Void)?
    var jobsSuspended = false
    var jobsFailure: Error?
    var releaseJobs: (() -> Void)?
    var captureFailure: Error?
    var constructFailure: Error?
    var statusFailure: Error?
    var remoteStatus = "pending"
    var remoteName: String?
    var captureSuspended = false
    var releaseCapture: (() -> Void)?
    func login(email: String, password: String) async throws -> ImmersalCredential {
        ImmersalCredential(email: email, userID: 7, token: "test-token")
    }
    func status(token: String) async throws -> ImmersalAccountStatus {
        events.append("status")
        if statusSuspended { await withCheckedContinuation { continuation in releaseStatus = { continuation.resume() } } }
        if let statusFailure { throw statusFailure }
        return ImmersalAccountStatus(userID: userID, imageCount: imageCount, imageMax: imageMax)
    }
    func capture(frame: ImmersalUploadFrame, token: String) async throws {
        events.append("capture")
        if captureSuspended { await withCheckedContinuation { continuation in releaseCapture = { continuation.resume() } } }
        imageCount += 1
        if let captureFailure { throw captureFailure }
    }
    func clear(token: String) async throws {
        events.append("clear"); imageCount = 0
        if let clearFailure { throw clearFailure }
    }
    func construct(name: String, token: String) async throws -> ImmersalConstruction {
        events.append("construct")
        remoteName = name
        if let constructFailure { throw constructFailure }
        return ImmersalConstruction(id: 123, size: imageCount)
    }
    func jobs(token: String) async throws -> [ImmersalRemoteJob] {
        events.append("list")
        if jobsSuspended { await withCheckedContinuation { continuation in releaseJobs = { continuation.resume() } } }
        if let jobsFailure { throw jobsFailure }
        return remoteName.map { [ImmersalRemoteJob(id: 123, size: 2, name: $0, status: remoteStatus)] } ?? []
    }
}
