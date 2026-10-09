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

    @Published var state: State = .ready
    @Published var progress = ScanProgress(
        pointCount: 0, coverageArea: 0, keyframeCount: 0, isScanning: false
    )
    @Published var scanHistory: [ScanHistoryItem] = []
    @Published var deletionError: String?
    @Published var draftSceneName = ""
    @Published var namingError: String?
    @Published private(set) var isStartingScan = false
    var deletionBlocked: (String) -> Bool = { _ in false }
    /// A nonempty reason protects the scan; nil or blank keeps the legacy guard in effect.
    var deletionBlockReason: ((String) -> String?)?

    var isCaptureBusy: Bool {
        if isStartingScan { return true }
        switch state {
        case .scanning, .processing: return true
        default: return false
        }
    }

    @Published var gpsStatus = "GPS 未开启"
    @Published private(set) var exportStatus: String?
    @Published var exportError: String?
    @Published var exportShareURL: URL?
    @Published private(set) var immersalUnavailableReason: String? = "正在检查扫描数据…"
    private var eligibilityID: UUID?
    var isExporting: Bool { exportStatus != nil }

    private let arScanner: ARKitScannerService
    private let scanner: ScannerService
    private let exporter: ScanExporting
    private let documentsDirectory: URL
    private let locationService: ScanLocationService
    private let metadataStore: ScanMetadataStore
    private let cameraAuthorizationStatus: () -> AVAuthorizationStatus
    private let requestCameraAccess: (@escaping (Bool) -> Void) -> Void
    private var savedSceneNames: [String: String] = [:]
    private var lastMetadataReadError: String?
    private var captureSceneName: String?
    private var exportID: UUID?
    private var exportCancellation: ScanExportCancellation?

    init(exporter: ScanExporting = ScanExportService(),
         documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!,
         metadataStore: ScanMetadataStore? = nil,
         scanner: ScannerService? = nil,
         locationService: ScanLocationService? = nil,
         cameraAuthorizationStatus: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) },
         requestCameraAccess: @escaping (@escaping (Bool) -> Void) -> Void = { AVCaptureDevice.requestAccess(for: .video, completionHandler: $0) }) {
        let arScanner = ARKitScannerService()
        self.arScanner = arScanner
        self.scanner = scanner ?? arScanner
        self.exporter = exporter
        self.documentsDirectory = documentsDirectory
        self.metadataStore = metadataStore ?? ScanMetadataStore(documentsDirectory: documentsDirectory)
        self.cameraAuthorizationStatus = cameraAuthorizationStatus
        self.requestCameraAccess = requestCameraAccess
        self.locationService = locationService ?? ScanLocationService(store: arScanner.locationStore)
        self.locationService.$status.assign(to: &$gpsStatus)
        refreshSceneNames()
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
        guard !isExporting, !isCaptureBusy else { return }
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

    var arSession: ARSession { arScanner.arSession }

    // MARK: - Camera Permission

    func checkCameraPermission() {
        guard !isCaptureBusy, !isExporting else { return }
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
        startScanning()
    }

    // MARK: - Scan Control

    func startScanning() {
        guard !isExporting, !isCaptureBusy else { return }
        let trimmed = draftSceneName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            captureSceneName = trimmed.isEmpty ? nil : try ScanMetadataStore.normalizedName(trimmed)
        } catch {
            namingError = error.localizedDescription
            return
        }
        namingError = nil
        isStartingScan = true
        switch cameraAuthorizationStatus() {
        case .authorized:
            startAuthorizedScan()
        case .notDetermined:
            state = .requestingPermission
            requestCameraAccess { [weak self] granted in
                Task { @MainActor in
                    guard let self, self.isStartingScan else { return }
                    if granted {
                        self.startAuthorizedScan()
                    } else {
                        self.isStartingScan = false
                        self.captureSceneName = nil
                        self.state = .permissionDenied
                    }
                }
            }
        case .denied, .restricted:
            isStartingScan = false
            captureSceneName = nil
            state = .permissionDenied
        @unknown default:
            isStartingScan = false
            captureSceneName = nil
            state = .permissionDenied
        }
    }

    private func startAuthorizedScan() {
        let scanner = self.scanner
        scannerQueue.async { [weak self] in
            do {
                try scanner.startScan()
                Task { @MainActor in
                    guard let self else { return }
                    self.state = .scanning
                    self.isStartingScan = false
                    self.locationService.start()
                    self.startProgressUpdates()
                }
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor in
                    self?.isStartingScan = false
                    self?.captureSceneName = nil
                    self?.state = .error(msg)
                }
            }
        }
    }

    /// Save the native scan once; each platform exports its archive explicitly later.
    func stopAndProcess() {
        guard state == .scanning, !isStartingScan else { return }
        stopProgressUpdates()
        locationService.stop()
        let outputPath = makeExportPath()
        let sceneName = captureSceneName ?? defaultSceneName(for: outputPath)
        state = .processing("正在停止扫描...")

        let scanner = self.scanner
        scannerQueue.async { [weak self] in
            do {
                let _ = try scanner.stopScan()
                let prog = scanner.getScanProgress()
                Task { @MainActor in self?.progress = prog }

                let saved = try scanner.exportScanData(outputPath: outputPath) { status in
                    Task { @MainActor in
                        guard let self, case .processing = self.state else { return }
                        self.state = .processing(status)
                    }
                }
                guard saved else { throw ScannerError.exportFailed(reason: "扫描数据未能保存") }
                Task { @MainActor in
                    self?.finishSavedScan(at: outputPath, sceneName: sceneName)
                }
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor in
                    self?.captureSceneName = nil
                    self?.state = .error(msg)
                }
            }
        }
    }

    func resetToReady() {
        guard !isExporting, !isCaptureBusy else { return }
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
        var date = Date()
        while true {
            let directory = documentsDirectory.appendingPathComponent("scan_\(formatter.string(from: date))")
            let candidates = [directory] + ScanExportFormat.allCases.map { $0.archiveURL(for: directory) }
            if candidates.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) {
                return directory.path
            }
            date = date.addingTimeInterval(1)
        }
    }

    // MARK: - Shared Scene Names

    func sceneName(for path: String) -> String {
        let scanID = URL(fileURLWithPath: path).lastPathComponent
        return savedSceneNames[scanID] ?? defaultSceneName(for: path)
    }

    @discardableResult
    func renameScan(at path: String, to name: String) -> Bool {
        guard !isCaptureBusy else {
            namingError = "请等待当前扫描保存完成后再修改场景名称。"
            return false
        }
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard directory.deletingLastPathComponent().path == documentsDirectory.standardizedFileURL.path,
              ScanHistoryItem.parseDate(from: directory.lastPathComponent) != nil,
              FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            namingError = "找不到这条扫描记录，无法修改名称。"
            return false
        }
        do {
            let normalized = try ScanMetadataStore.normalizedName(name)
            try metadataStore.setSceneName(normalized, for: directory.lastPathComponent)
            savedSceneNames[directory.lastPathComponent] = normalized
            if let index = scanHistory.firstIndex(where: { $0.id == directory.lastPathComponent }) {
                scanHistory[index].sceneName = normalized
            }
            namingError = nil
            lastMetadataReadError = nil
            return true
        } catch {
            namingError = error.localizedDescription
            return false
        }
    }

    private func defaultSceneName(for path: String) -> String {
        let scanID = URL(fileURLWithPath: path).lastPathComponent
        guard let date = ScanHistoryItem.parseDate(from: scanID) else { return scanID }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "扫描 \(formatter.string(from: date))"
    }

    private func refreshSceneNames() {
        do {
            savedSceneNames = try metadataStore.sceneNames()
            lastMetadataReadError = nil
        } catch {
            let message = error.localizedDescription
            if lastMetadataReadError != message {
                namingError = message
                lastMetadataReadError = message
            }
        }
    }

    private func finishSavedScan(at path: String, sceneName: String) {
        var nameSaveError: String?
        do {
            try metadataStore.setSceneName(sceneName, for: URL(fileURLWithPath: path).lastPathComponent)
        } catch {
            nameSaveError = "扫描已保存，但场景名称保存失败：\(error.localizedDescription)"
        }
        loadScanHistory()
        if let nameSaveError { namingError = nameSaveError }
        draftSceneName = ""
        captureSceneName = nil
        state = .preview(path)
    }

    // MARK: - Scan History

    /// 加载 Documents 目录下所有 scan_ 开头的扫描记录
    func loadScanHistory() {
        refreshSceneNames()
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
                formattedDate: displayFormatter.string(from: date),
                sceneName: savedSceneNames[name]
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
        guard !isExporting, !isCaptureBusy else {
            deletionError = "请等待当前扫描或导出完成后再删除扫描。"
            return
        }
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
        do {
            // Remove archives first, retaining the native scan if archive cleanup fails.
            for format in ScanExportFormat.allCases {
                let archive = format.archiveURL(for: URL(fileURLWithPath: item.directoryPath))
                if fm.fileExists(atPath: archive.path) { try fm.removeItem(at: archive) }
            }
            try fm.removeItem(atPath: item.directoryPath)
        } catch {
            deletionError = "删除扫描失败：\(error.localizedDescription)"
            return
        }
        scanHistory.removeAll { $0.id == item.id }
        savedSceneNames.removeValue(forKey: item.id)
        do {
            try metadataStore.removeSceneName(for: item.id)
        } catch {
            deletionError = "扫描已删除，但名称记录清理失败：\(error.localizedDescription)"
        }
    }

    /// 显示历史列表
    func showHistory() {
        guard !isExporting, !isCaptureBusy else { return }
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
