import XCTest
@testable import AreaTargetScanner

@MainActor
final class DualExportViewModelTests: XCTestCase {
    func testCompletionPublishesOnlyChosenArchiveAndStaysInPreview() async throws {
        let exporter = ControlledExporter()
        let vm = ScanViewModel(exporter: exporter)
        vm.state = .preview("/tmp/scan_test")
        vm.beginExport(format: .immersal, from: "/tmp/scan_test")
        await fulfillment(of: [exporter.started], timeout: 3)
        XCTAssertTrue(vm.isExporting)
        vm.beginExport(format: .areaTarget, from: "/tmp/scan_test")
        exporter.finish.signal()
        await waitForCompletion(vm)
        XCTAssertEqual(exporter.calls, 1)
        XCTAssertEqual(vm.exportShareURL?.lastPathComponent, "scan_test_immersal.zip")
        XCTAssertEqual(vm.state, .preview("/tmp/scan_test"))
    }

    func testCancelledExportDoesNotOpenShareAndCanRetry() async throws {
        let exporter = ControlledExporter()
        let vm = ScanViewModel(exporter: exporter)
        vm.state = .preview("/tmp/scan_test")
        vm.beginExport(format: .immersal, from: "/tmp/scan_test")
        await fulfillment(of: [exporter.started], timeout: 3)
        vm.cancelExport()
        exporter.finish.signal()
        await waitForCompletion(vm)
        XCTAssertNil(vm.exportShareURL)
        XCTAssertNil(vm.exportError)
        XCTAssertEqual(vm.state, .preview("/tmp/scan_test"))
        exporter.finish.signal()
        vm.beginExport(format: .areaTarget, from: "/tmp/scan_test")
        await waitForCompletion(vm)
        XCTAssertEqual(vm.exportShareURL?.lastPathComponent, "scan_test.zip")
    }

    func testFailureLeavesPreviewAndDoesNotShare() async throws {
        let exporter = ControlledExporter(fails: true)
        let vm = ScanViewModel(exporter: exporter)
        vm.state = .preview("/tmp/scan_test")
        exporter.finish.signal()
        vm.beginExport(format: .immersal, from: "/tmp/scan_test")
        await waitForCompletion(vm)
        XCTAssertNotNil(vm.exportError)
        XCTAssertNil(vm.exportShareURL)
        XCTAssertEqual(vm.state, .preview("/tmp/scan_test"))
    }

    func testCompletionForDepartedPreviewDoesNotOpenShare() async {
        let exporter = ControlledExporter()
        let vm = ScanViewModel(exporter: exporter)
        vm.state = .preview("/tmp/scan_test")
        vm.beginExport(format: .immersal, from: "/tmp/scan_test")
        await fulfillment(of: [exporter.started], timeout: 3)
        vm.state = .preview("/tmp/another_scan")
        exporter.finish.signal()
        await waitForCompletion(vm)
        XCTAssertNil(vm.exportShareURL)
        XCTAssertNil(vm.exportError)
    }

    func testHistoryCountsAndDeletesBothArchives() throws {
        let docs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scan = docs.appendingPathComponent("scan_20260929_220000")
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: docs) }
        try Data(repeating: 1, count: 1024).write(to: scan.appendingPathExtension("zip"))
        let immersal = docs.appendingPathComponent("scan_20260929_220000_immersal.zip")
        try Data(repeating: 1, count: 2048).write(to: immersal)
        let vm = ScanViewModel(documentsDirectory: docs)
        vm.loadScanHistory()
        let item = try XCTUnwrap(vm.scanHistory.first)
        XCTAssertTrue(item.hasImmersalZip)
        XCTAssertGreaterThanOrEqual(item.totalSizeMB, 3072.0 / 1048576)
        vm.deleteScan(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: immersal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scan.appendingPathExtension("zip").path))
        XCTAssertTrue(vm.scanHistory.isEmpty)
    }

    func testUploadingScanAndItsArchivesCannotBeDeleted() throws {
        let docs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scan = docs.appendingPathComponent("scan_20260929_220000")
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: docs) }
        let archive = ScanExportFormat.immersal.archiveURL(for: scan)
        try Data([1]).write(to: archive)
        let vm = ScanViewModel(documentsDirectory: docs)
        vm.deletionBlocked = { $0 == scan.path }
        vm.loadScanHistory()
        let item = try XCTUnwrap(vm.scanHistory.first)
        vm.deleteScan(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(vm.scanHistory.count, 1)
        XCTAssertNotNil(vm.deletionError)
        vm.deletionBlocked = { _ in false }
        vm.deleteScan(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scan.path))
    }

    private func waitForCompletion(_ vm: ScanViewModel) async {
        for _ in 0..<300 {
            if !vm.isExporting { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Export did not complete")
    }
}

private final class ControlledExporter: ScanExporting {
    let started = XCTestExpectation(description: "export started")
    let finish = DispatchSemaphore(value: 0)
    private(set) var calls = 0
    private let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func availability(scanDirectory: URL, format: ScanExportFormat) -> String? { nil }
    func export(scanDirectory: URL, format: ScanExportFormat,
                progress: @escaping (String) -> Void, isCancelled: @escaping () -> Bool) throws -> URL {
        calls += 1
        started.fulfill()
        _ = finish.wait(timeout: .now() + 5)
        if isCancelled() { throw CancellationError() }
        if fails { throw NSError(domain: "disk", code: 1) }
        progress("完成")
        return URL(fileURLWithPath: scanDirectory.path + (format == .immersal ? "_immersal.zip" : ".zip"))
    }
}
