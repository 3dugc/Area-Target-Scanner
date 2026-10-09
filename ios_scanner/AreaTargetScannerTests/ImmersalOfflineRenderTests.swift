import XCTest
import SwiftUI
import UIKit
import simd
@testable import AreaTargetScanner

/// Synthetic report fixtures are restricted to these tests. Rendering never starts
/// localization, requests camera permission, accesses Keychain, or downloads data.
@MainActor
final class ImmersalOfflineRenderTests: XCTestCase {
    private var root: URL!
    private var store: ImmersalMapStore!
    private var api: OfflineRenderDownloader!
    private var credentials: OfflineRenderCredentials!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ImmersalOfflineRender-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ImmersalMapStore(rootURL: root)
        api = OfflineRenderDownloader()
        credentials = OfflineRenderCredentials()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testDownloadPromptAndCachedMapRenderWithoutStartingLocalization() async throws {
        let initial = await model()
        XCTAssertNil(initial.mapURL)
        XCTAssertNil(initial.savedReport)
        try await attachScreen(mapView(initial), name: "offline-download-light")

        try store.save(data: Data([1, 2, 3, 4]), userID: 7, mapID: 123)
        let cached = await model()
        XCTAssertNotNil(cached.mapURL)
        XCTAssertNil(cached.savedReport, "A cached map must not supply a prefilled field-test report")
        try await attachScreen(mapView(cached), name: "offline-cached-light")
        try await attachScreen(mapView(cached), name: "offline-cached-dark", style: .dark)
        try await attachScreen(mapView(cached), name: "offline-cached-large-text", sizeCategory: .accessibilityExtraLarge)
        XCTAssertEqual(api.callCount, 0)
        XCTAssertEqual(credentials.loadCount, 0)
    }

    func testStoredInsufficientAndSufficientReportFixturesRenderOffline() async throws {
        try store.save(data: Data([1, 2, 3, 4]), userID: 7, mapID: 123)
        let vm = await model()
        let insufficient = fixtureReport(sufficient: false)
        XCTAssertFalse(insufficient.sampleSufficient)
        vm.save(insufficient)
        try await attachScreen(mapView(vm), name: "offline-quality-fixture-insufficient-light")

        let sufficient = fixtureReport(sufficient: true)
        XCTAssertTrue(sufficient.sampleSufficient)
        vm.save(sufficient)
        try await attachScreen(mapView(vm), name: "offline-quality-fixture-sufficient-light")
        try await attachScreen(mapView(vm), name: "offline-quality-fixture-sufficient-dark", style: .dark)
        try await attachScreen(mapView(vm), name: "offline-quality-fixture-sufficient-large-text",
                               sizeCategory: .accessibilityExtraLarge)
        XCTAssertEqual(vm.savedReport, sufficient)
        XCTAssertEqual(api.callCount, 0)
        XCTAssertEqual(credentials.loadCount, 0)
    }

    func testReportDetailFixturesRenderLightDarkAndLargeText() async throws {
        for (sufficient, name, style, sizeCategory) in [
            (false, "offline-report-detail-insufficient-light", UIUserInterfaceStyle.light, ContentSizeCategory.large),
            (true, "offline-report-detail-sufficient-light", .light, .large),
            (true, "offline-report-detail-sufficient-dark", .dark, .large),
            (true, "offline-report-detail-sufficient-large-text", .light, .accessibilityExtraLarge)
        ] {
            let report = fixtureReport(sufficient: sufficient)
            let detail = NavigationStack {
                ScrollView {
                    ImmersalQualityReportView(report: report)
                        .padding(24)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("离线测试报告样本")
                .navigationBarTitleDisplayMode(.inline)
            }
            try await attachScreen(detail, name: name, style: style, sizeCategory: sizeCategory)
        }
        XCTAssertEqual(api.callCount, 0)
        XCTAssertEqual(credentials.loadCount, 0)
    }

    private func model() async -> ImmersalMapTestModel {
        let vm = ImmersalMapTestModel(mapID: 123, userID: 7, api: api, store: store, credentials: credentials)
        for _ in 0..<200 {
            if !vm.isRestoring { return vm }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Offline map restoration must finish before rendering")
        return vm
    }

    private func mapView(_ model: ImmersalMapTestModel) -> some View {
        ImmersalMapTestView(mapID: 123, userID: 7, sceneName: "测试大厅", model: model,
            reportStore: LocalizationReportStore(rootDirectory: root.appendingPathComponent("reports")))
    }

    private func fixtureReport(sufficient: Bool) -> ImmersalLocalizationQualityReport {
        var accumulator = ImmersalLocalizationQualityAccumulator()
        let count = sufficient ? 40 : 8
        for index in 0..<count {
            var transform = matrix_identity_float4x4
            transform.columns.3.x = Float(index % 3) * 0.015
            accumulator.record(success: index % 10 != 0, elapsed: Double(index) * 1.5,
                               latency: 0.35 + Double(index % 5) * 0.05,
                               worldFromMap: transform, cameraPosition: SIMD3(Float(index) * 0.15, 0, 0))
        }
        return accumulator.report(mapID: 123, userID: 7, date: Date(timeIntervalSince1970: 1_790_730_960))
    }

    private func attachScreen<V: View>(_ view: V, name: String, style: UIUserInterfaceStyle = .light,
                                       sizeCategory: ContentSizeCategory = .large) async throws {
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: view
            .environment(\.scenePhase, .active)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 8 * 3600)!)
            .environment(\.sizeCategory, sizeCategory))
        host.overrideUserInterfaceStyle = style
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let window = UIWindow(frame: bounds)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        host.view.frame = bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 350_000_000)
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            rendered = host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered, "The native \(name) screen must render before attachment")
        XCTAssertEqual(image.size, bounds.size)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private final class OfflineRenderDownloader: ImmersalMapDownloading {
    private(set) var callCount = 0
    func downloadMap(mapID: Int, token: String) async throws -> Data {
        callCount += 1
        XCTFail("Offline screenshots must not request a map download")
        throw CancellationError()
    }
}

private final class OfflineRenderCredentials: ImmersalCredentialStoring {
    private(set) var loadCount = 0
    func load() throws -> ImmersalCredential? {
        loadCount += 1
        XCTFail("Offline screenshots must not access credentials")
        throw CocoaError(.fileReadNoPermission)
    }
    func save(_ credential: ImmersalCredential) throws { XCTFail("Rendering must not save credentials") }
    func clear() throws { XCTFail("Rendering must not clear credentials") }
}
