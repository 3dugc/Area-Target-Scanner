import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

struct ImmersalAlignmentFrame {
    let imageURL: URL
    let width: Int
    let height: Int
    let intrinsics: SIMD4<Float>
    let scanFromCamera: simd_float4x4
    let index: Int
    fileprivate let scanDirectory: URL
    fileprivate let relativeImagePath: String
}

/// Reads persisted scan keyframes for local map-to-scan alignment. Selection only
/// probes image metadata; decode one selected frame at a time off the main thread.
enum ImmersalAlignmentFrames {
    enum AlignmentError: LocalizedError {
        case invalidScan(String)
        var errorDescription: String? {
            switch self { case .invalidScan(let reason): return reason }
        }
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let coordinateSystem: String
        let matrixLayout: String
        let units: String
        let frames: [Frame]
    }

    private struct Frame: Decodable {
        let index: Int
        let imageFile: String
        let transform: [Double]
        let image: Dimensions
        let intrinsics: Intrinsics
        let imageOrientation: String
        let run: Int?
    }

    private struct Dimensions: Decodable { let width: Int; let height: Int }
    private struct Intrinsics: Decodable { let fx: Double; let fy: Double; let cx: Double; let cy: Double }

    static func select(scanDirectory: URL) throws -> [ImmersalAlignmentFrame] {
        guard scanDirectory.isFileURL else { throw invalid("只能从本机扫描目录读取标定帧。") }
        let directoryAttributes = try attributes(of: scanDirectory)
        guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw invalid("扫描目录无效，不能使用符号链接。")
        }
        let root = scanDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let manifestURL = try safeFile("manifest.json", in: root, maximumBytes: 16 * 1024 * 1024)
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)) }
        catch { throw invalid("扫描清单缺少必要字段或格式无效，无法读取标定帧。") }
        guard manifest.schemaVersion == 1, manifest.coordinateSystem == "arkit-world",
              manifest.matrixLayout == "arkit-column-major", manifest.units == "meters" else {
            throw invalid("扫描清单的版本、坐标系、矩阵布局或单位不受支持。")
        }
        guard manifest.frames.count >= 3 else { throw invalid("至少需要 3 张不同的扫描关键帧才能确认模型对齐。") }
        let runs = Set(manifest.frames.map { $0.run ?? 0 })
        guard runs.count == 1, runs.allSatisfy({ (0...Int(Int32.max)).contains($0) }) else {
            throw invalid("扫描包含不同或无效的跟踪批次，无法确认扫描坐标是否连续，请使用同一次连续扫描的数据。")
        }

        var indices = Set<Int>()
        var files = Set<URL>()
        let validated = try manifest.frames.map { value -> ImmersalAlignmentFrame in
            guard value.index >= 0, indices.insert(value.index).inserted else {
                throw invalid("扫描包含无效或重复的关键帧编号。")
            }
            guard value.imageOrientation == "landscapeRight" else {
                throw invalid("第 \(value.index) 帧不是原始 landscapeRight 图像，无法确认相机方向。")
            }
            try validateDimensions(width: value.image.width, height: value.image.height)
            let k = value.intrinsics
            let values = [k.fx, k.fy, k.cx, k.cy]
            guard values.allSatisfy({ $0.isFinite && Float($0).isFinite }),
                  Float(k.fx) > 0, Float(k.fy) > 0,
                  k.cx >= 0, k.cx < Double(value.image.width),
                  k.cy >= 0, k.cy < Double(value.image.height) else {
                throw invalid("第 \(value.index) 帧的相机内参无效或不在图像范围内。")
            }
            let pose = try validatedPose(value.transform, index: value.index)
            let file = try safeFile(value.imageFile, in: root)
            guard files.insert(file).inserted else { throw invalid("扫描关键帧重复引用同一图像。") }
            _ = try imageSource(file, width: value.image.width, height: value.image.height)
            return ImmersalAlignmentFrame(imageURL: file, width: value.image.width, height: value.image.height,
                                          intrinsics: SIMD4(Float(k.fx), Float(k.fy), Float(k.cx), Float(k.cy)),
                                          scanFromCamera: pose, index: value.index,
                                          scanDirectory: root, relativeImagePath: value.imageFile)
        }.sorted { $0.index < $1.index }

        let count = min(8, validated.count)
        return (0..<count).map { position in
            let offset = Int((Double(position) * Double(validated.count - 1) / Double(count - 1)).rounded())
            return validated[offset]
        }
    }

    static func pixels(for frame: ImmersalAlignmentFrame) throws -> Data {
        try validateDimensions(width: frame.width, height: frame.height)
        // Check again because a file or directory may have changed since selection.
        let file = try safeFile(frame.relativeImagePath, in: frame.scanDirectory)
        guard file == frame.imageURL else { throw invalid("标定帧路径已改变，请重新选择扫描。") }
        let source = try imageSource(file, width: frame.width, height: frame.height)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == frame.width, image.height == frame.height else {
            throw invalid("标定帧图像无法解码或实际尺寸已改变。")
        }
        var pixels = Data(count: frame.width * frame.height)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: frame.width, height: frame.height,
                                          bitsPerComponent: 8, bytesPerRow: frame.width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw invalid("无法分配标定帧灰度图像。")
            }
            // Match ImmersalScanExporter.makePNG: direct ImageIO decode and an
            // untransformed CGContext draw preserve raw top-to-bottom pixel rows.
            // Do not apply EXIF orientation or introduce a vertical flip here.
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        }
        return pixels
    }

    private static func validateDimensions(width: Int, height: Int) throws {
        guard (1...4096).contains(width), (1...4096).contains(height), width * height <= 16_000_000 else {
            throw invalid("标定帧图像尺寸无效：每边最多 4096 像素，总计最多 1600 万像素。")
        }
    }

    private static func validatedPose(_ t: [Double], index: Int) throws -> simd_float4x4 {
        guard t.count == 16, t.allSatisfy({ $0.isFinite && Float($0).isFinite }),
              abs(t[3]) < 1e-6, abs(t[7]) < 1e-6, abs(t[11]) < 1e-6, abs(t[15] - 1) < 1e-6 else {
            throw invalid("第 \(index) 帧相机位姿必须是有限的 4×4 仿射矩阵。")
        }
        let tolerance = 0.002
        for column in 0..<3 {
            for other in column..<3 {
                let dot = (0..<3).reduce(0.0) { $0 + t[column * 4 + $1] * t[other * 4 + $1] }
                guard abs(dot - (column == other ? 1 : 0)) < tolerance else {
                    throw invalid("第 \(index) 帧相机位姿包含缩放或非正交旋转。")
                }
            }
        }
        let rotation = simd_double3x3(columns: (SIMD3(t[0], t[1], t[2]), SIMD3(t[4], t[5], t[6]), SIMD3(t[8], t[9], t[10])))
        guard abs(simd_determinant(rotation) - 1) < tolerance else {
            throw invalid("第 \(index) 帧相机旋转包含反射，无法确认扫描坐标。")
        }
        return simd_float4x4(columns: (
            SIMD4(Float(t[0]), Float(t[1]), Float(t[2]), Float(t[3])),
            SIMD4(Float(t[4]), Float(t[5]), Float(t[6]), Float(t[7])),
            SIMD4(Float(t[8]), Float(t[9]), Float(t[10]), Float(t[11])),
            SIMD4(Float(t[12]), Float(t[13]), Float(t[14]), Float(t[15]))))
    }

    private static func imageSource(_ file: URL, width: Int, height: Int) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg.identifier, UTType.png.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height else {
            throw invalid("标定帧 JPEG/PNG 无法读取或图片尺寸与扫描清单不匹配。")
        }
        return source
    }

    private static func safeFile(_ path: String, in root: URL, maximumBytes: Int = 128 * 1024 * 1024) throws -> URL {
        let components = path.components(separatedBy: "/")
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              try attributes(of: root)[.type] as? FileAttributeType == .typeDirectory else {
            throw invalid("扫描清单包含不安全的文件路径。")
        }
        var file = root
        for (index, component) in components.enumerated() {
            file.appendPathComponent(component)
            let info = try attributes(of: file)
            let type = info[.type] as? FileAttributeType
            if index < components.count - 1 {
                guard type == .typeDirectory else { throw invalid("扫描图像目录不能使用符号链接。") }
            } else {
                guard type == .typeRegular, let bytes = info[.size] as? NSNumber,
                      bytes.int64Value > 0, bytes.int64Value <= maximumBytes else {
                    throw invalid("扫描文件为空、过大或使用了符号链接。")
                }
            }
        }
        guard file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw invalid("扫描文件超出本机扫描目录。")
        }
        return file
    }

    private static func attributes(of url: URL) throws -> [FileAttributeKey: Any] {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch { throw invalid("扫描文件缺失或无法读取：\(url.lastPathComponent)") }
    }

    private static func invalid(_ reason: String) -> AlignmentError { .invalidScan(reason) }
}
