import Foundation
import CryptoKit
import Darwin
import simd

struct LocalizationRecordingContext: Codable, Equatable {
    let deviceModel: String
    let systemVersion: String
    let appVersion: String
    let appBuild: String
    var previewDroppedFrames: Int = 0
    var captureEndReason: String? = nil
}

struct LocalizationRecording: Codable, Equatable, Identifiable {
    var schemaVersion = 1
    let id: UUID
    let date: Date
    let sourceFingerprint: String
    let inputDigest: String
    let frameCount: Int
    let duration: Double
    let context: LocalizationRecordingContext
}

final class LocalizationRecordingStore {
    static let maximumVideoBytes = 128 * 1024 * 1024
    static let maximumTotalBytes: Int64 = 2 * 1024 * 1024 * 1024
    private static let maximumManifestBytes = 64 * 1024
    private static let maximumFrameFileBytes = LocalizationQueryRecorder.maximumPixelBytes + 4096
    private static let binaryHeader = Data("localization-query-frames-v1\0".utf8)
    private static let filenames = ["manifest.json", "frames.bin", "preview.mp4"]
    private let rootURL: URL
    private let parentDirectory: Int32
    private let rootComponents: [String]
    private let lock = NSLock()

    private struct Manifest: Codable {
        let schemaVersion: Int
        let recording: LocalizationRecording
        let samplingPolicy: LocalizationSamplingPolicy
        let frameBytes: Int
        let videoBytes: Int64
        let videoDigest: String
    }
    private struct Envelope: Codable { let manifest: Manifest; let manifestDigest: String }
    enum Failure: LocalizedError {
        case invalidInput, invalidCache, corrupt, storageFull
        var errorDescription: String? {
            switch self {
            case .invalidInput: return "录制输入不完整或超过采样限制，请重新录制。"
            case .invalidCache: return "本机录像目录无法安全读取或保存。"
            case .corrupt: return "录像文件已损坏，无法保证两套地图回放同一批帧。"
            case .storageFull: return "本机测试录像已达到 2 GiB 上限。请删除不需要的录像后重试。"
            }
        }
    }

    init(rootDirectory: URL? = nil) {
        let requested = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalizationRecordings", isDirectory: true)
        let standardized = requested.standardizedFileURL
        let parent = requested.isFileURL && standardized.path != "/" && !Self.unsafeSymlink(standardized.path)
            ? Self.canonicalParent(standardized.deletingLastPathComponent().path) : nil
        let anchor = parent?.anchor ?? standardized.deletingLastPathComponent().path
        rootComponents = (parent?.missing ?? []) + [standardized.lastPathComponent]
        rootURL = URL(fileURLWithPath: ([anchor] + rootComponents).joined(separator: "/"), isDirectory: true)
        // Anchor inside the accessible container; iOS does not permit walking from /.
        parentDirectory = parent == nil ? -1 : Darwin.open(anchor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    deinit { if parentDirectory >= 0 { Darwin.close(parentDirectory) } }

    /// A canonical binary digest; no Swift descriptions, locale or JSON floats enter identity.
    static func inputDigest(frames: [LocalizationQueryFrame]) throws -> String {
        try validate(frames)
        var hash = SHA256()
        try chunks(frames) { hash.update(data: $0) }
        return hex(hash.finalize())
    }

    func save(frames: [LocalizationQueryFrame], videoURL: URL, sourceFingerprint: String, context: LocalizationRecordingContext) throws -> LocalizationRecording {
        lock.lock(); defer { lock.unlock() }
        try Self.validate(frames)
        guard ScanSourceFingerprint.valid(sourceFingerprint), Self.valid(context), videoURL.isFileURL,
              !Self.unsafeSymlink(videoURL.path) else { throw Failure.invalidInput }
        let source = Darwin.open(videoURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw Failure.invalidInput }
        defer { Darwin.close(source) }
        let videoSize = try Self.regularSize(source, maximum: Int64(Self.maximumVideoBytes))
        let frameSize = Self.binaryHeader.count + 4 + frames.reduce(0) { $0 + 112 + $1.pixels.count }
        guard let root = try openRoot(create: true) else { throw Failure.invalidCache }
        defer { Darwin.close(root) }
        try beginTransaction(root); defer { flock(root, LOCK_UN) }
        let total = try directoryBytes(root)
        guard total + Int64(frameSize) + videoSize + Int64(Self.maximumManifestBytes) <= Self.maximumTotalBytes else { throw Failure.storageFull }
        let id = UUID(), temporary = ".pending-" + UUID().uuidString.lowercased()
        guard mkdirat(root, temporary, mode_t(0o700)) == 0 else { throw Failure.invalidCache }
        let package = openat(root, temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard package >= 0 else { unlinkat(root, temporary, AT_REMOVEDIR); throw Failure.invalidCache }
        var published = false
        defer {
            if !published {
                for filename in Self.filenames { unlinkat(package, filename, 0) }
                unlinkat(root, temporary, AT_REMOVEDIR)
            }
            Darwin.close(package)
        }
        // The local image package must not be uploaded by automatic device backup.
        var stagingURL = rootURL.appendingPathComponent(temporary, isDirectory: true)
        var privacy = URLResourceValues(); privacy.isExcludedFromBackup = true
        try stagingURL.setResourceValues(privacy)
        let frameFile = try Self.createFile("frames.bin", in: package)
        var frameHash = SHA256()
        do {
            try Self.chunks(frames) { chunk in try Self.write(chunk, file: frameFile); frameHash.update(data: chunk) }
            guard fsync(frameFile) == 0 else { throw Failure.invalidCache }
            Darwin.close(frameFile)
        } catch { Darwin.close(frameFile); throw error }
        let videoFile = try Self.createFile("preview.mp4", in: package)
        let videoDigest: String
        do {
            videoDigest = try Self.stream(source, expectedSize: videoSize) { try Self.write($0, file: videoFile) }
            guard fsync(videoFile) == 0 else { throw Failure.invalidCache }
            Darwin.close(videoFile)
        } catch { Darwin.close(videoFile); throw error }
        let recording = LocalizationRecording(id: id, date: Date(), sourceFingerprint: sourceFingerprint,
            inputDigest: Self.hex(frameHash.finalize()), frameCount: frames.count,
            duration: frames.last!.timestamp - frames.first!.timestamp, context: context)
        let manifest = Manifest(schemaVersion: 1, recording: recording, samplingPolicy: .init(),
            frameBytes: frameSize, videoBytes: videoSize, videoDigest: videoDigest)
        let envelope = Envelope(manifest: manifest, manifestDigest: Self.digest(try Self.encode(manifest)))
        let metadata = try Self.encode(envelope)
        guard metadata.count <= Self.maximumManifestBytes else { throw Failure.invalidInput }
        let manifestFile = try Self.createFile("manifest.json", in: package)
        do {
            try Self.write(metadata, file: manifestFile)
            guard fsync(manifestFile) == 0 else { throw Failure.invalidCache }
            Darwin.close(manifestFile)
        } catch { Darwin.close(manifestFile); throw error }
        guard fsync(package) == 0 else { throw Failure.invalidCache }
        // An entire folder becomes visible only after all three files are durable.
        guard renameatx_np(root, temporary, root, id.uuidString.lowercased(), UInt32(RENAME_EXCL)) == 0 else { throw Failure.invalidCache }
        published = true
        guard fsync(root) == 0 else { throw Failure.invalidCache }
        return recording
    }

    func list(sourceFingerprint: String) throws -> [LocalizationRecording] {
        lock.lock(); defer { lock.unlock() }
        guard ScanSourceFingerprint.valid(sourceFingerprint) else { throw Failure.invalidInput }
        return try verifiedRecordings(sourceFingerprint: sourceFingerprint)
    }
    /// Deletion-only storage management can include recordings from other scans.
    func listAll() throws -> [LocalizationRecording] {
        lock.lock(); defer { lock.unlock() }
        return try verifiedRecordings(sourceFingerprint: nil)
    }
    /// Corrupt/unsupported entries remain visible for explicit storage management.
    func invalidRecordingIDs() throws -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        guard let root = try openRoot(create: false) else { return [] }
        defer { Darwin.close(root) }
        try beginTransaction(root); defer { flock(root, LOCK_UN) }
        var result: [UUID] = []
        for name in try names(root) {
            guard let id = UUID(uuidString: name), name == id.uuidString.lowercased() else { continue }
            if let package = try? openPackage(id, root: root) {
                defer { Darwin.close(package) }
                if (try? verify(package, id: id)) == nil { result.append(id) }
            } else { result.append(id) }
        }
        return result.sorted { $0.uuidString < $1.uuidString }
    }
    func deleteInvalid(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let root = try openRoot(create: false) else { throw Failure.invalidCache }
        defer { Darwin.close(root) }
        try beginTransaction(root); defer { flock(root, LOCK_UN) }
        let name = id.uuidString.lowercased()
        var info = stat()
        guard fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.invalidCache }
        if let package = try? openPackage(id, root: root) {
            defer { Darwin.close(package) }
            // Recheck inside the exclusive transaction: a stale invalid list must
            // never authorize deleting an entry that is now a valid recording.
            guard (try? verify(package, id: id)) == nil else { throw Failure.invalidInput }
        }
        try removePublishedEntry(name, root: root)
    }
    private func verifiedRecordings(sourceFingerprint: String?) throws -> [LocalizationRecording] {
        guard let root = try openRoot(create: false) else { return [] }
        defer { Darwin.close(root) }
        try beginTransaction(root); defer { flock(root, LOCK_UN) }
        var recordings: [LocalizationRecording] = []
        for name in try names(root) {
            guard let id = UUID(uuidString: name), id.uuidString.lowercased() == name,
                  let package = try? openPackage(id, root: root) else { continue }
            defer { Darwin.close(package) }
            guard let verified = try? verify(package, id: id), sourceFingerprint.map({ verified.manifest.recording.sourceFingerprint == $0 }) ?? true else { continue }
            recordings.append(verified.manifest.recording)
        }
        return recordings.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
    }

    func load(_ recording: LocalizationRecording) throws -> [LocalizationQueryFrame] {
        lock.lock(); defer { lock.unlock() }
        guard let root = try openRoot(create: false) else { throw Failure.invalidCache }
        defer { Darwin.close(root) }
        try beginTransaction(root); defer { flock(root, LOCK_UN) }
        let package = try openPackage(recording.id, root: root)
        defer { Darwin.close(package) }
        return try verify(package, id: recording.id, expected: recording).frames
    }

    func videoURL(for recording: LocalizationRecording) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard let root = try openRoot(create: false) else { throw Failure.invalidCache }
        defer { Darwin.close(root) }
        try beginTransaction(root); defer { flock(root, LOCK_UN) }
        let package = try openPackage(recording.id, root: root)
        defer { Darwin.close(package) }
        _ = try verify(package, id: recording.id, expected: recording)
        return rootURL.appendingPathComponent(recording.id.uuidString.lowercased(), isDirectory: true).appendingPathComponent("preview.mp4")
    }

    func delete(_ recording: LocalizationRecording) throws {
        lock.lock(); defer { lock.unlock() }
        guard let root = try openRoot(create: false) else { throw Failure.invalidCache }
        defer { Darwin.close(root) }
        try beginTransaction(root); defer { flock(root, LOCK_UN) }
        let package = try openPackage(recording.id, root: root)
        defer { Darwin.close(package) }
        let manifest = try readManifest(package, id: recording.id)
        guard manifest.recording == recording else { throw Failure.corrupt }
        guard Set(try names(package)) == Set(Self.filenames) else { throw Failure.invalidCache }
        for filename in Self.filenames {
            var info = stat()
            guard fstatat(package, filename, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidCache }
        }
        try removePublishedEntry(recording.id.uuidString.lowercased(), root: root)
    }

    /// Separate open descriptions lock the same directory across instances and
    /// processes. A terminated writer releases its lock before recovery runs.
    private func beginTransaction(_ root: Int32) throws {
        while flock(root, LOCK_EX) != 0 { guard errno == EINTR else { throw Failure.invalidCache } }
        do { try cleanupStaging(root) }
        catch { flock(root, LOCK_UN); throw error }
    }
    private func cleanupStaging(_ root: Int32) throws {
        var visited = 0, removed = false
        for name in try names(root) {
            let prefix: String
            if name.hasPrefix(".pending-") { prefix = ".pending-" }
            else if name.hasPrefix(".deleted-") { prefix = ".deleted-" }
            else { continue }
            let suffix = String(name.dropFirst(prefix.count))
            guard let id = UUID(uuidString: suffix), suffix == id.uuidString.lowercased() else { continue }
            try removeEntry(name, parent: root, depth: 0, visited: &visited); removed = true
        }
        if removed { guard fsync(root) == 0 else { throw Failure.invalidCache } }
    }
    private func removePublishedEntry(_ name: String, root: Int32) throws {
        let tombstone = ".deleted-" + UUID().uuidString.lowercased()
        guard renameatx_np(root, name, root, tombstone, UInt32(RENAME_EXCL)) == 0 else { throw Failure.invalidCache }
        // Persist the explicit deletion before reclaiming bytes. If interrupted,
        // only this tombstone is recovered on the next exclusive transaction.
        guard fsync(root) == 0 else { throw Failure.invalidCache }
        var visited = 0
        try removeEntry(tombstone, parent: root, depth: 0, visited: &visited)
        guard fsync(root) == 0 else { throw Failure.invalidCache }
    }
    private func removeEntry(_ name: String, parent: Int32, depth: Int, visited: inout Int) throws {
        guard depth <= 8, visited < 10_000, name != ".", name != "..", !name.contains("/") else { throw Failure.invalidCache }
        visited += 1
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.invalidCache }
        if info.st_mode & S_IFMT == S_IFDIR {
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw Failure.invalidCache }
            defer { Darwin.close(child) }
            for descendant in try names(child) { try removeEntry(descendant, parent: child, depth: depth + 1, visited: &visited) }
            guard fsync(child) == 0, unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw Failure.invalidCache }
        } else {
            // Includes symbolic links: unlink removes only the anchored entry.
            guard unlinkat(parent, name, 0) == 0 else { throw Failure.invalidCache }
        }
    }

    private func verify(_ package: Int32, id: UUID, expected: LocalizationRecording? = nil) throws -> (manifest: Manifest, frames: [LocalizationQueryFrame]) {
        let manifest = try readManifest(package, id: id)
        guard expected == nil || expected == manifest.recording,
              Set(try names(package)) == Set(Self.filenames) else { throw Failure.corrupt }
        let bytes = try Self.read("frames.bin", in: package, maximum: Self.maximumFrameFileBytes)
        guard bytes.count == manifest.frameBytes, Self.digest(bytes) == manifest.recording.inputDigest else { throw Failure.corrupt }
        let frames = try Self.decodeFrames(bytes)
        guard frames.count == manifest.recording.frameCount,
              frames.last!.timestamp - frames.first!.timestamp == manifest.recording.duration else { throw Failure.corrupt }
        let video = openat(package, "preview.mp4", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard video >= 0 else { throw Failure.corrupt }
        defer { Darwin.close(video) }
        guard try Self.regularSize(video, maximum: Int64(Self.maximumVideoBytes)) == manifest.videoBytes,
              try Self.stream(video, expectedSize: manifest.videoBytes, consume: { _ in }) == manifest.videoDigest else { throw Failure.corrupt }
        return (manifest, frames)
    }

    private func readManifest(_ package: Int32, id: UUID) throws -> Manifest {
        let bytes = try Self.read("manifest.json", in: package, maximum: Self.maximumManifestBytes)
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: bytes) } catch { throw Failure.corrupt }
        let manifest = envelope.manifest, recording = manifest.recording
        guard envelope.manifestDigest == Self.digest(try Self.encode(manifest)), manifest.schemaVersion == 1,
              recording.schemaVersion == 1, recording.id == id, recording.date.timeIntervalSince1970.isFinite,
              ScanSourceFingerprint.valid(recording.sourceFingerprint), ScanSourceFingerprint.valid(recording.inputDigest),
              recording.frameCount > 0, recording.frameCount <= LocalizationQueryRecorder.maximumFrames,
              recording.duration.isFinite, recording.duration >= 0, Self.valid(recording.context),
              manifest.samplingPolicy == LocalizationSamplingPolicy(),
              manifest.frameBytes > 0, manifest.frameBytes <= Self.maximumFrameFileBytes,
              manifest.videoBytes > 0, manifest.videoBytes <= Int64(Self.maximumVideoBytes),
              ScanSourceFingerprint.valid(manifest.videoDigest) else { throw Failure.corrupt }
        return manifest
    }

    private static func valid(_ context: LocalizationRecordingContext) -> Bool {
        let reasons = ["manualStop", "frameLimit", "byteLimit", "trackingInterrupted", "durationLimit", "cameraFailure"]
        return context.previewDroppedFrames >= 0 &&
            [context.deviceModel, context.systemVersion, context.appVersion, context.appBuild].allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 } &&
            (context.captureEndReason.map { reasons.contains($0) } ?? true)
    }

    private static func validate(_ frames: [LocalizationQueryFrame]) throws {
        guard !frames.isEmpty, frames.count <= LocalizationQueryRecorder.maximumFrames else { throw Failure.invalidInput }
        var recorder = LocalizationQueryRecorder()
        for frame in frames {
            guard max(frame.width, frame.height) <= 1920, LocalizationQueryFrame.rigid(frame.worldFromCamera),
                  recorder.append(frame, trackingNormal: true) else { throw Failure.invalidInput }
        }
    }

    /// Each frame has a fixed 112-byte metadata block, followed by dense gray8 bytes.
    private static func chunks(_ frames: [LocalizationQueryFrame], consume: (Data) throws -> Void) throws {
        var header = binaryHeader; append(UInt32(frames.count), to: &header); try consume(header)
        for frame in frames {
            var metadata = Data(); metadata.reserveCapacity(112)
            append(UInt64(frame.sequence), to: &metadata); append(frame.timestamp.bitPattern, to: &metadata)
            append(UInt32(frame.width), to: &metadata); append(UInt32(frame.height), to: &metadata)
            for index in 0..<4 { append(frame.intrinsics[index].bitPattern, to: &metadata) }
            for column in 0..<4 { for row in 0..<4 { append(frame.worldFromCamera[column][row].bitPattern, to: &metadata) } }
            append(UInt64(frame.pixels.count), to: &metadata)
            try consume(metadata); try consume(frame.pixels)
        }
    }
    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    private struct Cursor {
        let data: Data
        var offset = 0
        mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let count = MemoryLayout<T>.size
            guard count <= data.count - offset else { throw Failure.corrupt }
            var value: T = 0
            for index in 0..<count { value |= T(data[offset + index]) << (index * 8) }
            offset += count; return value
        }
        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - offset else { throw Failure.corrupt }
            defer { offset += count }; return data.subdata(in: offset..<(offset + count))
        }
    }
    private static func decodeFrames(_ bytes: Data) throws -> [LocalizationQueryFrame] {
        var cursor = Cursor(data: bytes)
        guard try cursor.bytes(binaryHeader.count) == binaryHeader else { throw Failure.corrupt }
        let count = try cursor.integer(UInt32.self)
        guard count > 0, count <= UInt32(LocalizationQueryRecorder.maximumFrames) else { throw Failure.corrupt }
        var frames: [LocalizationQueryFrame] = [], pixelBytes = 0
        for _ in 0..<count {
            let sequence = try cursor.integer(UInt64.self), timestamp = Double(bitPattern: try cursor.integer(UInt64.self))
            let width = Int(try cursor.integer(UInt32.self)), height = Int(try cursor.integer(UInt32.self))
            guard sequence <= UInt64(Int.max), width > 0, height > 0, max(width, height) <= 1920 else { throw Failure.corrupt }
            var intrinsics = SIMD4<Float>(), pose = matrix_identity_float4x4
            for index in 0..<4 { intrinsics[index] = Float(bitPattern: try cursor.integer(UInt32.self)) }
            for column in 0..<4 { for row in 0..<4 { pose[column][row] = Float(bitPattern: try cursor.integer(UInt32.self)) } }
            let byteCount = try cursor.integer(UInt64.self)
            guard byteCount == UInt64(width * height), byteCount <= UInt64(LocalizationQueryRecorder.maximumPixelBytes - pixelBytes) else { throw Failure.corrupt }
            pixelBytes += Int(byteCount)
            let pixels = try cursor.bytes(Int(byteCount))
            do {
                frames.append(try LocalizationQueryFrame(sequence: Int(sequence), timestamp: timestamp, pixels: pixels,
                    width: width, height: height, intrinsics: intrinsics, worldFromCamera: pose))
            } catch { throw Failure.corrupt }
        }
        guard cursor.offset == bytes.count else { throw Failure.corrupt }
        do { try validate(frames) } catch { throw Failure.corrupt }
        return frames
    }

    private func openRoot(create: Bool) throws -> Int32? {
        guard parentDirectory >= 0 else { throw Failure.invalidCache }
        var directory = dup(parentDirectory)
        guard directory >= 0 else { throw Failure.invalidCache }
        var owned = true; defer { if owned { Darwin.close(directory) } }
        for component in rootComponents {
            var next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT {
                guard create else { return nil }
                guard mkdirat(directory, component, mode_t(0o700)) == 0 || errno == EEXIST else { throw Failure.invalidCache }
                next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw Failure.invalidCache }
            Darwin.close(directory); directory = next
        }
        owned = false; return directory
    }
    private func openPackage(_ id: UUID, root: Int32? = nil) throws -> Int32 {
        let directory: Int32
        if let root { directory = root } else { guard let opened = try openRoot(create: false) else { throw Failure.invalidCache }; directory = opened }
        defer { if root == nil { Darwin.close(directory) } }
        let package = openat(directory, id.uuidString.lowercased(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard package >= 0 else { throw Failure.invalidCache }; return package
    }
    private func names(_ directory: Int32) throws -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw Failure.invalidCache }
        guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw Failure.invalidCache }
        defer { closedir(stream) }; rewinddir(stream)
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            guard result.count < 10_000 else { throw Failure.invalidCache }
            result.append(name)
        }
        return result
    }
    private func directoryBytes(_ directory: Int32, depth: Int = 0) throws -> Int64 {
        guard depth <= 3 else { throw Failure.invalidCache }
        var total: Int64 = 0
        for name in try names(directory) {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.invalidCache }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw Failure.invalidCache }
                defer { Darwin.close(child) }; total += try directoryBytes(child, depth: depth + 1)
            } else if info.st_mode & S_IFMT == S_IFREG {
                guard info.st_size >= 0 else { throw Failure.invalidCache }; total += Int64(info.st_size)
            } else { throw Failure.invalidCache }
            if total >= Self.maximumTotalBytes { return total }
        }
        return total
    }
    private static func createFile(_ name: String, in directory: Int32) throws -> Int32 {
        let file = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw Failure.invalidCache }; return file
    }
    private static func regularSize(_ file: Int32, maximum: Int64) throws -> Int64 {
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= maximum else { throw Failure.invalidInput }
        return Int64(info.st_size)
    }
    private static func write(_ data: Data, file: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let pointer = raw.baseAddress else { return }
            var count = 0
            while count < raw.count {
                let written = Darwin.write(file, pointer.advanced(by: count), raw.count - count)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Failure.invalidCache }; count += written
            }
        }
    }
    private static func stream(_ file: Int32, expectedSize: Int64, consume: (Data) throws -> Void) throws -> String {
        guard lseek(file, 0, SEEK_SET) == 0 else { throw Failure.corrupt }
        var hash = SHA256(), total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let received = Darwin.read(file, &buffer, buffer.count)
            if received < 0 && errno == EINTR { continue }
            guard received >= 0 else { throw Failure.invalidCache }
            if received == 0 { break }
            total += Int64(received); guard total <= expectedSize else { throw Failure.corrupt }
            let data = Data(buffer[0..<received]); hash.update(data: data); try consume(data)
        }
        guard total == expectedSize else { throw Failure.corrupt }; return hex(hash.finalize())
    }
    private static func read(_ name: String, in directory: Int32, maximum: Int) throws -> Data {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw Failure.corrupt }
        defer { Darwin.close(file) }
        let size = try regularSize(file, maximum: Int64(maximum))
        var data = Data(); data.reserveCapacity(Int(size))
        _ = try stream(file, expectedSize: size) { data.append($0) }; return data
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    private static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    private static func hex<T: Sequence>(_ bytes: T) -> String where T.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
    private static func canonicalParent(_ path: String) -> (anchor: String, missing: [String])? {
        var current = path, missing: [String] = []
        while true {
            if let pointer = realpath(current, nil) { let resolved = String(cString: pointer); free(pointer); return (resolved, Array(missing.reversed())) }
            guard errno == ENOENT, current != "/" else { return nil }
            let url = URL(fileURLWithPath: current); missing.append(url.lastPathComponent); current = url.deletingLastPathComponent().path
        }
    }
    private static func unsafeSymlink(_ path: String) -> Bool {
        var current = URL(fileURLWithPath: path).standardizedFileURL
        while current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK,
               current.path != "/var", current.path != "/tmp" { return true }
            current = current.deletingLastPathComponent()
        }
        return false
    }
}
