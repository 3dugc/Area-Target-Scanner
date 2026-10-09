import XCTest
import SwiftUI
import UIKit
@testable import AreaTargetScanner

@MainActor
final class AreaTargetProcessingViewTests: XCTestCase {
    func testNewTaskMapCLAHEIsDefaultOffAndNativeToggleDoesNotSubmit() async throws {
        let accessibilityScope = try HostedAccessibilityTestScope()
        defer { accessibilityScope.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MapCLAHEView-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let api = AreaFlowAPI(root: root)
        let model = AreaTargetProcessingModel(api: api, archiver: AreaFlowArchive(url: root.appendingPathComponent("upload.zip")),
            jobStore: AreaFlowJournal(), tokenStore: AreaFlowTokens(), assetStore: AreaFlowAssets(root: root))
        let settings = ScannerSettings(preferences: nil)
        let host = UIHostingController(rootView: AreaTargetProcessingView(model: model, scanDirectory: root,
            displayName: "光照增强开关", settings: settings))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 852))
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.frame = window.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 100_000_000); host.view.layoutIfNeeded()
        func switches(_ view: UIView) -> [UISwitch] {
            (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap(switches)
        }
        let toggle = try XCTUnwrap(switches(host.view).first)
        XCTAssertFalse(toggle.isOn)
        toggle.setOn(true, animated: false); toggle.sendActions(for: .valueChanged)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(toggle.isOn)
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertEqual(settings.processingProfile, .quality)
        XCTAssertTrue(settings.uvUnwrap)
        let events = await api.events
        XCTAssertTrue(events.isEmpty, "Choosing map preprocessing must not submit or change other settings")
    }

    func testProcessingPageUsesSharedSettingsWithoutInlinePickerOrStartingJobs() async throws {
        let accessibilityScope = try HostedAccessibilityTestScope()
        defer { accessibilityScope.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaProfileView-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let api = AreaFlowAPI(root: root)
        let model = AreaTargetProcessingModel(api: api, archiver: AreaFlowArchive(url: root.appendingPathComponent("upload.zip")),
            jobStore: AreaFlowJournal(), tokenStore: AreaFlowTokens(), assetStore: AreaFlowAssets(root: root))
        let settings = ScannerSettings(preferences: nil)
        let view = AreaTargetProcessingView(model: model, scanDirectory: root, displayName: "模式测试", settings: settings)
        XCTAssertTrue(view.settings === settings)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 852))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded()
        func controls(_ view: UIView) -> [UISegmentedControl] {
            (view as? UISegmentedControl).map { [$0] } ?? view.subviews.flatMap(controls)
        }
        XCTAssertTrue(controls(host.view).isEmpty, "Mode controls belong to the separate settings screen")
        XCTAssertEqual(settings.processingProfile, .quality)
        XCTAssertTrue(settings.uvUnwrap)
        settings.processingProfile = .fast
        settings.uvUnwrap = false
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(view.settings.processingProfile, .fast)
        XCTAssertFalse(view.settings.uvUnwrap)
        XCTAssertTrue(model.jobs.isEmpty)
        let events = await api.events
        XCTAssertTrue(events.isEmpty, "Changing mode must not submit a task")
    }

    func testDownloadedAndPendingMapsKeepFrozenSettingsWithNoInlinePicker() async throws {
        let accessibilityScope = try HostedAccessibilityTestScope()
        defer { accessibilityScope.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaProfileHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for phase in [AreaTargetTaskPhase.downloaded, .paused] {
            let api = AreaFlowAPI(root: root)
            let journal = AreaFlowJournal()
            let assets = AreaFlowAssets(root: root)
            var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: root.path,
                displayName: "已有 Fast 地图", createdAt: Date())
            job.profile = "fast"; job.phase = phase; job.mapCLAHE = true
            if phase == .downloaded {
                let asset = AreaTargetSavedAsset(jobID: job.id, bundleURL: root.appendingPathComponent("bundle.zip"),
                    directoryURL: root, modelURL: root.appendingPathComponent("model.glb"),
                    featuresURL: root.appendingPathComponent("features.db"), manifestURL: root.appendingPathComponent("manifest.json"), savedAt: Date())
                job.savedAsset = asset; assets.values[job.id] = asset
            }
            journal.jobs = [job]
            let model = AreaTargetProcessingModel(api: api, archiver: AreaFlowArchive(url: root.appendingPathComponent("upload.zip")),
                jobStore: journal, tokenStore: AreaFlowTokens(), assetStore: assets)
            for _ in 0..<200 {
                if !model.isRestoringAssets { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let settings = ScannerSettings(preferences: nil); settings.uvUnwrap = false
            let host = UIHostingController(rootView: AreaTargetProcessingView(model: model, scanDirectory: root,
                displayName: job.displayName, settings: settings).environment(\.sizeCategory, .accessibilityLarge))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 852))
            window.rootViewController = host; window.makeKeyAndVisible(); host.view.frame = window.bounds
            try await Task.sleep(nanoseconds: 100_000_000)
            host.view.layoutIfNeeded()
            func controls(_ view: UIView) -> [UISegmentedControl] {
                (view as? UISegmentedControl).map { [$0] } ?? view.subviews.flatMap(controls)
            }
            XCTAssertTrue(controls(host.view).isEmpty, "Task pages summarize settings; controls are in Settings")
            func switches(_ view: UIView) -> [UISwitch] {
                (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap(switches)
            }
            if phase == .downloaded {
                XCTAssertFalse(try XCTUnwrap(switches(host.view).first).isOn,
                    "Rebuild defaults to disabled independently of the existing enabled map")
            } else {
                XCTAssertTrue(switches(host.view).isEmpty, "Pending tasks retain the submitted map CLAHE state")
            }

            XCTAssertEqual(settings.processingProfile, .quality)
            XCTAssertFalse(settings.uvUnwrap)
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                rendered = host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(rendered)
            let attachment = XCTAttachment(image: image); attachment.name = "profile-\(phase.rawValue)-large-text-320"; attachment.lifetime = .keepAlways; add(attachment)
            if phase == .downloaded {
                func scrollViews(_ view: UIView) -> [UIScrollView] {
                    (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                }
                let scroll = try XCTUnwrap(scrollViews(host.view).first { $0.contentSize.height > $0.bounds.height })
                XCTAssertGreaterThan(scroll.bounds.height, 450, "The fixed footer must leave room to use scrollable settings")
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
                try await Task.sleep(nanoseconds: 50_000_000); host.view.layoutIfNeeded()
                let scrolled = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    _ = host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let detail = XCTAttachment(image: scrolled); detail.name = "profile-downloaded-settings-scrolled-large-text-320"; detail.lifetime = .keepAlways; add(detail)
            }
            window.isHidden = true; window.rootViewController = nil
            XCTAssertEqual(model.jobs.first?.profile, "fast")
            XCTAssertEqual(model.jobs.first?.uvUnwrap, true)
            XCTAssertEqual(model.jobs.count, 1)
            let events = await api.events; XCTAssertTrue(events.isEmpty)
        }
    }

    func testAreaTargetActivityIsIsolatedFromImmersalPlatform() async throws {
        XCTAssertTrue(ScannerPlatform.areaTarget.supportsAreaTargetProcessing)
        XCTAssertFalse(ScannerPlatform.immersal.supportsAreaTargetProcessing)
        XCTAssertFalse(ScannerPlatform.areaTarget.supportsCloudMapping)
        XCTAssertTrue(ScannerPlatform.immersal.supportsCloudMapping)
    }

    func testPreparationShowsDefaultOffExperimentalMapCLAHEAndRebuildExplanation() async throws {
        let accessibilityScope = try HostedAccessibilityTestScope()
        defer { accessibilityScope.restore() }
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = UIHostingController(rootView: AreaTargetProcessingView(model: fixture.model,
            scanDirectory: fixture.scan, displayName: "原选大厅", settings: ScannerSettings(preferences: nil)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded()
        let nodes = try await HostedAccessibilityTestScope.waitForNodes(in: host.view) {
            $0.contains { HostedAccessibilityTestScope.identifier(of: $0) == "area-target-map-clahe-toggle" }
        }
        func switches(in view: UIView) -> [UISwitch] {
            (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap { switches(in: $0) }
        }
        let controls = switches(in: host.view)
        let controlRows = controls.map {
            "UISwitch isOn=\($0.isOn) id=\($0.accessibilityIdentifier ?? "nil") label=\($0.accessibilityLabel ?? "nil") frame=\($0.convert($0.bounds, to: host.view))"
        }
        let nodeRows = nodes.map {
            "\(type(of: $0)) id=\(HostedAccessibilityTestScope.identifier(of: $0) ?? "nil") label=\($0.accessibilityLabel ?? "nil") value=\($0.accessibilityValue ?? "nil")"
        }
        let diagnostic = "jobs=\(fixture.model.jobs.count) scanExists=\(FileManager.default.fileExists(atPath: fixture.scan.path))\n"
            + (controlRows + nodeRows).joined(separator: "\n")
        let diagnosticAttachment = XCTAttachment(string: diagnostic)
        diagnosticAttachment.name = "clahe-preparation-controls-and-accessibility"
        diagnosticAttachment.lifetime = .keepAlways
        add(diagnosticAttachment)
        let screenshot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            _ = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        })
        screenshot.name = "clahe-preparation-before-identifier-assertion"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(controls.count, 1, "Preparation must render one real map enhancement switch")
        XCTAssertFalse(try XCTUnwrap(controls.first).isOn, "The rendered switch must default to off")
        let toggle = try XCTUnwrap(nodes.first { HostedAccessibilityTestScope.identifier(of: $0) == "area-target-map-clahe-toggle" })
        XCTAssertEqual(toggle.accessibilityLabel, "光照增强（实验）")
        XCTAssertEqual(toggle.accessibilityValue, "0", "New builds must default to off")
        XCTAssertTrue(nodes.contains { $0.accessibilityLabel?.contains("改变选项需要重新建图") == true })
        XCTAssertTrue(fixture.model.jobs.isEmpty)
        let events = await fixture.api.base.events
        XCTAssertTrue(events.isEmpty, "Rendering the option must not start cloud work")
    }

    func testPendingMapCLAHEJobShowsFrozenChoiceWithoutOfferingNewTaskToggle() async throws {
        let accessibilityScope = try HostedAccessibilityTestScope()
        defer { accessibilityScope.restore() }
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: fixture.scan.path,
            displayName: "已冻结增强任务", createdAt: Date(), serverOrigin: .current)
        job.phase = .paused
        job.mapCLAHE = true
        fixture.journal.jobs = [job]
        let model = cloudModel(fixture, journal: fixture.journal)
        let host = UIHostingController(rootView: AreaTargetProcessingView(model: model,
            scanDirectory: fixture.scan, displayName: job.displayName, settings: ScannerSettings(preferences: nil)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded()
        let nodes = try await HostedAccessibilityTestScope.waitForNodes(in: host.view) {
            $0.contains { $0.accessibilityLabel?.contains("光照增强：开启") == true }
        }
        XCTAssertTrue(nodes.contains { $0.accessibilityLabel?.contains("光照增强：开启") == true })
        XCTAssertFalse(nodes.contains { $0.accessibilityLabel == "光照增强（实验）" },
            "Pending tasks must show their frozen option rather than a new-build control")
        func switches(in view: UIView) -> [UISwitch] {
            (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap { switches(in: $0) }
        }
        XCTAssertTrue(switches(in: host.view).isEmpty, "A pending task must not render an editable switch")
        XCTAssertEqual(model.selectedJob?.mapCLAHE, true)
        let events = await fixture.api.base.events
        XCTAssertTrue(events.isEmpty)
    }

    func testLoginFreezesProfileUVAndMapCLAHEBeforeLaterSelectionChanges() async throws {
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var requirements = AreaFlowAPI.legacyRequirements
        requirements.mapCLAHESupported = true
        await fixture.api.base.setRequirements(requirements)
        let actions = AreaTargetCloudActionCoordinator(model: fixture.model)
        let settings = ScannerSettings(preferences: nil)
        settings.processingProfile = .fast
        settings.uvUnwrap = false
        var nextBuildChoice = true
        let intent = AreaTargetCloudIntent.upload(scanDirectory: fixture.scan, displayName: "原增强选择", profile: settings.processingProfile, uvUnwrap: settings.uvUnwrap, mapCLAHE: nextBuildChoice)
        await actions.perform(intent)
        let request = try XCTUnwrap(actions.loginRequest)
        nextBuildChoice = false
        settings.processingProfile = .quality
        settings.uvUnwrap = true
        XCTAssertEqual(request.intent, .upload(scanDirectory: fixture.scan, displayName: "原增强选择", profile: .fast, uvUnwrap: false, mapCLAHE: true))
        XCTAssertNotEqual(request.intent, .upload(scanDirectory: fixture.scan, displayName: "原增强选择", profile: settings.processingProfile, uvUnwrap: settings.uvUnwrap, mapCLAHE: nextBuildChoice))
        await actions.authenticate(requestID: request.id, username: "scanner", password: "temporary password")
        await actions.continueAfterLogin()
        let job = try XCTUnwrap(fixture.model.selectedJob)
        XCTAssertTrue(job.mapCLAHE)
        XCTAssertEqual(job.remote?.mapCLAHE, true)
        XCTAssertEqual(job.profile, "fast")
        XCTAssertFalse(job.uvUnwrap)
        XCTAssertEqual(job.remote?.profile, "fast")
        XCTAssertEqual(job.remote?.uvUnwrap, false)
        let profiles = await fixture.api.base.submittedProfiles
        let uvChoices = await fixture.api.base.submittedUVUnwrap
        XCTAssertEqual(profiles, ["fast"])
        XCTAssertEqual(uvChoices, [false])
        let submitted = await fixture.api.base.submittedMapCLAHE
        XCTAssertEqual(submitted, [true])
    }

    func testReauthenticationResumesCreatedEnabledJobInsteadOfChangingItsChoice() async throws {
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.api.saved = AreaFlowServiceAPI.fixtureSession
        fixture.api.rejectNextSubmit = true
        var requirements = AreaFlowAPI.legacyRequirements
        requirements.mapCLAHESupported = true
        await fixture.api.base.setRequirements(requirements)
        let model = cloudModel(fixture)
        let actions = AreaTargetCloudActionCoordinator(model: model)
        await actions.perform(.upload(scanDirectory: fixture.scan, displayName: "增强重认证", mapCLAHE: true))
        let original = try XCTUnwrap(model.selectedJob)
        let originalZIP = try XCTUnwrap(original.archiveURL)
        let request = try XCTUnwrap(actions.loginRequest)
        XCTAssertTrue(original.mapCLAHE)
        XCTAssertEqual(request.intent, .resume(jobID: original.id, origin: .current, displayName: original.displayName))
        await actions.authenticate(requestID: request.id, username: "scanner", password: "temporary password")
        await actions.continueAfterLogin()
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.selectedJobID, original.id)
        XCTAssertEqual(model.selectedJob?.mapCLAHE, true)
        XCTAssertEqual(model.selectedJob?.remote?.mapCLAHE, true)
        XCTAssertEqual(fixture.api.submitIDs, [original.id, original.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalZIP.path))
        let submitted = await fixture.api.base.submittedMapCLAHE
        XCTAssertEqual(submitted, [true])
        let count = await fixture.api.base.requirementsCallCount()
        XCTAssertEqual(count, 2, "Saved ZIP resumes still recheck the opt-in capability")
    }

    func testRequestedLoginSheetRendersUsernameAndSecurePasswordFields() async throws {
        let accessibilityScope = try HostedAccessibilityTestScope()
        defer { accessibilityScope.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaLoginView-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AreaTargetProcessingModel(api: AreaTargetAPIClient(sessionStore: AreaServiceTestSessions()),
            archiver: AreaFlowArchive(url: root.appendingPathComponent("upload.zip")), jobStore: AreaFlowJournal(),
            tokenStore: AreaFlowTokens(), assetStore: AreaFlowAssets(root: root), uploadDirectory: root.appendingPathComponent("uploads"))
        let request = AreaTargetServiceLoginRequest(id: UUID(), intent: .upload(scanDirectory: root, displayName: "登录后继续的原扫描"))
        let host = UIHostingController(rootView: AreaTargetServiceLoginView(model: model, request: request,
            cancel: {}, authenticate: { _, _ in }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded()
        func fields(in view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        let nodes = try await HostedAccessibilityTestScope.waitForNodes(in: host.view) { nodes in
            ["area-target-login-username", "area-target-login-password"].allSatisfy { identifier in
                nodes.contains { HostedAccessibilityTestScope.identifier(of: $0) == identifier }
            }
        }
        let renderedFields = fields(in: host.view)
        XCTAssertTrue(renderedFields.contains { $0.textContentType == .username })
        XCTAssertTrue(renderedFields.contains { $0.isSecureTextEntry && $0.textContentType == .password })
        // SwiftUI vends semantic fields separately from their backing UITextField.
        let username = try XCTUnwrap(nodes.first { HostedAccessibilityTestScope.identifier(of: $0) == "area-target-login-username" })
        let password = try XCTUnwrap(nodes.first { HostedAccessibilityTestScope.identifier(of: $0) == "area-target-login-password" })
        XCTAssertEqual(username.accessibilityLabel, "服务用户名")
        XCTAssertEqual(password.accessibilityLabel, "服务密码")
        XCTAssertTrue(model.jobs.isEmpty)
    }

    func testSignedOutPreparationOffersUploadWithoutShowingLogin() async throws {
        let accessibilityScope = try HostedAccessibilityTestScope()
        defer { accessibilityScope.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaGuestPreparation-\(UUID().uuidString)")
        let scan = root.appendingPathComponent("scan_selected", isDirectory: true)
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let api = AreaFlowServiceAPI(base: AreaFlowAPI(root: root))
        let model = AreaTargetProcessingModel(api: api, archiver: AreaFlowArchive(url: root.appendingPathComponent("upload.zip")),
            jobStore: AreaFlowJournal(), tokenStore: AreaFlowTokens(), assetStore: AreaFlowAssets(root: root),
            uploadDirectory: root.appendingPathComponent("uploads"))
        let host = UIHostingController(rootView: AreaTargetProcessingView(model: model, scanDirectory: scan, displayName: "原选大厅", settings: ScannerSettings(preferences: nil)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded()
        let nodes = try await HostedAccessibilityTestScope.waitForNodes(in: host.view) {
            $0.contains { $0.accessibilityLabel?.contains("原选大厅") == true }
        }
        XCTAssertFalse(nodes.contains { $0 is UITextField }, "Preparing a local scan must not show credential fields")
        XCTAssertFalse(nodes.contains { $0.accessibilityLabel == "登录" && $0.accessibilityTraits.contains(.button) },
            "The page offers the upload action, not an unsolicited login action")
        try await assertAccessibilityButton("上传并处理", in: host.view)
        XCTAssertTrue(nodes.contains { $0.accessibilityLabel?.contains("原选大厅") == true })
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertNil(model.serviceSession(for: .current))
        let events = await api.base.events
        XCTAssertTrue(events.isEmpty, "Opening preparation must not authenticate or submit the selected scan")
    }

    func testSignedOutTaskHistoryKeepsLocalTaskAndRetryAccessibleWithoutLoginFields() async throws {
        let accessibilityScope = try HostedAccessibilityTestScope()
        defer { accessibilityScope.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaGuestHistory-\(UUID().uuidString)")
        let scan = root.appendingPathComponent("scan_original", isDirectory: true)
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let api = AreaFlowServiceAPI(base: AreaFlowAPI(root: root))
        let journal = AreaFlowJournal()
        var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: scan.path,
            displayName: "原本暂停的任务", createdAt: Date(), serverOrigin: .current)
        job.phase = .paused
        journal.jobs = [job]
        let model = AreaTargetProcessingModel(api: api, archiver: AreaFlowArchive(url: root.appendingPathComponent("upload.zip")),
            jobStore: journal, tokenStore: AreaFlowTokens(), assetStore: AreaFlowAssets(root: root),
            uploadDirectory: root.appendingPathComponent("uploads"))
        let host = UIHostingController(rootView: AreaTargetProcessingView(model: model, scanDirectory: nil, displayName: "", entryPoint: .tasks, settings: ScannerSettings(preferences: nil)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded()
        let nodes = try await HostedAccessibilityTestScope.waitForNodes(in: host.view) {
            HostedAccessibilityTestScope.hasEnabledButton("检查并继续上传", in: $0)
        }
        XCTAssertFalse(nodes.contains { $0 is UITextField }, "Local task history is available while signed out")
        XCTAssertFalse(nodes.contains { $0.accessibilityLabel == "登录" && $0.accessibilityTraits.contains(.button) })
        try await assertAccessibilityButton("检查并继续上传", in: host.view)
        XCTAssertEqual(model.selectedJobID, job.id)
        XCTAssertEqual(journal.jobs.first?.id, job.id)
        XCTAssertTrue(model.deletionBlocked(scanPath: scan.path))
        let events = await api.base.events
        XCTAssertTrue(events.isEmpty, "Opening history must not query or resubmit a task")
    }

    func testTaskStatesRenderOfflineWithDownloadAndPauseActions() async throws {
        let accessibilityScope = try HostedAccessibilityTestScope()
        defer { accessibilityScope.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaViews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let api = AreaFlowAPI(root: root)
        for phase in [AreaTargetTaskPhase.paused, .submissionUnknown, .processing, .ready, .downloaded, .failed, .stopped] {
            let journal = AreaFlowJournal()
            var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: root.appendingPathComponent("scan_fixture").path,
                displayName: "一楼大厅", createdAt: Date())
            job.phase = phase
            job.accepted = [.processing, .ready, .downloaded, .failed].contains(phase)
            journal.jobs = [job]
            let model = AreaTargetProcessingModel(api: api, archiver: AreaFlowArchive(url: root.appendingPathComponent("upload.zip")),
                jobStore: journal, tokenStore: AreaFlowTokens(), assetStore: AreaFlowAssets(root: root), uploadDirectory: root.appendingPathComponent("uploads"))
            for style in [UIUserInterfaceStyle.light, .dark] {
                let host = UIHostingController(rootView: AreaTargetProcessingView(model: model, scanDirectory: job.scanDirectory,
                    displayName: job.displayName, settings: ScannerSettings(preferences: nil)).environment(\.sizeCategory, .accessibilityLarge))
                host.overrideUserInterfaceStyle = style
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.frame = window.bounds
                try await Task.sleep(nanoseconds: 100_000_000)
                host.view.layoutIfNeeded()
                var rendered = false
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    rendered = host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                XCTAssertTrue(rendered)
                let attachment = XCTAttachment(image: image)
                attachment.name = "area-target-\(phase.rawValue)-\(style.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
                window.isHidden = true
                window.rootViewController = nil
            }
            model.setAppActive(false)
        }
        let events = await api.events
        XCTAssertTrue(events.isEmpty, "Opening a task page must not upload or download without an action")
    }

    func testStoppedTaskKeepsLocalAssetExportAvailableWhileSignedOut() async throws {
        let accessibilityScope = try HostedAccessibilityTestScope()
        defer { accessibilityScope.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaStoppedView-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let api = AreaFlowServiceAPI(base: AreaFlowAPI(root: root))
        let journal = AreaFlowJournal()
        let assets = AreaFlowAssets(root: root)
        var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: root.appendingPathComponent("scan_fixture").path,
            displayName: "已停止的大厅任务", createdAt: Date(), serverOrigin: .current)
        job.phase = .stopped
        job.accepted = true
        let bundle = root.appendingPathComponent("asset_bundle.zip")
        try Data("saved local asset".utf8).write(to: bundle)
        let asset = AreaTargetSavedAsset(jobID: job.id, bundleURL: bundle, directoryURL: root,
            modelURL: root.appendingPathComponent("optimized.glb"), featuresURL: root.appendingPathComponent("features.db"),
            manifestURL: root.appendingPathComponent("manifest.json"), savedAt: Date())
        job.savedAsset = asset
        journal.jobs = [job]
        assets.values[job.id] = asset
        let model = AreaTargetProcessingModel(api: api, archiver: AreaFlowArchive(url: root.appendingPathComponent("upload.zip")),
            jobStore: journal, tokenStore: AreaFlowTokens(), assetStore: assets, uploadDirectory: root.appendingPathComponent("uploads"))
        let host = UIHostingController(rootView: AreaTargetProcessingView(model: model, scanDirectory: nil, displayName: "", entryPoint: .tasks, settings: ScannerSettings(preferences: nil)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded()
        XCTAssertNil(model.serviceSession(for: .current))
        XCTAssertEqual(model.selectedJob?.phase, .stopped)
        try await assertAccessibilityButton("导出资产包", in: host.view,
            message: "A verified local asset must remain exportable without a cloud login")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertEqual(api.statusCalls, 0)
        let events = await api.base.events
        XCTAssertTrue(events.isEmpty, "Opening this local UI must not submit, query, or download a cloud task")
    }

    func testNoSelectedScanOffersSharedScanSelectionBeforeCloudActions() async throws {
        let accessibilityScope = try HostedAccessibilityTestScope()
        defer { accessibilityScope.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaSelectView-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let api = AreaFlowServiceAPI(base: AreaFlowAPI(root: root))
        let model = AreaTargetProcessingModel(api: api, archiver: AreaFlowArchive(url: root.appendingPathComponent("upload.zip")),
            jobStore: AreaFlowJournal(), tokenStore: AreaFlowTokens(), assetStore: AreaFlowAssets(root: root),
            uploadDirectory: root.appendingPathComponent("uploads"))
        let host = UIHostingController(rootView: AreaTargetProcessingView(model: model, scanDirectory: nil, displayName: "", selectScan: {}, settings: ScannerSettings(preferences: nil)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded()
        let nodes = try await HostedAccessibilityTestScope.waitForNodes(in: host.view) {
            HostedAccessibilityTestScope.hasEnabledButton("选择扫描", in: $0)
        }
        try await assertAccessibilityButton("选择扫描", in: host.view)
        XCTAssertFalse(nodes.contains { $0.accessibilityLabel == "上传并处理" && $0.accessibilityTraits.contains(.button) })
        XCTAssertFalse(nodes.contains { $0.accessibilityLabel == "请先登录服务，再继续云端任务。" },
            "Selecting a source is the next step before cloud actions")
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertEqual(api.statusCalls, 0)
        let events = await api.base.events
        XCTAssertTrue(events.isEmpty, "Opening this local UI must not submit, query, or download a cloud task")
    }

    func testCloudTransferKeepsLocalPauseButtonEnabled() async throws {
        let accessibilityScope = try HostedAccessibilityTestScope()
        defer { accessibilityScope.restore() }
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.api.saved = AreaFlowServiceAPI.fixtureSession
        await fixture.api.base.setHoldUpload(true)
        let model = cloudModel(fixture)
        let actions = AreaTargetCloudActionCoordinator(model: model)
        let host = UIHostingController(rootView: AreaTargetProcessingView(model: model, scanDirectory: fixture.scan,
            displayName: "长传输可暂停", settings: ScannerSettings(preferences: nil), cloudActions: actions))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 100_000_000)
        actions.setScenePhase(.active)
        let upload = Task { await actions.perform(.upload(scanDirectory: fixture.scan, displayName: "长传输可暂停")) }
        defer { model.pause(); upload.cancel() }
        for _ in 0..<100 {
            if await fixture.api.base.events.contains(where: { $0.0 == "submit" }) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(model.operationInProgress)
        XCTAssertTrue(actions.isExecuting)
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded()
        try await assertAccessibilityButton("暂停本机操作", in: host.view, message: "A long transfer must retain an enabled local pause action")
        model.pause()
        await upload.value
        XCTAssertFalse(model.operationInProgress)
    }

    func testGuestUploadIntentWaitsForLoginAndCancellationDoesNotSubmit() async throws {
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let actions = AreaTargetCloudActionCoordinator(model: fixture.model)
        await actions.perform(.upload(scanDirectory: fixture.scan, displayName: "原选大厅"))
        let request = try XCTUnwrap(actions.loginRequest)
        XCTAssertEqual(request.intent, .upload(scanDirectory: fixture.scan, displayName: "原选大厅"))
        XCTAssertTrue(fixture.model.jobs.isEmpty)
        actions.cancelLogin()
        await actions.continueAfterLogin()
        XCTAssertNil(actions.loginRequest)
        XCTAssertTrue(fixture.model.jobs.isEmpty)
        let events = await fixture.api.base.events
        XCTAssertTrue(events.isEmpty)
    }

    func testLoginContinuesOriginallySelectedScanEvenIfTaskSelectionChanges() async throws {
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var other = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: fixture.root.appendingPathComponent("scan_other").path,
            displayName: "另一场景", createdAt: Date(), serverOrigin: .current)
        other.phase = .paused
        fixture.journal.jobs = [other]
        let model = cloudModel(fixture, journal: fixture.journal)
        let actions = AreaTargetCloudActionCoordinator(model: model)
        await actions.perform(.upload(scanDirectory: fixture.scan, displayName: "原选大厅"))
        let request = try XCTUnwrap(actions.loginRequest)
        model.selectJob(other.id)
        await actions.authenticate(requestID: request.id, username: "scanner", password: "temporary password")
        XCTAssertTrue(model.jobs.allSatisfy { $0.id == other.id }, "Login alone waits for the modal to dismiss before continuing")
        await actions.continueAfterLogin()
        let uploaded = try XCTUnwrap(model.selectedJob)
        XCTAssertEqual(uploaded.scanDirectoryPath, fixture.scan.path)
        XCTAssertEqual(uploaded.displayName, "原选大厅")
        XCTAssertNotEqual(uploaded.id, other.id)
        let events = await fixture.api.base.events
        XCTAssertEqual(events.filter { $0.0 == "submit" }.map { $0.1 }, [uploaded.id])
    }

    func testLoginRetryKeepsOriginalJobIdentityAndServerOrigin() async throws {
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let legacyAPI = AreaViewServiceAPI(base: AreaFlowAPI(root: fixture.root))
        var original = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: fixture.scan.path,
            displayName: "原任务", createdAt: Date(), serverOrigin: .legacy)
        original.phase = .paused
        fixture.journal.jobs = [original]
        try fixture.tokens.save(String(repeating: "a", count: 64), jobID: original.id)
        let model = cloudModel(fixture, journal: fixture.journal, legacyAPI: legacyAPI)
        let actions = AreaTargetCloudActionCoordinator(model: model)
        let intent = AreaTargetCloudIntent.resume(jobID: original.id, origin: .legacy, displayName: original.displayName)
        await actions.perform(intent)
        let request = try XCTUnwrap(actions.loginRequest)
        XCTAssertEqual(request.intent, intent)
        await actions.authenticate(requestID: request.id, username: "scanner", password: "temporary password")
        await actions.continueAfterLogin()
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.selectedJobID, original.id)
        XCTAssertEqual(model.selectedJob?.serverOrigin, .legacy)
        XCTAssertNil(fixture.api.saved)
        XCTAssertNotNil(legacyAPI.saved)
        let legacyEvents = await legacyAPI.base.events
        XCTAssertEqual(legacyEvents.filter { $0.0 == "submit" }.map { $0.1 }, [original.id])
        let currentEvents = await fixture.api.base.events
        XCTAssertTrue(currentEvents.isEmpty)
    }

    func testValidSessionRunsUploadWithoutShowingLogin() async throws {
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.api.saved = AreaFlowServiceAPI.fixtureSession
        let model = cloudModel(fixture)
        let actions = AreaTargetCloudActionCoordinator(model: model)
        await actions.perform(.upload(scanDirectory: fixture.scan, displayName: "已登录扫描"))
        XCTAssertNil(actions.loginRequest)
        XCTAssertEqual(fixture.api.signInCalls, 0)
        let events = await fixture.api.base.events
        XCTAssertEqual(events.filter { $0.0 == "submit" }.count, 1)
    }

    func testLateLoginResponseAfterCancellationCannotUpload() async throws {
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.api.holdSignIn = true
        let actions = AreaTargetCloudActionCoordinator(model: fixture.model)
        await actions.perform(.upload(scanDirectory: fixture.scan, displayName: "已取消扫描"))
        let request = try XCTUnwrap(actions.loginRequest)
        let login = Task { await actions.authenticate(requestID: request.id, username: "scanner", password: "temporary password") }
        for _ in 0..<100 {
            if fixture.api.signInCalls == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(fixture.api.signInCalls, 1)
        actions.cancelLogin()
        fixture.api.releaseSignIn()
        await login.value
        await actions.continueAfterLogin()
        XCTAssertNil(actions.loginRequest)
        XCTAssertTrue(fixture.model.jobs.isEmpty)
        let events = await fixture.api.base.events
        XCTAssertTrue(events.isEmpty, "A cancelled login continuation must not upload when authentication returns late")
    }

    func testBackgroundCancelsPendingLoginAndLateResponseCannotUploadOnReturn() async throws {
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.api.holdSignIn = true
        let actions = AreaTargetCloudActionCoordinator(model: fixture.model)
        await actions.perform(.upload(scanDirectory: fixture.scan, displayName: "后台不能续传"))
        let request = try XCTUnwrap(actions.loginRequest)
        let login = Task { await actions.authenticate(requestID: request.id, username: "scanner", password: "temporary password") }
        for _ in 0..<100 {
            if fixture.api.signInCalls == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        actions.setScenePhase(.background)
        fixture.api.releaseSignIn()
        await login.value
        actions.setScenePhase(.active)
        await actions.continueAfterLogin()
        XCTAssertNil(actions.loginRequest)
        XCTAssertTrue(fixture.model.jobs.isEmpty)
        let events = await fixture.api.base.events
        XCTAssertTrue(events.isEmpty, "Returning from the background must not resurrect a cancelled upload intent")
    }

    func testTemporaryInactiveLoginKeepsIntentButWaitsForActiveBeforeUpload() async throws {
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let actions = AreaTargetCloudActionCoordinator(model: fixture.model)
        await actions.perform(.upload(scanDirectory: fixture.scan, displayName: "自动填充后的原扫描"))
        let request = try XCTUnwrap(actions.loginRequest)
        actions.setScenePhase(.inactive)
        await actions.authenticate(requestID: request.id, username: "scanner", password: "temporary password")
        await actions.continueAfterLogin()
        XCTAssertTrue(fixture.model.jobs.isEmpty)
        actions.setScenePhase(.active)
        await actions.continueAfterLogin()
        XCTAssertEqual(fixture.model.selectedJob?.scanDirectoryPath, fixture.scan.path)
        let events = await fixture.api.base.events
        XCTAssertEqual(events.filter { $0.0 == "submit" }.count, 1)
    }

    func testStoppedJobDuringLoginCannotBeResubmitted() async throws {
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var job = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: fixture.scan.path,
            displayName: "停止的原任务", createdAt: Date(), serverOrigin: .current)
        job.phase = .paused
        job.mapCLAHE = true
        fixture.journal.jobs = [job]
        try fixture.tokens.save(String(repeating: "a", count: 64), jobID: job.id)
        let model = cloudModel(fixture, journal: fixture.journal)
        let actions = AreaTargetCloudActionCoordinator(model: model)
        await actions.perform(.resume(jobID: job.id, origin: .current, displayName: job.displayName))
        let request = try XCTUnwrap(actions.loginRequest)
        model.stopLocalTracking(jobID: job.id)
        await actions.authenticate(requestID: request.id, username: "scanner", password: "temporary password")
        await actions.continueAfterLogin()
        XCTAssertEqual(model.jobs.first?.phase, .stopped)
        XCTAssertEqual(model.jobs.first?.mapCLAHE, true)
        XCTAssertEqual(model.jobs.count, 1)
        let events = await fixture.api.base.events
        XCTAssertTrue(events.isEmpty)
    }

    func testUploadSessionRejectionReauthenticatesUsingCreatedJobInsteadOfNewSubmission() async throws {
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.api.saved = AreaFlowServiceAPI.fixtureSession
        fixture.api.rejectNextSubmit = true
        let model = cloudModel(fixture)
        let actions = AreaTargetCloudActionCoordinator(model: model)
        await actions.perform(.upload(scanDirectory: fixture.scan, displayName: "会话中途过期"))
        let original = try XCTUnwrap(model.selectedJob)
        let request = try XCTUnwrap(actions.loginRequest)
        XCTAssertEqual(request.intent, .resume(jobID: original.id, origin: .current, displayName: original.displayName))
        await actions.authenticate(requestID: request.id, username: "scanner", password: "temporary password")
        await actions.continueAfterLogin()
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.selectedJobID, original.id)
        XCTAssertEqual(fixture.api.submitIDs, [original.id, original.id])
        XCTAssertEqual(model.selectedJob?.phase, .processing)
    }

    func testExplicitExpiredRefreshReauthenticatesOriginalJobWithoutUpload() async throws {
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.api.saved = AreaFlowServiceAPI.fixtureSession
        let model = cloudModel(fixture)
        await model.start(scanDirectory: fixture.scan, displayName: "旧云端任务")
        let original = try XCTUnwrap(model.selectedJob)
        fixture.api.rejectNextStatus = true
        let actions = AreaTargetCloudActionCoordinator(model: model)
        await actions.perform(.refresh(jobID: original.id, origin: original.serverOrigin, displayName: original.displayName))
        let request = try XCTUnwrap(actions.loginRequest)
        XCTAssertEqual(request.intent, .refresh(jobID: original.id, origin: .current, displayName: original.displayName))
        await actions.authenticate(requestID: request.id, username: "scanner", password: "temporary password")
        await actions.continueAfterLogin()
        XCTAssertEqual(model.selectedJobID, original.id)
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(fixture.api.submitIDs, [original.id])
    }

    func testExplicitExpiredDownloadReauthenticatesOriginalJobWithoutUpload() async throws {
        let fixture = try cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.api.saved = AreaFlowServiceAPI.fixtureSession
        let model = cloudModel(fixture)
        await model.start(scanDirectory: fixture.scan, displayName: "旧任务结果")
        await fixture.api.base.setRemoteStatus(.completed)
        let original = try XCTUnwrap(model.selectedJob)
        await model.refresh(jobID: original.id)
        fixture.api.rejectNextStatus = true
        let actions = AreaTargetCloudActionCoordinator(model: model)
        await actions.perform(.download(jobID: original.id, origin: original.serverOrigin, displayName: original.displayName))
        let request = try XCTUnwrap(actions.loginRequest)
        XCTAssertEqual(request.intent, .download(jobID: original.id, origin: .current, displayName: original.displayName))
        await actions.authenticate(requestID: request.id, username: "scanner", password: "temporary password")
        await actions.continueAfterLogin()
        XCTAssertEqual(model.selectedJobID, original.id)
        XCTAssertEqual(model.selectedJob?.phase, .downloaded)
        XCTAssertEqual(fixture.api.submitIDs, [original.id])
    }

    private struct CloudFixture {
        let root: URL
        let scan: URL
        let api: AreaViewServiceAPI
        let journal: AreaFlowJournal
        let tokens: AreaFlowTokens
        let model: AreaTargetProcessingModel
    }

    private func cloudFixture() throws -> CloudFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaAction-\(UUID().uuidString)")
        let scan = root.appendingPathComponent("scan_original", isDirectory: true)
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        let api = AreaViewServiceAPI(base: AreaFlowAPI(root: root))
        let journal = AreaFlowJournal()
        let tokens = AreaFlowTokens()
        let model = AreaTargetProcessingModel(api: api, archiver: AreaFlowArchive(url: root.appendingPathComponent("upload.zip")),
            jobStore: journal, tokenStore: tokens, assetStore: AreaFlowAssets(root: root), uploadDirectory: root.appendingPathComponent("uploads"))
        return CloudFixture(root: root, scan: scan, api: api, journal: journal, tokens: tokens, model: model)
    }

    private func cloudModel(_ fixture: CloudFixture, journal: AreaFlowJournal? = nil, legacyAPI: AreaTargetAPI? = nil) -> AreaTargetProcessingModel {
        AreaTargetProcessingModel(api: fixture.api, legacyAPI: legacyAPI, archiver: AreaFlowArchive(url: fixture.root.appendingPathComponent("upload.zip")),
            jobStore: journal ?? fixture.journal, tokenStore: fixture.tokens, assetStore: AreaFlowAssets(root: fixture.root),
            uploadDirectory: fixture.root.appendingPathComponent("uploads"))
    }

    private func accessibilityNodes(in root: UIView) -> [NSObject] {
        HostedAccessibilityTestScope.nodes(in: root.window ?? root)
    }

    private func assertAccessibilityButton(_ label: String, in root: UIView,
                                           message: String = "Expected action must be reachable in the hosted accessibility tree",
                                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let nodes = try await HostedAccessibilityTestScope.waitForNodes(in: root) {
            HostedAccessibilityTestScope.hasEnabledButton(label, in: $0)
        }
        let found = HostedAccessibilityTestScope.hasEnabledButton(label, in: nodes)
        if !found {
            let screenshot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: root.bounds).image { _ in
                _ = root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
            })
            screenshot.name = "rendered-\(label)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(found, message + " (enabled button=\(label))", file: file, line: line)
    }

    func testSignedInViewUsesStoredSessionWithoutRenderingPasswordFields() async throws {
        let accessibilityScope = try HostedAccessibilityTestScope()
        defer { accessibilityScope.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaSignedInView-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let api = AreaFlowAPI(root: root)
        let authenticatedAPI = AreaFlowServiceAPI(base: api)
        authenticatedAPI.saved = AreaFlowServiceAPI.fixtureSession
        let model = AreaTargetProcessingModel(api: authenticatedAPI,
            archiver: AreaFlowArchive(url: root.appendingPathComponent("upload.zip")), jobStore: AreaFlowJournal(),
            tokenStore: AreaFlowTokens(), assetStore: AreaFlowAssets(root: root), uploadDirectory: root.appendingPathComponent("uploads"))
        let host = UIHostingController(rootView: AreaTargetProcessingView(model: model, scanDirectory: nil, displayName: "", entryPoint: .tasks, settings: ScannerSettings(preferences: nil)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded()
        func fields(in view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        XCTAssertTrue(fields(in: host.view).isEmpty)
        XCTAssertEqual(model.serviceSession(for: .current)?.username, "scanner")
        XCTAssertNil(model.authenticationMessage)
        let events = await api.events
        XCTAssertTrue(events.isEmpty, "Opening the signed-in task page must not submit a scan")
    }
}

private final class AreaViewServiceAPI: AreaTargetAPI {
    let base: AreaFlowAPI
    var saved: AreaTargetServiceSession?
    var signInCalls = 0
    var holdSignIn = false
    var rejectNextSubmit = false
    var rejectNextStatus = false
    var submitIDs: [String] = []
    private var signInContinuation: CheckedContinuation<Void, Never>?
    var requiresServiceAuthentication: Bool { true }
    init(base: AreaFlowAPI) { self.base = base }
    func savedServiceSession() throws -> AreaTargetServiceSession? { saved }
    func signIn(username: String, password: String) async throws -> AreaTargetServiceSession {
        signInCalls += 1
        if holdSignIn { await withCheckedContinuation { signInContinuation = $0 } }
        saved = AreaFlowServiceAPI.fixtureSession
        return saved!
    }
    func releaseSignIn() {
        holdSignIn = false
        signInContinuation?.resume()
        signInContinuation = nil
    }
    func validateServiceSession() async throws -> AreaTargetServiceSession? { saved }
    func signOut() async throws { saved = nil }
    func fetchProcessingRequirements() async throws -> AreaTargetProcessingRequirements { try await base.fetchProcessingRequirements() }
    func submit(archiveURL: URL, jobID: String, token: String, profile: String, uvUnwrap: Bool, mapCLAHE: Bool = false,
                progress: @escaping @Sendable (Double) -> Void) async throws -> AreaTargetRemoteJob {
        submitIDs.append(jobID)
        if rejectNextSubmit {
            rejectNextSubmit = false
            saved = nil
            throw AreaTargetAPIError.authenticationRequired
        }
        return try await base.submit(archiveURL: archiveURL, jobID: jobID, token: token, profile: profile, uvUnwrap: uvUnwrap, mapCLAHE: mapCLAHE, progress: progress)
    }
    func status(jobID: String, token: String) async throws -> AreaTargetRemoteJob {
        if rejectNextStatus {
            rejectNextStatus = false
            saved = nil
            throw AreaTargetAPIError.authenticationRequired
        }
        return try await base.status(jobID: jobID, token: token)
    }
    func download(jobID: String, token: String, result: AreaTargetResult,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await base.download(jobID: jobID, token: token, result: result, progress: progress)
    }
}

/// Hosted XCTest does not initialize AX automation like an XCUITest runner does.
/// The scope is confined to the test bundle and restores its original flag.
/// Mechanism reference: cashapp/AccessibilitySnapshot, ASAccessibilityEnabler.m.
@MainActor
final class HostedAccessibilityTestScope {
    private let library: UnsafeMutableRawPointer
    private let readAutomation: @convention(c) () -> Int32
    private let writeAutomation: @convention(c) (Int32) -> Void
    private let originalAutomation: Int32
    private var restored = false

    init() throws {
        let library = try XCTUnwrap(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), "AX test runtime must be available")
        guard let read = dlsym(library, "_AXSAutomationEnabled"),
              let write = dlsym(library, "_AXSSetAutomationEnabled") else {
            dlclose(library)
            throw NSError(domain: "HostedAccessibilityTestScope", code: 1)
        }
        let readFlag = unsafeBitCast(read, to: (@convention(c) () -> Int32).self)
        let writeFlag = unsafeBitCast(write, to: (@convention(c) (Int32) -> Void).self)
        self.library = library
        readAutomation = readFlag
        writeAutomation = writeFlag
        originalAutomation = readFlag()
        writeFlag(1)
    }

    func restore() {
        guard !restored else { return }
        writeAutomation(originalAutomation)
        XCTAssertEqual(readAutomation(), originalAutomation, "Hosted tests must restore AX automation")
        restored = true
        dlclose(library)
    }

    static func identifier(of object: NSObject) -> String? {
        if let identifier = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier { return identifier }
        // SwiftUI's Any-wrapped virtual nodes can lose ObjC protocol conformance.
        guard object.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
        return object.value(forKey: "accessibilityIdentifier") as? String
    }

    static func nodes(in root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            for case let child as NSObject in object.accessibilityElements ?? [] { visit(child) }
            if #available(iOS 17.0, *) {
                for case let child as NSObject in object.automationElements ?? [] { visit(child) }
            }
            let count = object.accessibilityElementCount()
            if count > 0, count < 1_000 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { visit(child) }
                }
            }
            if let view = object as? UIView { view.subviews.forEach(visit) }
        }
        visit(root)
        return result
    }

    static func hasEnabledButton(_ title: String, in nodes: [NSObject]) -> Bool {
        nodes.contains { $0.accessibilityLabel == title && $0.accessibilityTraits.contains(.button)
            && !$0.accessibilityTraits.contains(.notEnabled) }
    }

    static func waitForNodes(in view: UIView, until ready: ([NSObject]) -> Bool) async throws -> [NSObject] {
        let root = view.window ?? view
        let deadline = Date().addingTimeInterval(2)
        while true {
            root.layoutIfNeeded()
            let result = nodes(in: root)
            if ready(result) || Date() >= deadline { return result }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
