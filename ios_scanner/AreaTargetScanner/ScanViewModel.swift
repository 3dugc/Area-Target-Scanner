import Foundation
import AVFoundation
import ARKit

@MainActor
final class ScanViewModel: ObservableObject {

    enum State: Equatable {
        case requestingPermission
        case permissionDenied
        case ready
        case scanning
        case processing(String) // status message
        case preview(String)    // export directory path
        case error(String)
        case history            // 扫描历史列表
    }

    @Published var state: State = .requestingPermission
    @Published var progress = ScanProgress(
        pointCount: 0, coverageArea: 0, keyframeCount: 0, isScanning: false
    )
    @Published var scanHistory: [ScanHistoryItem] = []
    @Published var deletionError: String?
    var deletionBlocked: (String) -> Bool = { _ in false }
    /// A nonempty reason protects the scan; nil or blank keeps the legacy guard in effect.
    var deletionBlockReason: ((String) -> String?)?

    @Published var gpsStatus = "GPS 未开启"
    @Published private(set) var exportStatus: String?
    @Published var exportError: String?
    @Published var exportShareURL: URL?
    @Published private(set) var immersalUnavailableReason: String? = "正在检查扫描数据…"
    private var eligibilityID: UUID?
    var isExporting: Bool { exportStatus != nil }

    private let scanner = ARKitScannerService()
    private let exporter: ScanExporting
    private let documentsDirectory: URL
    private let cameraAuthorizationStatus: () -> AVAuthorizationStatus
    private let locationService: ScanLocationService
    private var exportID: UUID?
    private var exportCancellation: ScanExportCancellation?

    init(exporter: ScanExporting = ScanExportService(),
         documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!,
         cameraAuthorizationStatus: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) }) {
        self.exporter = exporter
        self.documentsDirectory = documentsDirectory
        self.cameraAuthorizationStatus = cameraAuthorizationStatus
        self.locationService = ScanLocationService(store: scanner.locationStore)
        locationService.$status.assign(to: &$gpsStatus)
    }

    func setAppActive(_ active: Bool) {
        locationService.setAppActive(active)
        guard active else { return }
        switch state {
        case .permissionDenied, .requestingPermission: checkCameraPermission()
        default: break
        }
    }

    func prepareExportAvailability(for path: String) async {
        let id = UUID()
        eligibilityID = id
        immersalUnavailableReason = "正在检查扫描数据…"
        let exporter = self.exporter
        let result = await Task.detached(priority: .userInitiated) {
            exporter.availability(scanDirectory: URL(fileURLWithPath: path), format: .immersal)
        }.value
        guard !Task.isCancelled, eligibilityID == id else { return }
        immersalUnavailableReason = result
    }

    func beginExport(format: ScanExportFormat, from path: String) {
        guard !isExporting else { return }
        let directory = URL(fileURLWithPath: path)
        let id = UUID()
        let cancellation = ScanExportCancellation()
        exportID = id
        exportCancellation = cancellation
        exportShareURL = nil
        exportError = nil
        exportStatus = "正在准备导出…"
        let exporter = self.exporter
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            try exporter.export(scanDirectory: directory, format: format, progress: { status in
                Task { @MainActor in
                    guard let self, self.exportID == id, !cancellation.isCancelled else { return }
                    self.exportStatus = status
                }
            }, isCancelled: { cancellation.isCancelled })
        }
        Task { [weak self] in
            let result = await worker.result
            guard let self, self.exportID == id else { return }
            self.exportID = nil
            self.exportCancellation = nil
            self.exportStatus = nil
            guard !cancellation.isCancelled, self.state == .preview(path) else { return }
            switch result {
            case .success(let url): self.exportShareURL = url
            case .failure(let error): self.exportError = error.localizedDescription
            }
        }
    }

    func cancelExport() {
        guard isExporting else { return }
        exportCancellation?.cancel()
        exportStatus = "正在取消…"
    }

    private let scannerQueue = DispatchQueue(label: "com.areatarget.scanner.vm")
    private var progressTimer: Timer?

    var arSession: ARSession { scanner.arSession }

    // MARK: - Camera Permission

    func checkCameraPermission() {
        switch cameraAuthorizationStatus() {
        case .authorized:
            state = .ready
        case .notDetermined:
            state = .requestingPermission
        case .denied, .restricted:
            state = .permissionDenied
        @unknown default:
            state = .requestingPermission
        }
    }

    func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                self?.state = granted ? .ready : .permissionDenied
            }
        }
    }

    // MARK: - Scan Control

    func startScanning() {
        guard !isExporting else { return }
        guard cameraAuthorizationStatus() == .authorized else {
            checkCameraPermission()
            return
        }
        let scanner = self.scanner
        scannerQueue.async { [weak self] in
            do {
                try scanner.startScan()
                Task { @MainActor in
                    self?.locationService.start()
                    self?.state = .scanning
                    self?.startProgressUpdates()
                }
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor in self?.state = .error(msg) }
            }
        }
    }

    /// Stop scanning → immediately start processing → auto-preview
    func stopAndProcess() {
        stopProgressUpdates()
        locationService.stop()
        let outputPath = makeExportPath()
        let exporter = self.exporter
        state = .processing("正在停止扫描...")

        let scanner = self.scanner
        Task.detached { [weak self] in
            do {
                // Step 1: Stop scan
                let _ = try scanner.stopScan()
                let prog = scanner.getScanProgress()
                await MainActor.run { self?.progress = prog }

                // Step 2: Export data with progress callback
                await MainActor.run { self?.state = .processing("正在准备导出...") }
                let _ = try scanner.exportScanData(outputPath: outputPath) { status in
                    Task { @MainActor in
                        self?.state = .processing(status)
                    }
                }

                // Step 3: Create zip
                await MainActor.run { self?.state = .processing("正在打包ZIP...") }
                do {
                    _ = try exporter.export(scanDirectory: URL(fileURLWithPath: outputPath), format: .areaTarget,
                                            progress: { _ in }, isCancelled: { false })
                    await MainActor.run { self?.state = .preview(outputPath) }
                } catch {
                    // The saved scan is usable even when automatic ZIP creation fails.
                    let message = error.localizedDescription
                    await MainActor.run {
                        self?.state = .preview(outputPath)
                        self?.exportError = "扫描已保存，打包失败，可在导出中重试：\(message)"
                    }
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { self?.state = .error(msg) }
            }
        }
    }

    func resetToReady() {
        guard !isExporting else { return }
        locationService.stop()
        stopProgressUpdates()
        progress = ScanProgress(
            pointCount: 0, coverageArea: 0, keyframeCount: 0, isScanning: false
        )
        checkCameraPermission()
    }

    /// Find a previewable 3D model file in the export directory.
    /// Prefer textured formats for preview: USDZ, then OBJ only when its MTL and texture are present.
    func modelURL(for exportPath: String) -> URL? {
        let fm = FileManager.default

        let usdzPath = (exportPath as NSString).appendingPathComponent("model.usdz")
        if fm.fileExists(atPath: usdzPath) {
            return URL(fileURLWithPath: usdzPath)
        }

        let objPath = (exportPath as NSString).appendingPathComponent("model.obj")
        let mtlPath = (exportPath as NSString).appendingPathComponent("model.mtl")
        let texturePath = (exportPath as NSString).appendingPathComponent("texture.jpg")
        if fm.fileExists(atPath: objPath),
           fm.fileExists(atPath: mtlPath),
           fm.fileExists(atPath: texturePath) {
            return URL(fileURLWithPath: objPath)
        }

        let usdaPath = (exportPath as NSString).appendingPathComponent("model.usda")
        if fm.fileExists(atPath: usdaPath) {
            return URL(fileURLWithPath: usdaPath)
        }

        if fm.fileExists(atPath: objPath) {
            return URL(fileURLWithPath: objPath)
        }
        return nil
    }

    /// List all files in the export directory (for debugging)
    func exportedFiles(for exportPath: String) -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: exportPath) else {
            return ["(目录不存在)"]
        }
        return items.sorted()
    }

    /// Get the zip file URL for sharing
    func zipURL(for exportPath: String) -> URL? {
        let path = exportPath + ".zip"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// Get all shareable file URLs in the export directory
    func shareURLs(for exportPath: String) -> [URL] {
        var urls: [URL] = []
        // Prefer zip if available
        if let zip = zipURL(for: exportPath) {
            urls.append(zip)
        }
        return urls
    }

    // MARK: - Progress Updates

    private func startProgressUpdates() {
        let scanner = self.scanner
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
            let prog = scanner.getScanProgress()
            Task { @MainActor in
                self?.progress = prog
                self?.locationService.refreshStatus()
            }
        }
    }

    private func stopProgressUpdates() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - Helpers

    private func makeExportPath() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return documentsDirectory.appendingPathComponent("scan_\(formatter.string(from: Date()))").path
    }

    // MARK: - Scan History

    /// 加载 Documents 目录下所有 scan_ 开头的扫描记录
    func loadScanHistory() {
        let fm = FileManager.default
        let docsPath = documentsDirectory.path

        guard let contents = try? fm.contentsOfDirectory(atPath: docsPath) else { return }

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var items: [ScanHistoryItem] = []
        for name in contents {
            guard name.hasPrefix("scan_"),
                  let date = ScanHistoryItem.parseDate(from: name) else { continue }

            let dirPath = (docsPath as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }

            var item = ScanHistoryItem(
                id: name,
                directoryPath: dirPath,
                date: date,
                formattedDate: displayFormatter.string(from: date)
            )

            // 读取元数据
            if let files = try? fm.contentsOfDirectory(atPath: dirPath) {
                item.fileCount = files.count
                item.hasTexture = files.contains("texture.jpg")

                // 统计关键帧数
                let imagesDir = (dirPath as NSString).appendingPathComponent("images")
                if let imgFiles = try? fm.contentsOfDirectory(atPath: imagesDir) {
                    item.keyframeCount = imgFiles.filter { $0.hasSuffix(".jpg") }.count
                }
            }

            let directory = URL(fileURLWithPath: dirPath)
            item.hasZip = fm.fileExists(atPath: ScanExportFormat.areaTarget.archiveURL(for: directory).path)
            item.hasImmersalZip = fm.fileExists(atPath: ScanExportFormat.immersal.archiveURL(for: directory).path)
            item.totalSizeMB = Self.directorySize(path: dirPath, fm: fm) / (1024 * 1024)
            for format in ScanExportFormat.allCases {
                if let attrs = try? fm.attributesOfItem(atPath: format.archiveURL(for: directory).path),
                   let size = attrs[.size] as? NSNumber {
                    item.totalSizeMB += size.doubleValue / (1024 * 1024)
                }
            }

            items.append(item)
        }

        scanHistory = items.sorted()
    }

    /// 删除一条扫描记录（目录 + ZIP）
    func deleteScan(_ item: ScanHistoryItem) {
        guard !isExporting else { return }
        if let reason = deletionBlockReason?(item.directoryPath)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            deletionError = reason
            return
        }
        guard !deletionBlocked(item.directoryPath) else {
            deletionError = "云端任务仍需要这条扫描。请先到任务页完成上传，或确认相关任务已不再需要原始数据，再删除扫描。"
            return
        }
        deletionError = nil
        let fm = FileManager.default
        try? fm.removeItem(atPath: item.directoryPath)
        for format in ScanExportFormat.allCases {
            try? fm.removeItem(at: format.archiveURL(for: URL(fileURLWithPath: item.directoryPath)))
        }
        scanHistory.removeAll { $0.id == item.id }
    }

    /// 显示历史列表
    func showHistory() {
        guard !isExporting else { return }
        loadScanHistory()
        state = .history
    }

    // MARK: - Size Calculation

    private static func directorySize(path: String, fm: FileManager) -> Double {
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Double = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? Double {
                total += size
            }
        }
        return total
    }
}
