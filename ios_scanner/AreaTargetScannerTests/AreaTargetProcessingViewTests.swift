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
        let renderedFields = fields(in: host.view)
        XCTAssertTrue(renderedFields.contains { $0.textContentType == .username })
        XCTAssertTrue(renderedFields.contains { $0.isSecureTextEntry && $0.textContentType == .password })
        XCTAssertTrue(model.jobs.isEmpty)
    }

    func testTaskStatesRenderOfflineWithDownloadAndPauseActions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AreaViews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let api = AreaFlowAPI(root: root)
        for phase in [AreaTargetTaskPhase.paused, .submissionUnknown, .processing, .ready, .downloaded, .failed] {
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
