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

    private let scanner = ARKitScannerService()
    private let scannerQueue = DispatchQueue(label: "com.areatarget.scanner.vm")
    private var progressTimer: Timer?

    var arSession: ARSession { scanner.arSession }

    // MARK: - Camera Permission

    func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
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
        let scanner = self.scanner
        scannerQueue.async { [weak self] in
            do {
                try scanner.startScan()
                Task { @MainActor in
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
                let outputPath = self?.makeExportPath() ?? ""
                let _ = try scanner.exportScanData(outputPath: outputPath) { status in
                    Task { @MainActor in
                        self?.state = .processing(status)
                    }
                }

                // Step 3: Create zip
                await MainActor.run { self?.state = .processing("正在打包ZIP...") }
                let zipPath = outputPath + ".zip"
                try self?.createZip(from: outputPath, to: zipPath)

                // Step 4: Done → preview
                await MainActor.run { self?.state = .preview(outputPath) }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { self?.state = .error(msg) }
            }
        }
    }

    func resetToReady() {
        stopProgressUpdates()
        progress = ScanProgress(
            pointCount: 0, coverageArea: 0, keyframeCount: 0, isScanning: false
        )
        state = .ready
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
            Task { @MainActor in self?.progress = prog }
        }
    }

    private func stopProgressUpdates() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - Helpers

    private nonisolated func makeExportPath() -> String {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        return docs.appendingPathComponent("scan_\(timestamp)").path
    }

    private nonisolated func createZip(from sourcePath: String, to zipPath: String) throws {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let zipURL = URL(fileURLWithPath: zipPath)
        let fm = FileManager.default
        if fm.fileExists(atPath: zipPath) {
            try fm.removeItem(at: zipURL)
        }
        var coordinatorError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: [.forUploading],
            error: &coordinatorError
        ) { tempZipURL in
            do { try fm.copyItem(at: tempZipURL, to: zipURL) }
            catch { copyError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        guard fm.fileExists(atPath: zipPath) else {
            throw NSError(domain: "ScanExport", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "创建 zip 文件失败"])
        }
    }

    // MARK: - Scan History

    /// 加载 Documents 目录下所有 scan_ 开头的扫描记录
    func loadScanHistory() {
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let docsPath = docsURL.path

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

            // 检查 ZIP
            let zipPath = dirPath + ".zip"
            item.hasZip = fm.fileExists(atPath: zipPath)

            // 计算总大小（目录 + zip）
            item.totalSizeMB = Self.directorySize(path: dirPath, fm: fm) / (1024 * 1024)
            if item.hasZip, let zipAttrs = try? fm.attributesOfItem(atPath: zipPath) {
                let zipSize = (zipAttrs[.size] as? Double) ?? 0
                item.totalSizeMB += zipSize / (1024 * 1024)
            }

            items.append(item)
        }

        scanHistory = items.sorted()
    }

    /// 删除一条扫描记录（目录 + ZIP）
    func deleteScan(_ item: ScanHistoryItem) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: item.directoryPath)
        let zipPath = item.directoryPath + ".zip"
        if fm.fileExists(atPath: zipPath) {
            try? fm.removeItem(atPath: zipPath)
        }
        scanHistory.removeAll { $0.id == item.id }
    }

    /// 显示历史列表
    func showHistory() {
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
