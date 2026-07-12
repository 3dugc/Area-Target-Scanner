import XCTest
import simd
@testable import AreaTargetScanner

/// Unit tests for TextureMappingPipeline.
///
/// Validates:
/// - mergeMeshData with various inputs
/// - Error handling for empty inputs
/// - Vertex transform correctness
/// - Normal computation
/// - Face index offset correctness
final class TextureMappingPipelineTests: XCTestCase {

    private var pipeline: TextureMappingPipeline!

    override func setUp() {
        super.setUp()
        pipeline = TextureMappingPipeline()
    }

    // MARK: - mergeMeshData Error Cases

    func testMergeMeshData_emptyArray_throwsNoMeshData() {
        XCTAssertThrowsError(try pipeline.mergeMeshData([])) { error in
            guard case TextureMappingError.noMeshData = error else {
                XCTFail("Expected noMeshData, got \(error)")
                return
            }
        }
    }

    // MARK: - mergeMeshData Single Mesh

    func testMergeMeshData_singleTriangle_preservesVertexCount() throws {
        let mesh = SimpleMeshData(
            vertices: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0)
            ],
            faces: [SIMD3<UInt32>(0, 1, 2)],
            transform: matrix_identity_float4x4
        )

        let merged = try pipeline.mergeMeshData([mesh])

        XCTAssertEqual(merged.vertices.count, 3)
        XCTAssertEqual(merged.normals.count, 3)
        XCTAssertEqual(merged.faces.count, 1)
    }

    func testMergeMeshData_identityTransform_preservesPositions() throws {
        let mesh = SimpleMeshData(
            vertices: [
                SIMD3<Float>(1, 2, 3),
                SIMD3<Float>(4, 5, 6),
                SIMD3<Float>(7, 8, 9)
            ],
            faces: [SIMD3<UInt32>(0, 1, 2)],
            transform: matrix_identity_float4x4
        )

        let merged = try pipeline.mergeMeshData([mesh])

        XCTAssertEqual(merged.vertices[0].x, 1, accuracy: 0.001)
        XCTAssertEqual(merged.vertices[0].y, 2, accuracy: 0.001)
        XCTAssertEqual(merged.vertices[0].z, 3, accuracy: 0.001)
    }

    func testMergeMeshData_translationTransform_appliedCorrectly() throws {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(10, 20, 30, 1)

        let mesh = SimpleMeshData(
            vertices: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0)
            ],
            faces: [SIMD3<UInt32>(0, 1, 2)],
            transform: transform
        )

        let merged = try pipeline.mergeMeshData([mesh])

        XCTAssertEqual(merged.vertices[0].x, 10, accuracy: 0.001)
        XCTAssertEqual(merged.vertices[0].y, 20, accuracy: 0.001)
        XCTAssertEqual(merged.vertices[0].z, 30, accuracy: 0.001)
        XCTAssertEqual(merged.vertices[1].x, 11, accuracy: 0.001)
    }

    // MARK: - mergeMeshData Multiple Meshes

    func testMergeMeshData_twoMeshes_faceIndicesOffset() throws {
        let mesh1 = SimpleMeshData(
            vertices: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0)
            ],
            faces: [SIMD3<UInt32>(0, 1, 2)],
            transform: matrix_identity_float4x4
        )
        let mesh2 = SimpleMeshData(
            vertices: [
                SIMD3<Float>(2, 0, 0),
                SIMD3<Float>(3, 0, 0),
                SIMD3<Float>(2, 1, 0)
            ],
            faces: [SIMD3<UInt32>(0, 1, 2)],
            transform: matrix_identity_float4x4
        )

        let merged = try pipeline.mergeMeshData([mesh1, mesh2])

        XCTAssertEqual(merged.vertices.count, 6)
        XCTAssertEqual(merged.faces.count, 2)

        // First mesh face indices unchanged
        XCTAssertEqual(merged.faces[0].x, 0)
        XCTAssertEqual(merged.faces[0].y, 1)
        XCTAssertEqual(merged.faces[0].z, 2)

        // Second mesh face indices offset by 3
        XCTAssertEqual(merged.faces[1].x, 3)
        XCTAssertEqual(merged.faces[1].y, 4)
        XCTAssertEqual(merged.faces[1].z, 5)
    }

    func testMergeMeshData_twoMeshes_totalVertexCount() throws {
        let mesh1 = SimpleMeshData(
            vertices: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)],
            faces: [SIMD3<UInt32>(0, 1, 2)],
            transform: matrix_identity_float4x4
        )
        let mesh2 = SimpleMeshData(
            vertices: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 1, 0)],
            faces: [SIMD3<UInt32>(0, 1, 2), SIMD3<UInt32>(1, 2, 3)],
            transform: matrix_identity_float4x4
        )

        let merged = try pipeline.mergeMeshData([mesh1, mesh2])

        XCTAssertEqual(merged.vertices.count, 7)
        XCTAssertEqual(merged.normals.count, 7)
        XCTAssertEqual(merged.faces.count, 3)
    }

    // MARK: - Normal Computation

    func testMergeMeshData_normals_areUnitLength() throws {
        let mesh = SimpleMeshData(
            vertices: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0)
            ],
            faces: [SIMD3<UInt32>(0, 1, 2)],
            transform: matrix_identity_float4x4
        )

        let merged = try pipeline.mergeMeshData([mesh])

        for normal in merged.normals {
            let length = simd_length(normal)
            XCTAssertEqual(length, 1.0, accuracy: 0.01,
                "Normal should be unit length, got \(length)")
        }
    }

    func testMergeMeshData_xyPlaneTriangle_normalPointsInZ() throws {
        // Triangle in XY plane → normal should point in Z direction
        let mesh = SimpleMeshData(
            vertices: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0)
            ],
            faces: [SIMD3<UInt32>(0, 1, 2)],
            transform: matrix_identity_float4x4
        )

        let merged = try pipeline.mergeMeshData([mesh])

        // All normals should have significant Z component
        for normal in merged.normals {
            XCTAssertTrue(abs(normal.z) > 0.9,
                "Normal Z component should be dominant for XY plane triangle, got \(normal)")
        }
    }

    // MARK: - TextureMappingError Tests

    func testTextureMappingError_noMeshData_description() {
        let error = TextureMappingError.noMeshData
        XCTAssertNotNil(error.errorDescription)
    }

    func testTextureMappingError_noKeyframeData_description() {
        let error = TextureMappingError.noKeyframeData
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("keyframe"))
    }

    func testTextureMappingError_uvUnwrapFailed_includesReason() {
        let error = TextureMappingError.uvUnwrapFailed(reason: "xatlas failed")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("xatlas failed"))
    }

    func testTextureMappingError_atlasRenderFailed_includesReason() {
        let error = TextureMappingError.atlasRenderFailed(reason: "out of memory")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("out of memory"))
    }

    // MARK: - generateTexturedMesh Input Validation

    func testGenerateTexturedMesh_emptyPoses_throwsNoKeyframeData() {
        XCTAssertThrowsError(try pipeline.generateTexturedMesh(
            meshAnchors: [],
            cameraPoses: [],
            images: [CapturedImage(imageData: Data([0xFF]), filename: "f.jpg")],
            intrinsics: CameraIntrinsics(fx: 525, fy: 525, cx: 320, cy: 240, width: 640, height: 480)
        )) { error in
            guard case TextureMappingError.noKeyframeData = error else {
                XCTFail("Expected noKeyframeData, got \(error)")
                return
            }
        }
    }

    func testGenerateTexturedMesh_emptyImages_throwsNoKeyframeData() {
        XCTAssertThrowsError(try pipeline.generateTexturedMesh(
            meshAnchors: [],
            cameraPoses: [CameraPose(timestamp: 0, transform: Array(repeating: Float(0), count: 16), imageFilename: "f.jpg")],
            images: [],
            intrinsics: CameraIntrinsics(fx: 525, fy: 525, cx: 320, cy: 240, width: 640, height: 480)
        )) { error in
            guard case TextureMappingError.noKeyframeData = error else {
                XCTFail("Expected noKeyframeData, got \(error)")
                return
            }
        }
    }
}
