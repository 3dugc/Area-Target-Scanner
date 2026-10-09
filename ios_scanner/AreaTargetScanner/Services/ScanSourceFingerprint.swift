import Foundation
import CryptoKit
import CoreFoundation

/// Identity of the raw capture, independent of display names and provider export formats.
enum ScanSourceFingerprint {
    // Raw originals are streamed independently of the smaller derivative/upload ZIP budget.
    static let maximumOriginalSourceBytes: Int64 = 8 * 1024 * 1024 * 1024

    enum Failure: LocalizedError {
        case invalid, changed, cancelled
        var errorDescription: String? {
            switch self {
            case .invalid: return "无法核对扫描来源，请使用完整的原扫描数据。"
            case .changed: return "扫描源数据已改变，请重新上传后再比较。"
            case .cancelled: return "已停止核对扫描来源。"
            }
        }
    }

    static func compute(directory: URL, isCancelled: () -> Bool = { false }) throws -> String {
        let root = directory.standardizedFileURL
        guard root.isFileURL, try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              root.resolvingSymlinksInPath().path == root.path else { throw Failure.invalid }
        func document(_ path: String) throws -> [String: Any] {
            let url = try file(path, root: root)
            guard try size(url) <= 16 * 1024 * 1024,
                  let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw Failure.invalid
            }
            return object
        }
        let native = FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path)
        let metadata = try document(native ? "manifest.json" : "poses.json")
        let fallback = native ? nil : try document("intrinsics.json")
        guard let frames = metadata["frames"] as? [[String: Any]], !frames.isEmpty, frames.count <= 10_000 else {
            throw Failure.invalid
        }
        // Reject oversized collections before hashing any original. Keep the
        // sizes frozen so a file changed after preflight cannot expand the work.
        var total: Int64 = 0
        func reserveFile(_ path: String) throws -> Int64 {
            let expected = try size(file(path, root: root))
            guard expected <= maximumOriginalSourceBytes - total else { throw Failure.invalid }
            total += expected
            return expected
        }
        let imageSizes = try frames.map { frame -> Int64 in
            if isCancelled() { throw Failure.cancelled }
            guard let path = frame["imageFile"] as? String, path.hasPrefix("images/") else { throw Failure.invalid }
            return try reserveFile(path)
        }
        let modelSize = try reserveFile("model.obj")
        var hash = SHA256()
        hash.update(data: Data("area-target-source-v1\n".utf8))
        var previousTime = -Double.infinity
        var seen = Set<Int>()
        func addFile(_ path: String, expected: Int64) throws {
            let url = try file(path, root: root)
            guard try size(url) == expected else { throw Failure.changed }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var contents = SHA256()
            var consumed: Int64 = 0
            // Foundation may bridge reads through autoreleased NSData. Bound
            // those temporary objects to one chunk even for a valid large source.
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { return false }
                if isCancelled() { throw Failure.cancelled }
                consumed += Int64(chunk.count)
                guard consumed <= expected else { throw Failure.changed }
                contents.update(data: chunk)
                return true
            }) {}
            guard consumed == expected, try size(url) == expected else { throw Failure.changed }
            hash.update(data: Data("\(expected):".utf8))
            hash.update(data: Data(contents.finalize()))
        }
        for (frame, expectedImageSize) in zip(frames, imageSizes) {
            if isCancelled() { throw Failure.cancelled }
            guard let index = number(frame["index"]), index >= 0, index.rounded() == index, index < Double(Int.max),
                  seen.insert(Int(index)).inserted,
                  let time = number(frame["timestamp"]), time >= 0, time > previousTime,
                  let path = frame["imageFile"] as? String, path.hasPrefix("images/"),
                  let pose = frame["transform"] as? [Any], pose.count == 16, pose.allSatisfy({ number($0) != nil }),
                  let intrinsics = frame["intrinsics"] as? [String: Any] ?? fallback,
                  let dimensions = frame["image"] as? [String: Any] ?? fallback,
                  let fx = number(intrinsics["fx"]), let fy = number(intrinsics["fy"]),
                  let cx = number(intrinsics["cx"]), let cy = number(intrinsics["cy"]),
                  let width = number(dimensions["width"]), let height = number(dimensions["height"]),
                  fx > 0, fy > 0, width > 0, height > 0, width <= 8192, height <= 8192 else {
                throw Failure.invalid
            }
            previousTime = time
            // No path, name, GPS, account or packaging metadata enters the common identity.
            let canonical: [String: Any] = [
                "index": index, "timestamp": time, "transform": pose,
                "intrinsics": [fx, fy, cx, cy], "image": [width, height],
                "orientation": frame["imageOrientation"] as? String ?? "landscapeLeft"
            ]
            let data = try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys])
            hash.update(data: Data("\(data.count):".utf8)); hash.update(data: data)
            try addFile(path, expected: expectedImageSize)
        }
        hash.update(data: Data("model:".utf8))
        try addFile("model.obj", expected: modelSize)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func valid(_ fingerprint: String?) -> Bool {
        guard let fingerprint, fingerprint.utf8.count == 64 else { return false }
        return fingerprint.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func size(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize,
              bytes > 0, bytes <= 500 * 1024 * 1024 else { throw Failure.invalid }
        return Int64(bytes)
    }
    private static func file(_ path: String, root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.contains("\\"), !path.contains("\0"), !path.hasPrefix("/"),
              !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Failure.invalid }
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath().path == url.path else { throw Failure.invalid }
        return url
    }
}
