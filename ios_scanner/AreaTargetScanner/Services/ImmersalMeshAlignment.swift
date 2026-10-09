import Foundation
import simd
import AreaTargetNative

enum ImmersalMeshAlignment {
    struct Result {
        let mapFromScan: simd_float4x4
        let matchedCount: Int
        let inlierCount: Int
        let maxPositionResidualMeters: Double
        let maxAngleResidualDegrees: Double
    }

    enum AlignmentError: LocalizedError {
        case insufficientMatches, invalidTransform, inconsistentMatches

        var errorDescription: String? {
            switch self {
            case .insufficientMatches:
                return "原扫描图像的有效定位不足，至少需要 3 帧一致结果才能叠加网格。"
            case .invalidTransform:
                return "网格对齐包含无效或非刚体坐标变换，无法可靠叠加。"
            case .inconsistentMatches:
                return "原扫描与定位地图的对齐结果不一致，暂不叠加网格。"
            }
        }
    }

    /// Pass the SDK pose and captured AR-camera pose to the shared core.
    /// The core owns the camera-basis conversion and rigid validation.
    static func candidate(scanFromCamera: simd_float4x4, mapPosition: SIMD3<Float>,
                          mapRotation: simd_quatf) -> simd_float4x4? {
        let scanPose = rowMajor(scanFromCamera)
        let position = [mapPosition.x, mapPosition.y, mapPosition.z]
        let rotation = [mapRotation.vector.x, mapRotation.vector.y,
                        mapRotation.vector.z, mapRotation.vector.w]
        var output = [Float](repeating: 0, count: 16)
        let status = scanPose.withUnsafeBufferPointer { scan in
            position.withUnsafeBufferPointer { translation in
                rotation.withUnsafeBufferPointer { quaternion in
                    output.withUnsafeMutableBufferPointer { result in
                        atc_make_immersal_alignment_candidate_v2(
                            scan.baseAddress, translation.baseAddress,
                            quaternion.baseAddress, result.baseAddress)
                    }
                }
            }
        }
        return status == Int32(ATC_OK) ? matrix(rowMajor: output) : nil
    }

    /// The shared core selects a measured rigid consensus and its residuals.
    static func estimate(_ candidates: [simd_float4x4]) throws -> Result {
        guard let count = UInt32(exactly: candidates.count) else {
            throw AlignmentError.invalidTransform
        }
        var configuration = ATCRigidConsensusConfigV2()
        configuration.struct_size = UInt32(MemoryLayout<ATCRigidConsensusConfigV2>.size)
        configuration.api_version = atc_get_api_version()
        guard atc_get_default_rigid_consensus_config_v2(&configuration) == Int32(ATC_OK) else {
            throw AlignmentError.invalidTransform
        }
        var output = ATCRigidConsensusResultV2()
        output.struct_size = UInt32(MemoryLayout<ATCRigidConsensusResultV2>.size)
        output.api_version = atc_get_api_version()
        let matrices = candidates.flatMap(rowMajor)
        let status = matrices.withUnsafeBufferPointer {
            atc_estimate_rigid_consensus_v2(&configuration, $0.baseAddress, count, &output)
        }
        guard status == Int32(ATC_OK), output.valid != 0 else {
            switch output.rejection_reason {
            case UInt32(ATC_CONSENSUS_INSUFFICIENT): throw AlignmentError.insufficientMatches
            case UInt32(ATC_CONSENSUS_INCONSISTENT): throw AlignmentError.inconsistentMatches
            default: throw AlignmentError.invalidTransform
            }
        }
        let pose = withUnsafeBytes(of: output.map_from_scan) {
            matrix(rowMajor: Array($0.bindMemory(to: Float.self)))
        }
        return Result(mapFromScan: pose, matchedCount: Int(output.matched_count),
                      inlierCount: Int(output.inlier_count),
                      maxPositionResidualMeters: Double(output.maximum_translation_residual_m),
                      maxAngleResidualDegrees: Double(output.maximum_rotation_residual_rad) * 180 / .pi)
    }

    private static func rowMajor(_ matrix: simd_float4x4) -> [Float] {
        (0..<4).flatMap { row in (0..<4).map { column in matrix[column][row] } }
    }

    private static func matrix(rowMajor values: [Float]) -> simd_float4x4 {
        var result = matrix_identity_float4x4
        for row in 0..<4 { for column in 0..<4 { result[column][row] = values[row * 4 + column] } }
        return result
    }
}
