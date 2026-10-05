import XCTest
import SwiftUI
import UIKit
@testable import AreaTargetScanner

@MainActor
final class AreaTargetProcessingViewTests: XCTestCase {
    func testSignedOutViewRendersUsernameAndSecurePasswordFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaLoginView-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AreaTargetProcessingModel(api: AreaTargetAPIClient(sessionStore: AreaServiceTestSessions()),
            archiver: AreaFlowArchive(url: root.appendingPathComponent("upload.zip")), jobStore: AreaFlowJournal(),
            tokenStore: AreaFlowTokens(), assetStore: AreaFlowAssets(root: root), uploadDirectory: root.appendingPathComponent("uploads"))
        let host = UIHostingController(rootView: AreaTargetProcessingView(model: model, scanDirectory: nil, displayName: ""))
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
        // Materialize SwiftUI's semantic tree before checking input accessibility.
        _ = accessibilityNodes(in: host.view)
        let renderedFields = fields(in: host.view)
        XCTAssertTrue(renderedFields.contains { $0.textContentType == .username })
        XCTAssertTrue(renderedFields.contains { $0.isSecureTextEntry && $0.textContentType == .password })
        XCTAssertTrue(renderedFields.contains { $0.textContentType == .username && $0.accessibilityLabel == "服务用户名" })
        XCTAssertTrue(renderedFields.contains { $0.isSecureTextEntry && $0.accessibilityLabel == "服务密码" })
        XCTAssertTrue(model.jobs.isEmpty)
    }

    func testTaskStatesRenderOfflineWithDownloadAndPauseActions() async throws {
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
                    displayName: job.displayName).environment(\.sizeCategory, .accessibilityLarge))
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
        let host = UIHostingController(rootView: AreaTargetProcessingView(model: model, scanDirectory: nil, displayName: "", entryPoint: .tasks))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded()
        XCTAssertNil(model.serviceSession(for: .current))
        XCTAssertEqual(model.selectedJob?.phase, .stopped)
        assertAccessibilityButton("导出资产包", in: host.view,
            message: "A verified local asset must remain exportable without a cloud login")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertEqual(api.statusCalls, 0)
        let events = await api.base.events
        XCTAssertTrue(events.isEmpty, "Opening this local UI must not submit, query, or download a cloud task")
    }

    func testNoSelectedScanOffersSharedScanSelectionBeforeCloudActions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaSelectView-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let api = AreaFlowServiceAPI(base: AreaFlowAPI(root: root))
        let model = AreaTargetProcessingModel(api: api, archiver: AreaFlowArchive(url: root.appendingPathComponent("upload.zip")),
            jobStore: AreaFlowJournal(), tokenStore: AreaFlowTokens(), assetStore: AreaFlowAssets(root: root),
            uploadDirectory: root.appendingPathComponent("uploads"))
        let host = UIHostingController(rootView: AreaTargetProcessingView(model: model, scanDirectory: nil, displayName: "", selectScan: {}))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded()
        let nodes = accessibilityNodes(in: host.view)
        assertAccessibilityButton("选择扫描", in: host.view)
        XCTAssertFalse(nodes.contains { $0.accessibilityLabel == "上传并处理" && $0.accessibilityTraits.contains(.button) })
        XCTAssertFalse(nodes.contains { $0.accessibilityLabel == "请先登录服务，再继续云端任务。" },
            "Selecting a source is the next step before cloud actions")
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertEqual(api.statusCalls, 0)
        let events = await api.base.events
        XCTAssertTrue(events.isEmpty, "Opening this local UI must not submit, query, or download a cloud task")
    }

    private func automationElements(in object: NSObject) -> [Any] {
        if #available(iOS 17.0, *) { return object.automationElements ?? [] }
        return []
    }

    private func accessibilityNodes(in root: UIView) -> [NSObject] {
        var nodes: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            nodes.append(object)
            // Containers can vend arrays instead of overriding the dynamic count/index
            // methods. Reading the public arrays also materializes SwiftUI's AX tree.
            for child in object.accessibilityElements ?? [] {
                if let child = child as? NSObject { visit(child) }
            }
            for child in automationElements(in: object) {
                if let child = child as? NSObject { visit(child) }
            }
            let count = object.accessibilityElementCount()
            if count > 0 && count < 1_000 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { visit(child) }
                }
            }
            if let view = object as? UIView { view.subviews.forEach { visit($0) } }
        }
        visit(root)
        return nodes
    }

    private func assertAccessibilityButton(_ label: String, in root: UIView,
                                           message: String = "Expected action must be reachable in the hosted accessibility tree",
                                           file: StaticString = #filePath, line: UInt = #line) {
        let nodes = accessibilityNodes(in: root)
        let found = nodes.contains {
            $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button)
                && !$0.accessibilityTraits.contains(.notEnabled)
        }
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaSignedInView-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let api = AreaFlowAPI(root: root)
        let authenticatedAPI = AreaFlowServiceAPI(base: api)
        authenticatedAPI.saved = AreaFlowServiceAPI.fixtureSession
        let model = AreaTargetProcessingModel(api: authenticatedAPI,
            archiver: AreaFlowArchive(url: root.appendingPathComponent("upload.zip")), jobStore: AreaFlowJournal(),
            tokenStore: AreaFlowTokens(), assetStore: AreaFlowAssets(root: root), uploadDirectory: root.appendingPathComponent("uploads"))
        let host = UIHostingController(rootView: AreaTargetProcessingView(model: model, scanDirectory: nil, displayName: "", entryPoint: .tasks))
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
