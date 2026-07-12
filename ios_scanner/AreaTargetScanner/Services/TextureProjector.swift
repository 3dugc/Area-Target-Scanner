import Foundation
import simd

/// Selects the best camera keyframe for each triangle face and projects
/// 3D world points onto camera image planes using a pinhole camera model.
final class TextureProjector {

    /// Select the best camera frame for each triangle face based on
    /// face normal alignment and distance scoring.
    /// - Parameters:
    ///   - faces: Triangle face indices
    ///   - vertices: World-space vertex positions
    ///   - normals: Per-vertex normals
    ///   - cameraPoses: Keyframe camera poses
    ///   - intrinsics: Camera intrinsic parameters
    /// - Returns: One FaceFrameAssignment per face
    func selectBestFrames(
        faces: [SIMD3<UInt32>],
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        cameraPoses: [CameraPose],
        intrinsics: CameraIntrinsics
    ) -> [FaceFrameAssignment] {
        var assignments: [FaceFrameAssignment] = []
        assignments.reserveCapacity(faces.count)

        // Pre-compute which frames to skip:
        // 1. Identity matrix = no valid pose (ARKit not yet tracking)
        // 2. Near-origin translation = camera hasn't moved yet (e.g. frame_0000
        //    with rotation but translation ≈ 0; isIdentityTransform misses this
        //    because the rotation part differs, but distance ≈ 0 causes
        //    score = dot/dist² to explode to ~10^16, monopolizing all visible faces)
        let skipMask = cameraPoses.map { pose -> Bool in
            if isIdentityTransform(pose.transform) { return true }
            let t = pose.transform
            let tx = t[12], ty = t[13], tz = t[14]
            let translationLen = sqrt(tx * tx + ty * ty + tz * tz)
            return translationLen < 0.01 // skip frames within 1cm of origin
        }
        let skippedCount = skipMask.filter { $0 }.count
        if skippedCount > 0 {
            print("[TextureProjector] Skipping \(skippedCount) identity/near-origin frame(s)")
        }

        for faceIdx in 0..<faces.count {
            let face = faces[faceIdx]
            let v0 = vertices[Int(face.x)]
            let v1 = vertices[Int(face.y)]
            let v2 = vertices[Int(face.z)]

            // Face center
            let center = (v0 + v1 + v2) / 3.0

            // Face normal from cross product
            let edge1 = v1 - v0
            let edge2 = v2 - v0
            let crossProduct = simd_cross(edge1, edge2)
            let crossLen = simd_length(crossProduct)
            let faceNormal: SIMD3<Float> = crossLen > 1e-10
                ? simd_normalize(crossProduct)
                : SIMD3<Float>(0, 1, 0) // degenerate face fallback

            var bestFrameIdx = -1
            var bestScore: Float = 0

            for frameIdx in 0..<cameraPoses.count {
                // Skip identity-pose frames (e.g. initial scan frame with no real pose)
                if skipMask[frameIdx] { continue }

                let pose = cameraPoses[frameIdx]
                let t = pose.transform
                // Extract camera position from column-major transform (column 3, rows 0-2)
                let cameraPos = SIMD3<Float>(t[12], t[13], t[14])

                let toCamera = cameraPos - center
                let distance = simd_length(toCamera)
                if distance < 1e-10 { continue }

                let viewDir = toCamera / distance // normalize
                let dotProduct = simd_dot(faceNormal, viewDir)

                // Backface culling
                if dotProduct <= 0 { continue }

                // Frustum check: use projectVertex — non-nil means in frustum
                if projectVertex(worldPoint: center, cameraPose: pose, intrinsics: intrinsics) == nil {
                    continue
                }

                // Score: dot / distance (linear decay)
                // Previously dot/dist² caused near-origin frames to monopolize
                // faces due to 1/dist² exploding at small distances.
                let score = dotProduct / distance

                if score > bestScore {
                    bestScore = score
                    bestFrameIdx = frameIdx
                }
            }

            if bestFrameIdx >= 0 {
                assignments.append(FaceFrameAssignment(faceIndex: faceIdx, frameIndex: bestFrameIdx, score: bestScore))
            } else {
                // Fallback: use nearest non-skipped frame
                let nearestIdx = findNearestFrame(center: center, cameraPoses: cameraPoses, skipMask: skipMask)
                assignments.append(FaceFrameAssignment(faceIndex: faceIdx, frameIndex: nearestIdx, score: 0))
            }
        }

        return assignments
    }

    /// Check if a column-major float[16] transform is an identity matrix.
    /// Identity poses indicate frames captured before ARKit tracking was established.
    private func isIdentityTransform(_ t: [Float], tolerance: Float = 1e-4) -> Bool {
        guard t.count == 16 else { return false }
        let identity: [Float] = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        ]
        for i in 0..<16 {
            if abs(t[i] - identity[i]) > tolerance { return false }
        }
        return true
    }

    /// Find the camera pose with minimum distance to a given point.
    /// Used as fallback when no suitable frame passes culling/frustum checks.
    /// Skips identity-pose frames.
    private func findNearestFrame(center: SIMD3<Float>, cameraPoses: [CameraPose], skipMask: [Bool]) -> Int {
        var nearestIdx = 0
        var nearestDist: Float = .greatestFiniteMagnitude

        for i in 0..<cameraPoses.count {
            if skipMask[i] { continue }
            let t = cameraPoses[i].transform
            let cameraPos = SIMD3<Float>(t[12], t[13], t[14])
            let dist = simd_length(cameraPos - center)
            if dist < nearestDist {
                nearestDist = dist
                nearestIdx = i
            }
        }

        return nearestIdx
    }

    /// Project a 3D world point onto a camera's image plane.
    /// Uses the pinhole camera model: pixel = K × [R|t] × worldPoint
    /// - Parameters:
    ///   - worldPoint: The 3D point in world coordinates
    ///   - cameraPose: The camera's pose (world transform)
    ///   - intrinsics: Camera intrinsic parameters
    /// - Returns: Normalized image coordinates (u, v) in [0, 1], or nil if
    ///   the point is behind the camera or outside the image bounds
    func projectVertex(
        worldPoint: SIMD3<Float>,
        cameraPose: CameraPose,
        intrinsics: CameraIntrinsics
    ) -> SIMD2<Float>? {
        // 1. Reconstruct simd_float4x4 from column-major float array
        let t = cameraPose.transform
        let poseMatrix = simd_float4x4(
            SIMD4<Float>(t[0], t[1], t[2], t[3]),
            SIMD4<Float>(t[4], t[5], t[6], t[7]),
            SIMD4<Float>(t[8], t[9], t[10], t[11]),
            SIMD4<Float>(t[12], t[13], t[14], t[15])
        )

        // 2. Build view matrix (world → camera) by inverting the pose
        let viewMatrix = simd_inverse(poseMatrix)

        // 3. Transform world point to camera coordinates
        let homogeneous = SIMD4<Float>(worldPoint.x, worldPoint.y, worldPoint.z, 1.0)
        let cameraPoint = viewMatrix * homogeneous

        // 4. Check if point is in front of camera
        //    ARKit uses right-hand coordinate system where camera faces -Z
        if cameraPoint.z >= 0 {
            return nil
        }

        // 5. Pinhole projection
        //    In camera space: X-right, Y-up, camera looks along -Z
        //    In image space: u-right, v-down (top-left origin)
        //    Project: px = fx * (X / -Z) + cx   (X maps directly to u)
        //             py = fy * (-Y / -Z) + cy  (Y flipped for image v-down)
        //    Simplify: px = fx * (X / -Z) + cx
        //              py = fy * (Y / Z) + cy
        let negZ = -cameraPoint.z  // positive depth
        let px = intrinsics.fx * (cameraPoint.x / negZ) + intrinsics.cx
        let py = intrinsics.fy * (-cameraPoint.y / negZ) + intrinsics.cy

        // 6. Normalize to [0, 1]
        let u = px / Float(intrinsics.width)
        let v = py / Float(intrinsics.height)

        // 7. Bounds check
        if u < 0 || u > 1 || v < 0 || v > 1 {
            return nil
        }

        return SIMD2<Float>(u, v)
    }
}
