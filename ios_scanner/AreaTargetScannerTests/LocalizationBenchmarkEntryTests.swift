import XCTest
import SwiftUI
import UIKit
import Vision
@testable import AreaTargetScanner

@MainActor
final class LocalizationBenchmarkEntryTests: XCTestCase {
    private let path = "/fixtures/scan_20261008_120000"
    private let source = String(repeating: "a", count: 64)

    func testNoSelectedScanKeepsEntryUnavailableWithReason() {
        let result = readiness(path: nil)
        XCTAssertEqual(result.state, .noScan)
        XCTAssertFalse(result.canOpen)
        XCTAssertFalse(result.message.isEmpty)
    }

    func testBothPlatformsCanUseSameReadyPairWithoutChangingSelection() {
        for platform in ScannerPlatform.allCases {
            let workspace = ScannerWorkspace(preferences: nil, platform: platform, selectedScanPath: path)
            let result = readiness(path: workspace.selectedScanPath)
            XCTAssertTrue(result.canOpen)
            XCTAssertEqual(result.state, .ready)
            XCTAssertEqual(result.areaJob?.scanDirectoryPath, path)
            XCTAssertEqual(result.immersalJob?.scanName, URL(fileURLWithPath: path).lastPathComponent)
            XCTAssertEqual(workspace.platform, platform)
        }
    }

    func testCompletedCloudMapsStillRequireVerifiedLocalDownloads() {
        XCTAssertEqual(readiness(areaReady: false).state, .areaAssetMissing)
        XCTAssertEqual(readiness(immersalReady: false).state, .immersalMapMissing)
        XCTAssertFalse(readiness(immersalReady: false).canOpen)
    }

    func testRequiresDownloadedAreaAndCompletedImmersalWithValidMapID() {
        var area = areaJob(); area.phase = .ready
        XCTAssertEqual(readiness(area: area).state, .areaNotDownloaded)
        area = areaJob(); area.savedAsset = nil
        XCTAssertEqual(readiness(area: area).state, .areaNotDownloaded)
        var immersal = immersalJob(); immersal.phase = .processing
        XCTAssertEqual(readiness(immersal: immersal).state, .immersalNotCompleted)
        immersal = immersalJob(); immersal.mapID = 0
        XCTAssertEqual(readiness(immersal: immersal).state, .immersalNotCompleted)
    }

    func testUnknownAndDifferentOriginalSourcesCannotPair() {
        var area = areaJob(); area.sourceFingerprint = nil
        var immersal = immersalJob(); immersal.sourceFingerprint = nil
        XCTAssertEqual(readiness(area: area, immersal: immersal).state, .unknownSource)
        area = areaJob(); area.sourceFingerprint = "legacy"
        XCTAssertEqual(readiness(area: area).state, .unknownSource)
        area = areaJob(); immersal = immersalJob(); immersal.sourceFingerprint = String(repeating: "b", count: 64)
        XCTAssertEqual(readiness(area: area, immersal: immersal).state, .sourceMismatch)
        XCTAssertFalse(readiness(area: area, immersal: immersal).canOpen)
    }

    func testCompletedImmersalWithUnrecordedSourceExplainsUnknownProvenance() {
        var immersal = immersalJob(); immersal.sourceFingerprint = nil
        XCTAssertEqual(readiness(immersal: immersal).state, .unknownSource)
    }

    func testSameFingerprintFromAnotherScanIsNotSelectedScanPair() {
        var area = areaJob()
        area = AreaTargetProcessingJob(id: area.id, scanDirectoryPath: "/fixtures/scan_other",
            displayName: "Other", createdAt: area.createdAt)
        area.phase = .downloaded; area.sourceFingerprint = source; area.savedAsset = areaJob().savedAsset
        XCTAssertEqual(readiness(area: area).state, .areaNotDownloaded)
        var immersal = immersalJob()
        immersal = ImmersalMappingJob(id: immersal.id, userID: immersal.userID,
            scanName: "scan_other", mapName: immersal.mapName, createdAt: immersal.createdAt)
        immersal.phase = .done; immersal.mapID = 42; immersal.sourceFingerprint = source
        XCTAssertEqual(readiness(immersal: immersal).state, .immersalNotCompleted)
    }

    func testPairSelectsNewestCompletedMatchingJobForSelectedScan() {
        let area = areaJob()
        let old = immersalJob(date: Date(timeIntervalSince1970: 1))
        let newest = immersalJob(date: Date(timeIntervalSince1970: 2))
        var differentSource = immersalJob(date: Date(timeIntervalSince1970: 3))
        differentSource.sourceFingerprint = String(repeating: "b", count: 64)
        let result = ScannerWorkspace.benchmarkReadiness(for: path, areaJobs: [area],
            immersalJobs: [old, differentSource, newest], areaAssetReady: { _ in true }, immersalMapReady: { _ in true })
        XCTAssertEqual(result.immersalJob?.id, newest.id)
        XCTAssertTrue(result.canOpen)
    }

    func testSavedAreaAssetIdentityMustMatchItsJob() {
        var area = areaJob()
        let wrong = areaJob(id: "different-map").savedAsset
        area.savedAsset = wrong
        XCTAssertEqual(readiness(area: area).state, .areaAssetMissing)
    }

    private func readiness(path: String? = "/fixtures/scan_20261008_120000", area: AreaTargetProcessingJob? = nil,
                           immersal: ImmersalMappingJob? = nil, areaReady: Bool = true,
                           immersalReady: Bool = true) -> LocalizationBenchmarkReadiness {
        ScannerWorkspace.benchmarkReadiness(for: path, areaJobs: [area ?? areaJob()],
            immersalJobs: [immersal ?? immersalJob()], areaAssetReady: { _ in areaReady }, immersalMapReady: { _ in immersalReady })
    }

    private func areaJob(id: String = "area-map") -> AreaTargetProcessingJob {
        let directory = URL(fileURLWithPath: path)
        var job = AreaTargetProcessingJob(id: id, scanDirectoryPath: path, displayName: "Fixture", createdAt: Date())
        job.phase = .downloaded; job.sourceFingerprint = source
        job.savedAsset = AreaTargetSavedAsset(jobID: id, bundleURL: directory.appendingPathComponent("bundle.zip"),
            directoryURL: directory, modelURL: directory.appendingPathComponent("optimized.glb"),
            featuresURL: directory.appendingPathComponent("features.db"), manifestURL: directory.appendingPathComponent("manifest.json"),
            savedAt: Date())
        return job
    }

    private func immersalJob(date: Date = Date()) -> ImmersalMappingJob {
        var job = ImmersalMappingJob(id: UUID(), userID: 7, scanName: URL(fileURLWithPath: path).lastPathComponent,
            mapName: "Fixture", createdAt: date)
        job.phase = .done; job.mapID = 42; job.sourceFingerprint = source
        return job
    }
}

@MainActor
final class LocalizationBenchmarkRenderTests: XCTestCase {
    func testProcessPageAlwaysShowsComparisonEntryInBothPlatforms() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BenchmarkProcessRender-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ScanViewModel(documentsDirectory: root, cameraAuthorizationStatus: { .denied },
            requestCameraAccess: { _ in XCTFail("Showing the process page must not request camera access") })
        for platform in ScannerPlatform.allCases {
            let view = ScanProcessingView(viewModel: model, platform: platform, scan: nil,
                selectRecord: {}, rename: { _ in }, preview: { _ in }, upload: { _ in }, showTasks: {})
            try await render(view, name: "benchmark-process-\(platform.rawValue)",
                expected: ["算法比较", "录制视频", "运行两套算法", "查看报告", "选择一个扫描场景"])
        }
    }

    func testOpeningComparisonDoesNotStartCameraOrReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BenchmarkRender-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var cameraRequests = 0; var trackingRuns = 0
        let localizer = LocalizationBenchmarkSession(recordingStore: .init(rootDirectory: root.appendingPathComponent("recordings")),
            reportStore: .init(rootDirectory: root.appendingPathComponent("reports")),
            requestCamera: { cameraRequests += 1; return false }, runSession: { _ in trackingRuns += 1 })
        let directory = root.appendingPathComponent("scan_20261008_120000")
        var area = AreaTargetProcessingJob(id: UUID().uuidString.lowercased(), scanDirectoryPath: directory.path,
            displayName: "合成测试大厅", createdAt: Date())
        area.phase = .downloaded; area.sourceFingerprint = String(repeating: "a", count: 64)
        area.savedAsset = .init(jobID: area.id, bundleURL: directory.appendingPathComponent("bundle.zip"),
            directoryURL: directory, modelURL: directory.appendingPathComponent("optimized.glb"),
            featuresURL: directory.appendingPathComponent("features.db"), manifestURL: directory.appendingPathComponent("manifest.json"),
            savedAt: Date())
        var immersal = ImmersalMappingJob(id: UUID(), userID: 1_918_264_535, scanName: directory.lastPathComponent,
            mapName: "SyntheticMap", createdAt: Date())
        immersal.phase = .done; immersal.mapID = 1_923_846_264; immersal.sourceFingerprint = area.sourceFingerprint
        try await render(LocalizationBenchmarkView(areaJob: area, immersalJob: immersal,
            scanDirectory: directory, localizer: localizer,
            areaAssetStore: AreaTargetAssetStore(rootDirectory: root.appendingPathComponent("assets")),
            mapStore: ImmersalMapStore(rootURL: root.appendingPathComponent("maps"))), name: "benchmark-initial-comparison",
            expected: ["录像算法比较", "开始录制视频", "合成测试大厅"])
        XCTAssertEqual(cameraRequests, 0)
        XCTAssertEqual(trackingRuns, 0)
        XCTAssertEqual(localizer.stage, .idle)
        XCTAssertEqual(localizer.frameCount, 0)
        XCTAssertNil(localizer.report)
    }

    /// App-hosted SwiftUI does not consistently expose view identifiers through
    /// UIView's public accessibility containers. Assert visible pixels and keep
    /// the accessibility tree as diagnostic evidence for the separate UI automation.
    private func render<V: View>(_ view: V, name: String, expected: [String]) async throws {
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: view
            .environment(\.scenePhase, .active)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.sizeCategory, .large))
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let window = UIWindow(frame: bounds)
        host.overrideUserInterfaceStyle = .light; window.overrideUserInterfaceStyle = .light
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        host.view.frame = bounds
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 350_000_000)
        host.view.layoutIfNeeded()
        let accessibility = XCTAttachment(string: accessibleContents(of: window))
        accessibility.name = name + "-accessibility"; accessibility.lifetime = .keepAlways; add(accessibility)

        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            rendered = host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered, "The native \(name) screen must finish rendering")
        XCTAssertEqual(image.size, bounds.size)
        let screenshot = XCTAttachment(image: image)
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage), options: [:]).perform([request])
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let evidence = XCTAttachment(string: recognized)
        evidence.name = name + "-recognized-text"; evidence.lifetime = .keepAlways; add(evidence)
        for value in expected {
            XCTAssertTrue(normalized(recognized).contains(normalized(value)),
                "\(name) must visibly render: \(value). Recognized text: \(recognized)")
        }
    }

    private func normalized(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private func accessibleContents(of root: NSObject) -> String {
        var visited = Set<ObjectIdentifier>()
        var values = [String]()
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 30, visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let label = object.accessibilityLabel { values.append(label) }
            if let identifier = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier { values.append(identifier) }
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
