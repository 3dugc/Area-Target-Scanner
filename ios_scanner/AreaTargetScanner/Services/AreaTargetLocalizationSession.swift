import ARKit
import AVFoundation
import Combine
import SceneKit
import simd

@MainActor
final class AreaTargetLocalizationSession: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    static let engineVersion = "area-target-core-2/recovery-3/final-geometry-1/opencv-5.0.0/no-ar-prior"
    let session = ARSession()
    @Published private(set) var report: LocalizationEvaluationReport?
    @Published private(set) var isRunning = false
    @Published private(set) var isLoading = false
    @Published private(set) var recognitionMode = AreaTargetRecognitionMode.standard
    @Published private(set) var status = "准备现场定位测试"
    @Published private(set) var pointCount: Int?
    @Published private(set) var worldFromScan: simd_float4x4?
    @Published private(set) var alignmentState = LocalizationAlignmentPolicy.State.searching
    @Published private(set) var markerInScan: SIMD3<Float>?
    @Published private(set) var scanMesh: SCNNode?
    @Published private(set) var meshStatus = "未加载原扫描网格"
    private let engine: AreaTargetOfflineLocalizing
    private let requestCamera: () async -> Bool
    private let runSession: (ARSession) -> Void
    private let meshPreparation: AreaTargetMeshPreparation
    private let now: () -> Double
    private var alignmentPolicy = LocalizationAlignmentPolicy()
    private var generation = UUID()
    private var loadingTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var localizing = false
    private var lastAttempt = -Double.infinity
    private var lastSequence = -1
    private var nextSequence = 0
    private var hasTracked = false
    private var accumulator: LocalizationEvaluationAccumulator?

    init(engine: AreaTargetOfflineLocalizing = AreaTargetOfflineLocalizer(),
         requestCamera: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .video) },
         runSession: @escaping (ARSession) -> Void = { session in
             session.run(ARWorldTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
         },
         meshLoader: @escaping (URL) throws -> SCNNode = { try ImmersalScanMeshLoader.load(scanDirectory: $0) },
         sourceFingerprint: @escaping (URL) throws -> String = { try ScanSourceFingerprint.compute(directory: $0) },
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.engine = engine; self.requestCamera = requestCamera; self.runSession = runSession
        self.now = now
        meshPreparation = AreaTargetMeshPreparation(loader: meshLoader, fingerprint: sourceFingerprint)
        super.init()
        session.delegate = self; session.delegateQueue = .main
    }

    func start(asset: AreaTargetSavedAsset, sourceFingerprint: String?, scanDirectory: URL? = nil,
               assetDigest: String? = nil, buildConfiguration: String? = nil,
               recognitionMode: AreaTargetRecognitionMode = .standard) {
        guard !isLoading, !isRunning else { return }
        let run = UUID(); generation = run
        self.recognitionMode = recognitionMode
        let verifiedSource = ScanSourceFingerprint.valid(sourceFingerprint) ? sourceFingerprint : nil
        accumulator = LocalizationEvaluationAccumulator(identity: LocalizationAssetIdentity(
            provider: .areaTarget, assetID: asset.jobID, sourceFingerprint: verifiedSource,
            engineVersion: Self.engineVersion, assetDigest: assetDigest,
            buildConfiguration: LocalizationCoreMetadata.liveBuildConfiguration(base: buildConfiguration),
            areaTargetRecognitionMode: recognitionMode))
        report = nil; pointCount = nil; worldFromScan = nil; markerInScan = nil; scanMesh = nil
        alignmentPolicy.reset(); alignmentState = .searching
        localizing = false; lastAttempt = -.infinity; lastSequence = -1; nextSequence = 0; hasTracked = false
        isLoading = true; status = "正在准备本机定位引擎…"
        meshStatus = "未找到可核对的原扫描网格，仅显示测试标记"
        loadingTask = Task { [weak self] in
            guard let self else { return }
            let allowed = await self.requestCamera()
            guard self.generation == run, !Task.isCancelled else { return }
            guard allowed else {
                self.isLoading = false; self.status = "请在系统设置中允许相机访问后重试。"; return
            }
            do {
                let count = try await self.engine.load(url: asset.featuresURL)
                guard self.generation == run, !Task.isCancelled else { return }
                try await self.engine.configure(mode: recognitionMode)
                guard self.generation == run, !Task.isCancelled else { return }
                self.pointCount = count
                if let scanDirectory, let verifiedSource {
                    self.status = "正在核对原扫描网格…"
                    let prepared = await self.meshPreparation.prepare(directory: scanDirectory, expected: verifiedSource)
                    guard self.generation == run, !Task.isCancelled else { return }
                    self.scanMesh = prepared.mesh; self.meshStatus = prepared.status
                } else if scanDirectory != nil {
                    self.meshStatus = "此资产没有已记录的原扫描来源，仅显示测试标记；仍可离线定位。"
                }
                guard self.generation == run, !Task.isCancelled else { return }
                self.isLoading = false; self.isRunning = true
                self.status = "缓慢移动手机，等待相机追踪就绪"
                self.runSession(self.session)
            } catch {
                guard self.generation == run else { return }
                self.engine.close()
                self.isLoading = false
                self.status = (error as? AreaTargetRecognitionModeError)?.errorDescription ??
                    (error as? AreaTargetOfflineError)?.errorDescription ?? "离线定位数据无法载入，请重新下载或重新尝试。"
            }
        }
    }

    func stop(message: String = "本段测试已结束") {
        generation = UUID()
        loadingTask?.cancel(); loadingTask = nil; frameTask?.cancel(); frameTask = nil
        isRunning = false; isLoading = false; localizing = false
        session.pause(); engine.close()
        alignmentPolicy.reset(); alignmentState = .searching
        worldFromScan = nil; markerInScan = nil; scanMesh = nil
        meshStatus = "下次测试将重新核对原扫描网格"
        status = message
    }

    /// The same immutable image and capture transform reach evaluation. The native
    /// call receives pixels and intrinsics only, never the AR tracking transform.
    func process(_ frame: LocalizationQueryFrame) async {
        guard isRunning else { return }
        checkAlignmentExpiry()
        guard isRunning, !localizing, frame.sequence > lastSequence,
              frame.timestamp - lastAttempt >= 1.5 else { return }
        let run = generation
        lastAttempt = frame.timestamp; lastSequence = frame.sequence; localizing = true
        let began = now()
        status = "正在本机识别空间…"
        let result = await engine.localize(pixels: frame.pixels, width: frame.width,
            height: frame.height, intrinsics: frame.intrinsics)
        guard generation == run, isRunning, !Task.isCancelled else { return }
        localizing = false
        let alignment = result.map { frame.worldFromCamera * $0.cameraFromScan }
        let camera = frame.worldFromCamera.columns.3
        let arrived = now()
        guard accumulator?.record(sequence: frame.sequence, captureTime: frame.timestamp,
            latency: max(0, arrived - began),
            cameraPosition: SIMD3(camera.x, camera.y, camera.z), worldFromScan: alignment,
            commonAlignmentValid: true) == true else { return }
        report = accumulator?.report()
        // Count the actual native result above; confirmation and short ARKit-only
        // holding below never manufacture another visual success.
        alignmentPolicy.observe(cameraFromScan: result?.cameraFromScan, worldFromCamera: frame.worldFromCamera,
            sequence: frame.sequence, captureTime: frame.timestamp, now: arrived,
            confidence: result?.confidence ?? 0, matchedFeatures: result?.matchedFeatures ?? 0)
        worldFromScan = alignmentPolicy.alignment; alignmentState = alignmentPolicy.state
        if let displayed = worldFromScan, alignmentState == .confirmed {
            if markerInScan == nil {
                let target = displayed.inverse * frame.worldFromCamera * SIMD4<Float>(0, 0, -1.5, 1)
                markerInScan = SIMD3(target.x, target.y, target.z)
            }
        }
        updateAlignmentStatus()
    }

    func checkAlignmentExpiry() {
        let previous = alignmentPolicy.state
        alignmentPolicy.tick(now: now())
        worldFromScan = alignmentPolicy.alignment; alignmentState = alignmentPolicy.state
        if previous != alignmentState { updateAlignmentStatus() }
    }

    private func updateAlignmentStatus() {
        switch alignmentState {
        case .searching: status = "缓慢移动手机，等待相机追踪就绪"
        case .candidate: status = "找到定位候选 · 保持清晰视角，等待再次确认"
        case .confirmed: status = scanMesh == nil ? "已识别此空间 · 观察标记是否稳定" : "已识别此空间 · 对照网格与真实边缘"
        case .degraded: status = "本帧视觉定位未确认 · 暂时保持原位置，正在重新识别"
        case .lost: status = "定位已过期或未匹配 · 换个角度对准扫描过的区域"
        }
    }

    func trackingChanged(isNormal: Bool) {
        guard isRunning else { return }
        if isNormal { hasTracked = true }
        else if hasTracked { stop(message: "相机追踪中断，本段测试已结束。回到清晰区域后重新开始。") }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRunning else { return }
        checkAlignmentExpiry()
        guard case .normal = frame.camera.trackingState else { trackingChanged(isNormal: false); return }
        trackingChanged(isNormal: true)
        guard !localizing, frame.timestamp - lastAttempt >= 1.5 else { return }
        let buffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { return }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let pixels: Data?
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            pixels = try? ImmersalImagePacking.copyRows(base: base, width: width, height: height,
                bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
        } else { pixels = nil }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        guard let pixels else { return }
        let k = frame.camera.intrinsics
        guard let query = try? LocalizationQueryFrame(sequence: nextSequence, timestamp: frame.timestamp,
            pixels: pixels, width: width, height: height, intrinsics: SIMD4(k[0][0], k[1][1], k[2][0], k[2][1]),
            worldFromCamera: frame.camera.transform) else { return }
        nextSequence += 1
        frameTask = Task { [weak self] in await self?.process(query) }
    }

    func sessionWasInterrupted(_ session: ARSession) { stop(message: "相机被中断，本段测试已结束。") }
    func session(_ session: ARSession, didFailWithError error: Error) { stop(message: "相机暂不可用，请重新开始测试。") }
}

private struct AreaTargetPreparedMesh: @unchecked Sendable {
    let mesh: SCNNode?
    let status: String
}

private final class AreaTargetMeshPreparation: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.areatarget.localization-mesh", qos: .userInitiated)
    private let loader: (URL) throws -> SCNNode
    private let fingerprint: (URL) throws -> String
    init(loader: @escaping (URL) throws -> SCNNode, fingerprint: @escaping (URL) throws -> String) {
        self.loader = loader; self.fingerprint = fingerprint
    }
    func prepare(directory: URL, expected: String) async -> AreaTargetPreparedMesh {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                do {
                    guard try self.fingerprint(directory) == expected else {
                        continuation.resume(returning: AreaTargetPreparedMesh(mesh: nil,
                            status: "当前原扫描与此资产来源不一致，仅显示测试标记；仍可离线定位。")); return
                    }
                    let mesh = try self.loader(directory)
                    continuation.resume(returning: AreaTargetPreparedMesh(mesh: mesh, status: "原扫描来源已核对 · 网格可叠加"))
                } catch {
                    continuation.resume(returning: AreaTargetPreparedMesh(mesh: nil,
                        status: "原扫描网格暂不可用，仅显示测试标记；仍可离线定位。"))
                }
            }
        }
    }
}
