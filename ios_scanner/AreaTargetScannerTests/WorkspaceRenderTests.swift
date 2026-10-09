import XCTest
import SwiftUI
import UIKit
@testable import AreaTargetScanner

/// Native, offline workspace fixtures. The attachments are for visual review; the
/// assertions cover real rendering, persisted identity, and cloud activity isolation.
@MainActor
final class WorkspaceRenderTests: XCTestCase {
    private var root: URL!
    private var directory: URL!
    private var api: WorkspaceRenderAPI!
    private var credentials: WorkspaceRenderCredentials!
    private var store: ImmersalJobStore!
    private var scanModel: ScanViewModel!
    private var areaTargetModel: AreaTargetProcessingModel!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceRender-\(UUID().uuidString)")
        directory = root.appendingPathComponent("scan_20260930_091600")
        let images = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let jpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { context in
            UIColor.lightGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.jpegData(compressionQuality: 0.8))
        for index in 0..<57 {
            try jpeg.write(to: images.appendingPathComponent(String(format: "%06d.jpg", index)))
        }
        try jpeg.write(to: directory.appendingPathComponent("texture.jpg"))
        try """
        mtllib model.mtl
        v 0 0 0
        v 1 0 0
        v 0 1 0
        vt 0 0
        vt 1 0
        vt 0 1
        usemtl fixture
        f 1/1 2/2 3/3
        """.write(to: directory.appendingPathComponent("model.obj"), atomically: true, encoding: .utf8)
        try "newmtl fixture\nKd 1 1 1\nmap_Kd texture.jpg\n"
            .write(to: directory.appendingPathComponent("model.mtl"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["frames": (0..<57).map { ["index": $0] }])
            .write(to: directory.appendingPathComponent("manifest.json"))
        areaTargetModel = AreaTargetProcessingModel(api: AreaFlowAPI(root: root),
            archiver: AreaFlowArchive(url: root.appendingPathComponent("upload.zip")),
            jobStore: AreaFlowJournal(), tokenStore: AreaFlowTokens(), assetStore: AreaFlowAssets(root: root),
            uploadDirectory: root.appendingPathComponent("uploads"))
        api = WorkspaceRenderAPI()
        credentials = WorkspaceRenderCredentials()
        store = ImmersalJobStore(url: root.appendingPathComponent("jobs.json"))
        scanModel = ScanViewModel(exporter: WorkspaceRenderExporter(), documentsDirectory: root,
                                  cameraAuthorizationStatus: { .authorized },
                                  requestCameraAccess: { _ in XCTFail("Rendering must not request camera access") })
        scanModel.loadScanHistory()
        XCTAssertTrue(scanModel.renameScan(at: directory.path, to: "一楼大厅"))
        XCTAssertEqual(scanModel.scanHistory.first?.keyframeCount, 57)
        XCTAssertNotNil(scanModel.modelURL(for: directory.path))
    }

    override func tearDownWithError() throws {
        areaTargetModel?.setAppActive(false)
        areaTargetModel = nil
        scanModel = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testWorkspacePagesRenderWithSharedSceneInLightDarkAndLargeText() async throws {
        let mapping = mappingModel()
        let fixtures: [(String, ScannerPlatform, WorkspaceTab, String?, UIUserInterfaceStyle, ContentSizeCategory)] = [
            ("area-process-light", .areaTarget, .process, directory.path, .light, .large),
            ("immersal-process-light", .immersal, .process, directory.path, .light, .large),
            ("scan-home-light", .areaTarget, .scan, nil, .light, .large),
            ("records-light", .areaTarget, .records, nil, .light, .large),
            ("process-empty", .areaTarget, .process, nil, .light, .large),
            ("area-process-dark", .areaTarget, .process, directory.path, .dark, .large),
            ("process-large-text", .areaTarget, .process, directory.path, .light, .accessibilityExtraLarge),
            ("immersal-process-large-text", .immersal, .process, directory.path, .light, .accessibilityExtraLarge),
            ("immersal-process-dark", .immersal, .process, directory.path, .dark, .large),
            ("records-large-text", .areaTarget, .records, nil, .light, .accessibilityExtraLarge),
            ("scan-home-large-text", .areaTarget, .scan, nil, .light, .accessibilityExtraLarge)
        ]
        for (name, platform, tab, selectedPath, style, sizeCategory) in fixtures {
            let workspace = ScannerWorkspace(preferences: nil, platform: platform, tab: tab, selectedScanPath: selectedPath)
            try await withScreen(ContentView(viewModel: scanModel, mappingModel: mapping, workspace: workspace,
                areaTargetModel: areaTargetModel, settings: ScannerSettings(preferences: nil)),
                                 style: style, sizeCategory: sizeCategory) { screen in
                self.attach(screen, name: name)
                XCTAssertEqual(workspace.tab, tab)
                XCTAssertEqual(workspace.selectedScanPath, selectedPath)
                XCTAssertEqual(self.scanModel.scanHistory.first?.displayName, "一楼大厅")
            }
        }
        XCTAssertTrue(api.events.isEmpty, "Opening workspace pages must not upload, log in, or query when there is no pending job")
    }

    func testRenderedPlatformSwitchPreservesSceneAndStartsPollingOnlyForImmersal() async throws {
        try store.save([pendingJob()])
        let mapping = mappingModel()
        let workspace = ScannerWorkspace(preferences: nil, platform: .areaTarget, tab: .process,
                                         selectedScanPath: directory.path)
        try await withScreen(ContentView(viewModel: scanModel, mappingModel: mapping, workspace: workspace,
                areaTargetModel: areaTargetModel, settings: ScannerSettings(preferences: nil))) { screen in
            XCTAssertTrue(self.api.events.isEmpty, "Area Target must not poll a stored pending Immersal job")

            XCTAssertTrue(workspace.selectPlatform(.immersal, operationInProgress: false))
            for _ in 0..<100 {
                if self.api.events.contains("jobs") { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try await self.settle(screen)
            XCTAssertEqual(self.api.events, ["jobs"], "Entering Immersal should query the pending job once without uploading")
            XCTAssertEqual(workspace.selectedScanPath, self.directory.path)
            XCTAssertEqual(workspace.tab, .process)
            XCTAssertEqual(self.scanModel.sceneName(for: self.directory.path), "一楼大厅")
            XCTAssertEqual(self.scanModel.scanHistory.first?.displayName, "一楼大厅")
            XCTAssertNil(self.scanModel.immersalUnavailableReason)
            self.attach(screen, name: "workspace-switched-to-immersal")

            XCTAssertTrue(workspace.selectPlatform(.areaTarget, operationInProgress: false))
            try await self.settle(screen)
            await mapping.refreshJobs()
            XCTAssertEqual(self.api.events, ["jobs"], "Returning to Area Target must deactivate cloud refresh")
            XCTAssertEqual(workspace.selectedScanPath, self.directory.path)
            XCTAssertEqual(workspace.tab, .process)
            XCTAssertEqual(self.scanModel.scanHistory.first?.displayName, "一楼大厅")
            self.attach(screen, name: "workspace-switched-back-to-area-target")
        }
        mapping.setAppActive(false)
        let restored = ScanViewModel(exporter: WorkspaceRenderExporter(), documentsDirectory: root)
        restored.loadScanHistory()
        XCTAssertEqual(restored.scanHistory.first?.displayName, "一楼大厅", "The shared name must survive a fresh model")
    }

    func testRenderedRecordsTabDoesNotJumpToProcessingForExistingPreviewState() async throws {
        try store.save([pendingJob()])
        scanModel.state = .preview(directory.path)
        let mapping = mappingModel()
        let workspace = ScannerWorkspace(preferences: nil, platform: .areaTarget, tab: .records,
                                         selectedScanPath: directory.path)
        try await withScreen(ContentView(viewModel: scanModel, mappingModel: mapping, workspace: workspace,
                areaTargetModel: areaTargetModel, settings: ScannerSettings(preferences: nil))) { screen in
            XCTAssertEqual(workspace.tab, .records, "Mounting an existing preview must respect the explicitly selected records tab")
            XCTAssertEqual(workspace.selectedScanPath, self.directory.path)
            XCTAssertEqual(self.scanModel.scanHistory.first?.displayName, "一楼大厅")
            XCTAssertTrue(self.api.events.isEmpty, "Area Target records must not poll an Immersal job")
            self.attach(screen, name: "records-with-saved-preview-state")
        }
    }

    func testImmersalAccountTasksAndSceneNameEditorRenderOffline() async throws {
        try store.save([pendingJob()])
        let mapping = mappingModel()
        for (entry, name) in [(ImmersalMappingView.EntryPoint.account, "immersal-account-light"), (.tasks, "immersal-tasks-light")] {
            try await withScreen(ImmersalMappingView(model: mapping, scanDirectory: nil, entryPoint: entry,
                                                    sceneName: { _ in "一楼大厅" })) { screen in
                self.attach(screen, name: name)
            }
        }
        try await withScreen(SceneNameEditor(name: "一楼大厅") { _ in
            XCTFail("A screenshot must not save a name")
            return nil
        }) { screen in
            self.attach(screen, name: "scene-rename-editor-light")
        }
        XCTAssertTrue(api.events.isEmpty, "Account and task rendering must remain offline")
    }

    func testDifferentSceneShowsBusyJobThenInterruptedAndDeletedTasksOffline() async throws {
        let selectedDirectory = root.appendingPathComponent("scan_20260930_101600")
        try FileManager.default.copyItem(at: directory, to: selectedDirectory)
        XCTAssertTrue(scanModel.renameScan(at: directory.path, to: "旧大厅"))
        XCTAssertTrue(scanModel.renameScan(at: selectedDirectory.path, to: "测试大厅"))
        scanModel.loadScanHistory()
        let names = [directory.lastPathComponent: "旧大厅", selectedDirectory.lastPathComponent: "测试大厅"]
        let resolveName: (String) -> String? = { names[$0] }

        var oldJob = pendingJob()
        oldJob.mapID = nil
        oldJob.phase = .workspaceConflict
        oldJob.uploadedCount = 0
        oldJob.workspaceImageCount = 4
        oldJob.message = "云端工作区已有 4 张图片，请检查后继续。"
        try store.save([oldJob])
        let mapping = mappingModel()
        api.holdStatus = true
        defer {
            mapping.pause()
            self.api.releaseStatus()
        }

        mapping.requestWorkspaceRestart(jobID: oldJob.id)
        for _ in 0..<100 {
            if api.statusIsWaiting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(api.statusIsWaiting, "The fake workspace check must remain pending during the busy-state renders")
        XCTAssertTrue(mapping.isBusy)
        XCTAssertEqual(mapping.busyJobID, oldJob.id)
        XCTAssertEqual(mapping.operationStage, .checkingWorkspace)
        XCTAssertNil(mapping.activeJobID, "Checking another job must not be treated as an active upload")
        XCTAssertEqual(mapping.jobs.first, oldJob)
        XCTAssertNil(ImmersalMappingPresentation.currentJob(jobs: mapping.jobs,
                                                           scanName: selectedDirectory.lastPathComponent,
                                                           selectedJobID: nil),
                     "The selected new scan must not inherit the old scan's job")
        XCTAssertEqual(resolveName(try XCTUnwrap(mapping.jobs.first { $0.id == mapping.busyJobID }).scanName), "旧大厅")
        XCTAssertEqual(scanModel.sceneName(for: selectedDirectory.path), "测试大厅")

        for (name, style, sizeCategory) in [
            ("busy-other-scene-light", UIUserInterfaceStyle.light, ContentSizeCategory.large),
            ("busy-other-scene-large-text", .light, .accessibilityExtraLarge),
            ("busy-other-scene-dark", .dark, .large)
        ] {
            try await withScreen(ImmersalMappingView(model: mapping, scanDirectory: selectedDirectory,
                                                    sceneName: resolveName),
                                 style: style, sizeCategory: sizeCategory) { screen in
                self.attach(screen, name: name)
                XCTAssertTrue(mapping.isBusy)
                XCTAssertEqual(mapping.busyJobID, oldJob.id)
                XCTAssertEqual(mapping.operationStage, .checkingWorkspace)
            }
        }
        for (name, sizeCategory) in [("busy-tasks-light", ContentSizeCategory.large),
                                     ("busy-tasks-large-text", .accessibilityExtraLarge)] {
            try await withScreen(ImmersalMappingView(model: mapping, scanDirectory: nil, entryPoint: .tasks,
                                                    sceneName: resolveName),
                                 sizeCategory: sizeCategory) { screen in
                self.attach(screen, name: name)
            }
        }
        for (name, sizeCategory) in [("busy-current-task-light", ContentSizeCategory.large),
                                     ("busy-current-task-large-text", .accessibilityExtraLarge)] {
            try await withScreen(ImmersalMappingView(model: mapping, scanDirectory: directory,
                                                    sceneName: resolveName),
                                 sizeCategory: sizeCategory) { screen in
                self.attach(screen, name: name)
            }
        }
        XCTAssertEqual(api.events, ["status"], "Showing a different scene and the task list must not start another request")

        mapping.pause()
        XCTAssertFalse(mapping.isBusy)
        XCTAssertNil(mapping.busyJobID)
        XCTAssertNil(mapping.operationStage)
        XCTAssertNil(mapping.workspaceConfirmation)
        XCTAssertEqual(mapping.jobs, [oldJob], "Interrupting a read-only workspace check must preserve the conflict and source identity")
        try await withScreen(ImmersalMappingView(model: mapping, scanDirectory: selectedDirectory,
                                                sceneName: resolveName)) { screen in
            self.attach(screen, name: "interrupted-other-scene-light")
        }
        try await withScreen(ImmersalMappingView(model: mapping, scanDirectory: nil, entryPoint: .tasks,
                                                sceneName: resolveName)) { screen in
            self.attach(screen, name: "interrupted-tasks-light")
        }

        XCTAssertTrue(mapping.deleteJob(jobID: oldJob.id))
        XCTAssertTrue(mapping.jobs.isEmpty)
        XCTAssertTrue(try store.load().isEmpty, "Deleting the task must also remove the persisted record")
        XCTAssertFalse(mapping.isBusy)
        XCTAssertNil(mapping.busyJobID)
        XCTAssertNil(mapping.operationStage)
        XCTAssertFalse(mapping.blocksDeletion(of: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "Deleting a task must preserve the old scan files")
        XCTAssertTrue(FileManager.default.fileExists(atPath: selectedDirectory.path), "Deleting the old task must preserve the selected new scan")

        // Release the already-cancelled read only after deletion. A stale response
        // must not recreate a task or show a confirmation for the wrong scene.
        api.releaseStatus()
        try await withScreen(ImmersalMappingView(model: mapping, scanDirectory: nil, entryPoint: .tasks,
                                                sceneName: resolveName)) { screen in
            self.attach(screen, name: "deleted-tasks-empty-light")
            XCTAssertTrue(mapping.jobs.isEmpty)
            XCTAssertNil(mapping.workspaceConfirmation)
            XCTAssertFalse(mapping.isBusy)
        }
        try await withScreen(ImmersalMappingView(model: mapping, scanDirectory: selectedDirectory,
                                                sceneName: resolveName)) { screen in
            self.attach(screen, name: "deleted-other-scene-light")
        }
        XCTAssertEqual(api.events, ["status"], "Interrupt and local task deletion must not clear, upload, or construct in the cloud")
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(scanModel.sceneName(for: directory.path), "旧大厅")
        XCTAssertEqual(scanModel.sceneName(for: selectedDirectory.path), "测试大厅")
    }

    private func mappingModel() -> ImmersalMappingModel {
        ImmersalMappingModel(api: api, credentials: credentials, store: store,
                             frames: WorkspaceRenderFrames(), documentsDirectory: root)
    }

    private func pendingJob() -> ImmersalMappingJob {
        var job = ImmersalMappingJob(id: UUID(uuidString: "91380000-0000-0000-0000-000000000057")!, userID: 7,
                                    scanName: directory.lastPathComponent, mapName: "LobbyMap",
                                    createdAt: Date(timeIntervalSince1970: 1_790_730_960))
        job.frameCount = 57
        job.uploadedCount = 57
        job.mapID = 123
        job.phase = .pending
        return job
    }

    private struct Screen {
        let window: UIWindow
        let host: UIHostingController<AnyView>
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
    }

    private func withScreen<V: View>(_ view: V, style: UIUserInterfaceStyle = .light,
                                     sizeCategory: ContentSizeCategory = .large,
                                     inspect: (Screen) async throws -> Void) async throws {
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: AnyView(view
            .environment(\.scenePhase, .active)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 8 * 3600)!)
            .environment(\.sizeCategory, sizeCategory)))
        host.overrideUserInterfaceStyle = style
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        let screen = Screen(window: window, host: host)
        defer {
            host.view.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        host.view.frame = screen.bounds
        try await settle(screen)
        try await inspect(screen)
    }

    private func settle(_ screen: Screen) async throws {
        screen.host.view.setNeedsLayout()
        screen.host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 350_000_000)
        screen.host.view.layoutIfNeeded()
    }

    private func attach(_ screen: Screen, name: String) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: screen.bounds, format: format).image { _ in
            rendered = screen.host.view.drawHierarchy(in: screen.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered, "The native \(name) screen must render before it is attached")
        XCTAssertEqual(image.size, screen.bounds.size)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}

private final class WorkspaceRenderExporter: ScanExporting {
    func availability(scanDirectory: URL, format: ScanExportFormat) -> String? { nil }
    func export(scanDirectory: URL, format: ScanExportFormat,
                progress: @escaping (String) -> Void, isCancelled: @escaping () -> Bool) throws -> URL {
        XCTFail("Rendering must not start an export")
        throw CancellationError()
    }
}

private final class WorkspaceRenderCredentials: ImmersalCredentialStoring {
    private var value: ImmersalCredential? = ImmersalCredential(email: "scanner@example.com", userID: 7, token: "offline-fixture")
    func load() throws -> ImmersalCredential? { value }
    func save(_ credential: ImmersalCredential) throws { value = credential }
    func clear() throws { value = nil }
}

private struct WorkspaceRenderFrames: ImmersalFramePreparing {
    func prepareUpload(scanDirectory: URL, isCancelled: () -> Bool) throws -> ImmersalUploadScan {
        XCTFail("Rendering must not prepare an upload")
        throw CancellationError()
    }
}

private final class WorkspaceRenderAPI: ImmersalAPI {
    var events: [String] = []
    var holdStatus = false
    private var statusContinuation: CheckedContinuation<ImmersalAccountStatus, Never>?
    var statusIsWaiting: Bool { statusContinuation != nil }

    func releaseStatus() {
        let continuation = statusContinuation
        statusContinuation = nil
        continuation?.resume(returning: ImmersalAccountStatus(userID: 7, imageCount: 4, imageMax: 100))
    }

    func login(email: String, password: String) async throws -> ImmersalCredential {
        events.append("login")
        throw CancellationError()
    }
    func status(token: String) async throws -> ImmersalAccountStatus {
        events.append("status")
        if holdStatus {
            return await withCheckedContinuation { statusContinuation = $0 }
        }
        throw CancellationError()
    }
    func capture(frame: ImmersalUploadFrame, token: String) async throws {
        events.append("capture")
        throw CancellationError()
    }
    func clear(token: String) async throws {
        events.append("clear")
        throw CancellationError()
    }
    func construct(name: String, token: String) async throws -> ImmersalConstruction {
        events.append("construct")
        throw CancellationError()
    }
    func jobs(token: String) async throws -> [ImmersalRemoteJob] {
        events.append("jobs")
        return [ImmersalRemoteJob(id: 123, size: 57, name: "LobbyMap", status: "pending")]
    }
}
