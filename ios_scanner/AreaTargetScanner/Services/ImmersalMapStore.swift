import Foundation
import CryptoKit

/// Account-scoped, integrity-checked map files. Call off the main thread for large maps.
/// A descriptor is the atomic commit point; existing content-addressed files stay valid
/// while a native localization engine may still hold their previously returned URL.
final class ImmersalMapStore {
    static let maximumMapBytes = 64 * 1024 * 1024
    let rootURL: URL
    private let maximumBytes: Int
    private let publishDescriptor: (Data, URL) throws -> Void
    private let lock = NSLock()

    private struct Descriptor: Codable {
        let schemaVersion: Int
        let userID: Int
        let mapID: Int
        let byteCount: Int
        let sha256: String
    }

    init(rootURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ImmersalMaps", isDirectory: true),
         maximumMapBytes: Int = ImmersalMapStore.maximumMapBytes,
         publishDescriptor: ((Data, URL) throws -> Void)? = nil) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        maximumBytes = max(1, min(maximumMapBytes, Self.maximumMapBytes))
        self.publishDescriptor = publishDescriptor ?? { try $0.write(to: $1, options: .atomic) }
    }

    func mapURL(userID: Int, mapID: Int) throws -> URL? {
        lock.lock(); defer { lock.unlock() }
        let directory = try mapDirectory(userID: userID, mapID: mapID)
        let descriptorURL = directory.appendingPathComponent("current.json")
        guard let descriptorData = try readRegularFile(descriptorURL, maximumBytes: 4096) else { return nil }
        let descriptor: Descriptor
        do { descriptor = try JSONDecoder().decode(Descriptor.self, from: descriptorData) }
        catch { throw StoreError.invalidCache }
        guard descriptor.schemaVersion == 1, descriptor.userID == userID, descriptor.mapID == mapID,
              descriptor.byteCount > 0, descriptor.byteCount <= maximumBytes,
              descriptor.sha256.utf8.count == 64,
              descriptor.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw StoreError.invalidCache
        }
        let mapURL = directory.appendingPathComponent(descriptor.sha256 + ".bytes")
        guard let data = try readRegularFile(mapURL, maximumBytes: maximumBytes),
              data.count == descriptor.byteCount, Self.digest(data) == descriptor.sha256 else {
            throw StoreError.invalidCache
        }
        return mapURL
    }

    @discardableResult
    func save(data: Data, userID: Int, mapID: Int) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let directory = try mapDirectory(userID: userID, mapID: mapID)
        guard !data.isEmpty, data.count <= maximumBytes else { throw StoreError.invalidData }
        let digest = Self.digest(data)
        let descriptor = Descriptor(schemaVersion: 1, userID: userID, mapID: mapID,
                                    byteCount: data.count, sha256: digest)
        let descriptorData = try JSONEncoder().encode(descriptor)
        let mapURL = directory.appendingPathComponent(digest + ".bytes")
        let descriptorURL = directory.appendingPathComponent("current.json")
        try rejectSymlink(mapURL)
        try rejectSymlink(descriptorURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // If descriptor publication fails, the previous descriptor still points to its
        // complete, immutable file. A new unreferenced content file is harmless.
        try data.write(to: mapURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try publishDescriptor(descriptorData, descriptorURL)
        return mapURL
    }

    private func mapDirectory(userID: Int, mapID: Int) throws -> URL {
        guard userID >= 0, mapID > 0 else { throw StoreError.invalidIdentity }
        let directory = rootURL.appendingPathComponent(String(userID), isDirectory: true)
            .appendingPathComponent(String(mapID), isDirectory: true)
        try rejectSymlink(directory)
        return directory
    }

    private func rejectSymlink(_ url: URL) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw StoreError.invalidCache
        }
    }

    /// Missing descriptors mean no download. Other I/O errors and malformed files fail visibly.
    private func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data? {
        try rejectSymlink(url)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let byteCount = attributes[.size] as? NSNumber,
              byteCount.intValue > 0, byteCount.intValue <= maximumBytes else { throw StoreError.invalidCache }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == byteCount.intValue else { throw StoreError.invalidCache }
        return data
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum StoreError: LocalizedError {
        case invalidIdentity, invalidData, invalidCache

        var errorDescription: String? {
            switch self {
            case .invalidIdentity: return "地图或账号编号无效。"
            case .invalidData: return "地图文件为空或超过本机允许的大小。"
            case .invalidCache: return "本机地图缓存校验失败，请重新下载地图。"
            }
        }
    }
}
