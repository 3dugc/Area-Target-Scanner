import Foundation
import Security

protocol AreaTargetJobStoring {
    func load() throws -> [AreaTargetProcessingJob]
    func save(_ jobs: [AreaTargetProcessingJob]) throws
}

struct AreaTargetJobStore: AreaTargetJobStoring {
    let url: URL
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AreaTargetCloud/jobs.json")) { self.url = url }

    func load() throws -> [AreaTargetProcessingJob] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= 8 * 1024 * 1024 else {
            throw AreaTargetLocalError.invalidJournal
        }
        let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard bytes.count <= 8 * 1024 * 1024 else { throw AreaTargetLocalError.invalidJournal }
        let jobs = try JSONDecoder().decode([AreaTargetProcessingJob].self, from: bytes)
        try validate(jobs)
        return jobs
    }

    func save(_ jobs: [AreaTargetProcessingJob]) throws {
        try validate(jobs)
        let bytes = try JSONEncoder().encode(jobs)
        guard bytes.count <= 8 * 1024 * 1024 else { throw AreaTargetLocalError.invalidJournal }
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    private func validate(_ jobs: [AreaTargetProcessingJob]) throws {
        guard Set(jobs.map(\.id)).count == jobs.count, jobs.allSatisfy({ job in
            Self.validID(job.id) && job.scanDirectoryPath.hasPrefix("/") &&
            !job.scanDirectoryPath.contains("\0") && job.scanDirectory.lastPathComponent.hasPrefix("scan_") &&
            !job.displayName.isEmpty && job.displayName.count <= 120 &&
            ["fast", "quality"].contains(job.profile) && job.transferProgress.isFinite &&
            (0...1).contains(job.transferProgress) &&
            (job.archivePath == nil || (job.archivePath!.hasPrefix("/") && !job.archivePath!.contains("\0"))) &&
            (job.archiveSHA256 == nil || Self.validToken(job.archiveSHA256!)) &&
            (job.remote == nil || job.remote!.jobID == job.id) &&
            (job.savedAsset == nil || job.savedAsset!.jobID == job.id)
        }) else { throw AreaTargetLocalError.invalidJournal }
    }

    static func validID(_ id: String) -> Bool { UUID(uuidString: id)?.uuidString.lowercased() == id }
    static func validToken(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

protocol AreaTargetTokenStoring {
    func token(jobID: String) throws -> String?
    func save(_ token: String, jobID: String) throws
    func remove(jobID: String) throws
}

final class AreaTargetKeychainStore: AreaTargetTokenStoring {
    private let service: String
    init(service: String = "com.areatarget.scanner.area-target.jobs") { self.service = service }

    private func query(_ jobID: String) throws -> [String: Any] {
        guard AreaTargetJobStore.validID(jobID) else { throw AreaTargetLocalError.invalidJournal }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: jobID, kSecAttrSynchronizable as String: false]
    }

    func token(jobID: String) throws -> String? {
        var query = try query(jobID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data,
              let token = String(data: bytes, encoding: .utf8), AreaTargetJobStore.validToken(token) else {
            throw AreaTargetLocalError.credentialsUnavailable
        }
        return token
    }

    func save(_ token: String, jobID: String) throws {
        guard AreaTargetJobStore.validToken(token) else { throw AreaTargetLocalError.credentialsUnavailable }
        let query = try query(jobID)
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AreaTargetLocalError.credentialsUnavailable }
    }

    func remove(jobID: String) throws {
        let status = SecItemDelete(try query(jobID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AreaTargetLocalError.credentialsUnavailable }
    }
}

enum AreaTargetLocalError: Error, LocalizedError {
    case invalidJournal, credentialsUnavailable, archiveChanged, missingScan, diskPersistence
    var errorDescription: String? {
        switch self {
        case .invalidJournal: return "本机 Area Target 任务记录无法读取，已停止上传以保护任务。"
        case .credentialsUnavailable: return "无法读取本机任务凭据，请解锁设备后重试。"
        case .archiveChanged: return "已准备的扫描包发生变化，未重新上传。请先确认原云端任务状态。"
        case .missingScan: return "原扫描数据已不存在，无法重新准备上传。"
        case .diskPersistence: return "本机任务状态未能保存，已停止发送请求。请检查剩余空间后重试。"
        }
    }
}
