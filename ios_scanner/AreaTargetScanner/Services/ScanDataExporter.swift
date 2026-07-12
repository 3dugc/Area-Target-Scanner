import Foundation
import ARKit

/// Helper class responsible for writing scan data to disk in standard formats.
///
/// Handles:
/// - PLY point cloud export (XYZ + color + normals)
/// - poses.json (camera poses with column-major 4x4 transforms)
/// - intrinsics.json (camera intrinsic parameters)
/// - JPEG images in images/ subdirectory
/// - GLB 3D model (mesh from LiDAR)
///
/// - Requirements: 3.1, 3.2, 3.3, 3.4
final class ScanDataExporter {

    // MARK: - Errors

    enum ExportError: Error, LocalizedError {
        case directoryCreationFailed(String)
        case plyWriteFailed(String)
        case jsonEncodeFailed(String)
        case imageWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .directoryCreationFailed(let path):
                return "Failed to create directory: \(path)"
            case .plyWriteFailed(let reason):
                return "Failed to write PLY file: \(reason)"
            case .jsonEncodeFailed(let reason):
                return "Failed to encode JSON: \(reason)"
            case .imageWriteFailed(let filename):
                return "Failed to write image: \(filename)"
            }
        }
    }

    // MARK: - Public API

    /// Exports all scan data to the specified output directory.
    ///
    /// Creates the following structure:
    /// ```
    /// outputPath/
    /// ├── pointcloud.ply
    /// ├── poses.json
    /// ├── intrinsics.json
    /// ├── model.obj          (textured if mapping succeeds, untextured otherwise)
    /// ├── model.mtl          (only when textured)
    /// ├── texture.jpg        (only when textured)
    /// ├── model.usdz         (only when textured + system supports ModelIO)
    /// ├── model.usda         (untextured fallback)
    /// └── images/
    ///     ├── frame_0000.jpg
    ///     └── ...
    /// ```
    ///
    /// - Parameters:
    ///   - vertices: Point cloud vertices, each as [x, y, z, r, g, b, nx, ny, nz]
    ///   - poses: Camera poses for each keyframe
    ///   - intrinsics: Camera intrinsic parameters
    ///   - images: Captured JPEG images
    ///   - outputPath: Directory path to write the scan data package
    /// - Throws: `ExportError` on any I/O failure
    func exportAll(
        vertices: [[Float]],
        poses: [CameraPose],
        intrinsics: CameraIntrinsics,
        images: [CapturedImage],
        meshAnchors: [ARMeshAnchor] = [],
        outputPath: String,
        onProgress: ((String) -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        let outputURL = URL(fileURLWithPath: outputPath)

        // Create output directory if needed
        try createDirectoryIfNeeded(at: outputURL, fileManager: fileManager)

        // Write all components
        onProgress?("正在导出点云 (\(vertices.count) 点)...")
        try writePLY(vertices: vertices, to: outputURL.appendingPathComponent("pointcloud.ply"))

        onProgress?("正在导出相机位姿 (\(poses.count) 帧)...")
        try writePosesJSON(poses: poses, to: outputURL.appendingPathComponent("poses.json"))

        onProgress?("正在导出相机参数...")
        try writeIntrinsicsJSON(intrinsics: intrinsics, to: outputURL.appendingPathComponent("intrinsics.json"))

        onProgress?("正在导出关键帧图像 (\(images.count) 张)...")
        try writeImages(images: images, to: outputURL.appendingPathComponent("images"))

        // Export 3D mesh model (OBJ + USDA) if mesh data is available
        if !meshAnchors.isEmpty {
            onProgress?("正在导出基础网格模型 (\(meshAnchors.count) 个mesh)...")
            try? MeshExporter.export(meshAnchors: meshAnchors, to: outputPath)
        }

        // Textured mesh export: runs after untextured export so textured OBJ overwrites untextured one on success
        if !meshAnchors.isEmpty && !images.isEmpty {
            do {
                onProgress?("正在合并网格...")
                let pipeline = TextureMappingPipeline()
                let texturedMesh = try pipeline.generateTexturedMesh(
                    meshAnchors: meshAnchors,
                    cameraPoses: poses,
                    images: images,
                    intrinsics: intrinsics,
                    atlasSize: 4096,
                    onProgress: onProgress
                )
                onProgress?("正在导出纹理OBJ...")
                try TexturedMeshExporter.exportOBJ(mesh: texturedMesh, to: outputPath)
                onProgress?("正在导出USDZ...")
                do {
                    try TexturedMeshExporter.exportUSDZ(mesh: texturedMesh, to: outputPath)
                    print("[ScanDataExporter] ✅ USDZ exported successfully")
                } catch {
                    print("[ScanDataExporter] ⚠️ USDZ export failed: \(error.localizedDescription), OBJ+texture still available")
                }
                print("[ScanDataExporter] ✅ Textured mesh exported successfully")
            } catch {
                // Texture mapping failed — fall back to untextured mesh export (already done above)
                print("[ScanDataExporter] ⚠️ Texture mapping failed: \(error.localizedDescription). Using untextured mesh.")
            }
        }
    }

    // MARK: - PLY Export

    /// Writes point cloud vertices to a PLY file with ASCII format.
    ///
    /// Each vertex contains XYZ position, RGB color (0-255), and normal vector.
    ///
    /// - Requirements: 3.1
    /// - Parameters:
    ///   - vertices: Array of vertex data, each element is [x, y, z, r, g, b, nx, ny, nz]
    ///   - url: File URL to write the PLY file
    func writePLY(vertices: [[Float]], to url: URL) throws {
        var plyContent = ""

        // PLY header
        plyContent += "ply\n"
        plyContent += "format ascii 1.0\n"
        plyContent += "element vertex \(vertices.count)\n"
        plyContent += "property float x\n"
        plyContent += "property float y\n"
        plyContent += "property float z\n"
        plyContent += "property uchar red\n"
        plyContent += "property uchar green\n"
        plyContent += "property uchar blue\n"
        plyContent += "property float nx\n"
        plyContent += "property float ny\n"
        plyContent += "property float nz\n"
        plyContent += "end_header\n"

        // Vertex data
        for vertex in vertices {
            guard vertex.count >= 9 else { continue }
            let x = vertex[0]
            let y = vertex[1]
            let z = vertex[2]
            let r = UInt8(clamping: Int(vertex[3] * 255.0))
            let g = UInt8(clamping: Int(vertex[4] * 255.0))
            let b = UInt8(clamping: Int(vertex[5] * 255.0))
            let nx = vertex[6]
            let ny = vertex[7]
            let nz = vertex[8]
            plyContent += "\(x) \(y) \(z) \(r) \(g) \(b) \(nx) \(ny) \(nz)\n"
        }

        guard let data = plyContent.data(using: .utf8) else {
            throw ExportError.plyWriteFailed("Failed to encode PLY content as UTF-8")
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.plyWriteFailed(error.localizedDescription)
        }
    }

    // MARK: - Poses JSON Export

    /// Writes camera poses to a JSON file.
    ///
    /// Each frame entry contains: index, timestamp, imageFile, and 4x4 transform (column-major).
    ///
    /// - Requirements: 3.2
    /// - Parameters:
    ///   - poses: Array of camera poses
    ///   - url: File URL to write poses.json
    func writePosesJSON(poses: [CameraPose], to url: URL) throws {
        var frames: [[String: Any]] = []

        for (index, pose) in poses.enumerated() {
            let frame: [String: Any] = [
                "index": index,
                "timestamp": pose.timestamp,
                "imageFile": "images/\(pose.imageFilename)",
                "transform": pose.transform
            ]
            frames.append(frame)
        }

        let posesDict: [String: Any] = ["frames": frames]

        guard JSONSerialization.isValidJSONObject(posesDict) else {
            throw ExportError.jsonEncodeFailed("Invalid JSON object for poses")
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: posesDict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.jsonEncodeFailed(error.localizedDescription)
        }
    }

    // MARK: - Intrinsics JSON Export

    /// Writes camera intrinsics to a JSON file.
    ///
    /// - Requirements: 3.3
    /// - Parameters:
    ///   - intrinsics: Camera intrinsic parameters
    ///   - url: File URL to write intrinsics.json
    func writeIntrinsicsJSON(intrinsics: CameraIntrinsics, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(intrinsics)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.jsonEncodeFailed(error.localizedDescription)
        }
    }

    // MARK: - Image Export

    /// Writes captured JPEG images to an images/ subdirectory.
    ///
    /// - Requirements: 3.4
    /// - Parameters:
    ///   - images: Array of captured images with JPEG data
    ///   - directoryURL: Directory URL for the images/ folder
    func writeImages(images: [CapturedImage], to directoryURL: URL) throws {
        let fileManager = FileManager.default
        try createDirectoryIfNeeded(at: directoryURL, fileManager: fileManager)

        for image in images {
            let fileURL = directoryURL.appendingPathComponent(image.filename)
            do {
                try image.imageData.write(to: fileURL, options: .atomic)
            } catch {
                throw ExportError.imageWriteFailed(image.filename)
            }
        }
    }

    // MARK: - Helpers

    private func createDirectoryIfNeeded(at url: URL, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw ExportError.directoryCreationFailed(url.path)
            }
        }
    }
}
