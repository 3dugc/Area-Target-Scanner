import Foundation
import SceneKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Loads the scan's existing OBJ in its original ARKit world coordinates (meters).
/// Call off the main thread, then attach the returned node on the render thread.
/// Alignment belongs on a separate parent node; this loader never centers or scales.
enum ImmersalScanMeshLoader {
    enum LoadError: Error, LocalizedError {
        case unsafePath
        case missingModel
        case invalidGeometry

        var errorDescription: String? {
            switch self {
            case .unsafePath: return "原扫描模型路径无效，无法加载网格"
            case .missingModel: return "原扫描未保存 model.obj，仍可继续定位测试"
            case .invalidGeometry: return "原扫描模型没有可显示的三角网格，仍可继续定位测试"
            }
        }
    }

    static func load(scanDirectory: URL) throws -> SCNNode {
        try validatePath(scanDirectory)
        let manager = FileManager.default
        let directory = scanDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard let directoryType = try? manager.attributesOfItem(atPath: directory.path)[.type],
              directoryType as? FileAttributeType == .typeDirectory else {
            throw LoadError.missingModel
        }
        let model = directory.appendingPathComponent("model.obj")
        try validatePath(model)
        guard let attributes = try? manager.attributesOfItem(atPath: model.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LoadError.missingModel
        }

        let file = try FileHandle(forReadingFrom: model)
        defer { try? file.close() }
        let geometry = try readOBJ { try file.read(upToCount: $0) }
        return try makeOverlay(from: SCNNode(geometry: geometry))
    }

    /// Retains only positions/triangle indices plus a bounded input buffer. Material
    /// and texture directives are never resolved. The callback also permits tiny
    /// chunk sizes in tests without changing the production FileHandle path.
    static func readOBJ(chunkSize: Int = 256 * 1024, readChunk: (Int) throws -> Data?) throws -> SCNGeometry {
        guard chunkSize > 0 else { throw LoadError.invalidGeometry }
        let readSize = min(chunkSize, 256 * 1024)
        let maximumLineBytes = 1024 * 1024
        var pending = Data()
        var mesh = OBJMesh()
        while try autoreleasepool(invoking: {
            guard let chunk = try readChunk(readSize), !chunk.isEmpty else { return false }
            guard chunk.count <= readSize else { throw LoadError.invalidGeometry }
            pending.append(chunk)
            let consumed = try pending.withUnsafeBytes { rawBytes -> Int in
                let bytes = rawBytes.bindMemory(to: UInt8.self)
                var start = 0
                for end in bytes.indices where bytes[end] == 10 || bytes[end] == 13 {
                    guard end - start <= maximumLineBytes else { throw LoadError.invalidGeometry }
                    if end > start {
                        guard let line = String(bytes: bytes[start..<end], encoding: .utf8) else {
                            throw LoadError.invalidGeometry
                        }
                        try mesh.append(line: line)
                    }
                    start = end + 1
                }
                return start
            }
            if consumed > 0 {
                // Data.removeFirst can keep every consumed chunk in its backing
                // allocation. Copy only the unfinished line into fresh storage.
                pending = pending.withUnsafeBytes { bytes in
                    let remaining = bytes.count - consumed
                    guard remaining > 0, let base = bytes.baseAddress else { return Data() }
                    return Data(bytes: base.advanced(by: consumed), count: remaining)
                }
            }
            guard pending.count <= maximumLineBytes else { throw LoadError.invalidGeometry }
            return true
        }) {}
        if !pending.isEmpty {
            guard let line = String(data: pending, encoding: .utf8) else { throw LoadError.invalidGeometry }
            try mesh.append(line: line)
        }
        return try mesh.geometry()
    }

    /// Cloning keeps every local transform/pivot; geometry copies isolate materials.
    static func makeOverlay(from source: SCNNode) throws -> SCNNode {
        let root = source.clone()
        var triangleCount = 0
        root.enumerateHierarchy { node, _ in
            node.camera = nil
            node.light = nil
            node.opacity = 1
            guard let geometry = node.geometry else { return }
            let count = geometry.elements.reduce(0) { total, element in
                switch element.primitiveType {
                case .triangles, .triangleStrip: return total + element.primitiveCount
                default: return total
                }
            }
            guard count > 0, let copy = geometry.copy() as? SCNGeometry else {
                node.geometry = nil
                return
            }
            triangleCount += count
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.fillMode = .lines
            material.isDoubleSided = true
            #if canImport(UIKit)
            material.diffuse.contents = UIColor.cyan
            #else
            material.diffuse.contents = NSColor.cyan
            #endif
            material.transparency = 1
            copy.materials = [material]
            node.geometry = copy
        }
        guard triangleCount > 0 else { throw LoadError.invalidGeometry }
        return root
    }

    private struct OBJMesh {
        var positions: [SIMD3<Float>] = []
        var triangles: [UInt32] = []
        var normalCount = 0
        var textureCoordinateCount = 0

        mutating func append(line: String) throws {
            let content = line.prefix(while: { $0 != "#" })
            let fields = content.split(whereSeparator: \.isWhitespace)
            guard let directive = fields.first else { return }
            switch directive {
            case "v":
                guard fields.count >= 4, positions.count < Int(UInt32.max),
                      let x = Float(fields[1]), let y = Float(fields[2]), let z = Float(fields[3]),
                      x.isFinite, y.isFinite, z.isFinite else { throw LoadError.invalidGeometry }
                positions.append(SIMD3(x, y, z))
            case "vn": normalCount += 1
            case "vt": textureCoordinateCount += 1
            case "f":
                guard fields.count >= 4 else { throw LoadError.invalidGeometry }
                var first: UInt32 = 0
                var previous: UInt32 = 0
                for (offset, field) in fields.dropFirst().enumerated() {
                    let indices = field.split(separator: "/", omittingEmptySubsequences: false)
                    guard (1...3).contains(indices.count),
                          let index = Self.index(indices[0], count: positions.count) else { throw LoadError.invalidGeometry }
                    if indices.count >= 2, !indices[1].isEmpty {
                        guard Self.index(indices[1], count: textureCoordinateCount) != nil else { throw LoadError.invalidGeometry }
                    } else if indices.count == 2 {
                        throw LoadError.invalidGeometry
                    }
                    if indices.count == 3 {
                        guard Self.index(indices[2], count: normalCount) != nil else { throw LoadError.invalidGeometry }
                    }
                    let vertex = UInt32(index)
                    if offset == 0 {
                        first = vertex
                    } else if offset >= 2 {
                        triangles.append(first)
                        triangles.append(previous)
                        triangles.append(vertex)
                    }
                    previous = vertex
                }
            default: break
            }
        }

        func geometry() throws -> SCNGeometry {
            guard !positions.isEmpty, !triangles.isEmpty else { throw LoadError.invalidGeometry }
            let vertexData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
            let indexData = triangles.withUnsafeBufferPointer { Data(buffer: $0) }
            let source = SCNGeometrySource(data: vertexData, semantic: .vertex,
                                           vectorCount: positions.count, usesFloatComponents: true,
                                           componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
                                           dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
            let element = SCNGeometryElement(data: indexData, primitiveType: .triangles,
                                             primitiveCount: triangles.count / 3, bytesPerIndex: MemoryLayout<UInt32>.size)
            return SCNGeometry(sources: [source], elements: [element])
        }

        private static func index(_ text: Substring, count: Int) -> Int? {
            guard let index = Int(text), index != 0 else { return nil }
            if index > 0 { return index <= count ? index - 1 : nil }
            return index >= -count ? count + index : nil
        }
    }

    private static func validatePath(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              !url.pathComponents.contains("..") else { throw LoadError.unsafePath }
        var component = url.standardizedFileURL
        while component.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: component.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                // Darwin exposes its system temporary and mobile container paths
                // through these aliases. All scan-specific symlinks are rejected.
                guard component.path == "/var" || component.path == "/tmp" else {
                    throw LoadError.unsafePath
                }
            }
            component.deleteLastPathComponent()
        }
    }
}
