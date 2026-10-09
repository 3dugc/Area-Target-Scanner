import Foundation
import simd
import AreaTargetNative

enum AreaTargetRecognitionMode: String, Codable {
    case standard, enhanced
    var nativeValue: Int32 { self == .enhanced ? 1 : 0 }
}
enum AreaTargetRecognitionModeError: LocalizedError {
    case unsupported, configurationFailed
    var errorDescription: String? {
        switch self {
        case .unsupported: return "当前定位引擎不支持增强识别，请关闭增强识别后重试。"
        case .configurationFailed: return "识别模式未能设置，本次定位已停止，请重新尝试。"
        }
    }
}

struct AreaTargetLocalizationResult { let cameraFromScan:simd_float4x4; let confidence:Float; let matchedFeatures:Int }
protocol AreaTargetOfflineLocalizing:AnyObject {
    func load(url:URL) async throws -> Int
    func configure(mode: AreaTargetRecognitionMode) async throws
    func localize(pixels:Data,width:Int,height:Int,intrinsics:SIMD4<Float>) async -> AreaTargetLocalizationResult?
    func close()
}
extension AreaTargetOfflineLocalizing {
    /// Existing engines support standard mode only unless they explicitly implement recovery.
    func configure(mode: AreaTargetRecognitionMode) async throws {
        guard mode == .standard else { throw AreaTargetRecognitionModeError.unsupported }
    }
}
enum AreaTargetPose {
    /// Native already converts CV axes to AR camera axes. Only the storage layout changes here.
    static func cameraFromScan(rowMajor: [Float]) -> simd_float4x4? {
        guard rowMajor.count == 16, rowMajor.allSatisfy({ $0.isFinite }) else { return nil }
        let matrix = simd_float4x4(columns: (
            SIMD4(rowMajor[0], rowMajor[4], rowMajor[8], rowMajor[12]),
            SIMD4(rowMajor[1], rowMajor[5], rowMajor[9], rowMajor[13]),
            SIMD4(rowMajor[2], rowMajor[6], rowMajor[10], rowMajor[14]),
            SIMD4(rowMajor[3], rowMajor[7], rowMajor[11], rowMajor[15])))
        guard abs(matrix.columns.0.w) < 0.0001, abs(matrix.columns.1.w) < 0.0001,
              abs(matrix.columns.2.w) < 0.0001, abs(matrix.columns.3.w - 1) < 0.0001 else { return nil }
        let rotation = simd_float3x3(columns: (SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
            SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
            SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)))
        let product = rotation.transpose * rotation
        for column in 0..<3 { for row in 0..<3 {
            guard abs(product[column][row] - (column == row ? 1 : 0)) <= 0.001 else { return nil }
        } }
        guard abs(simd_determinant(rotation) - 1) <= 0.001 else { return nil }
        return matrix
    }
}
struct AreaTargetNativeFrameResult { let state: Int; let pose: [Float]; let confidence: Float; let matchedFeatures: Int }
protocol AreaTargetNativeCalling: AnyObject {
    func create() -> UnsafeMutableRawPointer?
    func destroy(_ handle: UnsafeMutableRawPointer)
    func addVocabulary(_ handle: UnsafeMutableRawPointer, word: AreaTargetFeatureDatabase.VocabularyWord) -> Bool
    func addKeyframe(_ handle: UnsafeMutableRawPointer, keyframe: AreaTargetFeatureDatabase.Keyframe) -> Bool
    func addAKAZE(_ handle: UnsafeMutableRawPointer, keyframe: AreaTargetFeatureDatabase.Keyframe) -> Bool
    func buildIndex(_ handle: UnsafeMutableRawPointer) -> Bool
    func setRecoveryMode(_ handle: UnsafeMutableRawPointer, mode: AreaTargetRecognitionMode) -> Bool
    func process(_ handle: UnsafeMutableRawPointer, pixels: Data, width: Int, height: Int, intrinsics: SIMD4<Float>) -> AreaTargetNativeFrameResult
}
extension AreaTargetNativeCalling {
    func setRecoveryMode(_ handle: UnsafeMutableRawPointer, mode: AreaTargetRecognitionMode) -> Bool {
        mode == .standard
    }
}

/// Every native operation, including destruction, runs on one serial background queue.
/// Re-loading creates a fresh handle; a continuous run retains the native retrieval state.
final class AreaTargetOfflineLocalizer: AreaTargetOfflineLocalizing, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.areatarget.area-native", qos: .userInitiated)
    private let state: NativeState
    init() { state = NativeState(native: RealAreaTargetNative()) }
    init(native: AreaTargetNativeCalling) { state = NativeState(native: native) }

    func load(url: URL) async throws -> Int {
        let generation = state.advance()
        let ticket = NativeOperationTicket()
        let state = state
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    guard state.isCurrent(generation), !ticket.isCancelled else {
                        continuation.resume(throwing: CancellationError()); return
                    }
                    state.free()
                    do {
                        let database = try AreaTargetFeatureDatabase.load(url: url)
                        guard state.isCurrent(generation), !ticket.isCancelled else { throw CancellationError() }
                        guard let handle = state.native.create() else { throw AreaTargetOfflineError.nativeFailure }
                        state.handle = handle
                        guard state.native.setRecoveryMode(handle, mode: state.mode) else {
                            throw AreaTargetRecognitionModeError.configurationFailed
                        }
                        // Adding a keyframe computes its BoW immediately: vocabulary must come first.
                        for word in database.vocabulary {
                            guard state.isCurrent(generation), !ticket.isCancelled else { throw CancellationError() }
                            guard state.native.addVocabulary(handle, word: word) else { throw AreaTargetOfflineError.nativeFailure }
                        }
                        for keyframe in database.keyframes {
                            guard state.isCurrent(generation), !ticket.isCancelled else { throw CancellationError() }
                            guard state.native.addKeyframe(handle, keyframe: keyframe) else { throw AreaTargetOfflineError.nativeFailure }
                        }
                        for keyframe in database.keyframes where keyframe.akaze != nil {
                            guard state.isCurrent(generation), !ticket.isCancelled else { throw CancellationError() }
                            guard state.native.addAKAZE(handle, keyframe: keyframe) else { throw AreaTargetOfflineError.nativeFailure }
                        }
                        guard state.native.buildIndex(handle) else { throw AreaTargetOfflineError.nativeFailure }
                        guard state.isCurrent(generation), !ticket.isCancelled else { throw CancellationError() }
                        continuation.resume(returning: database.featureCount)
                    } catch {
                        state.free()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            ticket.cancel()
            Self.close(state, ifCurrent: generation)
        })
    }

    func configure(mode: AreaTargetRecognitionMode) async throws {
        let generation = state.current()
        let ticket = NativeOperationTicket()
        let state = state
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Self.queue.async {
                    guard state.isCurrent(generation), !ticket.isCancelled else {
                        continuation.resume(throwing: CancellationError()); return
                    }
                    if let handle = state.handle, !state.native.setRecoveryMode(handle, mode: mode) {
                        // A failed mode request must never leave a standard handle usable as enhanced.
                        state.free()
                        continuation.resume(throwing: AreaTargetRecognitionModeError.configurationFailed); return
                    }
                    state.mode = mode
                    continuation.resume()
                }
            }
        }, onCancel: { ticket.cancel(); Self.close(state, ifCurrent: generation) })
    }

    func localize(pixels: Data, width: Int, height: Int, intrinsics: SIMD4<Float>) async -> AreaTargetLocalizationResult? {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              pixels.count == width * height, intrinsics.x.isFinite, intrinsics.y.isFinite,
              intrinsics.z.isFinite, intrinsics.w.isFinite, intrinsics.x > 0, intrinsics.y > 0 else { return nil }
        let generation = state.current()
        let state = state
        let ticket = NativeOperationTicket()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                Self.queue.async {
                    guard state.isCurrent(generation), !ticket.isCancelled, let handle = state.handle else {
                        continuation.resume(returning: nil); return
                    }
                    let result = state.native.process(handle, pixels: pixels, width: width, height: height, intrinsics: intrinsics)
                    guard state.isCurrent(generation), !ticket.isCancelled,
                          result.state == 1, result.confidence.isFinite, (0...1).contains(result.confidence),
                          result.matchedFeatures >= 8, let pose = AreaTargetPose.cameraFromScan(rowMajor: result.pose) else {
                        continuation.resume(returning: nil); return
                    }
                    continuation.resume(returning: AreaTargetLocalizationResult(cameraFromScan: pose,
                        confidence: result.confidence, matchedFeatures: result.matchedFeatures))
                }
            }
        }, onCancel: { ticket.cancel() })
    }

    func close() { Self.close(state, ifCurrent: nil) }
    /// A barrier is useful when callers must finish resource release before starting a measured run.
    func waitUntilIdle() async { await withCheckedContinuation { continuation in Self.queue.async { continuation.resume() } } }
    private static func close(_ state: NativeState, ifCurrent expected: UInt64?) {
        guard let generation = state.invalidate(ifCurrent: expected) else { return }
        queue.async { if state.isCurrent(generation) { state.free() } }
    }
    deinit { Self.close(state, ifCurrent: nil) }
}

private final class NativeState: @unchecked Sendable {
    let native: AreaTargetNativeCalling
    var handle: UnsafeMutableRawPointer?
    var mode = AreaTargetRecognitionMode.standard
    private let lock = NSLock()
    private var generation: UInt64 = 0
    init(native: AreaTargetNativeCalling) { self.native = native }
    func current() -> UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    func advance() -> UInt64 { lock.lock(); defer { lock.unlock() }; generation &+= 1; return generation }
    func isCurrent(_ value: UInt64) -> Bool { current() == value }
    func invalidate(ifCurrent expected: UInt64?) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        if let expected, expected != generation { return nil }
        generation &+= 1
        return generation
    }
    func free() { if let handle { native.destroy(handle) }; handle = nil }
}
private final class NativeOperationTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

private final class RealAreaTargetNative: AreaTargetNativeCalling {
    func create() -> UnsafeMutableRawPointer? { vl_create() }
    func destroy(_ handle: UnsafeMutableRawPointer) { vl_destroy(handle) }
    func addVocabulary(_ handle: UnsafeMutableRawPointer, word: AreaTargetFeatureDatabase.VocabularyWord) -> Bool {
        word.descriptor.withUnsafeBytes { bytes in
            vl_add_vocabulary_word(handle, word.id, bytes.bindMemory(to: UInt8.self).baseAddress, 32, word.weight) == 1
        }
    }
    func addKeyframe(_ handle: UnsafeMutableRawPointer, keyframe: AreaTargetFeatureDatabase.Keyframe) -> Bool {
        keyframe.pose.withUnsafeBufferPointer { pose in
            keyframe.orb.descriptors.withUnsafeBytes { descriptors in
                keyframe.orb.points3D.withUnsafeBufferPointer { points3D in
                    keyframe.orb.points2D.withUnsafeBufferPointer { points2D in
                        vl_add_keyframe(handle, keyframe.id, pose.baseAddress, descriptors.bindMemory(to: UInt8.self).baseAddress,
                            Int32(keyframe.orb.count), points3D.baseAddress, points2D.baseAddress) == 1
                    }
                }
            }
        }
    }
    func addAKAZE(_ handle: UnsafeMutableRawPointer, keyframe: AreaTargetFeatureDatabase.Keyframe) -> Bool {
        guard let akaze = keyframe.akaze, akaze.count > 0 else { return false }
        return akaze.descriptors.withUnsafeBytes { descriptors in
            akaze.points3D.withUnsafeBufferPointer { points3D in
                akaze.points2D.withUnsafeBufferPointer { points2D in
                    vl_add_keyframe_akaze(handle, keyframe.id, descriptors.bindMemory(to: UInt8.self).baseAddress,
                        Int32(akaze.count), 61, points3D.baseAddress, points2D.baseAddress) == 1
                }
            }
        }
    }
    func buildIndex(_ handle: UnsafeMutableRawPointer) -> Bool { vl_build_index(handle) == 1 }
    func setRecoveryMode(_ handle: UnsafeMutableRawPointer, mode: AreaTargetRecognitionMode) -> Bool {
        vl_set_recovery_mode(handle, mode.nativeValue) == 1
    }
    func process(_ handle: UnsafeMutableRawPointer, pixels: Data, width: Int, height: Int, intrinsics: SIMD4<Float>) -> AreaTargetNativeFrameResult {
        var result = VLResult()
        pixels.withUnsafeBytes { bytes in
            // AR tracking transforms are deliberately excluded from native inference.
            vl_process_frame_out(handle, bytes.bindMemory(to: UInt8.self).baseAddress,
                Int32(width), Int32(height), intrinsics.x, intrinsics.y, intrinsics.z, intrinsics.w, 0, nil, &result)
        }
        let pose = withUnsafeBytes(of: result.pose) { Array($0.bindMemory(to: Float.self)) }
        return AreaTargetNativeFrameResult(state: Int(result.state), pose: pose,
            confidence: result.confidence, matchedFeatures: Int(result.matched_features))
    }
}
