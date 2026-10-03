import Foundation

/// Atomic journal, intentionally separate from credentials and scan/export directories.
struct ImmersalJobStore {
    let url: URL
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Immersal/jobs.json")) { self.url = url }

    func load() throws -> [ImmersalMappingJob] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let jobs = try JSONDecoder().decode([ImmersalMappingJob].self, from: Data(contentsOf: url))
        guard Set(jobs.map(\.id)).count == jobs.count, jobs.allSatisfy({ job in
            job.userID >= 0 && job.scanName.hasPrefix("scan_") &&
            !job.scanName.contains("/") && !job.scanName.contains("\\") &&
            !job.mapName.isEmpty && job.mapName.utf8.allSatisfy(Self.isAlphanumeric) &&
            job.frameCount >= 0 && job.uploadedCount >= 0 && job.uploadedCount <= job.frameCount &&
            (job.workspaceImageCount == nil || job.workspaceImageCount! >= 0) &&
            (job.mapID == nil || job.mapID! > 0)
        }) else { throw ImmersalMappingError.message("本机任务记录无效，已停止上传以保护云端工作区。") }
        return jobs
    }

    static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    func save(_ jobs: [ImmersalMappingJob]) throws {
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
}

enum ImmersalMappingError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
