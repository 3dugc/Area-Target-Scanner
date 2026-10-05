import Foundation
import CoreFoundation
import ZIPFoundation
import CryptoKit
import ImageIO

protocol AreaTargetArchiving {
    func archive(scanDirectory: URL, uvUnwrap: Bool, profile: String, requirements: AreaTargetProcessingRequirements?,
                 progress: @escaping @Sendable (String) -> Void, isCancelled: @escaping @Sendable () -> Bool) throws -> URL
    func archive(scanDirectory: URL, uvUnwrap: Bool, progress: @escaping @Sendable (String) -> Void,
                 isCancelled: @escaping @Sendable () -> Bool) throws -> URL
}

extension AreaTargetArchiving {
    func archive(scanDirectory: URL, uvUnwrap: Bool, profile: String, requirements: AreaTargetProcessingRequirements?,
                 progress: @escaping @Sendable (String) -> Void, isCancelled: @escaping @Sendable () -> Bool) throws -> URL {
        try archive(scanDirectory: scanDirectory, uvUnwrap: uvUnwrap, progress: progress, isCancelled: isCancelled)
    }
}

final class AreaTargetScanArchive: AreaTargetArchiving {
    enum ArchiveError: Error, LocalizedError, Equatable {
        case invalidScan(String)
        case cancelled
        var errorDescription: String? {
            switch self {
            case .invalidScan(let reason): return reason
            case .cancelled: return "已取消扫描归档。"
            }
        }
    }
    func archive(scanDirectory: URL, uvUnwrap: Bool, profile: String, requirements: AreaTargetProcessingRequirements?,
                 progress: @escaping @Sendable (String) -> Void, isCancelled: @escaping @Sendable () -> Bool) throws -> URL {
        guard let requirements, let policy = requirements.preparationPolicy(for: profile) else {
            return try archive(scanDirectory: scanDirectory, uvUnwrap: uvUnwrap, progress: progress, isCancelled: isCancelled)
        }
        try check(isCancelled)
        let root = scanDirectory.standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard root.isFileURL, values.isDirectory == true, values.isSymbolicLink != true else { throw invalid("扫描目录无效") }
        progress("正在校验原始扫描并准备云端要求的上传副本…")
        let files = try selectedFiles(in: root, uvUnwrap: uvUnwrap, isCancelled: isCancelled)
        guard files.count <= AreaTargetFileSafety.maximumEntries else { throw invalid("扫描包含过多文件") }
        var sourceDigests: [String: String] = [:]
        for path in files {
            try check(isCancelled)
            sourceDigests[path] = try AreaTargetFileSafety.digest(AreaTargetFileSafety.safeFile(path, in: root),
                maximum: AreaTargetFileSafety.maximumExpandedBytes, isCancelled: isCancelled).sha256
        }
        let native = FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path)
        var manifest = try document(native ? "manifest.json" : "poses.json", in: root)
        guard let frames = manifest["frames"] as? [[String: Any]], !frames.isEmpty, frames.count <= 10_000 else { throw invalid("扫描清单已改变或关键帧无效") }
        let metadataPath = native ? "manifest.json" : "poses.json"
        guard try AreaTargetFileSafety.digest(AreaTargetFileSafety.safeFile(metadataPath, in: root),
            maximum: AreaTargetFileSafety.maximumMetadataBytes).sha256 == sourceDigests[metadataPath] else { throw invalid("扫描源文件已改变，请重新创建上传任务") }
        let fallback = native ? nil : try document("intrinsics.json", in: root)
        let count = min(frames.count, policy.maxFrames)
        let indices = count == 1 ? [0] : (0..<count).map { ($0 * (frames.count - 1) + (count - 1) / 2) / (count - 1) }
        var dimensions: [(width: Int, height: Int, outputWidth: Int, outputHeight: Int)] = []
        for index in indices {
            guard let value = frames[index]["image"] as? [String: Any] ?? fallback,
                  let width = integer(value["width"]), let height = integer(value["height"]),
                  width > 0, height > 0, width <= 8192, height <= 8192, Int64(width) * Int64(height) <= 32_000_000 else { throw invalid("关键帧图像尺寸无效") }
            let scale = min(1, Double(policy.maximumLongEdge) / Double(max(width, height)))
            dimensions.append((width, height, max(1, Int(floor(Double(width) * scale))), max(1, Int(floor(Double(height) * scale)))))
        }
        let firstPixels = dimensions.reduce(Int64(0)) { $0 + Int64($1.outputWidth) * Int64($1.outputHeight) }
        if firstPixels > policy.maximumTotalPixels {
            let scale = sqrt(Double(policy.maximumTotalPixels) / Double(firstPixels))
            dimensions = dimensions.map { ($0.width, $0.height, max(1, Int(floor(Double($0.outputWidth) * scale))), max(1, Int(floor(Double($0.outputHeight) * scale)))) }
        }
        let pixels = dimensions.reduce(Int64(0)) { $0 + Int64($1.outputWidth) * Int64($1.outputHeight) }
        guard pixels <= policy.maximumTotalPixels else {
            return try archive(scanDirectory: root, uvUnwrap: uvUnwrap, progress: progress, isCancelled: isCancelled)
        }
        let scaleRecords = indices.enumerated().map { offset, index in
            ["index": index, "width": dimensions[offset].width, "height": dimensions[offset].height,
             "outputWidth": dimensions[offset].outputWidth, "outputHeight": dimensions[offset].outputHeight]
        }
        let digest = SHA256.hash(data: try JSONSerialization.data(withJSONObject: scaleRecords, options: [.sortedKeys]))
            .map { String(format: "%02x", $0) }.joined()
        let preparation = AreaTargetClientPreparation(schemaVersion: 1, policy: requirements.policy, policyVersion: requirements.policyVersion,
            profile: profile, preparedBy: "client", originalFrameCount: frames.count, selectedFrameCount: count, selectedIndices: indices,
            processedPixelCount: pixels, resizedFrameCount: dimensions.filter { $0.width != $0.outputWidth || $0.height != $0.outputHeight }.count,
            maximumOutputLongEdge: dimensions.map { max($0.outputWidth, $0.outputHeight) }.max() ?? 0, scaleDigest: digest)
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("area-target-prepared-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        func target(_ path: String) throws -> URL {
            let url = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        }
        let framePaths = Set(frames.compactMap { $0["imageFile"] as? String })
        // Texture references can reuse a frame image: keep that resource even when
        // the image is not selected as a training frame.
        var texturePaths = Set<String>()
        for path in files where (path as NSString).pathExtension.lowercased() == "mtl" {
            try lines(AreaTargetFileSafety.safeFile(path, in: root), isCancelled: isCancelled) { line in
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if let keyword = parts.first, keyword.lowercased().hasPrefix("map_") || ["bump", "disp", "decal"].contains(keyword.lowercased()), parts.count == 2 {
                    let parent = (path as NSString).deletingLastPathComponent
                    texturePaths.insert(parent.isEmpty ? parts[1] : parent + "/" + parts[1])
                }
            }
        }
        for path in files where !["manifest.json", "poses.json", "intrinsics.json"].contains(path) && (!framePaths.contains(path) || texturePaths.contains(path)) {
            try check(isCancelled)
            try FileManager.default.copyItem(at: AreaTargetFileSafety.safeFile(path, in: root), to: target(path))
        }
        var preparedFrames: [[String: Any]] = []
        for (offset, index) in indices.enumerated() {
            try check(isCancelled)
            progress("正在准备上传关键帧（\(offset + 1)/\(count)）…")
            var frame = frames[index]
            let size = dimensions[offset]
            guard let path = frame["imageFile"] as? String, path.hasPrefix("images/"), AreaTargetFileSafety.safeRelativePath(path) else { throw invalid("关键帧图片路径无效") }
            let destination = try target(path)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            let source = try AreaTargetFileSafety.safeFile(path, in: root)
            if size.width == size.outputWidth && size.height == size.outputHeight { try FileManager.default.copyItem(at: source, to: destination) }
            else { try autoreleasepool { try resizedImage(source, to: destination, width: size.outputWidth, height: size.outputHeight) } }
            guard let originalK = frame["intrinsics"] as? [String: Any] ?? fallback,
                  let fx = finite(originalK["fx"]), let fy = finite(originalK["fy"]), let cx = finite(originalK["cx"]), let cy = finite(originalK["cy"]),
                  fx > 0, fy > 0, cx >= 0, cy >= 0, cx <= Double(size.width), cy <= Double(size.height) else { throw invalid("关键帧相机内参无效") }
            let sx = Double(size.outputWidth) / Double(size.width), sy = Double(size.outputHeight) / Double(size.height)
            let k: [String: Any] = ["fx": fx * sx, "cx": cx * sx, "fy": fy * sy, "cy": cy * sy]
            frame["intrinsics"] = k
            frame["image"] = ["width": size.outputWidth, "height": size.outputHeight]
            if !native && frame["imageOrientation"] == nil { frame["imageOrientation"] = "landscapeRight" }
            preparedFrames.append(frame)
        }
        if !native {
            manifest["schemaVersion"] = 1; manifest["coordinateSystem"] = "arkit-world"
            manifest["matrixLayout"] = "arkit-column-major"; manifest["units"] = "meters"
        }
        manifest["frames"] = preparedFrames
        manifest["clientPreparation"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preparation))
        func writeDocument(_ value: [String: Any], _ path: String) throws {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            guard data.count <= AreaTargetFileSafety.maximumMetadataBytes else { throw invalid("上传清单超过元数据大小限制") }
            try data.write(to: target(path), options: .atomic)
        }
        try writeDocument(manifest, "manifest.json")
        if !native || files.contains("poses.json") {
            var poses = try document("poses.json", in: root); poses["frames"] = preparedFrames
            try writeDocument(poses, "poses.json")
        }
        if !native || files.contains("intrinsics.json") {
            guard var shared = preparedFrames.first?["intrinsics"] as? [String: Any] else { throw invalid("上传相机内参无效") }
            shared["width"] = dimensions[0].outputWidth; shared["height"] = dimensions[0].outputHeight
            try writeDocument(shared, "intrinsics.json")
        }
        for path in files {
            try check(isCancelled)
            guard try AreaTargetFileSafety.digest(AreaTargetFileSafety.safeFile(path, in: root),
                maximum: AreaTargetFileSafety.maximumExpandedBytes, isCancelled: isCancelled).sha256 == sourceDigests[path] else {
                throw invalid("扫描源文件已改变，请重新创建上传任务")
            }
        }
        return try archive(scanDirectory: stage, uvUnwrap: uvUnwrap, progress: progress, isCancelled: isCancelled)
    }

    static func clientPreparation(in archiveURL: URL) throws -> AreaTargetClientPreparation? {
        guard let archive = try? Archive(url: archiveURL, accessMode: .read), let entry = archive["manifest.json"] else { return nil }
        guard entry.uncompressedSize <= UInt64(AreaTargetFileSafety.maximumMetadataBytes) else { throw ArchiveError.invalidScan("上传清单超过元数据大小限制") }
        var bytes = Data()
        _ = try archive.extract(entry) { data in
            bytes.append(data)
            guard bytes.count <= AreaTargetFileSafety.maximumMetadataBytes else { throw ArchiveError.invalidScan("上传清单超过元数据大小限制") }
        }
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let preparation = object["clientPreparation"] else { return nil }
        let value = try JSONDecoder().decode(AreaTargetClientPreparation.self, from: JSONSerialization.data(withJSONObject: preparation))
        guard value.schemaVersion == 1, value.policy == "mobile-scan-preparation-v1", value.policyVersion == 1,
              value.preparedBy == "client", ["fast", "quality"].contains(value.profile),
              (1...10_000).contains(value.originalFrameCount), (1...80).contains(value.selectedFrameCount),
              value.selectedFrameCount == value.selectedIndices.count, value.selectedIndices.first == 0,
              value.selectedIndices.last == value.originalFrameCount - 1,
              zip(value.selectedIndices, value.selectedIndices.dropFirst()).allSatisfy({ $0 < $1 }),
              value.processedPixelCount > 0, value.processedPixelCount <= 200_000_000,
              (0...value.selectedFrameCount).contains(value.resizedFrameCount), (1...1600).contains(value.maximumOutputLongEdge),
              AreaTargetFileSafety.isLowerHex64(value.scaleDigest) else { throw ArchiveError.invalidScan("上传预处理记录无效") }
        return value
    }

    private func resizedImage(_ sourceURL: URL, to destinationURL: URL, width: Int, height: Int) throws {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false, kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false, kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, options as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw invalid("无法准备上传图像") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage(), let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, "public.jpeg" as CFString, 1, nil) else { throw invalid("无法写入上传图像") }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw invalid("上传图像编码失败") }
    }

    func archive(scanDirectory: URL, uvUnwrap: Bool, progress: @escaping @Sendable (String) -> Void,
                 isCancelled: @escaping @Sendable () -> Bool) throws -> URL {
        try check(isCancelled)
        let root = scanDirectory.standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard root.isFileURL, values.isDirectory == true, values.isSymbolicLink != true else { throw invalid("扫描目录无效") }
        progress("正在校验扫描数据…")
        let paths: [String]
        do { paths = try selectedFiles(in: root, uvUnwrap: uvUnwrap, isCancelled: isCancelled) }
        catch let error as ArchiveError { throw error }
        catch { throw invalid("扫描元数据、模型或图片不完整，请重新导出扫描") }
        guard paths.count <= AreaTargetFileSafety.maximumEntries else { throw invalid("扫描包含过多文件") }
        var snapshots: [(path: String, url: URL, size: Int64, digest: String)] = []
        var total: Int64 = 0
        for path in paths {
            try check(isCancelled)
            let url = try AreaTargetFileSafety.safeFile(path, in: root)
            let digest: (size: Int64, sha256: String)
            do { digest = try AreaTargetFileSafety.digest(url, maximum: AreaTargetFileSafety.maximumExpandedBytes, isCancelled: isCancelled) }
            catch AreaTargetAPIError.cancelled { throw ArchiveError.cancelled }
            total += digest.size
            guard total <= AreaTargetFileSafety.maximumExpandedBytes else { throw invalid("扫描展开后超过 500 MiB 限制") }
            snapshots.append((path, url, digest.size, digest.sha256))
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("area-target-scan-" + UUID().uuidString.lowercased() + ".zip")
        do {
            try write(snapshots, root: root, to: output, progress: progress, isCancelled: isCancelled)
            try check(isCancelled)
            guard try AreaTargetFileSafety.regularFileSize(output) < AreaTargetFileSafety.maximumZIPBytes - 4096 else { throw invalid("扫描 ZIP 超过上传大小限制") }
            progress("扫描归档已就绪")
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            if isCancelled() || (error as? AreaTargetAPIError) == .cancelled { throw ArchiveError.cancelled }
            if let error = error as? ArchiveError { throw error }
            throw invalid("扫描归档失败，请检查可用存储空间后重试")
        }
    }

    private func selectedFiles(in root: URL, uvUnwrap: Bool, isCancelled: () -> Bool) throws -> [String] {
        var paths = Set<String>()
        let native = root.appendingPathComponent("manifest.json")
        let frames: [[String: Any]]
        let legacyIntrinsics: [String: Any]?
        if FileManager.default.fileExists(atPath: native.path) {
            let manifest = try document("manifest.json", in: root)
            guard integer(manifest["schemaVersion"]) == 1, manifest["coordinateSystem"] as? String == "arkit-world",
                  manifest["matrixLayout"] as? String == "arkit-column-major", manifest["units"] as? String == "meters",
                  let listed = manifest["frames"] as? [[String: Any]] else { throw invalid("扫描清单的版本或坐标契约无效") }
            frames = listed
            legacyIntrinsics = nil
            paths.insert("manifest.json")
            for path in ["poses.json", "intrinsics.json"] where FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
                _ = try document(path, in: root)
                paths.insert(path)
            }
        } else {
            guard let listed = try document("poses.json", in: root)["frames"] as? [[String: Any]] else { throw invalid("扫描位姿缺少关键帧") }
            frames = listed
            legacyIntrinsics = try document("intrinsics.json", in: root)
            paths.formUnion(["poses.json", "intrinsics.json"])
        }
        guard !frames.isEmpty, frames.count <= AreaTargetFileSafety.maximumEntries - 4 else { throw invalid("扫描缺少关键帧或文件数量过多") }
        var indices = Set<Int>()
        var images = Set<String>()
        var previousTime: Double?
        for frame in frames {
            try check(isCancelled)
            guard let index = integer(frame["index"]), index >= 0, indices.insert(index).inserted,
                  let time = finite(frame["timestamp"]), time >= 0, previousTime.map({ time > $0 }) ?? true,
                  let image = frame["imageFile"] as? String, image.hasPrefix("images/"),
                  AreaTargetFileSafety.safeRelativePath(image), images.insert(image).inserted,
                  ["jpg", "jpeg", "png"].contains((image as NSString).pathExtension.lowercased()),
                  let transformValues = frame["transform"] as? [Any], transformValues.count == 16,
                  transformValues.allSatisfy({ finite($0) != nil }) else { throw invalid("关键帧位姿、图片路径或时间戳无效") }
            let transform = transformValues.compactMap(finite)
            guard
                  abs(transform[3]) < 0.0001, abs(transform[7]) < 0.0001, abs(transform[11]) < 0.0001, abs(transform[15] - 1) < 0.0001 else {
                throw invalid("关键帧位姿、图片路径或时间戳无效")
            }
            previousTime = time
            let k = frame["intrinsics"] as? [String: Any] ?? legacyIntrinsics
            let dimensions = frame["image"] as? [String: Any] ?? legacyIntrinsics
            guard let k, let dimensions, let width = integer(dimensions["width"]), let height = integer(dimensions["height"]),
                  width > 0, height > 0, width <= 8192, height <= 8192, Int64(width) * Int64(height) <= 32_000_000,
                  let fx = finite(k["fx"]), let fy = finite(k["fy"]), let cx = finite(k["cx"]), let cy = finite(k["cy"]),
                  fx > 0, fy > 0, cx >= 0, cy >= 0, cx <= Double(width), cy <= Double(height) else { throw invalid("关键帧图像尺寸或相机内参无效") }
            if legacyIntrinsics == nil {
                guard ["landscapeLeft", "landscapeRight"].contains(frame["imageOrientation"] as? String ?? "") else { throw invalid("扫描图像方向无效") }
            }
            let file = try AreaTargetFileSafety.safeFile(image, in: root)
            guard try AreaTargetFileSafety.regularFileSize(file) > 0 else { throw invalid("扫描包含空图片") }
            try validateImage(file, width: width, height: height)
            paths.insert(image)
        }

        let model = try AreaTargetFileSafety.safeFile("model.obj", in: root)
        guard try AreaTargetFileSafety.regularFileSize(model) <= AreaTargetFileSafety.maximumExpandedBytes else { throw invalid("OBJ 模型超过 500 MiB 大小限制") }
        paths.insert("model.obj")
        var materials = Set<String>()
        var hasVertex = false
        var hasFace = false
        try lines(model, isCancelled: isCancelled) { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.first == "v" { hasVertex = true }
            if parts.first == "f" { hasFace = true }
            if parts.first == "mtllib" {
                guard parts.count > 1 else { throw self.invalid("模型材质引用无效") }
                for path in parts.dropFirst() {
                    guard AreaTargetFileSafety.safeRelativePath(path), (path as NSString).pathExtension.lowercased() == "mtl" else { throw self.invalid("模型材质路径无效") }
                    materials.insert(path)
                }
            }
        }
        guard hasVertex, hasFace else { throw invalid("扫描没有可上传的 OBJ 网格") }
        var textures = Set<String>()
        for material in materials {
            let file = try AreaTargetFileSafety.safeFile(material, in: root)
            paths.insert(material)
            try lines(file, isCancelled: isCancelled) { line in
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard let keyword = parts.first, keyword.lowercased().hasPrefix("map_") || ["bump", "disp", "decal"].contains(keyword.lowercased()) else { return }
                guard parts.count == 2 else { throw self.invalid("模型纹理引用格式无效") }
                let relative = parts[1]
                guard AreaTargetFileSafety.safeRelativePath(relative), ["jpg", "jpeg", "png"].contains((relative as NSString).pathExtension.lowercased()) else { throw self.invalid("模型纹理路径无效") }
                let parent = (material as NSString).deletingLastPathComponent
                let texture = parent.isEmpty ? relative : parent + "/" + relative
                _ = try AreaTargetFileSafety.safeFile(texture, in: root)
                try self.validateImage(AreaTargetFileSafety.safeFile(texture, in: root))
                textures.insert(texture)
            }
        }
        if !uvUnwrap && (materials.isEmpty || textures.isEmpty) { throw invalid("关闭 UV 重建时需要完整的 OBJ 材质与纹理") }
        paths.formUnion(textures)
        return paths.sorted()
    }

    private func write(_ files: [(path: String, url: URL, size: Int64, digest: String)], root: URL, to output: URL,
                       progress: @escaping @Sendable (String) -> Void, isCancelled: @escaping @Sendable () -> Bool) throws {
        let archive = try Archive(url: output, accessMode: .create)
        for (index, file) in files.enumerated() {
            try check(isCancelled)
            progress("正在打包扫描文件（\(index + 1)/\(files.count)）…")
            _ = try AreaTargetFileSafety.safeFile(file.path, in: root)
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            var digest = SHA256()
            var consumed: Int64 = 0
            try archive.addEntry(with: file.path, type: .file, uncompressedSize: file.size, bufferSize: 64 * 1024) { position, count in
                try self.check(isCancelled)
                guard position == consumed else { throw self.invalid("扫描文件读取位置无效") }
                let data = try handle.read(upToCount: count) ?? Data()
                consumed += Int64(data.count)
                digest.update(data: data)
                return data
            }
            guard consumed == file.size, try AreaTargetFileSafety.regularFileSize(file.url) == file.size,
                  digest.finalize().map({ String(format: "%02x", $0) }).joined() == file.digest else { throw invalid("扫描源文件已改变，请重新创建上传任务") }
        }
    }

    private func document(_ path: String, in root: URL) throws -> [String: Any] {
        let data = try AreaTargetFileSafety.smallData(AreaTargetFileSafety.safeFile(path, in: root))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid("扫描元数据格式无效") }
        return object
    }
    private func finite(_ value: Any?) -> Double? { guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }; return value.doubleValue }
    private func integer(_ value: Any?) -> Int? {
        guard let number = finite(value), number.rounded() == number, number >= Double(Int.min), number < Double(Int.max) else { return nil }
        return Int(number)
    }
    private func check(_ cancelled: () -> Bool) throws { if cancelled() { throw ArchiveError.cancelled } }
    private func invalid(_ text: String) -> ArchiveError { .invalidScan(text) }

    private func validateImage(_ url: URL, width: Int? = nil, height: Int? = nil) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let actualWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let actualHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              actualWidth > 0, actualHeight > 0, actualWidth <= 8192, actualHeight <= 8192,
              Int64(actualWidth) * Int64(actualHeight) <= 32_000_000,
              width.map({ actualWidth == $0 }) ?? true, height.map({ actualHeight == $0 }) ?? true else {
            throw invalid("扫描图片无法读取、尺寸不匹配或超过图像大小限制")
        }
    }

    /// OBJ/MTL are read line by line with a bounded line length, including cancellation during large meshes.
    private func lines(_ url: URL, isCancelled: () -> Bool, consume: (String) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var remainder = Data()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            try check(isCancelled)
            remainder.append(data)
            while let newline = remainder.firstIndex(of: 10) {
                let lineData = remainder.prefix(upTo: newline)
                guard lineData.count <= 65_536, let line = String(data: lineData, encoding: .utf8) else { throw invalid("模型文本格式无效") }
                try consume(line.trimmingCharacters(in: .whitespacesAndNewlines))
                remainder.removeSubrange(...newline)
            }
            guard remainder.count <= 65_536 else { throw invalid("模型文本行过长") }
        }
        if !remainder.isEmpty {
            guard let line = String(data: remainder, encoding: .utf8) else { throw invalid("模型文本格式无效") }
            try consume(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
