import XCTest
import SwiftUI
import UIKit
import Vision
import simd
@testable import AreaTargetScanner

/// Synthetic fixtures only. Mounting these real native views must never request
/// camera permission, run AR tracking, load a native map, or perform a download.
@MainActor
final class LocalizationRenderTests: XCTestCase {
    private var root: URL!
    private var accessibilityScope: HostedAccessibilityTestScope?
    private let fingerprint = "3141592653589793238462643383279502884197169399375105820974944592"
    private let date = Date(timeIntervalSince1970: 1_790_730_960)
    private let variants: [(String, UIUserInterfaceStyle, ContentSizeCategory)] = [
        ("light", .light, .large), ("dark", .dark, .large),
        ("large-text", .light, .accessibilityExtraLarge)
    ]

    override func setUpWithError() throws {
        accessibilityScope = try HostedAccessibilityTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalizationRender-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        accessibilityScope?.restore(); accessibilityScope = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testDownloadedAreaTargetPageRendersWithoutStartingCameraOrNativeEngine() async throws {
        for (name, style, size) in variants {
            let engine = LocalizationRenderEngine()
            var cameraRequests = 0
            var arRuns = 0
            let session = AreaTargetLocalizationSession(engine: engine,
                requestCamera: { cameraRequests += 1; XCTFail("Rendering must not request camera permission"); return false },
                runSession: { _ in arRuns += 1; XCTFail("Rendering must not start AR tracking") })
            try await attachScreen(AreaTargetMapTestView(job: areaJob(), localizer: session,
                reportStore: LocalizationReportStore(rootDirectory: root.appendingPathComponent("reports"))),
                name: "area-target-offline-\(name)", style: style, size: size,
                expected: ["开始离线测试", "离线定位测试", "Area", "Target", "增强识别", "增加等待和耗电"])
            XCTAssertEqual(cameraRequests, 0)
            XCTAssertEqual(arRuns, 0)
            XCTAssertEqual(engine.loadCount, 0)
            XCTAssertEqual(engine.frameCount, 0)
            XCTAssertFalse(session.isRunning)
            XCTAssertNil(session.report, "A downloaded asset must not invent a completed field test")
        }
    }

    func testDoneSavesStoppedAreaTargetReportAndDismissesFullScreenTest() async throws {
        let job = areaJob()
        let session = AreaTargetLocalizationSession(engine: LocalizationDismissalEngine(),
            requestCamera: { true }, runSession: { _ in })
        session.start(asset: try XCTUnwrap(job.savedAsset), sourceFingerprint: job.sourceFingerprint,
            buildConfiguration: job.localizationBuildConfiguration)
        for _ in 0..<100 where session.isLoading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(session.isRunning)
        let frame = try LocalizationQueryFrame(sequence: 0, timestamp: 10, pixels: Data(repeating: 0, count: 4),
            width: 2, height: 2, intrinsics: SIMD4(1, 1, 1, 1), worldFromCamera: matrix_identity_float4x4)
        await session.process(frame)
        session.stop()
        let report = try XCTUnwrap(session.report)
        let reportStore = LocalizationReportStore(rootDirectory: root.appendingPathComponent("reports"))
        var dismissed = false
        let host = UIHostingController(rootView: LocalizationDismissalHarness(job: job, session: session, reportStore: reportStore) { dismissed = true })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        // A full-screen presentation needs a real scene, unlike a static snapshot.
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            host.dismiss(animated: false)
            host.view.endEditing(true); window.isHidden = true; window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        for _ in 0..<100 {
            if let presented = host.presentedViewController,
               presented.viewIfLoaded?.window === window, !presented.isBeingPresented,
               presented.transitionCoordinator == nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let presented = try XCTUnwrap(host.presentedViewController, "The real full-screen test must be presented")
        XCTAssertTrue(presented.viewIfLoaded?.window === window)
        XCTAssertFalse(presented.isBeingPresented)
        func doneItem(in controller: UIViewController) -> UIBarButtonItem? {
            let items = (controller.navigationItem.rightBarButtonItems ?? []) +
                controller.navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
            if let item = items.first(where: { $0.title == "完成" || $0.accessibilityLabel == "完成" ||
                $0.accessibilityIdentifier == "area-target-test-done" }) { return item }
            for child in controller.children { if let item = doneItem(in: child) { return item } }
            return controller.presentedViewController.flatMap { doneItem(in: $0) }
        }
        func doneButton(in view: UIView) -> UIButton? {
            if let button = view as? UIButton, button.currentTitle == "完成" ||
                button.accessibilityLabel == "完成" || button.accessibilityIdentifier == "area-target-test-done" { return button }
            return view.subviews.lazy.compactMap { doneButton(in: $0) }.first
        }
        var item: UIBarButtonItem?
        var button: UIButton?
        var semanticButton: NSObject?
        for _ in 0..<100 {
            host.view.layoutIfNeeded()
            item = doneItem(in: host)
            button = doneButton(in: window)
            semanticButton = HostedAccessibilityTestScope.nodes(in: window).first {
                (HostedAccessibilityTestScope.identifier(of: $0) == "area-target-test-done" || $0.accessibilityLabel == "完成")
                    && $0.accessibilityTraits.contains(.button) && !$0.accessibilityTraits.contains(.notEnabled)
            }
            if item != nil || button != nil || semanticButton != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let contents = XCTAttachment(string: accessibleContents(of: window))
        contents.name = "offline-done-accessibility"; contents.lifetime = .keepAlways; add(contents)
        let screenshot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        screenshot.name = "offline-done-presented-screen"; screenshot.lifetime = .keepAlways; add(screenshot)
        if let button { button.sendActions(for: .touchUpInside) }
        else if let semanticButton {
            XCTAssertTrue(semanticButton.accessibilityActivate(), "The rendered Done control must execute its real accessibility action")
        } else {
            let done = try XCTUnwrap(item)
            let action = try XCTUnwrap(done.action)
            XCTAssertTrue(UIApplication.shared.sendAction(action, to: done.target, from: done, for: nil))
        }
        for _ in 0..<100 where !dismissed || host.presentedViewController != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(dismissed, "Done must close the full-screen test after saving")
        XCTAssertNil(host.presentedViewController, "Done must finish dismissing the presented test")
        XCTAssertEqual(try reportStore.latest(identity: report.identity), report)
        XCTAssertFalse(session.isRunning)
    }

    func testKnownSyntheticEvaluationReportRendersLightDarkAndLargeText() async throws {
        let report = fixtureReport()
        XCTAssertEqual(report.eligibility, .eligible)
        XCTAssertEqual(report.score, 93)
        for (name, style, size) in variants {
            let view = NavigationStack {
                ScrollView { LocalizationEvaluationView(report: report).padding(24) }
                    .background(Color(uiColor: .systemGroupedBackground))
                    .navigationTitle("合成定位报告")
                    .navigationBarTitleDisplayMode(.inline)
            }
            try await attachScreen(view, name: "localization-score-\(name)", style: style, size: size,
                expected: ["合成定位报告", "Area", "Target", "93", "100", "定位成功率"])
        }
    }

    func testSameFrameComparisonInitialPageRendersWithoutRequestingCamera() async throws {
        for (name, style, size) in variants {
            var cameraRequests = 0
            var arRuns = 0
            let session = LocalizationComparisonSession(
                requestCamera: { cameraRequests += 1; XCTFail("Rendering must not request camera permission"); return false },
                runSession: { _ in arRuns += 1; XCTFail("Rendering must not start AR tracking") },
                store: LocalizationReportStore(rootDirectory: root.appendingPathComponent("reports")))
            let area = areaJob()
            var immersal = ImmersalMappingJob(id: UUID(), userID: 1_931_415_926,
                scanName: area.scanDirectory.lastPathComponent, mapName: "SyntheticRenderMap", createdAt: date)
            immersal.mapID = 1_923_846_264; immersal.phase = .done
            immersal.sourceFingerprint = fingerprint; immersal.frameCount = 24
            try await attachScreen(LocalizationComparisonView(areaJob: area, immersalJob: immersal,
                scanDirectory: area.scanDirectory, localizer: session,
                mapStore: ImmersalMapStore(rootURL: root.appendingPathComponent("maps")),
                reportStore: LocalizationReportStore(rootDirectory: root.appendingPathComponent("reports"))),
                name: "localization-comparison-\(name)", style: style, size: size,
                expected: ["同一扫描", "同帧对比", "算法对比", "合成测试大厅", "增强识别", "增加等待和耗电"])
            XCTAssertEqual(cameraRequests, 0)
            XCTAssertEqual(arRuns, 0)
            XCTAssertEqual(session.stage, .idle)
            XCTAssertEqual(session.frameCount, 0)
            XCTAssertNil(session.report)
            XCTAssertFalse(session.runner.isRunning)
        }
    }

    private func areaJob() -> AreaTargetProcessingJob {
        let id = UUID().uuidString.lowercased()
        var job = AreaTargetProcessingJob(id: id, scanDirectoryPath: root.appendingPathComponent("synthetic-scan").path,
            displayName: "合成测试大厅", createdAt: date)
        job.phase = .downloaded; job.accepted = true; job.sourceFingerprint = fingerprint
        job.savedAsset = AreaTargetSavedAsset(jobID: id, bundleURL: root.appendingPathComponent("synthetic.zip"),
            directoryURL: root, modelURL: root.appendingPathComponent("optimized.glb"),
            featuresURL: root.appendingPathComponent("features.db"), manifestURL: root.appendingPathComponent("manifest.json"), savedAt: date)
        return job
    }

    private func fixtureReport() -> LocalizationEvaluationReport {
        var evidence = LocalizationEvaluationAccumulator(identity: .init(provider: .areaTarget, assetID: "synthetic-render-asset",
            sourceFingerprint: fingerprint, engineVersion: "synthetic-render-fixture",
            assetDigest: String(repeating: "c", count: 64), buildConfiguration: "synthetic-render-only"))
        for index in 0..<24 {
            evidence.record(sequence: index, captureTime: Double(index) * 2,
                latency: 0.35 + Double(index % 5) * 0.05, cameraPosition: SIMD3(Float(index) * 0.2, 0, 0),
                worldFromScan: index.isMultiple(of: 6) ? nil : matrix_identity_float4x4, commonAlignmentValid: true)
        }
        return evidence.report(date: date)
    }

    private func attachScreen<V: View>(_ view: V, name: String, style: UIUserInterfaceStyle,
        size: ContentSizeCategory, expected: [String]) async throws {
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: AnyView(view
            .environment(\.scenePhase, .active)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 8 * 3600)!)
            .environment(\.sizeCategory, size)))
        host.overrideUserInterfaceStyle = style
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let window = UIWindow(frame: bounds)
        window.overrideUserInterfaceStyle = style; window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.view.endEditing(true); window.isHidden = true; window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        host.view.frame = bounds
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 350_000_000)
        host.view.layoutIfNeeded()
        let labels = accessibleContents(of: window)
        let text = XCTAttachment(string: labels)
        text.name = name + "-accessibility"; text.lifetime = .keepAlways; add(text)

        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            rendered = host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered, "The native \(name) screen must finish rendering before attachment")
        XCTAssertEqual(image.size, bounds.size)
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let destination = ProcessInfo.processInfo.environment["AREA_TARGET_RENDER_OUTPUT_DIR"], !destination.isEmpty {
            guard destination.hasPrefix("/") else { XCTFail("Render output requires an absolute host directory"); return }
            let directory = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        }
        let recognized = try recognizedContents(of: image)
        let evidence = XCTAttachment(string: recognized)
        evidence.name = name + "-recognized-text"; evidence.lifetime = .keepAlways; add(evidence)
        for value in expected {
            XCTAssertTrue(normalized(recognized).contains(normalized(value)),
                "\(name) must visibly render: \(value). Recognized text: \(recognized)")
        }
    }

    /// The app-hosted SwiftUI tree can expose only navigation labels through
    /// public accessibility APIs. Verify the actual rendered pixels with Vision;
    /// keep the accessibility attachment as diagnostic evidence.
    private func recognizedContents(of image: UIImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage), options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func normalized(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// SwiftUI may vend text and buttons as virtual accessibility elements rather
    /// than UILabel/UIButton subviews. Inspect both public container surfaces.
    private func accessibleContents(of root: NSObject) -> String {
        var visited = Set<ObjectIdentifier>()
        var values = [String]()
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 30, visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let label = object.accessibilityLabel { values.append(label) }
            if let value = object.accessibilityValue { values.append(value) }
            if let identifier = HostedAccessibilityTestScope.identifier(of: object) { values.append(identifier) }
            if let label = object as? UILabel, let text = label.text { values.append(text) }
            if let button = object as? UIButton, let title = button.currentTitle { values.append(title) }
            if let elements = object.accessibilityElements {
                for case let child as NSObject in elements { visit(child, depth: depth + 1) }
            }
            if #available(iOS 17.0, *), let elements = object.automationElements {
                for case let child as NSObject in elements { visit(child, depth: depth + 1) }
            }
            let count = object.accessibilityElementCount()
            if count > 0, count < 1000 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { visit(child, depth: depth + 1) }
                }
            }
            if let view = object as? UIView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return values.joined(separator: "\n")
    }
}

private struct LocalizationDismissalHarness: View {
    let job: AreaTargetProcessingJob
    let session: AreaTargetLocalizationSession
    let reportStore: LocalizationReportStore
    let onDismiss: () -> Void
    @State private var showing = false
    var body: some View {
        Color.clear.onAppear { showing = true }
            .fullScreenCover(isPresented: $showing, onDismiss: onDismiss) {
                AreaTargetMapTestView(job: job, localizer: session, reportStore: reportStore)
            }
    }
}

private final class LocalizationDismissalEngine: AreaTargetOfflineLocalizing {
    func load(url: URL) async throws -> Int { 20 }
    func localize(pixels: Data, width: Int, height: Int, intrinsics: SIMD4<Float>) async -> AreaTargetLocalizationResult? { nil }
    func close() {}
}

private final class LocalizationRenderEngine: AreaTargetOfflineLocalizing {
    private(set) var loadCount = 0
    private(set) var frameCount = 0
    func load(url: URL) async throws -> Int {
        loadCount += 1; XCTFail("Rendering must not load a native features database"); throw CancellationError()
    }
    func localize(pixels: Data, width: Int, height: Int, intrinsics: SIMD4<Float>) async -> AreaTargetLocalizationResult? {
        frameCount += 1; XCTFail("Rendering must not process native image frames"); return nil
    }
    func close() {}
}
