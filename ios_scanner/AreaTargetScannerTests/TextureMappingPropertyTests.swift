import XCTest
@testable import AreaTargetScanner
import simd
import ImageIO

/// Property-based tests for the mesh merge logic in TextureMappingPipeline.
///
/// Since ARMeshAnchor is a final ARKit class that cannot be instantiated in tests,
/// we test via `mergeMeshData(_:)` which accepts `SimpleMeshData` and exercises
/// the same merge algorithm.
///
/// Each test runs 100 random iterations to approximate property-based testing.
final class TextureMappingPropertyTests: XCTestCase {

    private var pipeline: TextureMappingPipeline!

    override func setUp() {
        super.setUp()
        pipeline = TextureMappingPipeline()
    }

    // MARK: - Random Generators

    /// Generate a random SIMD3<Float> vertex in [-10, 10].
    private func randomVertex() -> SIMD3<Float> {
        SIMD3<Float>(
            Float.random(in: -10...10),
            Float.random(in: -10...10),
            Float.random(in: -10...10)
        )
    }

    /// Generate a random 4×4 rigid transform (rotation + translation).
    private func randomTransform() -> simd_float4x4 {
        // Random translation
        let tx = Float.random(in: -5...5)
        let ty = Float.random(in: -5...5)
        let tz = Float.random(in: -5...5)

        // Random rotation around a random axis
        let angle = Float.random(in: 0...(2 * .pi))
        var axis = SIMD3<Float>(
            Float.random(in: -1...1),
            Float.random(in: -1...1),
            Float.random(in: -1...1)
        )
        let axisLen = simd_length(axis)
        if axisLen > 0.001 {
            axis /= axisLen
        } else {
            axis = SIMD3<Float>(0, 1, 0)
        }

        let rotation = simd_float4x4(simd_quatf(angle: angle, axis: axis))
        var transform = rotation
        transform.columns.3 = SIMD4<Float>(tx, ty, tz, 1.0)
        return transform
    }

    /// Generate a random SimpleMeshData with the given vertex and face counts.
    /// Face indices are guaranteed to be valid (< vertexCount).
    private func randomMeshData(vertexCount: Int, faceCount: Int) -> SimpleMeshData {
        let vertices = (0..<vertexCount).map { _ in randomVertex() }
        let faces = (0..<faceCount).map { _ -> SIMD3<UInt32> in
            // Pick 3 distinct random indices
            var indices = Set<UInt32>()
            while indices.count < 3 {
                indices.insert(UInt32.random(in: 0..<UInt32(vertexCount)))
            }
            let arr = Array(indices)
            return SIMD3<UInt32>(arr[0], arr[1], arr[2])
        }
        return SimpleMeshData(
            vertices: vertices,
            faces: faces,
            transform: randomTransform()
        )
    }

    /// Generate a random array of SimpleMeshData (1-5 meshes, each with 3-50 vertices).
    private func randomMeshArray() -> [SimpleMeshData] {
        let meshCount = Int.random(in: 1...5)
        return (0..<meshCount).map { _ in
            let vertexCount = Int.random(in: 3...50)
            let maxFaces = max(1, vertexCount / 3)
            let faceCount = Int.random(in: 1...maxFaces)
            return randomMeshData(vertexCount: vertexCount, faceCount: faceCount)
        }
    }

    // MARK: - Property P1: Mesh 合并顶点数守恒

    /// **Validates: Requirements 1.3**
    ///
    /// Property P1: For any set of non-empty SimpleMeshData, the merged MergedMesh's
    /// vertex count equals the sum of all input mesh vertex counts.
    func testProperty_P1_mergedVertexCountConservation() throws {
        for iteration in 0..<100 {
            let meshes = randomMeshArray()
            let expectedVertexCount = meshes.reduce(0) { $0 + $1.vertices.count }

            let merged = try pipeline.mergeMeshData(meshes)

            XCTAssertEqual(
                merged.vertices.count,
                expectedVertexCount,
                "P1 failed on iteration \(iteration): expected \(expectedVertexCount) vertices, got \(merged.vertices.count)"
            )
        }
    }

    // MARK: - Property P2: 合并后面片索引有效性

    /// **Validates: Requirements 1.2**
    ///
    /// Property P2: For any merged MergedMesh, all face indices (x, y, z) are
    /// strictly less than the total vertex count.
    func testProperty_P2_mergedFaceIndicesValid() throws {
        for iteration in 0..<100 {
            let meshes = randomMeshArray()
            let merged = try pipeline.mergeMeshData(meshes)
            let vertexCount = UInt32(merged.vertices.count)

            for (faceIdx, face) in merged.faces.enumerated() {
                XCTAssertTrue(
                    face.x < vertexCount && face.y < vertexCount && face.z < vertexCount,
                    "P2 failed on iteration \(iteration), face \(faceIdx): indices (\(face.x), \(face.y), \(face.z)) must all be < \(vertexCount)"
                )
            }
        }
    }

    // MARK: - Property P3: 合并后结构一致性

    /// **Validates: Requirements 1.4**
    ///
    /// Property P3: For any merged MergedMesh, the normals count equals the vertices count.
    func testProperty_P3_mergedNormalsCountMatchesVertices() throws {
        for iteration in 0..<100 {
            let meshes = randomMeshArray()
            let merged = try pipeline.mergeMeshData(meshes)

            XCTAssertEqual(
                merged.normals.count,
                merged.vertices.count,
                "P3 failed on iteration \(iteration): normals count (\(merged.normals.count)) != vertices count (\(merged.vertices.count))"
            )
        }
    }

    // MARK: - Random Mesh Generator for UV Unwrapping

    /// Generate a random valid mesh suitable for UV unwrapping.
    /// Returns vertices, normals, and faces with valid indices and distinct vertices per face.
    private func randomUnwrapMesh(vertexCount: Int, faceCount: Int) -> (vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [SIMD3<UInt32>]) {
        let vertices = (0..<vertexCount).map { _ in randomVertex() }
        let normals = vertices.map { _ -> SIMD3<Float> in
            var n = SIMD3<Float>(
                Float.random(in: -1...1),
                Float.random(in: -1...1),
                Float.random(in: -1...1)
            )
            let len = simd_length(n)
            if len > 0.001 { n /= len } else { n = SIMD3<Float>(0, 1, 0) }
            return n
        }
        let faces = (0..<faceCount).map { _ -> SIMD3<UInt32> in
            var indices = Set<UInt32>()
            while indices.count < 3 {
                indices.insert(UInt32.random(in: 0..<UInt32(vertexCount)))
            }
            let arr = Array(indices)
            return SIMD3<UInt32>(arr[0], arr[1], arr[2])
        }
        return (vertices, normals, faces)
    }

    // MARK: - Property P4: UV 坐标范围

    /// **Validates: Requirements 2.2**
    ///
    /// Property P4: For any UV-unwrapped UVMesh, all UV coordinates (u, v)
    /// satisfy 0 ≤ u ≤ 1 and 0 ≤ v ≤ 1.
    func testProperty_P4_uvCoordinatesInUnitRange() throws {
        let unwrapper = UVUnwrapper()

        for iteration in 0..<100 {
            let vertexCount = Int.random(in: 3...20)
            let maxFaces = max(1, vertexCount / 3)
            let faceCount = Int.random(in: 1...maxFaces)
            let (vertices, normals, faces) = randomUnwrapMesh(vertexCount: vertexCount, faceCount: faceCount)

            let uvMesh = try unwrapper.unwrap(vertices: vertices, normals: normals, faces: faces)

            for (uvIdx, uv) in uvMesh.uvCoordinates.enumerated() {
                XCTAssertTrue(
                    uv.x >= 0 && uv.x <= 1,
                    "P4 failed on iteration \(iteration), uv[\(uvIdx)].u = \(uv.x) is outside [0, 1]"
                )
                XCTAssertTrue(
                    uv.y >= 0 && uv.y <= 1,
                    "P4 failed on iteration \(iteration), uv[\(uvIdx)].v = \(uv.y) is outside [0, 1]"
                )
            }
        }
    }

    // MARK: - Property P5: UV 展开顶点追溯有效性

    /// **Validates: Requirements 2.4**
    ///
    /// Property P5: For any UV-unwrapped UVMesh, originalVertexIndices.count
    /// equals vertices.count, and all index values are less than the original
    /// mesh's vertex count.
    func testProperty_P5_originalVertexIndicesValidity() throws {
        let unwrapper = UVUnwrapper()

        for iteration in 0..<100 {
            let vertexCount = Int.random(in: 3...20)
            let maxFaces = max(1, vertexCount / 3)
            let faceCount = Int.random(in: 1...maxFaces)
            let (vertices, normals, faces) = randomUnwrapMesh(vertexCount: vertexCount, faceCount: faceCount)

            let uvMesh = try unwrapper.unwrap(vertices: vertices, normals: normals, faces: faces)

            // originalVertexIndices count must equal output vertex count
            XCTAssertEqual(
                uvMesh.originalVertexIndices.count,
                uvMesh.vertices.count,
                "P5 failed on iteration \(iteration): originalVertexIndices.count (\(uvMesh.originalVertexIndices.count)) != vertices.count (\(uvMesh.vertices.count))"
            )

            // All original indices must be < original vertex count
            let originalVertexCount = UInt32(vertexCount)
            for (idx, origIdx) in uvMesh.originalVertexIndices.enumerated() {
                XCTAssertTrue(
                    origIdx < originalVertexCount,
                    "P5 failed on iteration \(iteration), originalVertexIndices[\(idx)] = \(origIdx) is not < original vertex count \(originalVertexCount)"
                )
            }
        }
    }

    // MARK: - Random Generators for Frame Selection / Projection Tests

    /// Standard camera intrinsics used across P6/P7/P8 tests.
    private var standardIntrinsics: CameraIntrinsics {
        CameraIntrinsics(fx: 525, fy: 525, cx: 320, cy: 240, width: 640, height: 480)
    }

    /// Generate random world-space vertices (count in 3…30).
    private func randomWorldVertices(count: Int? = nil) -> [SIMD3<Float>] {
        let n = count ?? Int.random(in: 3...30)
        return (0..<n).map { _ in randomVertex() }
    }

    /// Generate random valid faces whose indices are all < vertexCount.
    /// Each face has 3 distinct vertex indices.
    private func randomFaces(vertexCount: Int, faceCount: Int? = nil) -> [SIMD3<UInt32>] {
        let n = faceCount ?? Int.random(in: 1...max(1, vertexCount / 3))
        return (0..<n).map { _ -> SIMD3<UInt32> in
            var indices = Set<UInt32>()
            while indices.count < 3 {
                indices.insert(UInt32.random(in: 0..<UInt32(vertexCount)))
            }
            let arr = Array(indices)
            return SIMD3<UInt32>(arr[0], arr[1], arr[2])
        }
    }

    /// Generate random camera poses (1-5) positioned to look at the mesh.
    /// Each camera is placed at a random offset from the origin and uses an
    /// identity rotation (looking down -Z in camera space).
    private func randomCameraPoses(count: Int? = nil) -> [CameraPose] {
        let n = count ?? Int.random(in: 1...5)
        return (0..<n).map { i -> CameraPose in
            let tx = Float.random(in: -5...5)
            let ty = Float.random(in: -5...5)
            let tz = Float.random(in: -5...5)
            // Identity rotation, translated to (tx, ty, tz)
            let transform: [Float] = [
                1, 0, 0, 0,  // column 0
                0, 1, 0, 0,  // column 1
                0, 0, 1, 0,  // column 2
                tx, ty, tz, 1 // column 3
            ]
            return CameraPose(timestamp: 0, transform: transform, imageFilename: "test_\(i).jpg")
        }
    }

    /// Generate per-vertex normals (unit vectors) for a given vertex count.
    private func randomNormals(count: Int) -> [SIMD3<Float>] {
        (0..<count).map { _ -> SIMD3<Float> in
            var n = SIMD3<Float>(
                Float.random(in: -1...1),
                Float.random(in: -1...1),
                Float.random(in: -1...1)
            )
            let len = simd_length(n)
            if len > 0.001 { n /= len } else { n = SIMD3<Float>(0, 1, 0) }
            return n
        }
    }

    // MARK: - Property P6: 帧选择评分与背面剔除

    /// **Validates: Requirements 3.2, 3.3, 3.6**
    ///
    /// Property P6: All scores returned by selectBestFrames are non-negative.
    /// When a face's normal has dot product ≤ 0 with the view direction from
    /// the only available camera, that camera should NOT be selected as best
    /// frame (or score should be 0 if it's the only camera — fallback).
    func testProperty_P6_frameSelectionScoresAndBackfaceCulling() {
        let projector = TextureProjector()
        let intrinsics = standardIntrinsics

        for iteration in 0..<100 {
            let vertices = randomWorldVertices()
            let faces = randomFaces(vertexCount: vertices.count)
            let normals = randomNormals(count: vertices.count)
            let cameraPoses = randomCameraPoses()

            let assignments = projector.selectBestFrames(
                faces: faces,
                vertices: vertices,
                normals: normals,
                cameraPoses: cameraPoses,
                intrinsics: intrinsics
            )

            // All scores must be >= 0
            for (idx, assignment) in assignments.enumerated() {
                XCTAssertGreaterThanOrEqual(
                    assignment.score, 0,
                    "P6 failed on iteration \(iteration), assignment \(idx): score \(assignment.score) is negative"
                )
            }
        }

        // Specific backface culling test: single camera behind the face
        // Face at origin with normal pointing in +Z, camera behind it at (0, 0, -5)
        // looking down -Z. The view direction from camera to face center is (0, 0, +5)
        // normalized = (0, 0, 1). dot(faceNormal=(0,0,1), viewDir=(0,0,1)) > 0 — that's
        // actually facing the camera. We need the face normal to point AWAY from camera.
        //
        // Place face with normal pointing -Z, camera at (0, 0, 5) looking down -Z.
        // viewDir from camera to face = (0,0,-5) normalized = (0,0,-1).
        // dot(faceNormal=(0,0,-1), viewDir=(0,0,-1)) = 1 > 0 — still facing.
        //
        // Correct setup: face normal = (0, 0, +1), camera at (0, 0, -5).
        // viewDir from camera to face center = (0, 0, 5) normalized = (0, 0, 1).
        // dot((0,0,1), (0,0,1)) = 1 > 0 — face IS visible.
        //
        // For backface: face normal = (0, 0, -1), camera at (0, 0, 5).
        // viewDir from camera to face center = (0, 0, -5) normalized = (0, 0, -1).
        // dot((0,0,-1), (0,0,-1)) = 1 > 0 — still visible because face normal
        // and view direction are aligned.
        //
        // Actually, backface means the face is pointing AWAY from the camera.
        // Face normal = (0, 0, +1), camera at (0, 0, -5).
        // viewDir = normalize((0,0,0) - (0,0,-5)) = (0,0,1). Wait, viewDir is
        // cameraPos - center. So viewDir = (0,0,-5) - (0,0,0) = (0,0,-5) → (0,0,-1).
        // dot((0,0,1), (0,0,-1)) = -1 ≤ 0 → backface culled!
        //
        // So: face normal +Z, camera at z=-5 → dot ≤ 0 → culled.
        do {
            // Triangle at origin in XY plane, normal pointing +Z
            let vertices: [SIMD3<Float>] = [
                SIMD3<Float>(-1, -1, 0),
                SIMD3<Float>( 1, -1, 0),
                SIMD3<Float>( 0,  1, 0)
            ]
            let faces: [SIMD3<UInt32>] = [SIMD3<UInt32>(0, 1, 2)]
            let normals: [SIMD3<Float>] = [
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1)
            ]

            // Camera behind the face (negative Z side), so face normal (+Z) points
            // away from camera. viewDir = cameraPos - center = (0,0,-5) - (0,0,0) = (0,0,-5).
            // dot(faceNormal, viewDir) = dot((0,0,1), (0,0,-1)) = -1 ≤ 0 → culled.
            let behindCamera = CameraPose(
                timestamp: 0,
                transform: [
                    1, 0, 0, 0,
                    0, 1, 0, 0,
                    0, 0, 1, 0,
                    0, 0, -5, 1
                ],
                imageFilename: "behind.jpg"
            )

            let assignments = projector.selectBestFrames(
                faces: faces,
                vertices: vertices,
                normals: normals,
                cameraPoses: [behindCamera],
                intrinsics: intrinsics
            )

            XCTAssertEqual(assignments.count, 1, "P6 backface test: should have 1 assignment")
            // The only camera is behind the face, so it should fall back with score 0
            XCTAssertEqual(
                assignments[0].score, 0,
                "P6 backface test: score should be 0 when only camera is behind the face"
            )
        }
    }

    // MARK: - Property P7: 帧分配完整性与索引有效性

    /// **Validates: Requirements 3.5, 3.7**
    ///
    /// Property P7: selectBestFrames returns exactly one FaceFrameAssignment per
    /// face, and all frameIndex values are in [0, cameraPoses.count).
    func testProperty_P7_assignmentCompletenessAndIndexValidity() {
        let projector = TextureProjector()
        let intrinsics = standardIntrinsics

        for iteration in 0..<100 {
            let vertices = randomWorldVertices()
            let faces = randomFaces(vertexCount: vertices.count)
            let normals = randomNormals(count: vertices.count)
            let cameraPoses = randomCameraPoses()

            let assignments = projector.selectBestFrames(
                faces: faces,
                vertices: vertices,
                normals: normals,
                cameraPoses: cameraPoses,
                intrinsics: intrinsics
            )

            // Assignment count must equal face count
            XCTAssertEqual(
                assignments.count,
                faces.count,
                "P7 failed on iteration \(iteration): assignments.count (\(assignments.count)) != faces.count (\(faces.count))"
            )

            // All frame indices must be in valid range
            for (idx, assignment) in assignments.enumerated() {
                XCTAssertTrue(
                    assignment.frameIndex >= 0 && assignment.frameIndex < cameraPoses.count,
                    "P7 failed on iteration \(iteration), assignment \(idx): frameIndex \(assignment.frameIndex) not in [0, \(cameraPoses.count))"
                )
            }
        }
    }

    // MARK: - Property P8: 投影有效性

    /// **Validates: Requirements 4.2, 4.3, 4.4**
    ///
    /// Property P8: For a camera at origin looking down -Z with known intrinsics:
    /// - Points in front of the camera (negative Z in camera space) that project
    ///   within image bounds return (u, v) ∈ [0,1]².
    /// - Points behind the camera (z ≥ 0 in camera space) return nil.
    func testProperty_P8_projectionValidity() {
        let projector = TextureProjector()
        let intrinsics = standardIntrinsics

        // Camera at origin, identity rotation, looking down -Z
        let cameraPose = CameraPose(
            timestamp: 0,
            transform: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1
            ],
            imageFilename: "test.jpg"
        )

        for iteration in 0..<100 {
            // --- Test points behind camera (z >= 0 in camera space) → nil ---
            let behindZ = Float.random(in: 0...20)
            let behindPoint = SIMD3<Float>(
                Float.random(in: -10...10),
                Float.random(in: -10...10),
                behindZ
            )
            let behindResult = projector.projectVertex(
                worldPoint: behindPoint,
                cameraPose: cameraPose,
                intrinsics: intrinsics
            )
            XCTAssertNil(
                behindResult,
                "P8 failed on iteration \(iteration): point behind camera at z=\(behindZ) should return nil, got \(String(describing: behindResult))"
            )

            // --- Test points in front of camera that are within image bounds ---
            // For identity camera at origin, camera space == world space.
            // Point must have z < 0 (in front of camera).
            // Projection: px = fx * (-x/z) + cx, py = fy * (-y/z) + cy
            // For (u,v) ∈ [0,1]: 0 ≤ px/width ≤ 1 and 0 ≤ py/height ≤ 1
            // px ∈ [0, 640], py ∈ [0, 480]
            // px = 525 * (-x/z) + 320 → -x/z ∈ [-320/525, 320/525]
            // py = 525 * (-y/z) + 240 → -y/z ∈ [-240/525, 240/525]
            let z = Float.random(in: -20 ... -0.1)
            let maxXRatio: Float = 320.0 / 525.0 * 0.9 // stay safely within bounds
            let maxYRatio: Float = 240.0 / 525.0 * 0.9
            let xOverZ = Float.random(in: -maxXRatio...maxXRatio)
            let yOverZ = Float.random(in: -maxYRatio...maxYRatio)
            let x = -xOverZ * z  // -x/z = xOverZ → x = -xOverZ * z
            let y = -yOverZ * z

            let frontPoint = SIMD3<Float>(x, y, z)
            let frontResult = projector.projectVertex(
                worldPoint: frontPoint,
                cameraPose: cameraPose,
                intrinsics: intrinsics
            )

            XCTAssertNotNil(
                frontResult,
                "P8 failed on iteration \(iteration): point in front of camera at (\(x), \(y), \(z)) should return non-nil"
            )
            if let uv = frontResult {
                XCTAssertTrue(
                    uv.x >= 0 && uv.x <= 1,
                    "P8 failed on iteration \(iteration): u = \(uv.x) not in [0, 1]"
                )
                XCTAssertTrue(
                    uv.y >= 0 && uv.y <= 1,
                    "P8 failed on iteration \(iteration): v = \(uv.y) not in [0, 1]"
                )
            }
        }
    }

    // MARK: - Edge Case: Empty Input

    /// Verifies that merging an empty array throws noMeshData.
    func testMergeMeshData_emptyInput_throwsNoMeshData() {
        XCTAssertThrowsError(try pipeline.mergeMeshData([])) { error in
            guard let mappingError = error as? TextureMappingError else {
                XCTFail("Expected TextureMappingError, got \(error)")
                return
            }
            if case .noMeshData = mappingError {
                // Expected
            } else {
                XCTFail("Expected .noMeshData, got \(mappingError)")
            }
        }
    }

    // MARK: - JPEG Test Data Helper

    /// Create minimal valid JPEG data using CoreGraphics + ImageIO.
    /// Returns a small solid-color JPEG image suitable for atlas rendering tests.
    private func makeTestJPEGData(width: Int = 4, height: Int = 4) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return Data()
        }
        // Fill with a solid color so sampling always returns valid pixels
        ctx.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = ctx.makeImage() else { return Data() }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData, "public.jpeg" as CFString, 1, nil
        ) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return mutableData as Data
    }

    // MARK: - Property P9: 纹理图集尺寸

    /// **Validates: Requirements 5.3**
    ///
    /// Property P9: For any valid atlasSize, renderAtlas outputs an image whose
    /// width and height both equal atlasSize.
    func testProperty_P9_atlasOutputSizeMatchesAtlasSize() throws {
        let renderer = TextureAtlasRenderer()

        // Build a simple single-triangle mesh with valid UV coordinates
        let vertices: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, -2),
            SIMD3<Float>(1, 0, -2),
            SIMD3<Float>(0, 1, -2)
        ]
        let normals: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, 0, 1)
        ]
        let uvCoordinates: [SIMD2<Float>] = [
            SIMD2<Float>(0.1, 0.1),
            SIMD2<Float>(0.9, 0.1),
            SIMD2<Float>(0.1, 0.9)
        ]
        let faces: [SIMD3<UInt32>] = [SIMD3<UInt32>(0, 1, 2)]
        let originalVertexIndices: [UInt32] = [0, 1, 2]

        let uvMesh = UVMesh(
            vertices: vertices,
            normals: normals,
            uvCoordinates: uvCoordinates,
            faces: faces,
            originalVertexIndices: originalVertexIndices
        )

        // Camera at origin looking down -Z (identity transform)
        let cameraPose = CameraPose(
            timestamp: 0,
            transform: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1
            ],
            imageFilename: "test_frame.jpg"
        )

        let intrinsics = CameraIntrinsics(
            fx: 525, fy: 525, cx: 320, cy: 240, width: 640, height: 480
        )

        // Single face assignment pointing to frame 0
        let faceAssignment = FaceFrameAssignment(faceIndex: 0, frameIndex: 0, score: 1.0)

        // Create a minimal JPEG image for the source frame
        let jpegData = makeTestJPEGData()
        XCTAssertFalse(jpegData.isEmpty, "Failed to create test JPEG data")
        let capturedImage = CapturedImage(imageData: jpegData, filename: "test_frame.jpg")

        // Test with 10 random atlasSize values from [32, 64, 128, 256]
        let candidateSizes = [32, 64, 128, 256]

        for iteration in 0..<10 {
            let atlasSize = candidateSizes[Int.random(in: 0..<candidateSizes.count)]

            let image = try renderer.renderAtlas(
                uvMesh: uvMesh,
                faceAssignments: [faceAssignment],
                images: [capturedImage],
                cameraPoses: [cameraPose],
                intrinsics: intrinsics,
                atlasSize: atlasSize
            )

            XCTAssertEqual(
                image.width, atlasSize,
                "P9 failed on iteration \(iteration): image.width (\(image.width)) != atlasSize (\(atlasSize))"
            )
            XCTAssertEqual(
                image.height, atlasSize,
                "P9 failed on iteration \(iteration): image.height (\(image.height)) != atlasSize (\(atlasSize))"
            )
        }
    }

    // MARK: - Test CGImage Helper

    /// Create a minimal test CGImage (solid red) for export tests.
    private func makeTestCGImage(width: Int = 4, height: Int = 4) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Generate a random TexturedMeshResult with valid random data.
    private func randomTexturedMeshResult() -> TexturedMeshResult {
        let vertexCount = Int.random(in: 3...50)
        let maxFaces = max(1, vertexCount / 3)
        let faceCount = Int.random(in: 1...maxFaces)

        let vertices = (0..<vertexCount).map { _ in
            SIMD3<Float>(Float.random(in: -10...10),
                         Float.random(in: -10...10),
                         Float.random(in: -10...10))
        }
        let normals = (0..<vertexCount).map { _ -> SIMD3<Float> in
            var n = SIMD3<Float>(Float.random(in: -1...1),
                                 Float.random(in: -1...1),
                                 Float.random(in: -1...1))
            let len = simd_length(n)
            if len > 0.001 { n /= len } else { n = SIMD3<Float>(0, 1, 0) }
            return n
        }
        let uvCoordinates = (0..<vertexCount).map { _ in
            SIMD2<Float>(Float.random(in: 0...1), Float.random(in: 0...1))
        }
        let faces = (0..<faceCount).map { _ -> SIMD3<UInt32> in
            var indices = Set<UInt32>()
            while indices.count < 3 {
                indices.insert(UInt32.random(in: 0..<UInt32(vertexCount)))
            }
            let arr = Array(indices)
            return SIMD3<UInt32>(arr[0], arr[1], arr[2])
        }

        let imgSize = [4, 8, 16][Int.random(in: 0...2)]
        let textureImage = makeTestCGImage(width: imgSize, height: imgSize)

        return TexturedMeshResult(
            vertices: vertices,
            normals: normals,
            uvCoordinates: uvCoordinates,
            faces: faces,
            textureImage: textureImage
        )
    }

    // MARK: - Property P10: OBJ 导出格式正确性

    /// **Validates: Requirements 6.1, 6.2, 6.3, 6.4**
    ///
    /// Property P10: For any valid TexturedMeshResult, the exported OBJ file has
    /// equal counts of v, vt, vn lines; all face indices in f lines are >= 1 and
    /// <= vertex count; the MTL file references texture.jpg; and exactly 3 files
    /// are created (model.obj, model.mtl, texture.jpg).
    func testProperty_P10_objExportFormatCorrectness() throws {
        let tempBaseDir = NSTemporaryDirectory() + "P10_test_\(UUID().uuidString)"

        defer {
            try? FileManager.default.removeItem(atPath: tempBaseDir)
        }

        for iteration in 0..<20 {
            let outputDir = tempBaseDir + "/iter_\(iteration)"
            let mesh = randomTexturedMeshResult()

            let exportedPaths = try TexturedMeshExporter.exportOBJ(mesh: mesh, to: outputDir)

            // --- Verify exactly 3 files created ---
            let fileManager = FileManager.default
            let filesInDir = try fileManager.contentsOfDirectory(atPath: outputDir)
            XCTAssertEqual(
                filesInDir.count, 3,
                "P10 iteration \(iteration): expected 3 files, got \(filesInDir.count): \(filesInDir)"
            )
            XCTAssertEqual(exportedPaths.count, 3,
                "P10 iteration \(iteration): exportOBJ should return 3 paths, got \(exportedPaths.count)")

            let expectedFiles = Set(["model.obj", "model.mtl", "texture.jpg"])
            let actualFiles = Set(filesInDir)
            XCTAssertEqual(expectedFiles, actualFiles,
                "P10 iteration \(iteration): expected files \(expectedFiles), got \(actualFiles)")

            // --- Parse OBJ file ---
            let objPath = (outputDir as NSString).appendingPathComponent("model.obj")
            let objContent = try String(contentsOfFile: objPath, encoding: .utf8)
            let objLines = objContent.components(separatedBy: "\n")

            var vCount = 0
            var vtCount = 0
            var vnCount = 0
            var faceLines: [String] = []

            for line in objLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("v ") { vCount += 1 }
                else if trimmed.hasPrefix("vt ") { vtCount += 1 }
                else if trimmed.hasPrefix("vn ") { vnCount += 1 }
                else if trimmed.hasPrefix("f ") { faceLines.append(trimmed) }
            }

            // v, vt, vn line counts must be equal
            XCTAssertEqual(vCount, vtCount,
                "P10 iteration \(iteration): v count (\(vCount)) != vt count (\(vtCount))")
            XCTAssertEqual(vCount, vnCount,
                "P10 iteration \(iteration): v count (\(vCount)) != vn count (\(vnCount))")
            XCTAssertEqual(vCount, mesh.vertices.count,
                "P10 iteration \(iteration): v count (\(vCount)) != mesh vertex count (\(mesh.vertices.count))")

            // All face indices must be >= 1 and <= vertex count
            let vertexCount = vCount
            for faceLine in faceLines {
                // Format: "f v1/vt1/vn1 v2/vt2/vn2 v3/vt3/vn3"
                let tokens = faceLine.dropFirst(2).split(separator: " ")
                for token in tokens {
                    let indices = token.split(separator: "/")
                    for indexStr in indices {
                        guard let index = Int(indexStr) else {
                            XCTFail("P10 iteration \(iteration): invalid index '\(indexStr)' in face line: \(faceLine)")
                            continue
                        }
                        XCTAssertGreaterThanOrEqual(index, 1,
                            "P10 iteration \(iteration): face index \(index) < 1 in line: \(faceLine)")
                        XCTAssertLessThanOrEqual(index, vertexCount,
                            "P10 iteration \(iteration): face index \(index) > vertex count \(vertexCount) in line: \(faceLine)")
                    }
                }
            }

            // --- Verify MTL references texture.jpg ---
            let mtlPath = (outputDir as NSString).appendingPathComponent("model.mtl")
            let mtlContent = try String(contentsOfFile: mtlPath, encoding: .utf8)
            XCTAssertTrue(mtlContent.contains("texture.jpg"),
                "P10 iteration \(iteration): MTL file does not reference texture.jpg")
        }
    }

    // MARK: - Property P11: 导出纹理无 EXIF 位置信息

    /// **Validates: Requirements 9.2**
    ///
    /// Property P11: For any exported texture.jpg, the JPEG data does not contain
    /// EXIF GPS location metadata.
    func testProperty_P11_exportedTextureHasNoEXIFGPS() throws {
        let tempBaseDir = NSTemporaryDirectory() + "P11_test_\(UUID().uuidString)"

        defer {
            try? FileManager.default.removeItem(atPath: tempBaseDir)
        }

        for iteration in 0..<10 {
            let outputDir = tempBaseDir + "/iter_\(iteration)"
            let mesh = randomTexturedMeshResult()

            try TexturedMeshExporter.exportOBJ(mesh: mesh, to: outputDir)

            // Read the exported texture.jpg
            let texturePath = (outputDir as NSString).appendingPathComponent("texture.jpg")
            let data = try Data(contentsOf: URL(fileURLWithPath: texturePath))
            XCTAssertFalse(data.isEmpty,
                "P11 iteration \(iteration): texture.jpg is empty")

            // Use CGImageSource to inspect EXIF metadata
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                XCTFail("P11 iteration \(iteration): failed to create CGImageSource from texture.jpg")
                continue
            }

            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]

            // Check that GPS dictionary is NOT present
            let gpsDict = properties?[kCGImagePropertyGPSDictionary]
            XCTAssertNil(gpsDict,
                "P11 iteration \(iteration): texture.jpg should not contain GPS EXIF data, but found: \(String(describing: gpsDict))")
        }
    }

    // MARK: - Pipeline Integration Tests (Task 9.3)

    /// **Validates: Requirements 1.5, 8.3**
    ///
    /// Test that the pipeline's mergeMeshData throws noMeshData when given empty input.
    /// This validates the pipeline-level error handling for empty mesh anchors.
    func testPipeline_emptyMeshAnchors_throwsNoMeshData() {
        let pipeline = TextureMappingPipeline()
        XCTAssertThrowsError(try pipeline.mergeMeshData([])) { error in
            guard case TextureMappingError.noMeshData = error else {
                XCTFail("Expected noMeshData, got \(error)")
                return
            }
        }
    }

    /// **Validates: Requirements 8.3**
    ///
    /// Test that the noKeyframeData error type exists, is throwable, and has a
    /// meaningful error description containing "keyframe".
    /// We cannot call generateTexturedMesh without real ARMeshAnchors, so we
    /// verify the error type directly.
    func testPipeline_noKeyframeData_errorType() {
        let error = TextureMappingError.noKeyframeData
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(
            error.errorDescription!.lowercased().contains("keyframe"),
            "noKeyframeData error description should mention 'keyframe', got: \(error.errorDescription!)"
        )
    }

    /// **Validates: Requirements 8.4**
    ///
    /// Test that ScanDataExporter.exportAll does not throw when meshAnchors is empty.
    /// When meshAnchors is empty, texture mapping is skipped entirely and the
    /// exporter falls back to the standard (untextured) export path.
    func testExportAll_noMeshAnchors_doesNotThrow() throws {
        let exporter = ScanDataExporter()
        let tempDir = NSTemporaryDirectory() + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let vertices = (0..<5).map { i -> [Float] in
            [Float(i) * 0.1, 0, 0, 0.5, 0.5, 0.5, 0, 1, 0]
        }
        let intrinsics = CameraIntrinsics(fx: 525, fy: 525, cx: 320, cy: 240, width: 640, height: 480)
        let poses = [
            CameraPose(
                timestamp: 0,
                transform: Array(repeating: Float(0), count: 16),
                imageFilename: "test.jpg",
                imageOrientation: .landscapeRight,
                intrinsics: intrinsics,
                imageWidth: intrinsics.width,
                imageHeight: intrinsics.height
            )
        ]
        let images = [CapturedImage(imageData: Data([0xFF, 0xD8]), filename: "test.jpg")]

        // Should not throw — texture mapping is skipped when meshAnchors is empty
        try exporter.exportAll(
            vertices: vertices,
            poses: poses,
            intrinsics: intrinsics,
            images: images,
            outputPath: tempDir
        )
    }

    /// **Validates: Requirements 1.5, 8.3, 8.4**
    ///
    /// Test that all TextureMappingError enum cases have non-nil error descriptions.
    /// This ensures the error handling is complete and user-facing messages are available.
    func testTextureMappingError_allCases() {
        let errors: [TextureMappingError] = [
            .noMeshData,
            .noKeyframeData,
            .uvUnwrapFailed(reason: "test"),
            .atlasRenderFailed(reason: "test")
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription,
                "Error \(error) should have a non-nil errorDescription")
        }
    }

    // MARK: - End-to-End Integration Test

    /// Create a test JPEG image of a given size filled with a specific color.
    private func makeColorJPEG(width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else { return Data() }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return mutableData as Data
    }

    /// End-to-end integration test: constructs synthetic mesh + camera data,
    /// runs the full texture mapping pipeline (merge → UV unwrap → project →
    /// atlas render → OBJ export), and verifies the output texture is NOT
    /// just the default gray fill.
    func testEndToEnd_fullPipeline_producesColoredTexture() throws {
        let pipeline = TextureMappingPipeline()

        // --- 1. Build a synthetic mesh: a quad (2 triangles) at z = -3, facing +Z ---
        //     The quad spans [-1, 1] in X and [-1, 1] in Y.
        let meshVertices: [SIMD3<Float>] = [
            SIMD3<Float>(-1, -1, -3),  // 0: bottom-left
            SIMD3<Float>( 1, -1, -3),  // 1: bottom-right
            SIMD3<Float>( 1,  1, -3),  // 2: top-right
            SIMD3<Float>(-1,  1, -3),  // 3: top-left
        ]
        let meshFaces: [SIMD3<UInt32>] = [
            SIMD3<UInt32>(0, 1, 2),
            SIMD3<UInt32>(0, 2, 3),
        ]
        let meshData = SimpleMeshData(
            vertices: meshVertices,
            faces: meshFaces,
            transform: matrix_identity_float4x4
        )

        // --- 2. Merge mesh ---
        let mergedMesh = try pipeline.mergeMeshData([meshData])
        XCTAssertEqual(mergedMesh.vertices.count, 4)
        XCTAssertEqual(mergedMesh.faces.count, 2)

        // --- 3. UV unwrap ---
        let uvMesh = try UVUnwrapper().unwrap(
            vertices: mergedMesh.vertices,
            normals: mergedMesh.normals,
            faces: mergedMesh.faces
        )
        XCTAssertFalse(uvMesh.uvCoordinates.isEmpty, "UV coordinates should not be empty")
        print("[E2E] UV mesh: \(uvMesh.vertices.count) verts, \(uvMesh.faces.count) faces")

        // --- 4. Set up camera: at origin, looking down -Z (identity transform) ---
        //     The quad is at z=-3, so it's in front of the camera.
        let cameraPose = CameraPose(
            timestamp: 0,
            transform: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1
            ],
            imageFilename: "frame_0000.jpg"
        )
        let intrinsics = CameraIntrinsics(fx: 525, fy: 525, cx: 320, cy: 240, width: 640, height: 480)

        // --- 5. Select best frames ---
        let projector = TextureProjector()
        let assignments = projector.selectBestFrames(
            faces: uvMesh.faces,
            vertices: uvMesh.vertices,
            normals: uvMesh.normals,
            cameraPoses: [cameraPose],
            intrinsics: intrinsics
        )
        XCTAssertEqual(assignments.count, uvMesh.faces.count, "Should have one assignment per face")
        let positiveScoreCount = assignments.filter { $0.score > 0 }.count
        print("[E2E] Assignments: \(assignments.count) total, \(positiveScoreCount) with positive score")

        // --- 6. Create a bright red test image (640x480 to match intrinsics) ---
        let redJPEG = makeColorJPEG(width: 640, height: 480, r: 1.0, g: 0.0, b: 0.0)
        XCTAssertFalse(redJPEG.isEmpty, "Failed to create test JPEG")
        let capturedImage = CapturedImage(imageData: redJPEG, filename: "frame_0000.jpg")

        // --- 7. Render atlas ---
        let renderer = TextureAtlasRenderer()
        let atlasSize = 256
        let atlasImage = try renderer.renderAtlas(
            uvMesh: uvMesh,
            faceAssignments: assignments,
            images: [capturedImage],
            cameraPoses: [cameraPose],
            intrinsics: intrinsics,
            atlasSize: atlasSize
        )
        XCTAssertEqual(atlasImage.width, atlasSize)
        XCTAssertEqual(atlasImage.height, atlasSize)

        // --- 8. Verify the atlas is NOT all gray ---
        //     Read pixels from the atlas and check that at least some are not gray (128,128,128).
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: atlasSize, height: atlasSize,
            bitsPerComponent: 8, bytesPerRow: atlasSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let pixelData = ctx.data else {
            XCTFail("Failed to create context for atlas pixel inspection")
            return
        }
        ctx.draw(atlasImage, in: CGRect(x: 0, y: 0, width: atlasSize, height: atlasSize))
        let pixels = pixelData.bindMemory(to: UInt8.self, capacity: atlasSize * atlasSize * 4)

        var nonGrayPixelCount = 0
        var redPixelCount = 0
        let totalPixels = atlasSize * atlasSize

        for i in 0..<totalPixels {
            let r = pixels[i * 4]
            let g = pixels[i * 4 + 1]
            let b = pixels[i * 4 + 2]
            // Gray is approximately (128, 128, 128)
            let isGray = abs(Int(r) - 128) < 10 && abs(Int(g) - 128) < 10 && abs(Int(b) - 128) < 10
            if !isGray {
                nonGrayPixelCount += 1
            }
            // Red-ish pixel (from our red test image)
            if r > 150 && g < 100 && b < 100 {
                redPixelCount += 1
            }
        }

        let nonGrayPercent = Double(nonGrayPixelCount) / Double(totalPixels) * 100
        let redPercent = Double(redPixelCount) / Double(totalPixels) * 100
        print("[E2E] Atlas pixels: \(nonGrayPixelCount)/\(totalPixels) non-gray (\(String(format: "%.1f", nonGrayPercent))%), \(redPixelCount) red (\(String(format: "%.1f", redPercent))%)")

        XCTAssertGreaterThan(nonGrayPixelCount, 0,
            "Atlas should have at least some non-gray pixels — texture projection is not working")
        XCTAssertGreaterThan(redPixelCount, 0,
            "Atlas should have red pixels from the test image — color sampling is not working")

        // --- 9. Export OBJ and verify files ---
        let tempDir = NSTemporaryDirectory() + "E2E_test_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let texturedMesh = TexturedMeshResult(
            vertices: uvMesh.vertices,
            normals: uvMesh.normals,
            uvCoordinates: uvMesh.uvCoordinates,
            faces: uvMesh.faces,
            textureImage: atlasImage
        )
        let exportedPaths = try TexturedMeshExporter.exportOBJ(mesh: texturedMesh, to: tempDir)
        XCTAssertEqual(exportedPaths.count, 3, "Should export 3 files (obj, mtl, jpg)")

        // Verify texture.jpg is not empty and has reasonable size
        let texturePath = (tempDir as NSString).appendingPathComponent("texture.jpg")
        let textureData = try Data(contentsOf: URL(fileURLWithPath: texturePath))
        XCTAssertGreaterThan(textureData.count, 100, "texture.jpg should have meaningful content")

        print("[E2E] ✅ Full pipeline test passed: texture has \(nonGrayPixelCount) colored pixels")
    }
}
