import Foundation
import ARKit
import simd

/// Concrete implementation of `ScannerService` using ARKit + LiDAR.
///
/// Manages ARKit session lifecycle, captures LiDAR point cloud data and RGB keyframes,
/// and records camera intrinsics/extrinsics for each keyframe.
///
/// The shared C++ core decides view novelty and image quality before JPEG capture.
///
/// ## Privacy Policy
/// All scan data is stored locally only. No network upload functionality is included.
/// This class does not use URLSession, URLRequest, or any networking APIs.
/// Scan data (point clouds, images, poses) is written exclusively to the local filesystem
/// via ``ScanDataExporter``.
///
/// - Requirements: 1.1, 1.2, 1.3, 15.1
final class ARKitScannerService: NSObject, ScannerService {
    let locationStore = ScanLocationStore()
    private let trackingRun = ScanTrackingRunState()

    // MARK: - Constants

    /// Thin state and bridge to the shared C++ capture policy.
    private var keyframePolicy = ScanKeyframePolicy()
    private var lastCaptureRun: Int?
    private var rejectedKeyframeCount = 0
    private var qualityFeedback: String?
    private var lastQualityCheck: TimeInterval = -.infinity
    /// Maximum point count before automatic downsampling
    private static let maxPointCount = 5_000_000
    /// JPEGs are encoded from ARKit's captured-image buffer without rotating pixels.
    private static let exportedImageOrientation: ScanImageOrientation = .landscapeRight

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
        keyframePolicy.reset(); lastCaptureRun = nil; rejectedKeyframeCount = 0
        qualityFeedback = nil; lastQualityCheck = -.infinity
        keyframeIndex = 0
        meshAnchors = []
        trackingRun.start()

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
            isScanning: isScanning,
            rejectedKeyframeCount: rejectedKeyframeCount,
            qualityFeedback: qualityFeedback
        )
    }


    // MARK: - Keyframe Capture Strategy

    /// Calls the canonical core policy without duplicating view thresholds.
    ///
    /// - Requirements: 1.2
    private func shouldCaptureKeyframe(currentTime: TimeInterval, currentTransform: simd_float4x4) -> Bool {
        keyframePolicy.shouldCapture(at: currentTime, transform: currentTransform)
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
    ///
    /// The captured-image buffer is encoded without applying a pixel rotation. Its
    /// accompanying pose therefore records the native ARKit landscape-right layout.
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

        // Bind the ARFrame's intrinsics to this exact frame before it can become a keyframe.
        let frameIntrinsics = extractIntrinsics(from: frame)
        currentIntrinsics = frameIntrinsics

        // Accumulate point cloud vertices from raw feature points
        let newVertices = extractPointCloudVertices(from: frame)
        if !newVertices.isEmpty {
            pointCloudVertices.append(contentsOf: newVertices)
            downsamplePointCloudIfNeeded()
        }

        // Keep pixels, calibration and pose bound to this exact ARFrame.
        let cameraTransform = frame.camera.transform

        // Skip keyframe capture if ARKit tracking is not fully established.
        // Early frames often have identity transforms (no real pose data),
        // which corrupt downstream texture mapping.
        guard let run = trackingRun.runForFrame(isTrackingNormal: frame.camera.trackingState == .normal) else {
            qualityFeedback = "等待相机稳定追踪后继续采集"
            return
        }
        if lastCaptureRun != run {
            keyframePolicy.reset(); lastCaptureRun = run; lastQualityCheck = -.infinity
        }

        guard shouldCaptureKeyframe(currentTime: currentTime, currentTransform: cameraTransform) else {
            return
        }
        // Device-side work scheduling only; quality and view decisions live in C++.
        guard currentTime - lastQualityCheck >= 0.2 else { return }
        lastQualityCheck = currentTime
        let quality = ScanFrameQuality.assess(pixelBuffer: frame.capturedImage)
        qualityFeedback = quality.feedback
        guard quality.rejection == nil else { rejectedKeyframeCount += 1; return }

        // Capture keyframe image
        guard let imageData = captureKeyframeImage(from: frame) else {
            return
        }

        let filename = String(format: "frame_%04d.jpg", keyframeIndex)

        // Record camera pose (extrinsics: 4x4 transform matrix) — Requirement 1.3
        let pose = CameraPose(
            timestamp: currentTime,
            transform: cameraTransform,
            imageFilename: filename,
            imageOrientation: Self.exportedImageOrientation,
            intrinsics: frameIntrinsics,
            imageWidth: frameIntrinsics.width,
            imageHeight: frameIntrinsics.height,
            run: run,
            location: locationStore.snapshot(at: Date().timeIntervalSince1970
                + frame.timestamp - ProcessInfo.processInfo.systemUptime)
        )

        let capturedImage = CapturedImage(imageData: imageData, filename: filename)

        // Store keyframe data
        capturedImages.append(capturedImage)
        cameraPoses.append(pose)

        // Update keyframe tracking state
        keyframePolicy.recordCapture(at: currentTime, transform: cameraTransform)
        keyframeIndex += 1
    }

    func sessionWasInterrupted(_ session: ARSession) { trackingRun.interrupt() }

    func session(_ session: ARSession, didFailWithError error: Error) { trackingRun.interrupt() }
}
