import Foundation
import simd

struct ImmersalLocalizationResult {
    let position: SIMD3<Float>
    let rotation: simd_quatf
    let confidence: Int
}

enum ImmersalOfflineError: LocalizedError {
    case unsupported, invalidMap, invalidImage
    var errorDescription: String? {
        switch self {
        case .unsupported: return "离线定位需要在 iPhone 或 iPad 真机上运行。"
        case .invalidMap: return "地图无法载入离线引擎，请重新下载，或确认云端地图已完成。"
        case .invalidImage: return "当前相机帧不可用于定位，请重试。"
        }
    }
}

enum ImmersalImagePacking {
    static func copyRows(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) throws -> Data {
        guard width > 0, height > 0, width <= 8192, height <= 8192, bytesPerRow >= width else {
            throw ImmersalOfflineError.invalidImage
        }
        var data = Data(count: width * height)
        data.withUnsafeMutableBytes { output in
            for row in 0..<height {
                output.baseAddress!.advanced(by: row * width).copyMemory(from: base.advanced(by: row * bytesPerRow), byteCount: width)
            }
        }
        return data
    }
}

enum ImmersalPose {
    /// Native result uses CV camera axes. ARKit cameras look along -Z with +Y up.
    static func worldFromMap(position: SIMD3<Float>, rotation: simd_quatf,
                             worldFromCamera: simd_float4x4) -> simd_float4x4? {
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite,
              rotation.vector.x.isFinite, rotation.vector.y.isFinite, rotation.vector.z.isFinite,
              rotation.vector.w.isFinite, simd_length(rotation.vector) > 0.001 else { return nil }
        var mapFromCamera = simd_float4x4(simd_normalize(rotation))
        mapFromCamera.columns.1 *= -1
        mapFromCamera.columns.2 *= -1
        mapFromCamera.columns.3 = SIMD4(position, 1)
        let result = worldFromCamera * mapFromCamera.inverse
        for column in 0..<4 { for row in 0..<4 { if !result[column][row].isFinite { return nil } } }
        return result
    }
}

/// All SDK calls share one queue: load/localize/free never overlap, including across views.
protocol ImmersalOfflineLocalizing: AnyObject {
    func load(url: URL) async throws -> Int
    func localize(pixels: Data, width: Int, height: Int, intrinsics: SIMD4<Float>) async -> ImmersalLocalizationResult?
    func close()
}

final class ImmersalOfflineLocalizer: ImmersalOfflineLocalizing, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.areatarget.immersal-native", qos: .userInitiated)
    private var handle: Int32 = -1
    private var mapData: Data?

    func load(url: URL) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                #if targetEnvironment(simulator)
                continuation.resume(throwing: ImmersalOfflineError.unsupported)
                #else
                self.freeOnQueue()
                do {
                    let data = try Data(contentsOf: url)
                    guard !data.isEmpty else { throw ImmersalOfflineError.invalidMap }
                    let loaded = data.withUnsafeBytes { icvLoadMap($0.baseAddress!) }
                    guard loaded >= 0 else { throw ImmersalOfflineError.invalidMap }
                    self.handle = loaded
                    self.mapData = data
                    continuation.resume(returning: max(0, Int(icvPointsGetCount(loaded))))
                } catch { continuation.resume(throwing: error) }
                #endif
            }
        }
    }

    func localize(pixels: Data, width: Int, height: Int, intrinsics: SIMD4<Float>) async -> ImmersalLocalizationResult? {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                #if targetEnvironment(simulator)
                continuation.resume(returning: nil)
                #else
                guard self.handle >= 0, pixels.count == width * height,
                      width > 0, height > 0, intrinsics.x > 0, intrinsics.y > 0 else {
                    continuation.resume(returning: nil); return
                }
                var mapHandle = self.handle
                var k = [intrinsics.x, intrinsics.y, intrinsics.z, intrinsics.w]
                var rotation: [Float] = [0, 0, 0, 1]
                var buffer = pixels
                let result = buffer.withUnsafeMutableBytes { bytes in
                    icvLocalize(1, &mapHandle, Int32(width), Int32(height), &k, bytes.baseAddress!, 1, 0, &rotation)
                }
                guard result.handle == self.handle else { continuation.resume(returning: nil); return }
                continuation.resume(returning: ImmersalLocalizationResult(
                    position: SIMD3(result.position.x, result.position.y, result.position.z),
                    rotation: simd_quatf(ix: result.rotation.x, iy: result.rotation.y, iz: result.rotation.z, r: result.rotation.w),
                    confidence: Int(result.confidence)))
                #endif
            }
        }
    }

    func close() { Self.queue.async { self.freeOnQueue() } }

    private func freeOnQueue() {
        #if !targetEnvironment(simulator)
        if handle >= 0 { _ = icvFreeMap(handle) }
        #endif
        handle = -1
        mapData = nil
    }

    deinit {
        let oldHandle = handle
        Self.queue.async {
            #if !targetEnvironment(simulator)
            if oldHandle >= 0 { _ = icvFreeMap(oldHandle) }
            #endif
        }
    }
}
