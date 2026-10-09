import XCTest
@testable import AreaTargetScanner

@MainActor
final class ScannerSettingsTests: XCTestCase {
    private var preferenceDomains: [String] = []

    override func tearDownWithError() throws {
        for domain in preferenceDomains {
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        }
        preferenceDomains.removeAll()
    }

    private func isolatedPreferences() throws -> UserDefaults {
        let domain = "ScannerSettingsTests.\(UUID().uuidString)"
        preferenceDomains.append(domain)
        return try XCTUnwrap(UserDefaults(suiteName: domain))
    }

    func testMissingPreferencesDefaultToQualityWithUVReconstructionEnabled() throws {
        let settings = ScannerSettings(preferences: try isolatedPreferences())

        XCTAssertEqual(settings.processingProfile, .quality)
        XCTAssertTrue(settings.uvUnwrap)
    }

    func testChangedSettingsPersistAcrossIndependentInstances() throws {
        let preferences = try isolatedPreferences()
        let original = ScannerSettings(preferences: preferences)
        original.processingProfile = .fast
        original.uvUnwrap = false

        let reopened = ScannerSettings(preferences: preferences)

        XCTAssertEqual(reopened.processingProfile, .fast)
        XCTAssertFalse(reopened.uvUnwrap)
        XCTAssertEqual(preferences.string(forKey: "scanner.settings.areaTarget.profile"), "fast")
        XCTAssertEqual(preferences.object(forKey: "scanner.settings.areaTarget.uvUnwrap") as? Bool, false)
    }

    func testQualityAndEnabledUVPersistWhenRestoredByTheUser() throws {
        let preferences = try isolatedPreferences()
        preferences.set("fast", forKey: "scanner.settings.areaTarget.profile")
        preferences.set(false, forKey: "scanner.settings.areaTarget.uvUnwrap")
        let settings = ScannerSettings(preferences: preferences)

        settings.processingProfile = .quality
        settings.uvUnwrap = true

        let reopened = ScannerSettings(preferences: preferences)
        XCTAssertEqual(reopened.processingProfile, .quality)
        XCTAssertTrue(reopened.uvUnwrap)
        XCTAssertEqual(preferences.string(forKey: "scanner.settings.areaTarget.profile"), "quality")
        XCTAssertEqual(preferences.object(forKey: "scanner.settings.areaTarget.uvUnwrap") as? Bool, true)
    }

    func testUnknownStoredProfileFallsBackToQualityAndPreservesExplicitUVChoice() throws {
        let preferences = try isolatedPreferences()
        preferences.set("future-profile", forKey: "scanner.settings.areaTarget.profile")
        preferences.set(false, forKey: "scanner.settings.areaTarget.uvUnwrap")

        let settings = ScannerSettings(preferences: preferences)

        XCTAssertEqual(settings.processingProfile, .quality)
        XCTAssertFalse(settings.uvUnwrap)
    }

    func testResetToDefaultsPersistsQualityAndEnabledUV() throws {
        let preferences = try isolatedPreferences()
        let settings = ScannerSettings(preferences: preferences)
        settings.processingProfile = .fast
        settings.uvUnwrap = false

        settings.resetToDefaults()

        XCTAssertEqual(settings.processingProfile, .quality)
        XCTAssertTrue(settings.uvUnwrap)
        let reopened = ScannerSettings(preferences: preferences)
        XCTAssertEqual(reopened.processingProfile, .quality)
        XCTAssertTrue(reopened.uvUnwrap)
    }

    func testNilPreferencesKeepChangesIsolatedFromOtherSettingsInstances() {
        let settings = ScannerSettings(preferences: nil)
        settings.processingProfile = .fast
        settings.uvUnwrap = false

        let independent = ScannerSettings(preferences: nil)

        XCTAssertEqual(settings.processingProfile, .fast)
        XCTAssertFalse(settings.uvUnwrap)
        XCTAssertEqual(independent.processingProfile, .quality)
        XCTAssertTrue(independent.uvUnwrap)
    }
}
