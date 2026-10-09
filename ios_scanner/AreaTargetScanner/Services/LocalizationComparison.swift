import Foundation
import Combine
import CryptoKit
import simd
import UIKit
import Darwin

struct LocalizationQueryFrame {
    let sequence: Int
    let timestamp: Double
    let pixels: Data
    let width: Int
    let height: Int
    let intrinsics: SIMD4<Float>
    let worldFromCamera: simd_float4x4

    init(sequence: Int, timestamp: Double, pixels: Data, width: Int, height: Int,
         intrinsics: SIMD4<Float>, worldFromCamera: simd_float4x4) throws {
        guard sequence >= 0, timestamp.isFinite, timestamp >= 0,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 32_000_000, pixels.count == width * height,
              (0..<4).allSatisfy({ intrinsics[$0].isFinite }),
              intrinsics.x > 0, intrinsics.y > 0, intrinsics.z >= 0, intrinsics.w >= 0,
              intrinsics.z <= Float(width), intrinsics.w <= Float(height),
              Self.rigid(worldFromCamera) else { throw LocalizationComparisonError.invalidFrame }
        self.sequence = sequence; self.timestamp = timestamp; self.worldFromCamera = worldFromCamera
        let scale = min(1, 1920.0 / Double(max(width, height)))
        let outWidth = max(1, Int((Double(width) * scale).rounded()))
        let outHeight = max(1, Int((Double(height) * scale).rounded()))
        self.width = outWidth; self.height = outHeight
        let sx = Float(outWidth) / Float(width); let sy = Float(outHeight) / Float(height)
        self.intrinsics = SIMD4(intrinsics.x * sx, intrinsics.y * sy, intrinsics.z * sx, intrinsics.w * sy)
        if outWidth == width, outHeight == height { self.pixels = pixels }
        else {
            // One deterministic resize is frozen once and given unchanged to both engines.
            var resized = Data(count: outWidth * outHeight)
            pixels.withUnsafeBytes { source in
                resized.withUnsafeMutableBytes { destination in
                    let input = source.bindMemory(to: UInt8.self); let output = destination.bindMemory(to: UInt8.self)
                    for y in 0..<outHeight {
                        let yy = min(height - 1, y * height / outHeight)
                        for x in 0..<outWidth {
                            output[y * outWidth + x] = input[yy * width + min(width - 1, x * width / outWidth)]
                        }
                    }
                }
            }
            self.pixels = resized
        }
    }

    static func rigid(_ matrix: simd_float4x4) -> Bool {
        guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { matrix[c][$0].isFinite } }),
              abs(matrix[0][3]) < 0.0001, abs(matrix[1][3]) < 0.0001,
              abs(matrix[2][3]) < 0.0001, abs(matrix[3][3] - 1) < 0.0001 else { return false }
        let rotation = simd_float3x3(SIMD3(matrix.columns.0.x,matrix.columns.0.y,matrix.columns.0.z),
            SIMD3(matrix.columns.1.x,matrix.columns.1.y,matrix.columns.1.z),
            SIMD3(matrix.columns.2.x,matrix.columns.2.y,matrix.columns.2.z))
        let error = rotation.transpose * rotation - matrix_identity_float3x3
        return abs(simd_determinant(rotation) - 1) < 0.001 &&
            (0..<3).allSatisfy { c in (0..<3).allSatisfy { abs(error[c][$0]) < 0.001 } }
    }
}

struct LocalizationQueryRecorder {
    static let maximumFrames = 32
    static let maximumPixelBytes = 96 * 1024 * 1024
    private(set) var frames: [LocalizationQueryFrame] = []
    private(set) var pixelBytes = 0
    var isFull: Bool { frames.count >= Self.maximumFrames || pixelBytes >= Self.maximumPixelBytes }
    var duration: Double { (frames.last?.timestamp ?? 0) - (frames.first?.timestamp ?? 0) }
    @discardableResult
    mutating func append(_ frame: LocalizationQueryFrame, trackingNormal: Bool) -> Bool {
        guard trackingNormal, !isFull, pixelBytes + frame.pixels.count <= Self.maximumPixelBytes,
              frames.last.map({ frame.sequence > $0.sequence && frame.timestamp - $0.timestamp >= 1.5 }) ?? true else { return false }
        frames.append(frame); pixelBytes += frame.pixels.count
        return true
    }
}

enum LocalizationComparisonError: LocalizedError {
    case invalidFrame, sourceMismatch, empty, busy
    var errorDescription: String? {
        switch self {
        case .invalidFrame: return "测试帧无效，或超过本机采样限制，请重新测试。"
        case .sourceMismatch: return "两套地图的扫描来源无法核对。请用同一份原扫描重新上传并下载。"
        case .empty: return "尚未采集可用测试帧。"
        case .busy: return "本次对比尚未结束。"
        }
    }
}

@MainActor
protocol LocalizationReplayEngine: AnyObject {
    var identity: LocalizationAssetIdentity { get }
    /// Includes calibration (if needed) and a fresh engine reload before evaluation.
    func prepare() async throws -> Bool
    func localize(frame: LocalizationQueryFrame) async -> simd_float4x4?
    func close()
}

struct LocalizationSamplingPolicy: Codable, Equatable {
    var minimumIntervalSeconds = 1.5
    var maximumFrameCount = 32
    var maximumPixelBytes = 96 * 1024 * 1024
    var maximumLongEdgePixels = 1920
    var imageFormat = "dense-gray8"
    var resize = "nearest-neighbor-once-before-replay"
    var tracking = "normal-uninterrupted-arkit"
}

struct LocalizationReplayAttempt: Codable, Equatable {
    let provider: LocalizationProvider
    let sequence: Int
    let captureOffsetSeconds: Double
    let latencySeconds: Double
    /// A rigid pose returned by the engine; this is not a truth-verified match.
    let poseReturned: Bool
}

struct LocalizationBenchmarkRuntimeContext: Codable, Equatable {
    let deviceModel: String
    let systemVersion: String
    let appVersion: String
    let appBuild: String
    let thermalState: String

    @MainActor static func capture() -> Self {
        let states: [ProcessInfo.ThermalState: String] = [.nominal: "nominal", .fair: "fair", .serious: "serious", .critical: "critical"]
        var hardware = utsname()
        let model: String
        if uname(&hardware) == 0 {
            model = withUnsafePointer(to: &hardware.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        } else { model = UIDevice.current.model }
        return .init(deviceModel: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? model, systemVersion: UIDevice.current.systemVersion,
                     appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                     appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                     thermalState: states[ProcessInfo.processInfo.thermalState] ?? "unknown")
    }
}

struct LocalizationComparisonReport: Codable, Equatable, Identifiable {
    var schemaVersion = 1
    var attempts: [LocalizationReplayAttempt]? = nil
    var recording: LocalizationRecording? = nil
    var runtimeContext: LocalizationBenchmarkRuntimeContext? = nil
    var analysis: LocalizationBenchmarkAnalysis? = nil
    var samplingPolicy: LocalizationSamplingPolicy? = .init()
    var calibrationExcluded: Bool? = true
    var enginesReloadedBeforeReplay: Bool? = true
    let id: UUID
    let date: Date
    let queryFingerprint: String
    let sourceFingerprint: String
    let executionOrder: [LocalizationProvider]
    let results: [LocalizationEvaluationReport]
    /// A rebuilt map shares a scan fingerprint but is a different tested asset.
    func matches(identities: [LocalizationAssetIdentity]) -> Bool {
        schemaVersion == 1 && ScanSourceFingerprint.valid(sourceFingerprint) &&
            identities.map(\.provider) == [.areaTarget, .immersal] &&
            identities.allSatisfy { $0.sourceFingerprint == sourceFingerprint } &&
            executionOrder == identities.map(\.provider) && results.map(\.identity) == identities
    }
    var hasComparableScores: Bool {
        samplingPolicy == LocalizationSamplingPolicy() && calibrationExcluded == true && enginesReloadedBeforeReplay == true &&
            results.count == 2 && results.allSatisfy { $0.score != nil }
    }
}

@MainActor
final class LocalizationComparisonRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "准备录制共同测试帧"
    private var generation = UUID()
    private var activeEngines: [LocalizationReplayEngine] = []

    func cancel() {
        generation = UUID(); isRunning = false
        activeEngines.forEach { $0.close() }; activeEngines = []
        status = "已停止本次对比"
    }

    func run(frames: [LocalizationQueryFrame], engines: [LocalizationReplayEngine]) async throws -> LocalizationComparisonReport {
        guard !isRunning else { throw LocalizationComparisonError.busy }
        guard !frames.isEmpty else { throw LocalizationComparisonError.empty }
        var check = LocalizationQueryRecorder()
        guard frames.allSatisfy({ check.append($0, trackingNormal: true) }) else { throw LocalizationComparisonError.invalidFrame }
        guard engines.map({ $0.identity.provider }) == [.areaTarget, .immersal],
              let fingerprint = engines.first?.identity.sourceFingerprint, ScanSourceFingerprint.valid(fingerprint),
              engines.allSatisfy({ $0.identity.sourceFingerprint == fingerprint }) else { throw LocalizationComparisonError.sourceMismatch }
        let run = UUID(); generation = run; isRunning = true; progress = 0; activeEngines = engines
        defer {
            // cancel() already closed the abandoned generation. Its late completion
            // must not close adapter objects that a newer run has since reloaded.
            if generation == run {
                engines.forEach { $0.close() }
                isRunning = false; activeEngines = []
            }
        }
        func current() throws {
            try Task.checkCancellation()
            guard generation == run else { throw CancellationError() }
        }
        var reports: [LocalizationEvaluationReport] = []
        var attempts: [LocalizationReplayAttempt] = []
        let queryDigest = try LocalizationRecordingStore.inputDigest(frames: frames)
        for (engineIndex, engine) in engines.enumerated() {
            try current()
            status = "准备 \(engine.identity.provider == .areaTarget ? "Area Target" : "Immersal") · 校准后重新载入"
            let aligned = try await engine.prepare()
            try current()
            var accumulator = LocalizationEvaluationAccumulator(identity: engine.identity, timingMode: .recordedReplay)
            for (frameIndex, frame) in frames.enumerated() {
                try current()
                status = "\(engine.identity.provider == .areaTarget ? "Area Target" : "Immersal") 回放 \(frameIndex + 1)/\(frames.count)"
                let began = ProcessInfo.processInfo.systemUptime
                let cameraFromScan = await engine.localize(frame: frame)
                let latency = max(0, ProcessInfo.processInfo.systemUptime - began)
                try current()
                let worldFromScan = cameraFromScan.flatMap { LocalizationQueryFrame.rigid($0) ? frame.worldFromCamera * $0 : nil }.flatMap { LocalizationEvaluationAccumulator.isRigid($0) ? $0 : nil }
                attempts.append(.init(provider: engine.identity.provider, sequence: frame.sequence,
                    captureOffsetSeconds: frame.timestamp - frames[0].timestamp, latencySeconds: latency, poseReturned: worldFromScan != nil))
                let camera = frame.worldFromCamera.columns.3
                accumulator.record(sequence: frame.sequence, captureTime: frame.timestamp, latency: latency,
                    cameraPosition: SIMD3(camera.x,camera.y,camera.z), worldFromScan: worldFromScan, commonAlignmentValid: aligned)
                progress = Double(engineIndex * frames.count + frameIndex + 1) / Double(engines.count * frames.count)
            }
            reports.append(accumulator.report())
            engine.close()
        }
        try current()
        status = "同帧对比已完成"
        return LocalizationComparisonReport(attempts: attempts, id: run, date: Date(), queryFingerprint: queryDigest,
            sourceFingerprint: fingerprint, executionOrder: engines.map { $0.identity.provider }, results: reports)
    }

}
