import Foundation
import simd
import AreaTargetNative

/// Thin, serial C ABI owner. Confirmation, gating, smoothing, expiry and state
/// all come from the shared C++ Session used by every platform.
final class LocalizationAlignmentPolicy {
    enum State: String { case searching, candidate, confirmed, degraded, lost }

    struct Configuration {
        fileprivate var core: ATCSessionConfigV2
        init() {
            var value = ATCSessionConfigV2()
            value.struct_size = UInt32(MemoryLayout<ATCSessionConfigV2>.size)
            value.api_version = atc_get_api_version()
            _ = atc_get_default_session_config_v2(&value)
            core = value
        }
    }

    private var handle: UnsafeMutableRawPointer?
    private var generation: UInt64 = 1
    private var trackingEpoch: UInt64 = 1
    private(set) var state = State.searching
    private(set) var alignment: simd_float4x4?
    private(set) var lastStatus: Int32 = 0

    init(configuration: Configuration = .init()) {
        var config = configuration.core
        lastStatus = atc_session_create(&config, &handle)
        if handle != nil { reset() }
    }

    deinit { atc_session_destroy(&handle) }

    func reset() {
        generation &+= 1; trackingEpoch &+= 1
        guard let handle else { alignment = nil; state = .lost; return }
        lastStatus = atc_session_reset(handle, generation, trackingEpoch)
        var result = makeResult()
        _ = atc_session_poll(handle, 0, &result)
        publish(result)
    }

    /// Polling does not submit a visual frame or advance its sequence number.
    func tick(now: Double) {
        guard let handle else { alignment = nil; state = .lost; return }
        guard let delivery = Self.nanoseconds(now) else { reset(); return }
        var result = makeResult()
        lastStatus = atc_session_poll(handle, delivery, &result)
        publish(result)
    }

    /// Identity-camera convenience used by the pure bridge contract tests.
    @discardableResult
    func observe(worldFromMap pose: simd_float4x4?, sequence: Int, captureTime: Double, now: Double) -> Bool {
        observe(cameraFromScan: pose, worldFromCamera: matrix_identity_float4x4,
            sequence: sequence, captureTime: captureTime, now: now)
    }

    /// Legacy native and SDK adapters expose AR-camera axes. Convert at the v2
    /// optical boundary once; the C++ Session performs W_C * C_S itself.
    @discardableResult
    func observe(cameraFromScan pose: simd_float4x4?, worldFromCamera: simd_float4x4,
                 sequence: Int, captureTime: Double, now: Double,
                 confidence: Float = 0, matchedFeatures: Int = 0) -> Bool {
        guard let handle else { alignment = nil; state = .lost; return false }
        guard sequence >= 0, let capture = Self.nanoseconds(captureTime), let delivery = Self.nanoseconds(now) else {
            reset(); return false
        }
        var raw = ATCResultV2()
        raw.struct_size = UInt32(MemoryLayout<ATCResultV2>.size)
        raw.api_version = atc_get_api_version()
        raw.status = pose == nil ? Int32(ATC_NO_MATCH) : Int32(ATC_OK)
        raw.raw_pose_valid = pose == nil ? 0 : 1
        raw.frame_id = UInt64(sequence); raw.capture_timestamp_ns = capture
        raw.map_generation = generation; raw.capture_clock_epoch = trackingEpoch
        raw.camera_id = 1; raw.map_instance_id = generation
        raw.confidence = confidence
        raw.inliers = UInt32(clamping: matchedFeatures)
        if let pose { Self.write(Self.opticalFromARCamera * pose, into: &raw.camera_from_scan) }

        var tracking = ATCTrackingSampleV2()
        tracking.struct_size = UInt32(MemoryLayout<ATCTrackingSampleV2>.size)
        tracking.api_version = atc_get_api_version()
        tracking.frame_id = raw.frame_id; tracking.capture_timestamp_ns = capture
        tracking.map_generation = generation; tracking.capture_clock_epoch = trackingEpoch
        tracking.camera_id = raw.camera_id; tracking.tracking_epoch = trackingEpoch
        tracking.pose_timestamp_ns = capture
        tracking.clock_mapping_valid = 1; tracking.pose_valid = 1; tracking.extrinsics_valid = 1
        tracking.tracking_quality = UInt32(ATC_TRACKING_QUALITY_NORMAL)
        Self.write(worldFromCamera * Self.opticalFromARCamera, into: &tracking.world_from_camera)
        var result = makeResult()
        lastStatus = atc_session_update_at(handle, &raw, &tracking, delivery, &result)
        publish(result)
        return lastStatus >= 0 && result.rejection_reason == UInt32(ATC_REJECTION_NONE)
    }

    private func makeResult() -> ATCSessionResultV2 {
        var result = ATCSessionResultV2()
        result.struct_size = UInt32(MemoryLayout<ATCSessionResultV2>.size)
        result.api_version = atc_get_api_version()
        return result
    }

    private func publish(_ result: ATCSessionResultV2) {
        switch Int(result.state) {
        case ATC_SESSION_CANDIDATE: state = .candidate
        case ATC_SESSION_TRACKING: state = .confirmed
        case ATC_SESSION_DEGRADED: state = .degraded
        case ATC_SESSION_LOST: state = .lost
        default: state = .searching
        }
        var result = result
        alignment = result.alignment_valid == 1 ? Self.read(&result.world_from_scan) : nil
    }

    private static let opticalFromARCamera = simd_float4x4(diagonal: SIMD4(1, -1, -1, 1))

    private static func nanoseconds(_ seconds: Double) -> UInt64? {
        let scaled = seconds * 1_000_000_000
        guard scaled.isFinite, scaled >= 0, scaled < Double(UInt64.max) else { return nil }
        return UInt64(scaled)
    }

    private static func write<T>(_ matrix: simd_float4x4, into storage: inout T) {
        withUnsafeMutableBytes(of: &storage) { buffer in
            let values = buffer.bindMemory(to: Float.self)
            for row in 0..<4 { for column in 0..<4 { values[row * 4 + column] = matrix[column][row] } }
        }
    }

    private static func read<T>(_ storage: inout T) -> simd_float4x4 {
        withUnsafeBytes(of: &storage) { buffer in
            let values = buffer.bindMemory(to: Float.self)
            return simd_float4x4(columns: (
                SIMD4(values[0], values[4], values[8], values[12]),
                SIMD4(values[1], values[5], values[9], values[13]),
                SIMD4(values[2], values[6], values[10], values[14]),
                SIMD4(values[3], values[7], values[11], values[15])))
        }
    }
}
