import Foundation
import ARKit
import simd
import CoreGraphics

/// Texture mapping pipeline that coordinates UV unwrapping, projection,
/// atlas rendering, and export to produce a textured mesh from scan data.
final class TextureMappingPipeline {

    /// Generate a textured mesh from scan data.
    /// - Parameters:
    ///   - meshAnchors: ARKit mesh anchors collected during scanning
    ///   - cameraPoses: Keyframe camera poses
    ///   - images: Keyframe JPEG image data
    ///   - intrinsics: Camera intrinsic parameters
    ///   - atlasSize: Texture atlas size in pixels (default 4096×4096)
    /// - Returns: A textured mesh result containing vertices, UVs, and the atlas image
    func generateTexturedMesh(
        meshAnchors: [ARMeshAnchor],
        cameraPoses: [CameraPose],
        images: [CapturedImage],
        intrinsics: CameraIntrinsics,
        atlasSize: Int = 4096,
        onProgress: ((String) -> Void)? = nil
    ) throws -> TexturedMeshResult {
        // 1. Validate inputs: throw noKeyframeData if cameraPoses or images are empty
        guard !cameraPoses.isEmpty, !images.isEmpty else {
            throw TextureMappingError.noKeyframeData
        }

        // 2. Merge mesh anchors into a single unified mesh (throws noMeshData if empty)
        onProgress?("正在合并网格 (\(meshAnchors.count) 个)...")
        let rawMerged = try mergeMeshAnchors(meshAnchors)
        print("[TextureMappingPipeline] Merged mesh (raw): \(rawMerged.vertices.count) vertices, \(rawMerged.faces.count) faces")

        // 2.5 Weld colocal vertices to restore mesh topology.
        // ARKit mesh anchors produce per-triangle vertices (no sharing across faces),
        // which causes xatlas to treat each triangle as an isolated chart.
        // Welding merges vertices within epsilon distance, enabling proper chart growth.
        onProgress?("正在焊接顶点...")
        let mergedMesh = weldVertices(rawMerged, epsilon: 1e-5)
        print("[TextureMappingPipeline] Welded mesh: \(mergedMesh.vertices.count) vertices, \(mergedMesh.faces.count) faces")

        // 3. UV unwrap the merged mesh
        onProgress?("正在UV展开 (\(mergedMesh.vertices.count) 顶点, \(mergedMesh.faces.count) 面)...")
        let uvMesh = try UVUnwrapper().unwrap(
            vertices: mergedMesh.vertices,
            normals: mergedMesh.normals,
            faces: mergedMesh.faces
        )
        print("[TextureMappingPipeline] UV mesh: \(uvMesh.vertices.count) vertices, \(uvMesh.faces.count) faces, \(uvMesh.uvCoordinates.count) UVs")

        // 4. Select the best camera frame for each face
        onProgress?("正在分配纹理帧 (\(uvMesh.faces.count) 面, \(cameraPoses.count) 帧)...")
        let faceAssignments = TextureProjector().selectBestFrames(
            faces: uvMesh.faces,
            vertices: uvMesh.vertices,
            normals: uvMesh.normals,
            cameraPoses: cameraPoses,
            intrinsics: intrinsics
        )
        let assignedWithScore = faceAssignments.filter { $0.score > 0 }.count
        print("[TextureMappingPipeline] Frame assignments: \(faceAssignments.count) total, \(assignedWithScore) with positive score")

        // 5. Render the texture atlas
        onProgress?("正在渲染纹理图集 (\(atlasSize)×\(atlasSize))...")
        let atlasImage = try TextureAtlasRenderer().renderAtlas(
            uvMesh: uvMesh,
            faceAssignments: faceAssignments,
            images: images,
            cameraPoses: cameraPoses,
            intrinsics: intrinsics,
            atlasSize: atlasSize
        )

        // 6. Assemble and return the final result
        return TexturedMeshResult(
            vertices: uvMesh.vertices,
            normals: uvMesh.normals,
            uvCoordinates: uvMesh.uvCoordinates,
            faces: uvMesh.faces,
            textureImage: atlasImage
        )
    }

    /// Merge simplified mesh data into a single unified mesh in world coordinates.
    /// This mirrors the logic of `mergeMeshAnchors` but works with `SimpleMeshData`,
    /// making it testable without ARKit dependencies.
    /// - Parameter meshes: Array of simplified mesh data to merge
    /// - Returns: A merged mesh with all vertices transformed to world space
    /// - Throws: `TextureMappingError.noMeshData` if meshes is empty
    func mergeMeshData(_ meshes: [SimpleMeshData]) throws -> MergedMesh {
        guard !meshes.isEmpty else {
            throw TextureMappingError.noMeshData
        }

        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allFaces: [SIMD3<UInt32>] = []
        var vertexOffset: UInt32 = 0

        for mesh in meshes {
            let transform = mesh.transform

            // Transform each vertex to world coordinates
            for localPos in mesh.vertices {
                let homogeneous = SIMD4<Float>(localPos.x, localPos.y, localPos.z, 1.0)
                let worldPos = transform * homogeneous
                allVertices.append(SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z))
            }

            // Compute per-vertex normals from face cross products
            var vertexNormals = [SIMD3<Float>](repeating: .zero, count: mesh.vertices.count)
            let normalMatrix = simd_float3x3(
                SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )

            for face in mesh.faces {
                let i0 = Int(face.x)
                let i1 = Int(face.y)
                let i2 = Int(face.z)
                let p0 = mesh.vertices[i0]
                let p1 = mesh.vertices[i1]
                let p2 = mesh.vertices[i2]
                let edge1 = p1 - p0
                let edge2 = p2 - p0
                let faceNormal = simd_cross(edge1, edge2)
                vertexNormals[i0] += faceNormal
                vertexNormals[i1] += faceNormal
                vertexNormals[i2] += faceNormal
            }

            for i in 0..<mesh.vertices.count {
                let localNormal = vertexNormals[i]
                let len = simd_length(localNormal)
                let normalized = len > 0 ? localNormal / len : SIMD3<Float>(0, 1, 0)
                let worldNormal = simd_normalize(normalMatrix * normalized)
                allNormals.append(worldNormal)
            }

            // Offset face indices
            for face in mesh.faces {
                allFaces.append(SIMD3<UInt32>(
                    face.x + vertexOffset,
                    face.y + vertexOffset,
                    face.z + vertexOffset
                ))
            }

            vertexOffset += UInt32(mesh.vertices.count)
        }

        return MergedMesh(vertices: allVertices, normals: allNormals, faces: allFaces)
    }

    /// Merge multiple ARMeshAnchors into a single unified mesh in world coordinates.
    /// - Parameter anchors: ARKit mesh anchors to merge
    /// - Returns: A merged mesh with all vertices transformed to world space
    /// - Throws: `TextureMappingError.noMeshData` if anchors is empty
    func mergeMeshAnchors(_ anchors: [ARMeshAnchor]) throws -> MergedMesh {
        guard !anchors.isEmpty else {
            throw TextureMappingError.noMeshData
        }

        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [SIMD3<UInt32>] = []
        var vertexOffset: UInt32 = 0

        for anchor in anchors {
            let geometry = anchor.geometry
            let transform = anchor.transform

            // Extract the upper-left 3x3 rotation part for transforming normals
            let normalMatrix = simd_float3x3(
                SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )

            let vertexCount = geometry.vertices.count
            let faceCount = geometry.faces.count

            // --- Transform vertices to world coordinates ---
            let vertexSource = geometry.vertices
            let vertexBuffer = vertexSource.buffer.contents().advanced(by: vertexSource.offset)
            let vertexStride = vertexSource.stride

            for i in 0..<vertexCount {
                let ptr = vertexBuffer.advanced(by: i * vertexStride)
                    .assumingMemoryBound(to: SIMD3<Float>.self)
                let localPos = ptr.pointee
                // Homogeneous transform: worldPos = transform * (localPos, 1.0)
                let homogeneous = SIMD4<Float>(localPos.x, localPos.y, localPos.z, 1.0)
                let worldPos = transform * homogeneous
                vertices.append(SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z))
            }

            // --- Extract face indices with vertex offset ---
            let faceElement = geometry.faces
            let indexBuffer = faceElement.buffer.contents()
            let bytesPerIndex = faceElement.bytesPerIndex
            let indicesPerFace = faceElement.indexCountPerPrimitive

            for i in 0..<faceCount {
                let faceBaseOffset = i * indicesPerFace * bytesPerIndex
                var idx = [UInt32](repeating: 0, count: 3)
                for j in 0..<min(indicesPerFace, 3) {
                    let indexOffset = faceBaseOffset + j * bytesPerIndex
                    let indexPtr = indexBuffer.advanced(by: indexOffset)
                    if bytesPerIndex == 4 {
                        idx[j] = indexPtr.assumingMemoryBound(to: UInt32.self).pointee + vertexOffset
                    } else if bytesPerIndex == 2 {
                        idx[j] = UInt32(indexPtr.assumingMemoryBound(to: UInt16.self).pointee) + vertexOffset
                    }
                }
                faces.append(SIMD3<UInt32>(idx[0], idx[1], idx[2]))
            }

            // --- Compute vertex normals from face cross products ---
            // Accumulate face normals to each vertex, then normalize
            var vertexNormals = [SIMD3<Float>](repeating: .zero, count: vertexCount)

            for i in 0..<faceCount {
                let faceBaseOffset = i * indicesPerFace * bytesPerIndex
                var localIdx = [Int](repeating: 0, count: 3)
                for j in 0..<min(indicesPerFace, 3) {
                    let indexOffset = faceBaseOffset + j * bytesPerIndex
                    let indexPtr = indexBuffer.advanced(by: indexOffset)
                    if bytesPerIndex == 4 {
                        localIdx[j] = Int(indexPtr.assumingMemoryBound(to: UInt32.self).pointee)
                    } else if bytesPerIndex == 2 {
                        localIdx[j] = Int(indexPtr.assumingMemoryBound(to: UInt16.self).pointee)
                    }
                }

                // Read local vertex positions for this face
                let p0Ptr = vertexBuffer.advanced(by: localIdx[0] * vertexStride)
                    .assumingMemoryBound(to: SIMD3<Float>.self)
                let p1Ptr = vertexBuffer.advanced(by: localIdx[1] * vertexStride)
                    .assumingMemoryBound(to: SIMD3<Float>.self)
                let p2Ptr = vertexBuffer.advanced(by: localIdx[2] * vertexStride)
                    .assumingMemoryBound(to: SIMD3<Float>.self)

                let edge1 = p1Ptr.pointee - p0Ptr.pointee
                let edge2 = p2Ptr.pointee - p0Ptr.pointee
                let faceNormal = simd_cross(edge1, edge2)

                // Accumulate to each vertex of this face
                vertexNormals[localIdx[0]] += faceNormal
                vertexNormals[localIdx[1]] += faceNormal
                vertexNormals[localIdx[2]] += faceNormal
            }

            // Normalize and transform normals to world space
            for i in 0..<vertexCount {
                let localNormal = vertexNormals[i]
                let len = simd_length(localNormal)
                let normalized = len > 0 ? localNormal / len : SIMD3<Float>(0, 1, 0)
                let worldNormal = simd_normalize(normalMatrix * normalized)
                normals.append(worldNormal)
            }

            vertexOffset += UInt32(vertexCount)
        }

        return MergedMesh(vertices: vertices, normals: normals, faces: faces)
    }

    // MARK: - Vertex Welding

    /// Merge colocal vertices (within epsilon distance) to restore mesh topology.
    ///
    /// ARKit mesh anchors produce per-triangle vertices with no index sharing
    /// across faces. This causes UV unwrappers like xatlas to treat each triangle
    /// as an isolated chart. Welding merges duplicate vertices so adjacent
    /// triangles share vertex indices, enabling proper chart growth.
    ///
    /// Uses spatial hashing (grid cells of size epsilon) for O(n) performance.
    func weldVertices(_ mesh: MergedMesh, epsilon: Float = 1e-5) -> MergedMesh {
        let vertexCount = mesh.vertices.count
        if vertexCount == 0 { return mesh }

        // Spatial hash: quantize each vertex position to a grid cell
        let invEps = 1.0 / epsilon

        // Map from grid cell to list of (original index, canonical index)
        // We use a dictionary keyed by quantized (ix, iy, iz)
        struct GridKey: Hashable {
            let x: Int64
            let y: Int64
            let z: Int64
        }

        var grid: [GridKey: [Int]] = [:]
        var oldToNew = [UInt32](repeating: 0, count: vertexCount)
        var newVertices: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        // Track accumulated normals for averaging
        var normalAccum: [SIMD3<Float>] = []
        var normalCount: [Int] = []

        for i in 0..<vertexCount {
            let v = mesh.vertices[i]
            let gx = Int64(floor(Double(v.x) * Double(invEps)))
            let gy = Int64(floor(Double(v.y) * Double(invEps)))
            let gz = Int64(floor(Double(v.z) * Double(invEps)))

            // Check this cell and 26 neighbors (to handle vertices near cell boundaries)
            var foundIdx: Int = -1
            outerLoop: for dx in Int64(-1)...Int64(1) {
                for dy in Int64(-1)...Int64(1) {
                    for dz in Int64(-1)...Int64(1) {
                        let key = GridKey(x: gx + dx, y: gy + dy, z: gz + dz)
                        if let candidates = grid[key] {
                            for ci in candidates {
                                let cv = newVertices[ci]
                                let diff = v - cv
                                if simd_dot(diff, diff) <= epsilon * epsilon {
                                    foundIdx = ci
                                    break outerLoop
                                }
                            }
                        }
                    }
                }
            }

            if foundIdx >= 0 {
                // Merge into existing vertex
                oldToNew[i] = UInt32(foundIdx)
                normalAccum[foundIdx] += mesh.normals[i]
                normalCount[foundIdx] += 1
            } else {
                // New unique vertex
                let newIdx = newVertices.count
                oldToNew[i] = UInt32(newIdx)
                newVertices.append(v)
                normalAccum.append(mesh.normals[i])
                normalCount.append(1)

                let key = GridKey(x: gx, y: gy, z: gz)
                grid[key, default: []].append(newIdx)
            }
        }

        // Average normals
        newNormals.reserveCapacity(newVertices.count)
        for i in 0..<newVertices.count {
            let n = normalAccum[i]
            let len = simd_length(n)
            newNormals.append(len > 0 ? n / len : SIMD3<Float>(0, 1, 0))
        }

        // Remap face indices and remove degenerate faces
        var newFaces: [SIMD3<UInt32>] = []
        newFaces.reserveCapacity(mesh.faces.count)
        var degenerateCount = 0
        for face in mesh.faces {
            let i0 = oldToNew[Int(face.x)]
            let i1 = oldToNew[Int(face.y)]
            let i2 = oldToNew[Int(face.z)]
            if i0 != i1 && i1 != i2 && i0 != i2 {
                newFaces.append(SIMD3<UInt32>(i0, i1, i2))
            } else {
                degenerateCount += 1
            }
        }

        if degenerateCount > 0 {
            print("[TextureMappingPipeline] Removed \(degenerateCount) degenerate faces after welding")
        }

        return MergedMesh(vertices: newVertices, normals: newNormals, faces: newFaces)
    }

    // MARK: - Mesh Decimation (Quadric Error Metrics)

    /// Simplify mesh by iteratively collapsing the lowest-cost edge using QEM.
    /// Each vertex accumulates a 4×4 quadric matrix from its incident planes;
    /// collapsing an edge merges the two quadrics and places the new vertex
    /// at the position that minimizes the combined error.
    func decimateMesh(_ mesh: MergedMesh, targetFaceCount: Int) -> MergedMesh {
        let vCount = mesh.vertices.count
        let fCount = mesh.faces.count
        if fCount <= targetFaceCount { return mesh }

        // Mutable copies
        var pos = mesh.vertices       // [SIMD3<Float>]
        var nrm = mesh.normals        // [SIMD3<Float>]
        var faces = mesh.faces         // [SIMD3<UInt32>]
        var alive = [Bool](repeating: true, count: fCount)

        // Quadric: store as 10 floats (symmetric 4x4 upper triangle)
        // Q = [a b c d; b e f g; c f h i; d g i j]
        // indices: a=0 b=1 c=2 d=3 e=4 f=5 g=6 h=7 i=8 j=9
        typealias Quadric = (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float)
        let zero: Quadric = (0,0,0,0,0,0,0,0,0,0)

        func addQ(_ a: Quadric, _ b: Quadric) -> Quadric {
            (a.0+b.0, a.1+b.1, a.2+b.2, a.3+b.3, a.4+b.4,
             a.5+b.5, a.6+b.6, a.7+b.7, a.8+b.8, a.9+b.9)
        }

        func planeQuadric(_ n: SIMD3<Float>, _ d: Float) -> Quadric {
            let (a,b,c) = (n.x, n.y, n.z)
            return (a*a, a*b, a*c, a*d,
                    b*b, b*c, b*d,
                    c*c, c*d,
                    d*d)
        }

        func evalQ(_ q: Quadric, _ v: SIMD3<Float>) -> Float {
            let x = v.x, y = v.y, z = v.z
            return q.0*x*x + 2*q.1*x*y + 2*q.2*x*z + 2*q.3*x
                 + q.4*y*y + 2*q.5*y*z + 2*q.6*y
                 + q.7*z*z + 2*q.8*z
                 + q.9
        }

        // Build per-vertex quadrics from face planes
        var Q = [Quadric](repeating: zero, count: vCount)
        for fi in 0..<fCount {
            let f = faces[fi]
            let p0 = pos[Int(f.x)], p1 = pos[Int(f.y)], p2 = pos[Int(f.z)]
            let e1 = p1 - p0, e2 = p2 - p0
            var n = simd_cross(e1, e2)
            let len = simd_length(n)
            if len > 1e-10 { n /= len } else { continue }
            let d = -simd_dot(n, p0)
            let pq = planeQuadric(n, d)
            Q[Int(f.x)] = addQ(Q[Int(f.x)], pq)
            Q[Int(f.y)] = addQ(Q[Int(f.y)], pq)
            Q[Int(f.z)] = addQ(Q[Int(f.z)], pq)
        }

        // Union-Find for vertex merging
        var parent = Array(0..<vCount)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while c != r { let next = parent[c]; parent[c] = r; c = next }
            return r
        }

        // Build edge set and compute costs
        struct Edge: Comparable {
            let cost: Float
            let v0: Int
            let v1: Int
            static func < (a: Edge, b: Edge) -> Bool { a.cost < b.cost }
        }

        // Collect unique edges from faces
        var edgeSet = Set<UInt64>()
        var edges: [Edge] = []
        for fi in 0..<fCount {
            let f = faces[fi]
            let tri = [Int(f.x), Int(f.y), Int(f.z)]
            for k in 0..<3 {
                let a = tri[k], b = tri[(k+1)%3]
                let key: UInt64 = a < b ? UInt64(a) << 32 | UInt64(b) : UInt64(b) << 32 | UInt64(a)
                if edgeSet.insert(key).inserted {
                    let mid = (pos[a] + pos[b]) * 0.5
                    let qSum = addQ(Q[a], Q[b])
                    let cost = evalQ(qSum, mid)
                    edges.append(Edge(cost: cost, v0: a, v1: b))
                }
            }
        }
        edges.sort()

        // Iteratively collapse cheapest edges
        var liveFaces = fCount
        var edgeIdx = 0
        while liveFaces > targetFaceCount && edgeIdx < edges.count {
            let e = edges[edgeIdx]
            edgeIdx += 1
            let r0 = find(e.v0), r1 = find(e.v1)
            if r0 == r1 { continue } // already merged

            // Merge r1 into r0
            parent[r1] = r0
            let mid = (pos[r0] + pos[r1]) * 0.5
            pos[r0] = mid
            nrm[r0] = simd_normalize(nrm[r0] + nrm[r1])
            Q[r0] = addQ(Q[r0], Q[r1])

            // Kill degenerate faces
            for fi in 0..<fCount {
                if !alive[fi] { continue }
                let f = faces[fi]
                let a = find(Int(f.x)), b = find(Int(f.y)), c = find(Int(f.z))
                if a == b || b == c || a == c {
                    alive[fi] = false
                    liveFaces -= 1
                }
            }
        }

        // Compact: remap vertices and rebuild faces
        var remap = [Int](repeating: -1, count: vCount)
        var outVerts: [SIMD3<Float>] = []
        var outNorms: [SIMD3<Float>] = []
        for i in 0..<vCount {
            let r = find(i)
            if remap[r] == -1 {
                remap[r] = outVerts.count
                outVerts.append(pos[r])
                let n = nrm[r]
                let nl = simd_length(n)
                outNorms.append(nl > 0 ? n / nl : SIMD3<Float>(0, 1, 0))
            }
            remap[i] = remap[r]
        }

        var outFaces: [SIMD3<UInt32>] = []
        outFaces.reserveCapacity(liveFaces)
        for fi in 0..<fCount {
            if !alive[fi] { continue }
            let f = faces[fi]
            let a = UInt32(remap[Int(f.x)])
            let b = UInt32(remap[Int(f.y)])
            let c = UInt32(remap[Int(f.z)])
            if a != b && b != c && a != c {
                outFaces.append(SIMD3<UInt32>(a, b, c))
            }
        }

        return MergedMesh(vertices: outVerts, normals: outNorms, faces: outFaces)
    }
}
