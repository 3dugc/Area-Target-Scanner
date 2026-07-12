import Foundation
import CoreGraphics
import ImageIO
import simd

/// Exports a textured mesh to standard 3D file formats (OBJ + MTL + JPG or USDZ).
final class TexturedMeshExporter {

    // MARK: - OBJ Export

    /// Export the textured mesh as OBJ + MTL + JPG files.
    ///
    /// Writes three files to `outputDir`:
    /// - `texture.jpg` — JPEG encoded at quality 0.9, no EXIF location data
    /// - `model.mtl` — material definition referencing texture.jpg
    /// - `model.obj` — vertex/UV/normal/face data referencing model.mtl
    ///
    /// - Parameters:
    ///   - mesh: The textured mesh result to export
    ///   - outputDir: Directory path where files will be written
    /// - Returns: List of exported file paths
    @discardableResult
    static func exportOBJ(
        mesh: TexturedMeshResult,
        to outputDir: String
    ) throws -> [String] {
        let fileManager = FileManager.default

        // Create output directory if it doesn't exist
        if !fileManager.fileExists(atPath: outputDir) {
            try fileManager.createDirectory(
                atPath: outputDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        let texturePath = (outputDir as NSString).appendingPathComponent("texture.jpg")
        let mtlPath = (outputDir as NSString).appendingPathComponent("model.mtl")
        let objPath = (outputDir as NSString).appendingPathComponent("model.obj")

        // 1. Write texture.jpg — JPEG encode at quality 0.9, no EXIF metadata
        let jpegData = try encodeJPEGWithoutEXIF(image: mesh.textureImage, quality: 0.9)
        try jpegData.write(to: URL(fileURLWithPath: texturePath))

        // 2. Write model.mtl
        // illum 1 = diffuse-only lighting model, prevents specular highlights washing out texture
        let mtlContent = """
            newmtl textured_material
            Ka 0.2 0.2 0.2
            Kd 1.0 1.0 1.0
            Ks 0.0 0.0 0.0
            Ns 1.0
            illum 1
            map_Kd texture.jpg
            
            """.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n") + "\n"
        try mtlContent.write(toFile: mtlPath, atomically: true, encoding: .utf8)

        // 3. Write model.obj
        let objContent = buildOBJContent(mesh: mesh)
        try objContent.write(toFile: objPath, atomically: true, encoding: .utf8)

        return [objPath, mtlPath, texturePath]
    }

    // MARK: - USDZ Export

    /// Export the textured mesh as a USDZ file using ModelIO framework.
    ///
    /// Gracefully returns an empty array if the system does not support USDZ export.
    ///
    /// - Parameters:
    ///   - mesh: The textured mesh result to export
    ///   - outputDir: Directory path where the file will be written
    /// - Returns: List of exported file paths (empty if USDZ not supported)
    @discardableResult
    static func exportUSDZ(
        mesh: TexturedMeshResult,
        to outputDir: String
    ) throws -> [String] {
        #if canImport(ModelIO) && canImport(MetalKit)
        return try exportUSDZWithModelIO(mesh: mesh, to: outputDir)
        #else
        return []
        #endif
    }

    // MARK: - Private Helpers

    /// Encode a CGImage as JPEG data without any EXIF metadata.
    /// Uses CGImageDestination with explicit quality setting and no metadata properties.
    private static func encodeJPEGWithoutEXIF(image: CGImage, quality: CGFloat) throws -> Data {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw TextureMappingError.atlasRenderFailed(reason: "Failed to create JPEG image destination")
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            throw TextureMappingError.atlasRenderFailed(reason: "Failed to finalize JPEG encoding")
        }

        return mutableData as Data
    }

    /// Build the OBJ file content string from a TexturedMeshResult.
    private static func buildOBJContent(mesh: TexturedMeshResult) -> String {
        var lines: [String] = []
        lines.reserveCapacity(3 + mesh.vertices.count + mesh.uvCoordinates.count + mesh.normals.count + mesh.faces.count + 4)

        lines.append("# Textured mesh exported by AreaTargetScanner")
        lines.append("mtllib model.mtl")
        lines.append("")

        // Vertices
        for v in mesh.vertices {
            lines.append("v \(v.x) \(v.y) \(v.z)")
        }

        // UV coordinates — OBJ convention: vt V=0 is bottom of texture image.
        // Our atlas renderer already writes pixels with this convention (flippedY),
        // so we output UVs as-is.
        for uv in mesh.uvCoordinates {
            lines.append("vt \(uv.x) \(uv.y)")
        }

        // Normals
        for n in mesh.normals {
            lines.append("vn \(n.x) \(n.y) \(n.z)")
        }

        // Material assignment must come right before faces
        lines.append("usemtl textured_material")

        // Faces — OBJ indices are 1-based
        for f in mesh.faces {
            let i1 = f.x + 1
            let i2 = f.y + 1
            let i3 = f.z + 1
            lines.append("f \(i1)/\(i1)/\(i1) \(i2)/\(i2)/\(i2) \(i3)/\(i3)/\(i3)")
        }

        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - USDZ Export (ModelIO)

#if canImport(ModelIO) && canImport(MetalKit)
import ModelIO
import MetalKit

extension TexturedMeshExporter {

    fileprivate static func exportUSDZWithModelIO(
        mesh: TexturedMeshResult,
        to outputDir: String
    ) throws -> [String] {
        // Check if USDZ export is supported
        guard MDLAsset.canExportFileExtension("usdz") else {
            return []
        }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: outputDir) {
            try fileManager.createDirectory(
                atPath: outputDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        let usdzPath = (outputDir as NSString).appendingPathComponent("model.usdz")

        // Write texture to a temporary file for ModelIO to reference
        let texturePath = (outputDir as NSString).appendingPathComponent("texture_usdz.jpg")
        let jpegData = try encodeJPEGWithoutEXIF(image: mesh.textureImage, quality: 0.9)
        try jpegData.write(to: URL(fileURLWithPath: texturePath))

        // Create allocator
        let allocator = MDLMeshBufferDataAllocator()

        // Build vertex buffer: position (float3) + normal (float3) + texcoord (float2)
        let vertexCount = mesh.vertices.count
        let stride = MemoryLayout<Float>.size * 8 // 3 + 3 + 2 = 8 floats per vertex
        var vertexData = Data(count: vertexCount * stride)

        vertexData.withUnsafeMutableBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            for i in 0..<vertexCount {
                let offset = i * 8
                floatBuffer[offset + 0] = mesh.vertices[i].x
                floatBuffer[offset + 1] = mesh.vertices[i].y
                floatBuffer[offset + 2] = mesh.vertices[i].z
                floatBuffer[offset + 3] = mesh.normals[i].x
                floatBuffer[offset + 4] = mesh.normals[i].y
                floatBuffer[offset + 5] = mesh.normals[i].z
                floatBuffer[offset + 6] = mesh.uvCoordinates[i].x
                floatBuffer[offset + 7] = mesh.uvCoordinates[i].y
            }
        }

        let vertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)

        // Build index buffer
        let faceCount = mesh.faces.count
        var indexData = Data(count: faceCount * 3 * MemoryLayout<UInt32>.size)

        indexData.withUnsafeMutableBytes { rawBuffer in
            let uint32Buffer = rawBuffer.bindMemory(to: UInt32.self)
            for i in 0..<faceCount {
                uint32Buffer[i * 3 + 0] = mesh.faces[i].x
                uint32Buffer[i * 3 + 1] = mesh.faces[i].y
                uint32Buffer[i * 3 + 2] = mesh.faces[i].z
            }
        }

        let indexBuffer = allocator.newBuffer(with: indexData, type: .index)

        // Define vertex descriptor
        let vertexDescriptor = MDLVertexDescriptor()

        let positionAttr = MDLVertexAttribute(
            name: MDLVertexAttributePosition,
            format: .float3,
            offset: 0,
            bufferIndex: 0
        )
        let normalAttr = MDLVertexAttribute(
            name: MDLVertexAttributeNormal,
            format: .float3,
            offset: MemoryLayout<Float>.size * 3,
            bufferIndex: 0
        )
        let texCoordAttr = MDLVertexAttribute(
            name: MDLVertexAttributeTextureCoordinate,
            format: .float2,
            offset: MemoryLayout<Float>.size * 6,
            bufferIndex: 0
        )

        vertexDescriptor.attributes = NSMutableArray(array: [positionAttr, normalAttr, texCoordAttr])
        let layout = MDLVertexBufferLayout(stride: stride)
        vertexDescriptor.layouts = NSMutableArray(array: [layout])

        // Create submesh with index buffer
        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: faceCount * 3,
            indexType: .uInt32,
            geometryType: .triangles,
            material: nil
        )

        // Create MDLMesh
        let mdlMesh = MDLMesh(
            vertexBuffer: vertexBuffer,
            vertexCount: vertexCount,
            descriptor: vertexDescriptor,
            submeshes: [submesh]
        )

        // Create material with texture
        let material = MDLMaterial(name: "textured_material", scatteringFunction: MDLScatteringFunction())
        let textureProperty = MDLMaterialProperty(
            name: "baseColor",
            semantic: .baseColor,
            url: URL(fileURLWithPath: texturePath)
        )
        material.setProperty(textureProperty)

        if let sub = mdlMesh.submeshes?.firstObject as? MDLSubmesh {
            sub.material = material
        }

        // Create asset and export
        let asset = MDLAsset()
        asset.add(mdlMesh)

        let usdzURL = URL(fileURLWithPath: usdzPath)
        try asset.export(to: usdzURL)

        // Clean up temporary texture file
        try? fileManager.removeItem(atPath: texturePath)

        return [usdzPath]
    }
}
#endif
