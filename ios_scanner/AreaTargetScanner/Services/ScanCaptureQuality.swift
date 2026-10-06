import Foundation
import simd
import CoreVideo

struct ScanFrameQuality {
    enum Rejection: String { case exposure, texture, blur, unreadable }
    let rejection: Rejection?
    let sharpness: Double
    let contrast: Double
    let mean: Double
    let sampleCount: UInt64

    static func assess(width: Int, height: Int, pixel: (Int, Int) -> UInt8) -> ScanFrameQuality {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { return unreadable }
        let bytes = (0..<height).flatMap { y in (0..<width).map { x in pixel(x, y) } }
        return bytes.withUnsafeBufferPointer { buffer in
            assess(base: buffer.baseAddress, width: width, height: height, stride: width)
        }
    }

    static func assess(pixelBuffer: CVPixelBuffer) -> ScanFrameQuality {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return unreadable }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        return assess(base: CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
            width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
            stride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
    }

    private static var unreadable: ScanFrameQuality {
        ScanFrameQuality(rejection: .unreadable, sharpness: 0, contrast: 0, mean: 0, sampleCount: 0)
    }

    private static func assess(base: UnsafePointer<UInt8>?, width: Int, height: Int, stride: Int) -> ScanFrameQuality {
        guard width > 0, height > 0, stride >= width else { return unreadable }
        var frame = ATCFrameV2()
        frame.struct_size = UInt32(MemoryLayout<ATCFrameV2>.size); frame.api_version = atc_default_config_v2().api_version
        frame.width = UInt32(width); frame.height = UInt32(height); frame.row_stride = UInt64(stride)
        frame.data = base; frame.byte_length = UInt64(stride) * UInt64(height - 1) + UInt64(width)
        frame.pixel_format = UInt32(ATC_PIXEL_FORMAT_GRAY8)
        var quality = ATCGrayQualityV2()
        quality.struct_size = UInt32(MemoryLayout<ATCGrayQualityV2>.size); quality.api_version = atc_default_config_v2().api_version
        guard atc_assess_gray_quality(&frame, &quality) == ATC_OK else { return unreadable }
        let rejection: Rejection?
        switch quality.rejection_reason {
        case UInt32(ATC_GRAY_QUALITY_ACCEPTED): rejection = nil
        case UInt32(ATC_GRAY_QUALITY_TOO_DARK), UInt32(ATC_GRAY_QUALITY_TOO_BRIGHT), UInt32(ATC_GRAY_QUALITY_SATURATED): rejection = .exposure
        case UInt32(ATC_GRAY_QUALITY_LOW_TEXTURE): rejection = .texture
        case UInt32(ATC_GRAY_QUALITY_BLURRED): rejection = .blur
        default: rejection = .unreadable
        }
        return ScanFrameQuality(rejection: rejection, sharpness: Double(quality.laplacian_variance),
            contrast: Double(quality.gray_standard_deviation), mean: Double(quality.mean_intensity), sampleCount: quality.sample_count)
    }

    var feedback: String {
        switch rejection {
        case .exposure: return "曝光不合适，调整朝向并避开强背光"
        case .texture: return "静态纹理不足，对准有细节的区域"
        case .blur: return "画面模糊，请放慢移动速度"
        case .unreadable: return "画面暂不可读，稍后重试"
        case nil: return "画面可用，缓慢移动并覆盖不同朝向"
        }
    }
}

struct ScanKeyframePolicy {
    private var lastTime: TimeInterval?
    private var lastTransform: simd_float4x4?

    func shouldCapture(at time: TimeInterval, transform: simd_float4x4) -> Bool {
        guard time.isFinite, time >= 0, time < Double(UInt64.max) / 1_000_000_000 else { return false }
        let current = rowMajor(transform)
        let previous = lastTransform.map(rowMajor)
        var shouldCapture: UInt32 = 0
        let previousTimestamp = UInt64((lastTime ?? 0) * 1_000_000_000)
        let status = current.withUnsafeBufferPointer { currentBuffer in
            if let previous {
                return previous.withUnsafeBufferPointer { previousBuffer in
                    atc_capture_candidate_v2(UInt64(time * 1_000_000_000), previousTimestamp,
                        previousBuffer.baseAddress, currentBuffer.baseAddress, &shouldCapture)
                }
            }
            return atc_capture_candidate_v2(UInt64(time * 1_000_000_000), previousTimestamp,
                nil, currentBuffer.baseAddress, &shouldCapture)
        }
        return status == ATC_OK && shouldCapture != 0
    }

    mutating func recordCapture(at time: TimeInterval, transform: simd_float4x4) {
        lastTime = time
        lastTransform = transform
    }

    mutating func reset() { self = ScanKeyframePolicy() }

    private func rowMajor(_ pose: simd_float4x4) -> [Float] {
        (0..<4).flatMap { row in (0..<4).map { column in pose[column][row] } }
    }
}
