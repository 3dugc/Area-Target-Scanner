import Foundation
import simd

/// The pixel orientation of a JPEG retained for an ARKit scan keyframe.
enum ScanImageOrientation: String, Codable, Equatable, CaseIterable {
    case landscapeLeft
    case landscapeRight
    case portrait
    case portraitUpsideDown
}

/// A single camera pose captured at a keyframe.
/// Stores the timestamp, 4x4 world-space transform, and the associated image filename.
struct CameraPose: Codable, Equatable {
    /// Capture timestamp (seconds since session start)
    let timestamp: Double
    /// 4x4 transformation matrix (world coordinate system), stored as column-major 16 floats
    let transform: [Float]
    /// Filename of the corresponding captured image (e.g. "frame_0000.jpg")
    let imageFilename: String
    /// Pixel orientation of the exported keyframe JPEG. Nil is a legacy/incomplete pose.
    let imageOrientation: ScanImageOrientation?
    /// Camera intrinsics that apply to this specific keyframe. Nil is a legacy/incomplete pose.
    let intrinsics: CameraIntrinsics?
    /// Width of the exported keyframe JPEG in pixels. Nil is a legacy/incomplete pose.
    let imageWidth: Int?
    /// Height of the exported keyframe JPEG in pixels. Nil is a legacy/incomplete pose.
    let imageHeight: Int?

    /// Convenience initializer from a simd_float4x4 matrix.
    init(
        timestamp: Double,
        transform: simd_float4x4,
        imageFilename: String,
        imageOrientation: ScanImageOrientation? = nil,
        intrinsics: CameraIntrinsics? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil
    ) {
        self.timestamp = timestamp
        // Store as column-major array (matches ARKit convention)
        self.transform = [
            transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
            transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
            transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
            transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w
        ]
        self.imageFilename = imageFilename
        self.imageOrientation = imageOrientation
        self.intrinsics = intrinsics
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    /// Memberwise initializer with raw float array.
    init(
        timestamp: Double,
        transform: [Float],
        imageFilename: String,
        imageOrientation: ScanImageOrientation? = nil,
        intrinsics: CameraIntrinsics? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil
    ) {
        precondition(transform.count == 16, "Transform must contain exactly 16 floats (4x4 matrix)")
        self.timestamp = timestamp
        self.transform = transform
        self.imageFilename = imageFilename
        self.imageOrientation = imageOrientation
        self.intrinsics = intrinsics
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }
}
