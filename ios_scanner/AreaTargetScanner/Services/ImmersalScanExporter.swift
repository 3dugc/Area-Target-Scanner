import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import ZIPFoundation
import Darwin

struct ImmersalUploadFrame {
    let png: Data
    let metadata: Data
}

/// An immutable manifest snapshot. Images are read on demand, with content checks.
struct ImmersalUploadScan {
    let frameCount: Int
    let fingerprint: String
    let readFrame: (Int, () -> Bool) throws -> ImmersalUploadFrame
}

protocol ImmersalFramePreparing {
    func prepareUpload(scanDirectory: URL, isCancelled: () -> Bool) throws -> ImmersalUploadScan
}

/// Converts a persisted schema-v1 scan into a flat Immersal image/pose ZIP.
/// Call from a background queue: image conversion intentionally retains only one frame at a time.
final class ImmersalScanExporter: ImmersalFramePreparing {
    enum ExportError: Error, LocalizedError {
        case invalidScan(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidScan(let reason): return reason
            case .cancelled: return "已取消 Immersal 导出"
            }
        }
    }

    private let publish: (URL, URL) throws -> Void

    /// Publication is a single same-filesystem rename; failures leave an existing good ZIP intact.
    init(publish: ((URL, URL) throws -> Void)? = nil) {
        self.publish = publish ?? Self.publishAtomically
    }

    /// Lightweight history eligibility check. Decoding/encoding image pixels happens only on export.
    func availability(scanDirectory: URL) -> String? {
        do {
            _ = try loadScan(scanDirectory)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func export(
        scanDirectory: URL,
        progress: @escaping (String) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws -> URL {
        try checkCancellation(isCancelled)
        progress("正在校验 Immersal 扫描数据…")
        let scan = try loadScan(scanDirectory, isCancelled: isCancelled)
        let parent = scanDirectory.deletingLastPathComponent()
        let name = scanDirectory.lastPathComponent + "_immersal"
        let output = parent.appendingPathComponent(name + ".zip")
        let temporary = parent.appendingPathComponent(".\(name)-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }

        // Leave this scope (and close the ZIP file) before atomic publication.
        try writeArchive(scan, to: temporary, progress: progress, isCancelled: isCancelled)
        try checkCancellation(isCancelled)
        progress("正在保存 Immersal ZIP…")
        try checkCancellation(isCancelled)
        try publish(temporary, output)
        return output
    }

    /// Validates the whole scan before any remote mutation. No ZIP or PNG files are created.
    func prepareUpload(scanDirectory: URL, isCancelled: () -> Bool) throws -> ImmersalUploadScan {
        let scan = try loadScan(scanDirectory, isCancelled: isCancelled)
        var digest = SHA256()
        var imageDigests: [Data] = []
        for frame in scan.frames {
            try autoreleasepool {
                try checkCancellation(isCancelled)
                let imageURL = try frameFile(frame, in: scan.directory)
                let data = try Data(contentsOf: imageURL)
                let imageDigest = Data(SHA256.hash(data: data))
                // Exercise the same decoder/encoder as upload and export before accepting the scan.
                _ = try makePNG(imageURL, frame: frame)
                let metadata = try makeJSON(frame, imagePath: frame.imageFile, fallbackRun: scan.fallbackRun)
                digest.update(data: metadata)
                digest.update(data: imageDigest)
                imageDigests.append(imageDigest)
            }
        }
        let fingerprint = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return ImmersalUploadScan(frameCount: scan.frames.count, fingerprint: fingerprint) { index, cancelled in
            try self.checkCancellation(cancelled)
            guard scan.frames.indices.contains(index) else { throw ExportError.invalidScan("上传帧编号越界") }
            let frame = scan.frames[index]
            let url = try self.frameFile(frame, in: scan.directory)
            guard Data(SHA256.hash(data: try Data(contentsOf: url))) == imageDigests[index] else {
                throw self.invalid(frame, "源图片已改变，请重新创建上传任务")
            }
            let png = try self.makePNG(url, frame: frame)
            let json = try self.makeJSON(frame, imagePath: frame.imageFile, fallbackRun: scan.fallbackRun)
            var object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
            object.removeValue(forKey: "imagePath")
            try self.checkCancellation(cancelled)
            return ImmersalUploadFrame(png: png, metadata: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        }
    }

    func uploadFrame(at index: Int, from scan: ImmersalUploadScan, isCancelled: () -> Bool) throws -> ImmersalUploadFrame {
        try scan.readFrame(index, isCancelled)
    }

    // MARK: Persisted metadata

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let coordinateSystem: String
        let matrixLayout: String
        let units: String
        let frames: [Frame]
    }

    private struct Frame: Decodable {
        let index: Int
        let timestamp: Double
        let imageFile: String
        let transform: [Double]
        let imageOrientation: String
        let image: Dimensions
        let intrinsics: Intrinsics
        let run: Int?
        let location: Location?
    }

    private struct Dimensions: Decodable {
        let width: Int
        let height: Int
    }

    private struct Intrinsics: Decodable {
        let fx: Double
        let fy: Double
        let cx: Double
        let cy: Double
    }

    private struct Location: Decodable {
        let latitude: Double?
        let longitude: Double?
        let altitude: Double?
        let timestamp: Double?
        let horizontalAccuracy: Double?
        let verticalAccuracy: Double?

        var coordinates: (latitude: Double, longitude: Double, altitude: Double) {
            guard let latitude, latitude.isFinite, (-90...90).contains(latitude),
                  let longitude, longitude.isFinite, (-180...180).contains(longitude),
                  let timestamp, timestamp.isFinite,
                  let horizontalAccuracy, horizontalAccuracy.isFinite, horizontalAccuracy >= 0 else {
                return (0, 0, 0)
            }
            // Capture already checks age against wall time. Frame timestamps use a different clock.
            let validAltitude: Double
            if let altitude, altitude.isFinite,
               let verticalAccuracy, verticalAccuracy.isFinite, verticalAccuracy >= 0 {
                validAltitude = altitude
            } else {
                validAltitude = 0
            }
            return (latitude, longitude, validAltitude)
        }
    }

    private struct ValidatedScan {
        let directory: URL
        let frames: [Frame]
        let fallbackRun: Int
    }

    private func loadScan(_ directory: URL, isCancelled: () -> Bool = { false }) throws -> ValidatedScan {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let manifestURL = try safeFile("manifest.json", in: root)
        let data: Data
        let manifest: Manifest
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw ExportError.invalidScan("扫描清单无法读取，请重新扫描")
        }
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch let error as DecodingError {
            throw decodingError(error, data: data)
        } catch {
            throw ExportError.invalidScan("扫描清单缺少必要信息或格式无效，请重新扫描")
        }
        guard manifest.schemaVersion == 1, manifest.coordinateSystem == "arkit-world",
              manifest.matrixLayout == "arkit-column-major", manifest.units == "meters" else {
            throw ExportError.invalidScan("扫描清单的版本、坐标系、矩阵布局或单位不受支持")
        }
        guard !manifest.frames.isEmpty else {
            throw ExportError.invalidScan("扫描中没有可导出的关键帧")
        }
        var indices = Set<Int>()
        var imageFiles = Set<String>()
        for frame in manifest.frames {
            try checkCancellation(isCancelled)
            guard frame.index >= 0, indices.insert(frame.index).inserted else {
                throw ExportError.invalidScan("扫描包含无效或重复的帧编号")
            }
            guard frame.timestamp.isFinite, frame.timestamp >= 0 else {
                throw invalid(frame, "时间戳无效")
            }
            guard frame.imageOrientation == "landscapeRight" else {
                throw invalid(frame, "图像方向不是原始 landscapeRight，无法安全导出")
            }
            guard frame.image.width > 0, frame.image.height > 0 else {
                throw invalid(frame, "图像尺寸无效")
            }
            let rowBytes = frame.image.width.multipliedReportingOverflow(by: 4)
            guard !rowBytes.overflow,
                  !rowBytes.partialValue.multipliedReportingOverflow(by: frame.image.height).overflow else {
                throw invalid(frame, "图像尺寸超出支持范围")
            }
            let k = frame.intrinsics
            guard k.fx.isFinite, k.fy.isFinite, k.cx.isFinite, k.cy.isFinite, k.fx > 0, k.fy > 0 else {
                throw invalid(frame, "相机内参无效")
            }
            if let run = frame.run, !(1...Int(Int32.max)).contains(run) {
                throw invalid(frame, "run 必须是正的 31 位整数")
            }
            try validatePose(frame)
            let file = try frameFile(frame, in: root)
            guard imageFiles.insert(file.path).inserted else {
                throw invalid(frame, "图像文件重复")
            }
        }
        let prefix = SHA256.hash(data: data).prefix(4)
        let digest = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return ValidatedScan(directory: root, frames: manifest.frames,
                             fallbackRun: max(1, Int(digest & 0x7fff_ffff)))
    }

    private func decodingError(_ error: DecodingError, data: Data) -> ExportError {
        let context: DecodingError.Context
        switch error {
        case .keyNotFound(_, let value), .valueNotFound(_, let value),
             .typeMismatch(_, let value), .dataCorrupted(let value): context = value
        @unknown default: return .invalidScan("扫描清单格式无效，请重新扫描")
        }
        if let position = context.codingPath.first(where: { $0.intValue != nil })?.intValue,
           let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let frames = document["frames"] as? [[String: Any]], frames.indices.contains(position),
           let index = frames[position]["index"] as? Int {
            return .invalidScan("第 \(index) 帧：元数据缺少必要字段或格式无效")
        }
        return .invalidScan("扫描清单缺少必要信息或格式无效，请重新扫描")
    }

    private func validatePose(_ frame: Frame) throws {
        let t = frame.transform
        guard t.count == 16, t.allSatisfy(\.isFinite),
              abs(t[3]) < 1e-6, abs(t[7]) < 1e-6, abs(t[11]) < 1e-6, abs(t[15] - 1) < 1e-6 else {
            throw invalid(frame, "相机位姿必须是有限的 4×4 仿射矩阵")
        }
        let tolerance = 0.002
        for col in 0..<3 {
            for other in col..<3 {
                let dot = (0..<3).reduce(0.0) { $0 + t[col * 4 + $1] * t[other * 4 + $1] }
                guard abs(dot - (col == other ? 1 : 0)) < tolerance else {
                    throw invalid(frame, "相机旋转矩阵不是正交单位矩阵")
                }
            }
        }
        let determinant = t[0] * (t[5] * t[10] - t[9] * t[6])
            - t[4] * (t[1] * t[10] - t[9] * t[2])
            + t[8] * (t[1] * t[6] - t[5] * t[2])
        guard abs(determinant - 1) < tolerance else {
            throw invalid(frame, "相机旋转矩阵包含反射或缩放")
        }
    }

    /// Reject traversal and symlinks at every path component, including directory symlinks.
    private func safeFile(_ path: String, in directory: URL) throws -> URL {
        let components = path.components(separatedBy: "/")
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ExportError.invalidScan("扫描清单包含不安全的文件路径")
        }
        var file = directory
        do {
            for component in components {
                file.appendPathComponent(component)
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                    throw ExportError.invalidScan("扫描文件不能使用符号链接")
                }
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.int64Value > 0,
                  file.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/") else {
                throw ExportError.invalidScan("扫描文件无效或为空：\(path)")
            }
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.invalidScan("扫描文件缺失或无法读取：\(path)")
        }
        return file
    }

    // MARK: Image and ZIP streaming

    private func frameFile(_ frame: Frame, in directory: URL) throws -> URL {
        do {
            return try safeFile(frame.imageFile, in: directory)
        } catch {
            throw invalid(frame, error.localizedDescription)
        }
    }

    private func writeArchive(
        _ scan: ValidatedScan, to url: URL,
        progress: (String) -> Void, isCancelled: () -> Bool
    ) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (offset, frame) in scan.frames.enumerated() {
            try autoreleasepool {
                try checkCancellation(isCancelled)
                let imageURL = try frameFile(frame, in: scan.directory)
                let name = String(format: "frame_%04ld", frame.index)
                progress("正在转换第 \(offset + 1)/\(scan.frames.count) 帧…")
                try checkCancellation(isCancelled)
                let png = try makePNG(imageURL, frame: frame)
                try checkCancellation(isCancelled)
                progress("正在打包第 \(offset + 1)/\(scan.frames.count) 帧…")
                try checkCancellation(isCancelled)
                try add(png, path: name + ".png", to: archive, isCancelled: isCancelled)
                let json = try makeJSON(frame, imagePath: name + ".png", fallbackRun: scan.fallbackRun)
                try add(json, path: name + ".json", to: archive, isCancelled: isCancelled)
                try checkCancellation(isCancelled)
            }
        }
    }

    private func makePNG(_ url: URL, frame: Frame) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == frame.image.width,
              properties[kCGImagePropertyPixelHeight] as? Int == frame.image.height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == frame.image.width, image.height == frame.image.height else {
            throw invalid(frame, "JPEG 无法解码或实际尺寸与清单不匹配")
        }
        // ImageIO's direct decode keeps raw sensor pixels and does not apply EXIF orientation.
        let width = image.width, height = image.height
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let bytes = context.data else {
            throw invalid(frame, "无法分配图像转换内存")
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // A 24-bit provider is necessary: a 32-bit context alone can produce an RGBA PNG.
        let rgba = bytes.assumingMemoryBound(to: UInt8.self)
        var rgb = Data(count: width * height * 3)
        rgb.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            let destination = buffer.bindMemory(to: UInt8.self)
            for pixel in 0..<(width * height) {
                for channel in 0..<3 { destination[pixel * 3 + channel] = rgba[pixel * 4 + channel] }
            }
        }
        guard let provider = CGDataProvider(data: rgb as CFData),
              let rgbImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                                     bytesPerRow: width * 3, space: space, bitmapInfo: [], provider: provider,
                                     decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw invalid(frame, "无法生成 RGB 图像")
        }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else {
            throw invalid(frame, "无法创建 PNG 编码器")
        }
        CGImageDestinationAddImage(destination, rgbImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw invalid(frame, "PNG 编码失败")
        }
        let data = result as Data
        guard data.count > 25, data[24] == 8, data[25] == 2 else {
            throw invalid(frame, "PNG 编码器未生成无透明通道的 8 位 RGB 图像")
        }
        return data
    }

    private func makeJSON(_ frame: Frame, imagePath: String, fallbackRun: Int) throws -> Data {
        let t = frame.transform, k = frame.intrinsics
        let gps = frame.location?.coordinates ?? (latitude: 0, longitude: 0, altitude: 0)
        // Camera-to-world: ARKit (right, up, back) → Immersal (right, down, forward).
        // R_immersal = R_arkit * diag(1, -1, -1); world translation is unchanged.
        let object: [String: Any] = [
            "imagePath": imagePath, "run": frame.run ?? fallbackRun, "index": frame.index, "anchor": false,
            "fx": k.fx, "fy": k.fy, "ox": k.cx, "oy": k.cy,
            "px": t[12], "py": t[13], "pz": t[14],
            "r00": t[0], "r01": -t[4], "r02": -t[8],
            "r10": t[1], "r11": -t[5], "r12": -t[9],
            "r20": t[2], "r21": -t[6], "r22": -t[10],
            "latitude": gps.latitude, "longitude": gps.longitude, "altitude": gps.altitude
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func add(_ data: Data, path: String, to archive: Archive, isCancelled: () -> Bool) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                             modificationDate: Date(timeIntervalSince1970: 315_532_800),
                             compressionMethod: .none) { position, size in
            try self.checkCancellation(isCancelled)
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    private func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw ExportError.cancelled }
    }

    private func invalid(_ frame: Frame, _ reason: String) -> ExportError {
        .invalidScan("第 \(frame.index) 帧：\(reason)")
    }

    private static func publishAtomically(_ temporary: URL, _ destination: URL) throws {
        let status = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in Darwin.rename(source!, target!) }
        }
        guard status == 0 else {
            let reason = String(cString: strerror(errno))
            throw ExportError.invalidScan("无法保存 Immersal ZIP：\(reason)")
        }
    }
}
