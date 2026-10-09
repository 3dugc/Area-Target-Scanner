import XCTest
@testable import AreaTargetScanner

@MainActor
final class ScannerWorkspaceTests: XCTestCase {
    func testPlatformSwitchPreservesSharedSceneAndPageAndPersistsPreference() {
        let suite = "workspace-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let workspace = ScannerWorkspace(preferences: preferences)
        XCTAssertEqual(workspace.platform, .areaTarget)
        workspace.selectScan("/tmp/scan_20260930_091600")
        XCTAssertTrue(workspace.selectPlatform(.immersal, operationInProgress: false))
        XCTAssertEqual(workspace.selectedScanPath, "/tmp/scan_20260930_091600")
        XCTAssertEqual(workspace.tab, .process)
        XCTAssertEqual(ScannerWorkspace(preferences: preferences).platform, .immersal)
        XCTAssertTrue(workspace.selectPlatform(.areaTarget, operationInProgress: false))
        XCTAssertEqual(workspace.selectedScanPath, "/tmp/scan_20260930_091600")
    }

    func testBusyOperationBlocksPlatformPageAndSceneChanges() {
        let workspace = ScannerWorkspace(preferences: nil)
        workspace.selectScan("/tmp/scan_a")
        XCTAssertFalse(workspace.selectPlatform(.immersal, operationInProgress: true))
        XCTAssertFalse(workspace.selectTab(.scan, operationInProgress: true))
        XCTAssertFalse(workspace.selectScan("/tmp/scan_b", operationInProgress: true))
        XCTAssertEqual(workspace.platform, .areaTarget)
        XCTAssertEqual(workspace.tab, .process)
        XCTAssertEqual(workspace.selectedScanPath, "/tmp/scan_a")
    }

    func testDeletingAnotherRecordPreservesSelectionAndDeletingSelectedClearsIt() {
        let workspace = ScannerWorkspace(preferences: nil)
        workspace.selectScan("/tmp/scan_a")
        workspace.didDeleteScan("/tmp/scan_b")
        XCTAssertEqual(workspace.selectedScanPath, "/tmp/scan_a")
        workspace.didDeleteScan("/tmp/scan_a")
        XCTAssertNil(workspace.selectedScanPath)
    }

    func testExportAndCloudOperationsAreSpecificToSelectedPlatform() {
        XCTAssertEqual(ScannerPlatform.areaTarget.exportFormat, .areaTarget)
        XCTAssertFalse(ScannerPlatform.areaTarget.supportsCloudMapping)
        XCTAssertEqual(ScannerPlatform.immersal.exportFormat, .immersal)
        XCTAssertTrue(ScannerPlatform.immersal.supportsCloudMapping)
    }
}
