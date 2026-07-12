import Foundation

/// Errors that can occur during scanning operations.
enum ScannerError: Error, LocalizedError {
    case scanNotStarted
    case scanAlreadyInProgress
    case insufficientData(pointCount: Int)
    case exportFailed(reason: String)
    case arkitUnavailable

    var errorDescription: String? {
        switch self {
        case .scanNotStarted:
            return "No active scan session. Call startScan() first."
        case .scanAlreadyInProgress:
            return "A scan is already in progress."
        case .insufficientData(let pointCount):
            return "扫描数据不足（当前 \(pointCount) 点），请继续扫描更多区域"
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        case .arkitUnavailable:
            return "ARKit is not available on this device."
        }
    }
}

/// Protocol defining the scanner service interface.
///
/// Responsible for managing ARKit LiDAR scanning sessions,
/// capturing point clouds, RGB images, and camera poses.
///
/// - Requirements: 1.1, 15.3
protocol ScannerService: AnyObject {
    /// Start an ARKit scanning session.
    /// Begins capturing LiDAR point cloud data and RGB image frames.
    /// - Throws: `ScannerError.scanAlreadyInProgress` if a scan is active,
    ///           `ScannerError.arkitUnavailable` if ARKit/LiDAR is not supported.
    func startScan() throws

    /// Stop the current scanning session and return the captured data.
    /// - Returns: A `ScanResult` containing point cloud, images, poses, and intrinsics.
    /// - Throws: `ScannerError.scanNotStarted` if no scan is active.
    func stopScan() throws -> ScanResult

    /// Export scan data to the specified directory in standard format.
    ///
    /// Outputs:
    /// - `pointcloud.ply` (XYZ + color + normals)
    /// - `poses.json` (camera poses, column-major transforms)
    /// - `intrinsics.json` (camera intrinsics)
    /// - `images/` directory with JPEG keyframe images
    ///
    /// - Parameter outputPath: Directory path to write the scan data package.
    /// - Returns: `true` if export succeeded.
    /// - Throws: `ScannerError.insufficientData` if point count < 1000,
    ///           `ScannerError.exportFailed` on I/O errors.
    func exportScanData(outputPath: String, onProgress: ((String) -> Void)?) throws -> Bool

    /// Get the current scan progress.
    /// - Returns: A `ScanProgress` snapshot with point count, coverage area, etc.
    func getScanProgress() -> ScanProgress
}
