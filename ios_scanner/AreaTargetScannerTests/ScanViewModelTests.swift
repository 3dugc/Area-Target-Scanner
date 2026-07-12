import XCTest
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
        viewModel = ScanViewModel()
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
