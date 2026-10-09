import Foundation
import ZIPFoundation
import Darwin

struct AreaTargetSavedAsset: Codable, Equatable {
    let jobID: String
    let bundleURL: URL
    let directoryURL: URL
    let modelURL: URL
    let featuresURL: URL
    let manifestURL: URL
    let savedAt: Date
}

protocol AreaTargetAssetStoring {
    func save(downloadURL: URL, jobID: String, result: AreaTargetResult) throws -> AreaTargetSavedAsset
    func asset(jobID: String) throws -> AreaTargetSavedAsset?
}

final class AreaTargetAssetStore: AreaTargetAssetStoring {
    private let root: URL
    private let lock = NSRecursiveLock()
    private struct Descriptor: Codable {
        let schemaVersion: Int
        let jobID: String
        let generation: String
        let sizeBytes: Int64
        let sha256: String
        let savedAt: Date
        let files: [String: FileDigest]
    }
    private struct FileDigest: Codable {
        let sizeBytes: Int64
        let sha256: String
    }
    init(rootDirectory: URL? = nil) {
        root = (rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AreaTargetCloud/assets", isDirectory: true)).standardizedFileURL
    }

    /// A new immutable generation is checked completely before a single atomic descriptor rename.
    func save(downloadURL: URL, jobID: String, result: AreaTargetResult) throws -> AreaTargetSavedAsset {
        lock.lock(); defer { lock.unlock() }
        try AreaTargetAPIClient.validateIdentity(jobID)
        try AreaTargetAPIClient.validateResult(result, jobID: jobID)
        let incoming = try AreaTargetFileSafety.digest(downloadURL, maximum: AreaTargetFileSafety.maximumZIPBytes)
        guard incoming.size == result.sizeBytes, incoming.sha256 == result.sha256 else { throw invalid("download integrity") }
        let jobDirectory = root.appendingPathComponent(jobID, isDirectory: true)
        try ensureDirectory(root)
        try ensureDirectory(jobDirectory)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var protectedRoot = root
        try protectedRoot.setResourceValues(excluded)
        let generation = UUID().uuidString.lowercased()
        let staging = jobDirectory.appendingPathComponent(".staging-" + generation, isDirectory: true)
        let published = jobDirectory.appendingPathComponent(generation, isDirectory: true)
        var didPublish = false
        defer {
            try? FileManager.default.removeItem(at: staging)
            if !didPublish { try? FileManager.default.removeItem(at: published) }
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let bundle = staging.appendingPathComponent("bundle.zip")
        try FileManager.default.copyItem(at: downloadURL, to: bundle)
        let copied = try AreaTargetFileSafety.digest(bundle, maximum: AreaTargetFileSafety.maximumZIPBytes)
        guard copied == incoming else { throw invalid("copy integrity") }
        let content = staging.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: false)
        try extract(bundle, to: content)
        try validateContents(content)
        let descriptor = Descriptor(schemaVersion: 1, jobID: jobID, generation: generation, sizeBytes: copied.size,
                                    sha256: copied.sha256, savedAt: Date(), files: try contentDigests(content))
        try FileManager.default.moveItem(at: staging, to: published)
        var protectedGeneration = published
        try protectedGeneration.setResourceValues(excluded)
        let descriptorData = try JSONEncoder().encode(descriptor)
        let temporaryPointer = jobDirectory.appendingPathComponent(".current-" + generation + ".json")
        defer { try? FileManager.default.removeItem(at: temporaryPointer) }
        try descriptorData.write(to: temporaryPointer, options: .atomic)
        let current = jobDirectory.appendingPathComponent("current.json")
        if FileManager.default.fileExists(atPath: current.path) { _ = try AreaTargetFileSafety.safeFile("current.json", in: jobDirectory) }
        let resultCode = temporaryPointer.path.withCString { source in current.path.withCString { destination in rename(source, destination) } }
        guard resultCode == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        didPublish = true
        return savedAsset(descriptor, directory: published)
    }

    func asset(jobID: String) throws -> AreaTargetSavedAsset? {
        lock.lock(); defer { lock.unlock() }
        try AreaTargetAPIClient.validateIdentity(jobID)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        try validateDirectory(root)
        let jobDirectory = root.appendingPathComponent(jobID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: jobDirectory.path) else { return nil }
        try validateDirectory(jobDirectory)
        let pointer = jobDirectory.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath: pointer.path) else { return nil }
        let descriptor: Descriptor
        do { descriptor = try JSONDecoder().decode(Descriptor.self, from: AreaTargetFileSafety.smallData(AreaTargetFileSafety.safeFile("current.json", in: jobDirectory), maximum: 65_536)) }
        catch { throw invalid("saved descriptor") }
        guard descriptor.schemaVersion == 1, descriptor.jobID == jobID,
              UUID(uuidString: descriptor.generation)?.uuidString.lowercased() == descriptor.generation,
              descriptor.sizeBytes > 0, descriptor.sizeBytes <= AreaTargetFileSafety.maximumZIPBytes,
              AreaTargetFileSafety.isLowerHex64(descriptor.sha256) else { throw invalid("saved descriptor identity") }
        let directory = jobDirectory.appendingPathComponent(descriptor.generation, isDirectory: true)
        try validateDirectory(directory)
        let bundle = try AreaTargetFileSafety.safeFile("bundle.zip", in: directory)
        let verified = try AreaTargetFileSafety.digest(bundle, maximum: AreaTargetFileSafety.maximumZIPBytes)
        guard verified.size == descriptor.sizeBytes, verified.sha256 == descriptor.sha256 else { throw invalid("saved bundle integrity") }
        let content = directory.appendingPathComponent("content", isDirectory: true)
        try validateDirectory(content)
        try validateContents(content)
        let digests = try contentDigests(content)
        guard Set(descriptor.files.keys) == Set(digests.keys), descriptor.files.allSatisfy({ key, value in
            digests[key]?.sizeBytes == value.sizeBytes && digests[key]?.sha256 == value.sha256
        }) else { throw invalid("saved file integrity") }
        return savedAsset(descriptor, directory: directory)
    }

    private func savedAsset(_ descriptor: Descriptor, directory: URL) -> AreaTargetSavedAsset {
        // Both callers have validated and published this generation. Normalize only
        // its returned identity; resolving the unvalidated cache root would hide links.
        let canonicalDirectory = directory.resolvingSymlinksInPath()
        let content = canonicalDirectory.appendingPathComponent("content", isDirectory: true)
        return AreaTargetSavedAsset(jobID: descriptor.jobID, bundleURL: canonicalDirectory.appendingPathComponent("bundle.zip"),
            directoryURL: content, modelURL: content.appendingPathComponent("optimized.glb"),
            featuresURL: content.appendingPathComponent("features.db"), manifestURL: content.appendingPathComponent("manifest.json"), savedAt: descriptor.savedAt)
    }

    private func extract(_ bundle: URL, to destination: URL) throws {
        let archive = try Archive(url: bundle, accessMode: .read)
        var entries: [(Entry, String)] = []
        var paths = Set<String>()
        var expanded: Int64 = 0
        for entry in archive {
            guard entries.count < AreaTargetFileSafety.maximumEntries, entry.type != .symlink else { throw invalid("archive entry limit or symlink") }
            let path = entry.type == .directory && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            guard AreaTargetFileSafety.safeRelativePath(path), paths.insert(path.lowercased()).inserted,
                  entry.uncompressedSize <= UInt64(AreaTargetFileSafety.maximumExpandedBytes) else { throw invalid("archive path or size") }
            expanded += Int64(entry.uncompressedSize)
            guard expanded <= AreaTargetFileSafety.maximumExpandedBytes else { throw invalid("expanded limit") }
            entries.append((entry, path))
        }
        guard !entries.isEmpty else { throw invalid("empty archive") }
        var actualTotal: Int64 = 0
        for (entry, path) in entries {
            let output = destination.appendingPathComponent(path)
            if entry.type == .directory {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw invalid("extract destination") }
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            var actualSize: Int64 = 0
            let checksum = try archive.extract(entry, bufferSize: 64 * 1024) { data in
                actualSize += Int64(data.count)
                actualTotal += Int64(data.count)
                guard actualSize <= Int64(entry.uncompressedSize), actualTotal <= AreaTargetFileSafety.maximumExpandedBytes else { throw self.invalid("expanded size") }
                try handle.write(contentsOf: data)
            }
            guard actualSize == Int64(entry.uncompressedSize), checksum == entry.checksum else { throw invalid("archive integrity") }
            try handle.synchronize()
        }
    }

    private func validateContents(_ directory: URL) throws {
        let manifestURL = try AreaTargetFileSafety.safeFile("manifest.json", in: directory)
        let modelURL = try AreaTargetFileSafety.safeFile("optimized.glb", in: directory)
        let featuresURL = try AreaTargetFileSafety.safeFile("features.db", in: directory)
        guard let manifest = try JSONSerialization.jsonObject(with: AreaTargetFileSafety.smallData(manifestURL)) as? [String: Any],
              manifest["version"] as? String == "2.0", manifest["meshFile"] as? String == "optimized.glb",
              manifest["featureDbFile"] as? String == "features.db", manifest["format"] as? String == "glb",
              let keyframes = manifest["keyframeCount"] as? Int, keyframes > 0,
              let bounds = manifest["bounds"] as? [String: Any], let minimum = bounds["min"] as? [Double],
              let maximum = bounds["max"] as? [Double], minimum.count == 3, maximum.count == 3,
              minimum.allSatisfy(\.isFinite), maximum.allSatisfy(\.isFinite),
              zip(minimum, maximum).allSatisfy({ $0 <= $1 }), try AreaTargetFileSafety.regularFileSize(featuresURL) > 0 else { throw invalid("manifest contract") }
        let modelSize = try AreaTargetFileSafety.regularFileSize(modelURL)
        guard modelSize >= 20, modelSize <= UInt32.max else { throw invalid("GLB size") }
        let model = try FileHandle(forReadingFrom: modelURL)
        defer { try? model.close() }
        let header = try model.read(upToCount: 20) ?? Data()
        func word(_ offset: Int) -> UInt32 { header[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) } }
        guard header.count == 20, word(0) == 0x46546c67, word(4) == 2, Int64(word(8)) == modelSize,
              word(16) == 0x4e4f534a, word(12) % 4 == 0, Int64(word(12)) + 20 <= modelSize else { throw invalid("GLB header") }
        let features = try FileHandle(forReadingFrom: featuresURL)
        defer { try? features.close() }
        guard try features.read(upToCount: 16) == Data("SQLite format 3\0".utf8) else { throw invalid("feature database header") }
    }

    private func ensureDirectory(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) { try validateDirectory(directory) }
        else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }
    private func contentDigests(_ directory: URL) throws -> [String: FileDigest] {
        var values: [String: FileDigest] = [:]
        for name in ["manifest.json", "optimized.glb", "features.db"] {
            let digest = try AreaTargetFileSafety.digest(AreaTargetFileSafety.safeFile(name, in: directory), maximum: AreaTargetFileSafety.maximumExpandedBytes)
            values[name] = FileDigest(sizeBytes: digest.size, sha256: digest.sha256)
        }
        return values
    }
    private func validateDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw invalid("cache directory") }
    }
    private func invalid(_ reason: String) -> AreaTargetAPIError { .invalidResult(reason) }
}
