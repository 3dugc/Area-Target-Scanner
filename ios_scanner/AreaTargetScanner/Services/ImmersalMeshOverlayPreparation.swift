import Foundation
import SceneKit

/// Source geometry and calibration images always come from the mapping job's own scan.
/// The original scan and all cached maps are read-only during this preparation.
struct ImmersalPreparedMeshOverlay {
    let mesh: SCNNode
    let frames: [ImmersalAlignmentFrame]
}

enum ImmersalMeshOverlayPreparation {
    private static let queue = DispatchQueue(label: "com.areatarget.immersal-overlay", qos: .userInitiated)

    static func prepare(scanDirectory: URL) async throws -> ImmersalPreparedMeshOverlay {
        try await onQueue {
            let frames = try ImmersalAlignmentFrames.select(scanDirectory: scanDirectory)
            let mesh = try ImmersalScanMeshLoader.load(scanDirectory: scanDirectory)
            return ImmersalPreparedMeshOverlay(mesh: mesh, frames: frames)
        }
    }

    static func pixels(for frame: ImmersalAlignmentFrame) async throws -> Data {
        try await onQueue { try ImmersalAlignmentFrames.pixels(for: frame) }
    }

    private static func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let result: T = try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
        try Task.checkCancellation()
        return result
    }
}

enum ImmersalMeshSource {
    static func directory(scanName: String, documentsDirectory: URL?) -> URL? {
        guard let documentsDirectory, !scanName.isEmpty, scanName != ".", scanName != "..",
              !scanName.contains("/"), !scanName.contains("\\"), !scanName.contains("\0") else { return nil }
        let root = documentsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(scanName, isDirectory: true)
        guard candidate.resolvingSymlinksInPath().standardizedFileURL.path == candidate.standardizedFileURL.path else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return candidate
    }
}
