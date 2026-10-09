import XCTest
import AVFoundation
import CoreLocation
@testable import AreaTargetScanner

@MainActor
final class ScanMetadataTests: XCTestCase {
    private let isolationRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScanMetadataTests-\(UUID().uuidString)", isDirectory: true)
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: isolationRoot)
        try super.tearDownWithError()
    }

    func testApplicationOpensReadyWithoutRequestingCameraPermission() {
        XCTAssertEqual(ScanViewModel(documentsDirectory: isolationRoot).state, .ready)
    }

    func testNavigationCannotAbandonActiveCapture() {
        let vm = ScanViewModel(documentsDirectory: isolationRoot)
        for state in [ScanViewModel.State.scanning, .processing("保存中")] {
            vm.state = state
            vm.resetToReady()
            XCTAssertEqual(vm.state, state)
            vm.showHistory()
            XCTAssertEqual(vm.state, state)
            XCTAssertTrue(vm.isCaptureBusy)
        }
    }

    func testStoppingWithoutAnActiveCaptureDoesNothing() {
        let vm = ScanViewModel(documentsDirectory: isolationRoot)
        vm.state = .ready
        vm.stopAndProcess()
        XCTAssertEqual(vm.state, .ready)
    }

    func testLegacyScanUsesReadableDateWithoutCreatingMetadata() throws {
        let docs = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: docs) }
        let scan = try makeScan(in: docs)
        let vm = ScanViewModel(documentsDirectory: docs)
        vm.loadScanHistory()
        let item = try XCTUnwrap(vm.scanHistory.first)
        XCTAssertEqual(item.displayName, "扫描 \(item.formattedDate)")
        XCTAssertEqual(vm.sceneName(for: scan.path), item.displayName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: docs.appendingPathComponent(".scanner-metadata").path))
    }

    func testRenamePersistsChineseSpacesWithoutChangingScanIdentityPayloadOrEitherArchive() throws {
        let docs = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: docs) }
        let scan = try makeScan(in: docs)
        let payload = Data("{\"scanName\":\"immutable\",\"mapName\":\"original\"}".utf8)
        try payload.write(to: scan.appendingPathComponent("poses.json"))
        let areaZip = ScanExportFormat.areaTarget.archiveURL(for: scan)
        let immersalZip = ScanExportFormat.immersal.archiveURL(for: scan)
        let areaBytes = Data([1, 5, 8, 3])
        let immersalBytes = Data([7, 2, 9, 4])
        try areaBytes.write(to: areaZip)
        try immersalBytes.write(to: immersalZip)
        let vm = ScanViewModel(documentsDirectory: docs)
        vm.loadScanHistory()
        let originalID = try XCTUnwrap(vm.scanHistory.first?.id)
        XCTAssertTrue(vm.renameScan(at: scan.path, to: "  一楼 大厅  \n"))
        XCTAssertEqual(vm.scanHistory.first?.displayName, "一楼 大厅")

        let reloaded = ScanViewModel(documentsDirectory: docs)
        reloaded.loadScanHistory()
        XCTAssertEqual(reloaded.sceneName(for: scan.path), "一楼 大厅")
        XCTAssertEqual(reloaded.scanHistory.first?.id, originalID)
        XCTAssertEqual(reloaded.scanHistory.first?.directoryPath, scan.path)
        XCTAssertEqual(try Data(contentsOf: scan.appendingPathComponent("poses.json")), payload)
        XCTAssertEqual(try Data(contentsOf: areaZip), areaBytes)
        XCTAssertEqual(try Data(contentsOf: immersalZip), immersalBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scan.path), ["poses.json"])
    }

    func testInvalidRenamePreservesExistingNameAndAcceptsSixtyGraphemes() throws {
        let docs = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: docs) }
        let scan = try makeScan(in: docs)
        let vm = ScanViewModel(documentsDirectory: docs)
        XCTAssertTrue(vm.renameScan(at: scan.path, to: "原名"))
        for invalid in [" \n\t", String(repeating: "界", count: 61)] {
            XCTAssertFalse(vm.renameScan(at: scan.path, to: invalid))
            XCTAssertNotNil(vm.namingError)
            XCTAssertEqual(vm.sceneName(for: scan.path), "原名")
        }
        let sixtyGraphemes = String(repeating: "👨‍👩‍👧‍👦", count: 60)
        XCTAssertTrue(vm.renameScan(at: scan.path, to: sixtyGraphemes))
        XCTAssertEqual(vm.sceneName(for: scan.path), sixtyGraphemes)
        XCTAssertNil(vm.namingError)
    }

    func testMalformedMetadataIsReportedAndNeverOverwritten() throws {
        let docs = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: docs) }
        let scan = try makeScan(in: docs)
        let store = ScanMetadataStore(documentsDirectory: docs)
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("{invalid existing metadata".utf8)
        try corrupt.write(to: store.fileURL)
        let vm = ScanViewModel(documentsDirectory: docs, metadataStore: store)
        vm.loadScanHistory()
        XCTAssertEqual(vm.scanHistory.count, 1)
        XCTAssertNotNil(vm.namingError)
        XCTAssertFalse(vm.renameScan(at: scan.path, to: "新名"))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
    }

    func testUnreadableMetadataIsNotTreatedAsMissing() throws {
        let docs = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: docs) }
        let scan = try makeScan(in: docs)
        let store = ScanMetadataStore(documentsDirectory: docs)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        let vm = ScanViewModel(documentsDirectory: docs, metadataStore: store)
        XCTAssertFalse(vm.renameScan(at: scan.path, to: "新名"))
        XCTAssertNotNil(vm.namingError)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testRenameWriteFailureDoesNotPublishAnUnsavedName() throws {
        let docs = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: docs) }
        let scan = try makeScan(in: docs)
        try Data([1]).write(to: docs.appendingPathComponent(".scanner-metadata"))
        let vm = ScanViewModel(documentsDirectory: docs)
        vm.loadScanHistory()
        let originalName = vm.scanHistory.first?.displayName
        XCTAssertFalse(vm.renameScan(at: scan.path, to: "无法保存"))
        XCTAssertNotNil(vm.namingError)
        XCTAssertEqual(vm.scanHistory.first?.displayName, originalName)
    }

    func testDeletingScanClearsSavedName() throws {
        let docs = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: docs) }
        let scan = try makeScan(in: docs)
        let vm = ScanViewModel(documentsDirectory: docs)
        XCTAssertTrue(vm.renameScan(at: scan.path, to: "待删除场景"))
        vm.loadScanHistory()
        vm.deleteScan(try XCTUnwrap(vm.scanHistory.first))
        XCTAssertTrue(vm.scanHistory.isEmpty)
        XCTAssertNil(vm.deletionError)
        _ = try makeScan(in: docs)
        vm.loadScanHistory()
        XCTAssertEqual(vm.scanHistory.first?.sceneName, nil)
        XCTAssertNotEqual(vm.sceneName(for: scan.path), "待删除场景")
    }

    func testFailedScanDeletionReportsErrorAndRetainsHistoryRow() throws {
        let docs = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: docs) }
        let scan = try makeScan(in: docs)
        let vm = ScanViewModel(documentsDirectory: docs)
        vm.loadScanHistory()
        let item = try XCTUnwrap(vm.scanHistory.first)
        try FileManager.default.removeItem(at: scan)
        vm.deleteScan(item)
        XCTAssertNotNil(vm.deletionError)
        XCTAssertEqual(vm.scanHistory.count, 1)
    }

    func testPendingStartBlocksDuplicateStartNavigationDeletionAndExport() async throws {
        let docs = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: docs) }
        let scan = try makeScan(in: docs)
        let scanner = MetadataTestScanner()
        let exporter = MetadataTestExporter()
        let vm = makeViewModel(documents: docs, scanner: scanner, exporter: exporter)
        vm.loadScanHistory()
        let item = try XCTUnwrap(vm.scanHistory.first)
        vm.startScanning()
        XCTAssertTrue(vm.isStartingScan)
        XCTAssertTrue(vm.isCaptureBusy)
        vm.startScanning()
        vm.resetToReady()
        vm.showHistory()
        vm.deleteScan(item)
        vm.beginExport(format: .areaTarget, from: scan.path)
        vm.stopAndProcess()
        XCTAssertFalse(vm.isExporting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.path))
        XCTAssertNotNil(vm.deletionError)
        await waitUntil { vm.state == .scanning }
        XCTAssertEqual(scanner.startCalls, 1)
        XCTAssertEqual(scanner.stopCalls, 0)
        vm.stopAndProcess()
        await waitUntil { !vm.isCaptureBusy }
        XCTAssertEqual(exporter.exportCalls, 0)
    }

    func testPermissionGrantResumesRequestedCaptureAndDenialKeepsDraft() async throws {
        let docs = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: docs) }
        let scanner = MetadataTestScanner()
        var permissionCompletion: ((Bool) -> Void)?
        let vm = makeViewModel(documents: docs, scanner: scanner, cameraStatus: { .notDetermined },
                               cameraRequest: { permissionCompletion = $0 })
        vm.draftSceneName = "等待授权"
        vm.startScanning()
        XCTAssertEqual(vm.state, .requestingPermission)
        XCTAssertTrue(vm.isStartingScan)
        XCTAssertNotNil(permissionCompletion)
        permissionCompletion?(false)
        await waitUntil { vm.state == .permissionDenied }
        XCTAssertFalse(vm.isCaptureBusy)
        XCTAssertEqual(vm.draftSceneName, "等待授权")
        XCTAssertEqual(scanner.startCalls, 0)
        vm.startScanning()
        permissionCompletion?(true)
        await waitUntil { vm.state == .scanning }
        XCTAssertEqual(scanner.startCalls, 1)
        vm.stopAndProcess()
        await waitUntil { !vm.isCaptureBusy }
    }

    func testInvalidDraftDoesNotStartCaptureAndBlankDraftUsesDateName() async throws {
        let docs = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: docs) }
        let scanner = MetadataTestScanner()
        let vm = makeViewModel(documents: docs, scanner: scanner)
        vm.draftSceneName = String(repeating: "名", count: 61)
        vm.startScanning()
        XCTAssertFalse(vm.isCaptureBusy)
        XCTAssertNotNil(vm.namingError)
        XCTAssertEqual(scanner.startCalls, 0)
        vm.draftSceneName = "  "
        vm.startScanning()
        await waitUntil { vm.state == .scanning }
        vm.stopAndProcess()
        await waitUntil { !vm.isCaptureBusy }
        let item = try XCTUnwrap(vm.scanHistory.first)
        XCTAssertEqual(item.displayName, "扫描 \(item.formattedDate)")
        XCTAssertEqual(item.sceneName, item.displayName)
    }

    func testSuccessfulCaptureSavesNativeDataOnceAndNameWithoutAutomaticZip() async throws {
        let docs = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: docs) }
        let scanner = MetadataTestScanner()
        let exporter = MetadataTestExporter()
        let vm = makeViewModel(documents: docs, scanner: scanner, exporter: exporter)
        vm.draftSceneName = "  二楼 展厅  "
        vm.startScanning()
        await waitUntil { vm.state == .scanning }
        vm.stopAndProcess()
        vm.stopAndProcess()
        await waitUntil { !vm.isCaptureBusy }
        guard case .preview(let path) = vm.state else { return XCTFail("Expected saved scan preview") }
        XCTAssertEqual(scanner.saveCalls, 1)
        XCTAssertEqual(scanner.stopCalls, 1)
        XCTAssertEqual(exporter.exportCalls, 0)
        XCTAssertEqual(vm.sceneName(for: path), "二楼 展厅")
        XCTAssertEqual(vm.scanHistory.first?.displayName, "二楼 展厅")
        XCTAssertEqual(vm.draftSceneName, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("native.scan").path))
        for format in ScanExportFormat.allCases {
            XCTAssertFalse(FileManager.default.fileExists(atPath: format.archiveURL(for: URL(fileURLWithPath: path)).path))
        }
    }

    func testConsecutiveCapturesKeepSeparateDirectoryIdentities() async throws {
        let docs = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: docs) }
        let vm = makeViewModel(documents: docs, scanner: MetadataTestScanner())
        for name in ["第一个场景", "第二个场景"] {
            vm.draftSceneName = name
            vm.startScanning()
            await waitUntil { vm.state == .scanning }
            vm.stopAndProcess()
            await waitUntil { !vm.isCaptureBusy }
        }
        XCTAssertEqual(vm.scanHistory.count, 2)
        XCTAssertEqual(Set(vm.scanHistory.map(\.id)).count, 2)
        XCTAssertEqual(Set(vm.scanHistory.map(\.displayName)), Set(["第一个场景", "第二个场景"]))
    }

    func testCaptureNameFailurePreservesSavedScanAndReportsProblem() async throws {
        let docs = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: docs) }
        let store = ScanMetadataStore(documentsDirectory: docs)
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("unreadable metadata".utf8)
        try corrupt.write(to: store.fileURL)
        let vm = makeViewModel(documents: docs, scanner: MetadataTestScanner())
        vm.draftSceneName = "场景名称"
        vm.startScanning()
        await waitUntil { vm.state == .scanning }
        vm.stopAndProcess()
        await waitUntil { !vm.isCaptureBusy }
        guard case .preview(let path) = vm.state else { return XCTFail("Scan must survive name persistence failure") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertNotNil(vm.namingError)
        XCTAssertEqual(vm.scanHistory.count, 1)
        XCTAssertEqual(vm.draftSceneName, "")
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
    }

    func testFailedCaptureKeepsDraftNameForRetry() async throws {
        let docs = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: docs) }
        let scanner = MetadataTestScanner()
        scanner.failSaving = true
        let vm = makeViewModel(documents: docs, scanner: scanner)
        vm.draftSceneName = "保留这个名字"
        vm.startScanning()
        await waitUntil { vm.state == .scanning }
        vm.stopAndProcess()
        await waitUntil { !vm.isCaptureBusy }
        guard case .error = vm.state else { return XCTFail("Expected save failure") }
        XCTAssertEqual(vm.draftSceneName, "保留这个名字")
        XCTAssertTrue(vm.scanHistory.isEmpty)
    }

    private func makeDocuments() throws -> URL {
        let docs = FileManager.default.temporaryDirectory.appendingPathComponent("ScanMetadataTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    private func makeScan(in docs: URL) throws -> URL {
        let scan = docs.appendingPathComponent("scan_20260929_220000")
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        return scan
    }

    private func makeViewModel(documents: URL, scanner: ScannerService,
                               exporter: ScanExporting = MetadataTestExporter(),
                               cameraStatus: @escaping () -> AVAuthorizationStatus = { .authorized },
                               cameraRequest: @escaping (@escaping (Bool) -> Void) -> Void = { $0(true) }) -> ScanViewModel {
        ScanViewModel(exporter: exporter, documentsDirectory: documents, scanner: scanner,
                      locationService: ScanLocationService(manager: MetadataTestLocationManager()),
                      cameraAuthorizationStatus: cameraStatus, requestCameraAccess: cameraRequest)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<300 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Capture operation did not complete")
    }
}

private final class MetadataTestScanner: ScannerService {
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var saveCalls = 0
    var failSaving = false
    func startScan() throws { startCalls += 1 }
    func stopScan() throws -> ScanResult {
        stopCalls += 1
        return ScanResult(pointCloudVertices: [], images: [], cameraPoses: [],
                          intrinsics: CameraIntrinsics(fx: 0, fy: 0, cx: 0, cy: 0, width: 0, height: 0))
    }
    func exportScanData(outputPath: String, onProgress: ((String) -> Void)?) throws -> Bool {
        saveCalls += 1
        if failSaving { throw ScannerError.exportFailed(reason: "Test write failure") }
        let scan = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        try Data("Native scan".utf8).write(to: scan.appendingPathComponent("native.scan"))
        return true
    }
    func getScanProgress() -> ScanProgress {
        ScanProgress(pointCount: 1000, coverageArea: 1, keyframeCount: 1, isScanning: stopCalls == 0)
    }
}

private final class MetadataTestExporter: ScanExporting {
    private(set) var exportCalls = 0
    func availability(scanDirectory: URL, format: ScanExportFormat) -> String? { nil }
    func export(scanDirectory: URL, format: ScanExportFormat,
                progress: @escaping (String) -> Void, isCancelled: @escaping () -> Bool) throws -> URL {
        exportCalls += 1
        return format.archiveURL(for: scanDirectory)
    }
}

private final class MetadataTestLocationManager: ScanLocationManaging {
    var authorizationStatus: CLAuthorizationStatus = .denied
    var desiredAccuracy: CLLocationAccuracy = 0
    var delegate: CLLocationManagerDelegate?
    func requestWhenInUseAuthorization() {}
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}
}
