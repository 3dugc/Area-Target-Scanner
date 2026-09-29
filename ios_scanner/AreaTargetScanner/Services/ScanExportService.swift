import Foundation
import Darwin

enum ScanExportFormat: String, CaseIterable {
    case areaTarget
    case immersal

    var title: String { self == .areaTarget ? "Area Target 原格式" : "Immersal 格式" }
    func archiveURL(for directory: URL) -> URL {
        URL(fileURLWithPath: directory.path + (self == .areaTarget ? ".zip" : "_immersal.zip"))
    }
}

protocol ScanExporting: AnyObject {
    func availability(scanDirectory: URL, format: ScanExportFormat) -> String?
    func export(scanDirectory: URL, format: ScanExportFormat,
                progress: @escaping (String) -> Void, isCancelled: @escaping () -> Bool) throws -> URL
}

final class ScanExportService: ScanExporting {
    private let immersal = ImmersalScanExporter()

    func availability(scanDirectory: URL, format: ScanExportFormat) -> String? {
        format == .immersal ? immersal.availability(scanDirectory: scanDirectory) : nil
    }

    func export(scanDirectory: URL, format: ScanExportFormat,
                progress: @escaping (String) -> Void, isCancelled: @escaping () -> Bool) throws -> URL {
        if isCancelled() { throw CancellationError() }
        if format == .immersal {
            return try immersal.export(scanDirectory: scanDirectory, progress: progress, isCancelled: isCancelled)
        }
        let output = format.archiveURL(for: scanDirectory)
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) { return output }
        progress("正在打包 Area Target ZIP…")
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".export-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: temporary) }
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: scanDirectory, options: [.forUploading], error: &coordinatorError) { archive in
            do {
                if isCancelled() { throw CancellationError() }
                try fm.copyItem(at: archive, to: temporary)
            } catch { copyError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        if isCancelled() { throw CancellationError() }
        guard rename(temporary.path, output.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "保存 Area Target ZIP 失败"])
        }
        return output
    }
}

/// Shared by the UI and synchronous background encoders; cancellation never deletes a published archive.
final class ScanExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
