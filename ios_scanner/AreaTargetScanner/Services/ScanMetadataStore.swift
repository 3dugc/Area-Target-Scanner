import Foundation

/// Local display names stay outside scan payloads and exported archives.
/// Every mutation reads the current file first, so unreadable metadata is never replaced.
final class ScanMetadataStore {
    let fileURL: URL

    init(documentsDirectory: URL) {
        fileURL = documentsDirectory
            .appendingPathComponent(".scanner-metadata", isDirectory: true)
            .appendingPathComponent("scene-names.json")
    }

    static func normalizedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MetadataError.emptyName }
        guard trimmed.count <= 60 else { throw MetadataError.nameTooLong }
        guard trimmed.rangeOfCharacter(from: .newlines) == nil else { throw MetadataError.multilineName }
        return trimmed
    }

    func sceneNames() throws -> [String: String] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return [:]
        }
        let names: [String: String]
        do {
            names = try JSONDecoder().decode([String: String].self, from: data)
            for value in names.values {
                guard try Self.normalizedName(value) == value else { throw MetadataError.invalidFile }
            }
        } catch {
            throw MetadataError.invalidFile
        }
        return names
    }

    func setSceneName(_ name: String, for scanID: String) throws {
        let name = try Self.normalizedName(name)
        var names = try sceneNames()
        names[scanID] = name
        try save(names)
    }

    func removeSceneName(for scanID: String) throws {
        var names = try sceneNames()
        guard names.removeValue(forKey: scanID) != nil else { return }
        try save(names)
    }

    private func save(_ names: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(names)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private enum MetadataError: LocalizedError {
        case emptyName, nameTooLong, multilineName, invalidFile

        var errorDescription: String? {
            switch self {
            case .emptyName: return "请输入场景名称。"
            case .nameTooLong: return "场景名称最多 60 个字符。"
            case .multilineName: return "场景名称不能包含换行。"
            case .invalidFile: return "场景名称记录无法读取。原有记录已保留，请先恢复名称记录文件。"
            }
        }
    }
}
