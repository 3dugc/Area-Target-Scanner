import XCTest
import AVFoundation
@testable import AreaTargetScanner

/// Tests for ScanViewModel state machine and utility methods.
///
/// Validates:
/// - State enum equality
/// - modelURL file discovery logic
/// - exportedFiles listing
/// - zipURL / shareURLs logic
/// - resetToReady state transition
/// - Initial state
@MainActor
final class ScanViewModelTests: XCTestCase {

    private var viewModel: ScanViewModel!
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        viewModel = ScanViewModel(cameraAuthorizationStatus: { .authorized })
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanVMTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Scan deletion protection

    func testDeleteScanLegacyBlockPreservesCaptureAndBothArchivesWithoutAssumingService() throws {
        let scan = tempDir.appendingPathComponent("scan_20261005_150000", isDirectory: true)
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        let source = scan.appendingPathComponent("capture.jpg")
        let sourceBytes = Data("original capture".utf8)
        try sourceBytes.write(to: source)
        let areaArchive = ScanExportFormat.areaTarget.archiveURL(for: scan)
        let immersalArchive = ScanExportFormat.immersal.archiveURL(for: scan)
        let areaBytes = Data("area-target archive".utf8)
        let immersalBytes = Data("immersal archive".utf8)
        try areaBytes.write(to: areaArchive)
        try immersalBytes.write(to: immersalArchive)
        let model = ScanViewModel(documentsDirectory: tempDir)
        model.loadScanHistory()
        let item = try XCTUnwrap(model.scanHistory.first)
        var checkedPaths: [String] = []
        model.deletionBlocked = { path in checkedPaths.append(path); return true }

        model.deleteScan(item)

        XCTAssertEqual(checkedPaths, [scan.path])
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: areaArchive), areaBytes)
        XCTAssertEqual(try Data(contentsOf: immersalArchive), immersalBytes)
        XCTAssertEqual(model.scanHistory.map(\.id), [item.id])
        let reason = try XCTUnwrap(model.deletionError)
        XCTAssertFalse(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(reason.contains("Immersal"), "A legacy boolean guard does not identify the blocking service")
        XCTAssertFalse(reason.contains("Area Target"), "The fallback must not guess which cloud service needs the source")

        model.deletionBlocked = { _ in false }
        model.deleteScan(item)

        XCTAssertNil(model.deletionError)
        XCTAssertTrue(model.scanHistory.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: areaArchive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: immersalArchive.path))
    }

    func testDeleteScanProvidedReasonPreservesOriginalUntilCleared() throws {
        for reason in ["Area Target 上传仍需要原扫描。", "Immersal 上传仍需要原扫描。", "Area Target 和 Immersal 上传仍需要原扫描。"] {
            let fixture = try makeDeletionFixture()
            var sourceNeeded = true
            var requestedPaths: [String] = []
            fixture.model.deletionBlocked = { _ in false }
            fixture.model.deletionBlockReason = { path in
                requestedPaths.append(path)
                return sourceNeeded && path == fixture.item.directoryPath ? reason : nil
            }

            fixture.model.deleteScan(fixture.item)

            XCTAssertEqual(requestedPaths, [fixture.item.directoryPath])
            XCTAssertEqual(fixture.model.deletionError, reason)
            try assertDeletionFixturePreserved(fixture)

            sourceNeeded = false
            fixture.model.deleteScan(fixture.item)

            assertDeletionFixtureRemoved(fixture)
        }
    }

    func testDeleteScanMissingOrWhitespaceReasonFallsBackToLegacyGuard() throws {
        let missingReasons: [String?] = [nil, " \n\t "]
        for reason in missingReasons {
            let fixture = try makeDeletionFixture()
            var sourceNeeded = true
            fixture.model.deletionBlockReason = { _ in reason }
            fixture.model.deletionBlocked = { path in sourceNeeded && path == fixture.item.directoryPath }

            fixture.model.deleteScan(fixture.item)

            let displayed = try XCTUnwrap(fixture.model.deletionError)
            XCTAssertFalse(displayed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(displayed.contains("Immersal"))
            XCTAssertFalse(displayed.contains("Area Target"))
            try assertDeletionFixturePreserved(fixture)

            sourceNeeded = false
            fixture.model.deleteScan(fixture.item)

            assertDeletionFixtureRemoved(fixture)
        }
    }

    private struct DeletionFixture {
        let model: ScanViewModel
        let item: ScanHistoryItem
        let source: URL
        let sourceBytes: Data
        let archives: [URL: Data]
    }

    private func makeDeletionFixture() throws -> DeletionFixture {
        let scan = tempDir.appendingPathComponent("scan_20261005_160000", isDirectory: true)
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        let source = scan.appendingPathComponent("capture.jpg")
        let sourceBytes = Data("original scan capture".utf8)
        try sourceBytes.write(to: source)
        let archives = [ScanExportFormat.areaTarget.archiveURL(for: scan): Data("area-target archive".utf8),
                        ScanExportFormat.immersal.archiveURL(for: scan): Data("immersal archive".utf8)]
        for (url, bytes) in archives { try bytes.write(to: url) }
        let model = ScanViewModel(documentsDirectory: tempDir)
        model.loadScanHistory()
        let item = try XCTUnwrap(model.scanHistory.first)
        return DeletionFixture(model: model, item: item, source: source, sourceBytes: sourceBytes, archives: archives)
    }

    private func assertDeletionFixturePreserved(_ fixture: DeletionFixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes, file: file, line: line)
        for (url, bytes) in fixture.archives {
            XCTAssertEqual(try Data(contentsOf: url), bytes, file: file, line: line)
        }
        XCTAssertEqual(fixture.model.scanHistory.map(\.id), [fixture.item.id], file: file, line: line)
    }

    private func assertDeletionFixtureRemoved(_ fixture: DeletionFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(fixture.model.deletionError, file: file, line: line)
        XCTAssertTrue(fixture.model.scanHistory.isEmpty, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.item.directoryPath), file: file, line: line)
        for url in fixture.archives.keys {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), file: file, line: line)
        }
    }

    // MARK: - State Enum Tests

    func testState_equatable_sameCase() {
        XCTAssertEqual(ScanViewModel.State.ready, ScanViewModel.State.ready)
        XCTAssertEqual(ScanViewModel.State.scanning, ScanViewModel.State.scanning)
        XCTAssertEqual(ScanViewModel.State.permissionDenied, ScanViewModel.State.permissionDenied)
    }

    func testState_equatable_differentCase() {
        XCTAssertNotEqual(ScanViewModel.State.ready, ScanViewModel.State.scanning)
        XCTAssertNotEqual(ScanViewModel.State.scanning, ScanViewModel.State.permissionDenied)
    }

    func testState_equatable_processingWithSameMessage() {
        XCTAssertEqual(
            ScanViewModel.State.processing("导出中"),
            ScanViewModel.State.processing("导出中")
        )
    }

    func testState_equatable_processingWithDifferentMessage() {
        XCTAssertNotEqual(
            ScanViewModel.State.processing("导出中"),
            ScanViewModel.State.processing("打包中")
        )
    }

    func testState_equatable_errorWithSameMessage() {
        XCTAssertEqual(
            ScanViewModel.State.error("失败"),
            ScanViewModel.State.error("失败")
        )
    }

    func testState_equatable_previewWithPath() {
        XCTAssertEqual(
            ScanViewModel.State.preview("/path/a"),
            ScanViewModel.State.preview("/path/a")
        )
        XCTAssertNotEqual(
            ScanViewModel.State.preview("/path/a"),
            ScanViewModel.State.preview("/path/b")
        )
    }

    // MARK: - Initial State

    func testInitialState_isRequestingPermission() {
        XCTAssertEqual(viewModel.state, .requestingPermission)
    }

    func testInitialProgress_isZero() {
        XCTAssertEqual(viewModel.progress.pointCount, 0)
        XCTAssertEqual(viewModel.progress.coverageArea, 0)
        XCTAssertEqual(viewModel.progress.keyframeCount, 0)
        XCTAssertFalse(viewModel.progress.isScanning)
    }

    // MARK: - Camera permission protection

    func testHistoryAndPreviewResetKeepsDeniedCameraPermissionAndOriginalScan() throws {
        let fixture = try makeDeletionFixture()
        for status in [AVAuthorizationStatus.denied, .restricted] {
            for priorState in [ScanViewModel.State.history, .preview(fixture.item.directoryPath)] {
                let model = ScanViewModel(documentsDirectory: tempDir, cameraAuthorizationStatus: { status })
                model.loadScanHistory()
                model.state = priorState
                model.progress = ScanProgress(pointCount: 123, coverageArea: 2, keyframeCount: 7, isScanning: true)

                model.resetToReady()

                XCTAssertEqual(model.state, .permissionDenied)
                XCTAssertEqual(model.progress.pointCount, 0)
                XCTAssertEqual(model.progress.keyframeCount, 0)
                XCTAssertFalse(model.progress.isScanning)
                XCTAssertEqual(model.scanHistory.map(\.id), [fixture.item.id])
                XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
                for (url, bytes) in fixture.archives { XCTAssertEqual(try Data(contentsOf: url), bytes) }
            }
        }
    }

    func testHistoryResetWithUndeterminedCameraReturnsPermissionRequestState() {
        let model = ScanViewModel(cameraAuthorizationStatus: { .notDetermined })
        model.state = .history

        model.resetToReady()

        XCTAssertEqual(model.state, .requestingPermission)
        XCTAssertFalse(model.progress.isScanning)
    }

    func testStartScanningWithoutCameraAuthorizationCannotLeavePermissionState() async throws {
        let fixture = try makeDeletionFixture()
        let cases: [(AVAuthorizationStatus, ScanViewModel.State)] = [
            (.denied, .permissionDenied), (.restricted, .permissionDenied), (.notDetermined, .requestingPermission),
        ]
        for (status, expectedState) in cases {
            var authorizationReads = 0
            let model = ScanViewModel(documentsDirectory: tempDir, cameraAuthorizationStatus: {
                authorizationReads += 1
                return status
            })
            model.loadScanHistory()
            // A stale UI ready state cannot bypass a current denied permission.
            model.state = .ready

            model.startScanning()
            try await Task.sleep(nanoseconds: 20_000_000)

            XCTAssertGreaterThan(authorizationReads, 0)
            XCTAssertEqual(model.state, expectedState)
            XCTAssertFalse(model.progress.isScanning)
            XCTAssertEqual(model.scanHistory.map(\.id), [fixture.item.id])
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
        }
    }

    func testReturningFromSettingsRefreshesCameraPermissionScreens() {
        var authorization = AVAuthorizationStatus.denied
        var reads = 0
        let model = ScanViewModel(cameraAuthorizationStatus: {
            reads += 1
            return authorization
        })
        model.state = .permissionDenied
        authorization = .authorized
        model.setAppActive(false)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(model.state, .permissionDenied)

        model.setAppActive(true)
        XCTAssertEqual(model.state, .ready, "Granting permission in Settings must unlock scanning after returning")
        XCTAssertGreaterThan(reads, 0)

        model.state = .requestingPermission
        authorization = .denied
        model.setAppActive(true)
        XCTAssertEqual(model.state, .permissionDenied)
    }

    func testForegroundPermissionRefreshDoesNotInterruptExistingScanWork() {
        let states: [ScanViewModel.State] = [.history, .preview("saved-scan"), .scanning, .processing("处理中"), .ready, .error("保留错误")]
        for state in states {
            var reads = 0
            let model = ScanViewModel(cameraAuthorizationStatus: {
                reads += 1
                return .authorized
            })
            model.state = state
            model.progress = ScanProgress(pointCount: 123, coverageArea: 2, keyframeCount: 7, isScanning: state == .scanning)
            model.setAppActive(true)
            XCTAssertEqual(model.state, state)
            XCTAssertEqual(model.progress.pointCount, 123)
            XCTAssertEqual(model.progress.keyframeCount, 7)
            XCTAssertEqual(reads, 0, "Foreground activation must not reset a record or an in-progress scan")
        }
    }

    // MARK: - resetToReady

    func testResetToReady_setsStateToReady() {
        viewModel.state = .scanning
        viewModel.resetToReady()
        XCTAssertEqual(viewModel.state, .ready)
    }

    func testResetToReady_resetsProgress() {
        viewModel.progress = ScanProgress(
            pointCount: 5000, coverageArea: 10.0, keyframeCount: 20, isScanning: true
        )
        viewModel.resetToReady()
        XCTAssertEqual(viewModel.progress.pointCount, 0)
        XCTAssertEqual(viewModel.progress.coverageArea, 0)
        XCTAssertEqual(viewModel.progress.keyframeCount, 0)
        XCTAssertFalse(viewModel.progress.isScanning)
    }

    // MARK: - modelURL

    func testModelURL_noFiles_returnsNil() {
        let url = viewModel.modelURL(for: tempDir.path)
        XCTAssertNil(url)
    }

    func testModelURL_usdzExists_returnsUSDZ() throws {
        let usdzPath = tempDir.appendingPathComponent("model.usdz")
        try Data("usdz".utf8).write(to: usdzPath)

        let url = viewModel.modelURL(for: tempDir.path)
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.lastPathComponent == "model.usdz")
    }

    func testModelURL_usdaExists_returnsUSDA() throws {
        let usdaPath = tempDir.appendingPathComponent("model.usda")
        try Data("usda".utf8).write(to: usdaPath)

        let url = viewModel.modelURL(for: tempDir.path)
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.lastPathComponent == "model.usda")
    }

    func testModelURL_objExists_returnsOBJ() throws {
        let objPath = tempDir.appendingPathComponent("model.obj")
        try Data("obj".utf8).write(to: objPath)

        let url = viewModel.modelURL(for: tempDir.path)
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.lastPathComponent == "model.obj")
    }

    func testModelURL_priorityOrder_usdzOverUsda() throws {
        try Data("usdz".utf8).write(to: tempDir.appendingPathComponent("model.usdz"))
        try Data("usda".utf8).write(to: tempDir.appendingPathComponent("model.usda"))
        try Data("obj".utf8).write(to: tempDir.appendingPathComponent("model.obj"))

        let url = viewModel.modelURL(for: tempDir.path)
        XCTAssertEqual(url?.lastPathComponent, "model.usdz",
            "USDZ should be preferred over USDA and OBJ")
    }

    func testModelURL_texturedObjPreferredOverUntexturedUSDA() throws {
        try Data("usda".utf8).write(to: tempDir.appendingPathComponent("model.usda"))
        try Data("obj".utf8).write(to: tempDir.appendingPathComponent("model.obj"))
        try Data("mtl".utf8).write(to: tempDir.appendingPathComponent("model.mtl"))
        try Data("texture".utf8).write(to: tempDir.appendingPathComponent("texture.jpg"))

        let url = viewModel.modelURL(for: tempDir.path)
        XCTAssertEqual(url?.lastPathComponent, "model.obj",
            "Textured OBJ should be preferred over untextured USDA")
    }

    func testModelURL_untexturedUsdaPreferredOverUntexturedOBJ() throws {
        try Data("usda".utf8).write(to: tempDir.appendingPathComponent("model.usda"))
        try Data("obj".utf8).write(to: tempDir.appendingPathComponent("model.obj"))

        let url = viewModel.modelURL(for: tempDir.path)
        XCTAssertEqual(url?.lastPathComponent, "model.usda",
            "USDA should remain the fallback before untextured OBJ")
    }

    // MARK: - exportedFiles

    func testExportedFiles_nonexistentDir_returnsPlaceholder() {
        let files = viewModel.exportedFiles(for: "/nonexistent/path")
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].contains("目录不存在"))
    }

    func testExportedFiles_emptyDir_returnsEmpty() {
        let files = viewModel.exportedFiles(for: tempDir.path)
        XCTAssertEqual(files.count, 0)
    }

    func testExportedFiles_withFiles_returnsSorted() throws {
        try Data("a".utf8).write(to: tempDir.appendingPathComponent("c.txt"))
        try Data("b".utf8).write(to: tempDir.appendingPathComponent("a.txt"))
        try Data("c".utf8).write(to: tempDir.appendingPathComponent("b.txt"))

        let files = viewModel.exportedFiles(for: tempDir.path)
        XCTAssertEqual(files, ["a.txt", "b.txt", "c.txt"])
    }

    // MARK: - zipURL / shareURLs

    func testZipURL_noZipFile_returnsNil() {
        let url = viewModel.zipURL(for: tempDir.path)
        XCTAssertNil(url)
    }

    func testZipURL_zipExists_returnsURL() throws {
        let zipPath = tempDir.path + ".zip"
        try Data("zip".utf8).write(to: URL(fileURLWithPath: zipPath))
        defer { try? FileManager.default.removeItem(atPath: zipPath) }

        let url = viewModel.zipURL(for: tempDir.path)
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.path.hasSuffix(".zip"))
    }

    func testShareURLs_noZip_returnsEmpty() {
        let urls = viewModel.shareURLs(for: tempDir.path)
        XCTAssertTrue(urls.isEmpty)
    }

    func testShareURLs_withZip_returnsZipURL() throws {
        let zipPath = tempDir.path + ".zip"
        try Data("zip".utf8).write(to: URL(fileURLWithPath: zipPath))
        defer { try? FileManager.default.removeItem(atPath: zipPath) }

        let urls = viewModel.shareURLs(for: tempDir.path)
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls[0].path.hasSuffix(".zip"))
    }
}
