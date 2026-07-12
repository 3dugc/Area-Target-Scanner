import Foundation
import ARKit
import simd

/// Concrete implementation of `ScannerService` using ARKit + LiDAR.
///
/// Manages ARKit session lifecycle, captures LiDAR point cloud data and RGB keyframes,
/// and records camera intrinsics/extrinsics for each keyframe.
///
/// Keyframe capture strategy: every 0.5 seconds OR camera movement > 10cm.
///
/// ## Privacy Policy
/// All scan data is stored locally only. No network upload functionality is included.
/// This class does not use URLSession, URLRequest, or any networking APIs.
/// Scan data (point clouds, images, poses) is written exclusively to the local filesystem
/// via ``ScanDataExporter``.
///
/// - Requirements: 1.1, 1.2, 1.3, 15.1
final class ARKitScannerService: NSObject, ScannerService {

    // MARK: - Constants

    /// Minimum time interval between keyframe captures (seconds)
    private static let keyframeTimeInterval: TimeInterval = 0.5
    /// Minimum camera movement to trigger keyframe capture (meters)
    private static let keyframeDistanceThreshold: Float = 0.10
    /// Maximum point count before automatic downsampling
    private static let maxPointCount = 5_000_000

    // MARK: - State

    /// Exposed for the AR camera preview view to share the same session.
    let arSession = ARSession()
    private var isScanning = false

    /// Accumulated point cloud vertices: each element is [x, y, z, r, g, b, nx, ny, nz]
    private var pointCloudVertices: [[Float]] = []
    /// Captured keyframe images
    private var capturedImages: [CapturedImage] = []
    /// Camera poses corresponding to each keyframe
    private var cameraPoses: [CameraPose] = []
    /// Camera intrinsics recorded from the latest frame
    private var currentIntrinsics: CameraIntrinsics?

    /// Timestamp of the last captured keyframe
    private var lastKeyframeTime: TimeInterval = 0
    /// Transform of the last captured keyframe (for distance check)
    private var lastKeyframeTransform: simd_float4x4?
    /// Session start time for relative timestamps
    private var sessionStartTime: TimeInterval = 0
    /// Running keyframe index for filename generation
    private var keyframeIndex: Int = 0
    /// Collected mesh anchors for GLB export
    private(set) var meshAnchors: [ARMeshAnchor] = []

    // MARK: - ScannerService Protocol

    func startScan() throws {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            throw ScannerError.arkitUnavailable
        }
        guard !isScanning else {
            throw ScannerError.scanAlreadyInProgress
        }

        // Reset state
        pointCloudVertices = []
        capturedImages = []
        cameraPoses = []
        currentIntrinsics = nil
        lastKeyframeTime = 0
        lastKeyframeTransform = nil
        keyframeIndex = 0
        meshAnchors = []

        // Configure ARKit session for LiDAR point cloud + RGB capture
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .meshWithClassification
        configuration.frameSemantics = [.sceneDepth]
        configuration.environmentTexturing = .automatic

        arSession.delegate = self
        arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        sessionStartTime = ProcessInfo.processInfo.systemUptime
        isScanning = true
    }

    func stopScan() throws -> ScanResult {
        guard isScanning else {
            throw ScannerError.scanNotStarted
        }

        arSession.pause()
        isScanning = false

        let intrinsics = currentIntrinsics ?? CameraIntrinsics(
            fx: 0, fy: 0, cx: 0, cy: 0, width: 0, height: 0
        )

        return ScanResult(
            pointCloudVertices: pointCloudVertices,
            images: capturedImages,
            cameraPoses: cameraPoses,
            intrinsics: intrinsics
        )
    }

    func exportScanData(outputPath: String, onProgress: ((String) -> Void)? = nil) throws -> Bool {
        guard !isScanning else {
            throw ScannerError.scanAlreadyInProgress
        }

        // Requirement 3.5: block export if point count < 1000
        guard pointCloudVertices.count >= 1000 else {
            throw ScannerError.insufficientData(pointCount: pointCloudVertices.count)
        }

        let intrinsics = currentIntrinsics ?? CameraIntrinsics(
            fx: 0, fy: 0, cx: 0, cy: 0, width: 0, height: 0
        )

        let exporter = ScanDataExporter()
        do {
            try exporter.exportAll(
                vertices: pointCloudVertices,
                poses: cameraPoses,
                intrinsics: intrinsics,
                images: capturedImages,
                meshAnchors: meshAnchors,
                outputPath: outputPath,
                onProgress: onProgress
            )
        } catch {
            throw ScannerError.exportFailed(reason: error.localizedDescription)
        }

        return true
    }

    func getScanProgress() -> ScanProgress {
        return ScanProgress(
            pointCount: pointCloudVertices.count,
            coverageArea: estimateCoverageArea(),
            keyframeCount: capturedImages.count,
            isScanning: isScanning
        )
    }


    // MARK: - Keyframe Capture Strategy

    /// Determines whether a new keyframe should be captured based on time and distance criteria.
    ///
    /// Captures a keyframe when:
    /// - At least 0.5 seconds have elapsed since the last keyframe, OR
    /// - The camera has moved more than 10cm since the last keyframe
    ///
    /// - Requirements: 1.2
    private func shouldCaptureKeyframe(currentTime: TimeInterval, currentTransform: simd_float4x4) -> Bool {
        // Always capture the first keyframe
        guard let lastTransform = lastKeyframeTransform else {
            return true
        }

        // Time-based criterion: >= 0.5 seconds since last keyframe
        let timeSinceLastKeyframe = currentTime - lastKeyframeTime
        if timeSinceLastKeyframe >= Self.keyframeTimeInterval {
            return true
        }

        // Distance-based criterion: camera moved > 10cm
        let distance = translationDistance(from: lastTransform, to: currentTransform)
        if distance > Self.keyframeDistanceThreshold {
            return true
        }

        return false
    }

    /// Computes the Euclidean distance between the translation components of two 4x4 transforms.
    private func translationDistance(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let posA = simd_float3(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let posB = simd_float3(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        return simd_length(posB - posA)
    }

    // MARK: - Camera Intrinsics Recording

    /// Extracts camera intrinsics (fx, fy, cx, cy, width, height) from an ARFrame.
    ///
    /// - Requirements: 1.3
    private func extractIntrinsics(from frame: ARFrame) -> CameraIntrinsics {
        let intrinsicMatrix = frame.camera.intrinsics
        let imageResolution = frame.camera.imageResolution

        return CameraIntrinsics(
            fx: intrinsicMatrix[0][0],
            fy: intrinsicMatrix[1][1],
            cx: intrinsicMatrix[2][0],
            cy: intrinsicMatrix[2][1],
            width: Int(imageResolution.width),
            height: Int(imageResolution.height)
        )
    }

    // MARK: - Point Cloud Extraction

    /// Extracts point cloud vertices from the ARFrame's scene depth and confidence maps.
    /// Each vertex is stored as [x, y, z, r, g, b, nx, ny, nz].
    private func extractPointCloudVertices(from frame: ARFrame) -> [[Float]] {
        guard let rawFeaturePoints = frame.rawFeaturePoints else {
            return []
        }

        let points = rawFeaturePoints.points
        var vertices: [[Float]] = []
        vertices.reserveCapacity(points.count)

        for point in points {
            // ARKit rawFeaturePoints provide position only;
            // color and normals default to 0 and will be refined during post-processing
            let vertex: [Float] = [
                point.x, point.y, point.z,  // position
                0.0, 0.0, 0.0,              // color (placeholder)
                0.0, 0.0, 0.0               // normal (placeholder)
            ]
            vertices.append(vertex)
        }

        return vertices
    }

    // MARK: - Keyframe Image Capture

    /// Captures the current camera frame as JPEG data for a keyframe.
    private func captureKeyframeImage(from frame: ARFrame) -> Data? {
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: 0.85)
    }

    // MARK: - Point Cloud Downsampling

    /// Downsamples the point cloud by keeping every Nth point when count exceeds the threshold.
    ///
    /// - Requirements: 1.4
    private func downsamplePointCloudIfNeeded() {
        guard pointCloudVertices.count > Self.maxPointCount else { return }

        // Keep every other point to halve the count
        var downsampled: [[Float]] = []
        downsampled.reserveCapacity(pointCloudVertices.count / 2)
        for i in stride(from: 0, to: pointCloudVertices.count, by: 2) {
            downsampled.append(pointCloudVertices[i])
        }
        pointCloudVertices = downsampled
    }

    // MARK: - Coverage Area Estimation

    /// Estimates the scanned coverage area from the XZ bounding box of captured keyframe positions.
    private func estimateCoverageArea() -> Float {
        guard cameraPoses.count >= 2 else { return 0.0 }

        var minX: Float = .greatestFiniteMagnitude
        var maxX: Float = -.greatestFiniteMagnitude
        var minZ: Float = .greatestFiniteMagnitude
        var maxZ: Float = -.greatestFiniteMagnitude

        for pose in cameraPoses {
            // Translation is in columns 12-14 (column-major: indices 12, 13, 14)
            guard pose.transform.count == 16 else { continue }
            let tx = pose.transform[12]
            let tz = pose.transform[14]
            minX = min(minX, tx)
            maxX = max(maxX, tx)
            minZ = min(minZ, tz)
            maxZ = max(maxZ, tz)
        }

        let width = maxX - minX
        let depth = maxZ - minZ
        return max(0, width * depth)
    }
}


// MARK: - ARSessionDelegate

extension ARKitScannerService: ARSessionDelegate {

    /// Called for each new ARFrame. Handles point cloud accumulation and keyframe capture.
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard isScanning else { return }
        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                meshAnchors.append(meshAnchor)
            }
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard isScanning else { return }
        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                // Replace existing anchor with updated version
                if let idx = meshAnchors.firstIndex(where: { $0.identifier == meshAnchor.identifier }) {
                    meshAnchors[idx] = meshAnchor
                } else {
                    meshAnchors.append(meshAnchor)
                }
            }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isScanning else { return }

        let currentTime = frame.timestamp - sessionStartTime

        // Always update intrinsics from the latest frame (Requirement 1.3)
        currentIntrinsics = extractIntrinsics(from: frame)

        // Accumulate point cloud vertices from raw feature points
        let newVertices = extractPointCloudVertices(from: frame)
        if !newVertices.isEmpty {
            pointCloudVertices.append(contentsOf: newVertices)
            downsamplePointCloudIfNeeded()
        }

        // Keyframe capture: every 0.5s or camera movement > 10cm (Requirement 1.2)
        let cameraTransform = frame.camera.transform

        // Skip keyframe capture if ARKit tracking is not fully established.
        // Early frames often have identity transforms (no real pose data),
        // which corrupt downstream texture mapping.
        guard frame.camera.trackingState == .normal else {
            return
        }

        guard shouldCaptureKeyframe(currentTime: currentTime, currentTransform: cameraTransform) else {
            return
        }

        // Capture keyframe image
        guard let imageData = captureKeyframeImage(from: frame) else {
            return
        }

        let filename = String(format: "frame_%04d.jpg", keyframeIndex)

        // Record camera pose (extrinsics: 4x4 transform matrix) — Requirement 1.3
        let pose = CameraPose(
            timestamp: currentTime,
            transform: cameraTransform,
            imageFilename: filename
        )

        let capturedImage = CapturedImage(imageData: imageData, filename: filename)

        // Store keyframe data
        capturedImages.append(capturedImage)
        cameraPoses.append(pose)

        // Update keyframe tracking state
        lastKeyframeTime = currentTime
        lastKeyframeTransform = cameraTransform
        keyframeIndex += 1
    }
}
