import XCTest
import SwiftUI
import UIKit
@testable import AreaTargetScanner

@MainActor
final class ScannerSettingsViewTests: XCTestCase {
    func testSeparateSettingsControlsChangeSharedPreferencesWithoutStartingJobs() async throws {
        let settings = ScannerSettings(preferences: nil)
        let host = UIHostingController(rootView: ScannerSettingsView(settings: settings))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.frame = window.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 100_000_000); host.view.layoutIfNeeded()
        let picker = try XCTUnwrap(descendants(host.view, of: UISegmentedControl.self).first)
        XCTAssertEqual(picker.titleForSegment(at: 0), "Quality")
        XCTAssertEqual(picker.titleForSegment(at: 1), "Fast")
        XCTAssertEqual(picker.selectedSegmentIndex, 0)
        picker.selectedSegmentIndex = 1; picker.sendActions(for: .valueChanged)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(settings.processingProfile, .fast)
        let toggle = try XCTUnwrap(descendants(host.view, of: UISwitch.self).first)
        XCTAssertTrue(toggle.isOn)
        toggle.setOn(false, animated: false); toggle.sendActions(for: .valueChanged)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(settings.uvUnwrap)
    }

    func testSettingsRenderInLightDarkAndNarrowLargeText() async throws {
        let fixtures: [(String, CGFloat, UIUserInterfaceStyle, ContentSizeCategory)] = [
            ("settings-light", 393, .light, .large),
            ("settings-dark", 393, .dark, .large),
            ("settings-large-text-320", 320, .light, .accessibilityLarge)
        ]
        for (name, width, style, size) in fixtures {
            let settings = ScannerSettings(preferences: nil)
            let host = UIHostingController(rootView: ScannerSettingsView(settings: settings)
                .environment(\.sizeCategory, size).environment(\.colorScheme, style == .dark ? .dark : .light))
            host.overrideUserInterfaceStyle = style
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 852))
            window.overrideUserInterfaceStyle = style
            window.rootViewController = host; window.makeKeyAndVisible(); host.view.frame = window.bounds
            try await Task.sleep(nanoseconds: 100_000_000); host.view.layoutIfNeeded()
            XCTAssertEqual(host.traitCollection.userInterfaceStyle, style)
            let picker = try XCTUnwrap(descendants(host.view, of: UISegmentedControl.self).first)
            XCTAssertEqual(picker.selectedSegmentIndex, 0)
            XCTAssertEqual(settings.processingProfile, .quality)
            XCTAssertTrue(settings.uvUnwrap)
            var drawn = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                drawn = host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(drawn)
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true; window.rootViewController = nil
        }
    }

    private func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
    }
}
