import XCTest
import SceneKit
import simd
#if canImport(UIKit)
import UIKit
#else
import AppKit
import Darwin
#endif
@testable import AreaTargetScanner

final class ImmersalScanMeshTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ImmersalScanMeshTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOBJPreservesNonzeroWorldOriginMeterDimensionsAndTriangles() throws {
        try writeOBJ(Self.obj)
        let root = try ImmersalScanMeshLoader.load(scanDirectory: directory)
        let positions = worldPositions(root)
        XCTAssertEqual(triangleCount(root), 2)
        XCTAssertFalse(positions.isEmpty)
        XCTAssertEqual(positions.map(\.x).min() ?? 0, 12, accuracy: 0.0001)
        XCTAssertEqual(positions.map(\.x).max() ?? 0, 14, accuracy: 0.0001)
        XCTAssertEqual(positions.map(\.y).min() ?? 0, -3, accuracy: 0.0001)
        XCTAssertEqual(positions.map(\.y).max() ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(positions.map(\.z).min() ?? 0, 8, accuracy: 0.0001)
        XCTAssertEqual(positions.map(\.z).max() ?? 0, 8, accuracy: 0.0001)
        XCTAssertEqual(root.simdTransform, matrix_identity_float4x4)
    }

    func testMeshUsesOpaqueConstantCyanWireframeWithNoTexture() throws {
        try writeOBJ(Self.obj)
        let root = try ImmersalScanMeshLoader.load(scanDirectory: directory)
        let meshes = geometryNodes(root)
        XCTAssertFalse(meshes.isEmpty)
        XCTAssertEqual(root.opacity, 1)
        for node in meshes {
            XCTAssertEqual(node.opacity, 1)
            for material in try XCTUnwrap(node.geometry).materials {
                XCTAssertEqual(material.lightingModel, .constant)
                XCTAssertEqual(material.fillMode, .lines)
                XCTAssertTrue(material.isDoubleSided)
                XCTAssertEqual(material.transparency, 1)
                let contents = try XCTUnwrap(material.diffuse.contents)
                #if canImport(UIKit)
                let color = try XCTUnwrap((contents as? UIColor)?.cgColor)
                #else
                let color = try XCTUnwrap((contents as? NSColor)?.usingColorSpace(.sRGB)?.cgColor)
                #endif
                let components = try XCTUnwrap(color.components)
                XCTAssertEqual(components.count, 4)
                if components.count == 4 {
                    for (actual, expected) in zip(components, [CGFloat(0), 1, 1, 1]) {
                        XCTAssertEqual(actual, expected, accuracy: 0.02)
                    }
                }
                XCTAssertFalse(material.normal.contents is URL)
                XCTAssertFalse(material.normal.contents is String)
            }
        }
    }

    func testGeometryLoadingDoesNotNeedOrFollowMaterialAndTextureFiles() throws {
        try writeOBJ("mtllib ../../outside-material.mtl\nusemtl texture\n" + Self.obj)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("model.mtl"),
                                                   withDestinationURL: directory.appendingPathComponent("missing.mtl"))
        let root = try ImmersalScanMeshLoader.load(scanDirectory: directory)
        XCTAssertEqual(triangleCount(root), 2)
    }

    func testClonedHierarchyKeepsTransformsAndDoesNotMutateSourceMaterials() throws {
        let original = SCNNode()
        original.simdPosition = SIMD3(4, 5, 6)
        let parent = SCNNode()
        parent.simdPosition = SIMD3(7, 8, 9)
        parent.simdOrientation = simd_quatf(angle: .pi / 3, axis: SIMD3(0, 1, 0))
        let mesh = SCNNode(geometry: SCNBox(width: 2, height: 3, length: 4, chamferRadius: 0))
        mesh.scale = SCNVector3(2, 3, 4)
        mesh.name = "mesh"
        let material = SCNMaterial()
        material.fillMode = .fill
        mesh.geometry?.materials = [material]
        parent.addChildNode(mesh)
        original.addChildNode(parent)
        let expectedTransform = mesh.simdWorldTransform

        let copy = try ImmersalScanMeshLoader.makeOverlay(from: original)
        let copiedMesh = try XCTUnwrap(copy.childNode(withName: "mesh", recursively: true))
        XCTAssertEqual(copiedMesh.simdWorldTransform, expectedTransform)
        XCTAssertFalse(copiedMesh.geometry === mesh.geometry)
        XCTAssertEqual(mesh.geometry?.firstMaterial?.fillMode, .fill)
        XCTAssertEqual(copiedMesh.geometry?.firstMaterial?.fillMode, .lines)
    }

    func testCloningStripsCamerasAndLightsButPreservesGeometryDescendants() throws {
        let source = SCNNode()
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.light = SCNLight()
        cameraNode.position = SCNVector3(5, 0, 0)
        cameraNode.addChildNode(SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)))
        source.addChildNode(cameraNode)
        let copy = try ImmersalScanMeshLoader.makeOverlay(from: source)
        copy.enumerateHierarchy { node, _ in
            XCTAssertNil(node.camera)
            XCTAssertNil(node.light)
        }
        XCTAssertGreaterThan(triangleCount(copy), 0)
        XCTAssertEqual(copy.childNodes.first?.position.x, 5)
        XCTAssertNotNil(cameraNode.camera)
    }

    func testMissingOBJDoesNotSubstituteAnotherFormatOrScan() throws {
        try Data("unrelated model".utf8).write(to: directory.appendingPathComponent("model.usdz"))
        XCTAssertThrowsError(try ImmersalScanMeshLoader.load(scanDirectory: directory))
    }

    func testEmptyAndPointOnlyGeometryAreRejected() throws {
        for obj in ["", "v 1 2 3\nv 2 3 4\n", "v 1 2 3\nv 2 3 4\nl 1 2\n"] {
            try writeOBJ(obj)
            XCTAssertThrowsError(try ImmersalScanMeshLoader.load(scanDirectory: directory))
        }
        XCTAssertThrowsError(try ImmersalScanMeshLoader.makeOverlay(from: SCNNode()))
    }

    func testRejectsSymbolicLinkToModelFile() throws {
        let actual = directory.appendingPathComponent("other.obj")
        try Self.obj.write(to: actual, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("model.obj"), withDestinationURL: actual)
        XCTAssertThrowsError(try ImmersalScanMeshLoader.load(scanDirectory: directory))
    }

    func testRejectsMalformedFaceRatherThanSilentlyLoadingPartialMesh() throws {
        for face in ["f 1 2 999", "f abc 2 3", "f 0 2 3", "f 1/999/1 2/2/1 3/3/1"] {
            try writeOBJ(Self.obj + "\n" + face + "\n")
            XCTAssertThrowsError(try ImmersalScanMeshLoader.load(scanDirectory: directory), face)
        }
    }

    func testRejectsSymbolicLinkScanDirectoryAndTraversal() throws {
        let real = directory.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Self.obj.write(to: real.appendingPathComponent("model.obj"), atomically: true, encoding: .utf8)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        XCTAssertThrowsError(try ImmersalScanMeshLoader.load(scanDirectory: alias))
        let traversal = try XCTUnwrap(URL(string: real.absoluteString + "/../real"))
        XCTAssertThrowsError(try ImmersalScanMeshLoader.load(scanDirectory: traversal))
        XCTAssertThrowsError(try ImmersalScanMeshLoader.load(scanDirectory: URL(string: "https://example.com/scan")!))
    }

    func testStreamingReaderHandlesTinyChunksCRLFAndUnterminatedLastFace() throws {
        let text = "# 扫描模型\r\nv 12 -3 8\r\nv 14 -3 8\r\nv 14 1 8\r\nv 12 1 8\r\n"
            + "vt 0 0\r\nvt 1 0\r\nvt 1 1\r\nvt 0 1\r\nvn 0 0 1\r\n"
            + "f -4/-4/-1 -3/-3/-1 -2/-2/-1 -1/-1/-1"
        let data = Data(text.utf8)
        var offset = 0
        var reads = 0
        let geometry = try ImmersalScanMeshLoader.readOBJ(chunkSize: 7) { requested in
            XCTAssertEqual(requested, 7)
            reads += 1
            guard offset < data.count else { return nil }
            let end = min(offset + requested, data.count)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }
        let node = SCNNode(geometry: geometry)
        XCTAssertGreaterThan(reads, 10)
        XCTAssertEqual(geometry.sources(for: .vertex).first?.vectorCount, 4)
        XCTAssertEqual(triangleCount(node), 2)
        XCTAssertEqual(worldPositions(node), [SIMD3(12, -3, 8), SIMD3(14, -3, 8), SIMD3(14, 1, 8), SIMD3(12, 1, 8)])
        let element = try XCTUnwrap(geometry.elements.first)
        XCTAssertEqual(element.bytesPerIndex, 4)
        let indices = element.data.withUnsafeBytes { data in
            (0..<6).map { data.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
        }
        XCTAssertEqual(indices, [0, 1, 2, 0, 2, 3])
    }

    func testStreamingReaderKeepsLargeMeshSharedVerticesAndBoundedReadRequests() throws {
        let vertexCount = 40_000
        var line = 0
        let geometry = try ImmersalScanMeshLoader.readOBJ { requested in
            XCTAssertLessThanOrEqual(requested, 256 * 1024)
            guard line < vertexCount + vertexCount - 2 else { return Data() }
            var chunk = Data()
            while line < vertexCount + vertexCount - 2, chunk.count < requested - 64 {
                let text: String
                if line < vertexCount {
                    text = "v \(12 + line) -3 8\n"
                } else {
                    let end = line - vertexCount + 3
                    text = "f 1 \(end - 1) \(end)\n"
                }
                chunk.append(contentsOf: text.utf8)
                line += 1
            }
            return chunk
        }
        XCTAssertEqual(geometry.sources(for: .vertex).first?.vectorCount, vertexCount)
        XCTAssertEqual(geometry.elements.first?.primitiveCount, vertexCount - 2)
        XCTAssertEqual(geometry.sources(for: .vertex).first?.dataStride, MemoryLayout<SIMD3<Float>>.stride)
        XCTAssertEqual(geometry.elements.first?.data.count, (vertexCount - 2) * 3 * MemoryLayout<UInt32>.size)
    }

    #if os(macOS)
    func testStreamingReaderReleasesConsumedStorageAcrossOneHundredMiB() throws {
        // Every chunk leaves seven bytes of an unfinished comment. Data.removeFirst
        // can retain the consumed allocation despite its small remaining count.
        // A generous allocator budget distinguishes that retained 100 MiB from
        // ordinary Foundation/SceneKit caches in this isolated macOS test target.
        var comment = Data(repeating: 35, count: 256 * 1024)
        comment[comment.count - 8] = 10
        let header = Data("v 12 -3 8\nv 14 -3 8\nv 12 1 8\nf 1 2 3\n".utf8)
        var reads = 0
        var baseline = 0
        var peak = 0
        let began = ProcessInfo.processInfo.systemUptime
        let geometry = try ImmersalScanMeshLoader.readOBJ { requested in
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            if reads == 0 { baseline = stats.size_in_use }
            peak = max(peak, stats.size_in_use - baseline)
            defer { reads += 1 }
            if reads == 0 { return header }
            if reads <= 400 {
                XCTAssertEqual(requested, comment.count)
                return comment
            }
            return nil
        }
        XCTAssertEqual(geometry.sources(for: .vertex).first?.vectorCount, 3)
        XCTAssertEqual(geometry.elements.first?.primitiveCount, 1)
        XCTAssertLessThan(peak, 8 * 1024 * 1024, "Consumed OBJ text must not accumulate in Data backing storage")
        print("100 MiB OBJ comments: \(ProcessInfo.processInfo.systemUptime - began) seconds; peak allocator delta \(peak) bytes")
    }
    #endif

    private func writeOBJ(_ content: String) throws {
        try content.write(to: directory.appendingPathComponent("model.obj"), atomically: true, encoding: .utf8)
    }

    private func geometryNodes(_ root: SCNNode) -> [SCNNode] {
        var nodes: [SCNNode] = []
        root.enumerateHierarchy { node, _ in if node.geometry != nil { nodes.append(node) } }
        return nodes
    }

    private func triangleCount(_ root: SCNNode) -> Int {
        geometryNodes(root).reduce(0) { total, node in
            total + (node.geometry?.elements.filter { $0.primitiveType == .triangles }.reduce(0) { $0 + $1.primitiveCount } ?? 0)
        }
    }

    private func worldPositions(_ root: SCNNode) -> [SIMD3<Float>] {
        geometryNodes(root).flatMap { node in
            (node.geometry?.sources(for: .vertex) ?? []).flatMap { source -> [SIMD3<Float>] in
                guard source.usesFloatComponents, source.bytesPerComponent == 4 else { return [] }
                return source.data.withUnsafeBytes { bytes in
                    (0..<source.vectorCount).map { index in
                        let start = source.dataOffset + index * source.dataStride
                        let p = SIMD3<Float>(bytes.loadUnaligned(fromByteOffset: start, as: Float.self),
                                             bytes.loadUnaligned(fromByteOffset: start + 4, as: Float.self),
                                             bytes.loadUnaligned(fromByteOffset: start + 8, as: Float.self))
                        return node.simdConvertPosition(p, to: nil)
                    }
                }
            }
        }
    }

    private static let obj = """
    o existing_scan
    v 12 -3 8
    v 14 -3 8
    v 14 1 8
    v 12 1 8
    vt 0 0
    vt 1 0
    vt 1 1
    vt 0 1
    vn 0 0 1
    f 1/1/1 2/2/1 3/3/1
    f 1/1/1 3/3/1 4/4/1
    """
}
