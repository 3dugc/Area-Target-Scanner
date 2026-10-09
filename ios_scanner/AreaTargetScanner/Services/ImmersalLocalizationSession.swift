import ARKit
import AVFoundation
import Combine
import SceneKit
import simd

@MainActor
final class ImmersalLocalizationSession: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    static let engineVersion = "immersal-sdk-2.4.0/sha256:45fad535dcbf0139feb9b15dafe74c8315436db21a138271924e10e56d2fca8f/no-ar-prior"
    let session = ARSession()
    @Published private(set) var isRunning = false
    @Published private(set) var isLoading = false
    @Published private(set) var status = "准备在原扫描空间开始测试"
    @Published private(set) var report: ImmersalLocalizationQualityReport?
    @Published private(set) var evaluationReport: LocalizationEvaluationReport?
    @Published private(set) var pointCount: Int?
    @Published private(set) var worldFromMap: simd_float4x4?
    @Published private(set) var alignmentState = LocalizationAlignmentPolicy.State.searching
    @Published private(set) var markerInMap: SIMD3<Float>?
    @Published private(set) var confidence: Int?
    @Published private(set) var scanMesh: SCNNode?
    @Published private(set) var mapFromScan: simd_float4x4?
    @Published private(set) var meshStatus = "开始测试后将核对原扫描模型"
    private let engine: ImmersalOfflineLocalizing
    private let requestCamera: () async -> Bool
    private let runSession: (ARSession) -> Void
    private let now: () -> Double
    private var alignmentPolicy = LocalizationAlignmentPolicy()
    private var generation = UUID()
    private var localizing = false
    private var lastAttempt = -Double.infinity
    private var lastSequence = -1
    private var hasTracked = false
    private var accumulator = ImmersalLocalizationQualityAccumulator()
    private var mapID = 0
    private var userID = 0
    private var evaluation: LocalizationEvaluationAccumulator?
    private var evaluationSequence = 0
    private var frozenSource: String?
    private var commonSourceVerified = false
    private var calibrationUsedEngine = false

    init(engine: ImmersalOfflineLocalizing = ImmersalOfflineLocalizer(),
         requestCamera: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .video) },
         runSession: @escaping (ARSession) -> Void = {
             $0.run(ARWorldTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
         }, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.engine = engine; self.requestCamera = requestCamera; self.runSession = runSession
        self.now = now
        super.init()
        session.delegate = self
        session.delegateQueue = .main
    }

    func start(url: URL, mapID: Int, userID: Int, scanDirectory: URL? = nil,
               sourceFingerprint: String? = nil, assetDigest: String? = nil, buildConfiguration: String? = nil) {
        guard !isLoading, !isRunning else { return }
        let run = UUID(); generation = run
        self.mapID = mapID; self.userID = userID
        frozenSource = ScanSourceFingerprint.valid(sourceFingerprint) ? sourceFingerprint : nil
        commonSourceVerified = false; calibrationUsedEngine = false; evaluationSequence = 0; evaluationReport = nil
        evaluation = LocalizationEvaluationAccumulator(identity: .init(provider: .immersal, assetID: "\(userID)/\(mapID)",
            sourceFingerprint: frozenSource, engineVersion: Self.engineVersion, assetDigest: assetDigest,
            buildConfiguration: LocalizationCoreMetadata.immersalLiveBuildConfiguration(base: buildConfiguration)))
        isLoading = true; status = "正在载入本机地图…"
        report = nil; worldFromMap = nil; markerInMap = nil; confidence = nil
        alignmentPolicy.reset(); alignmentState = .searching
        scanMesh = nil; mapFromScan = nil
        meshStatus = scanDirectory == nil ? "未找到原扫描模型，仅显示测试标记" : "正在准备原扫描网格…"
        accumulator = ImmersalLocalizationQualityAccumulator()
        hasTracked = false; lastAttempt = -.infinity; lastSequence = -1; localizing = false
        Task { [weak self] in
            guard let self else { return }
            let allowed = await self.requestCamera()
            guard self.generation == run else { return }
            guard allowed else {
                self.isLoading = false; self.status = "请在系统设置中允许相机访问后重试。"; return
            }
            do {
                let count = try await self.engine.load(url: url)
                guard self.generation == run else { return }
                self.pointCount = count
                if let scanDirectory { await self.prepareMesh(scanDirectory: scanDirectory, run: run) }
                guard self.generation == run else { return }
                if self.calibrationUsedEngine {
                    self.status = "校准完成，正在重新载入现场测试引擎…"
                    _ = try await self.engine.load(url: url)
                    guard self.generation == run else { return }
                }
                self.isLoading = false; self.isRunning = true
                self.status = "缓慢移动手机，等待相机追踪就绪"
                self.runSession(self.session)
            } catch {
                guard self.generation == run else { return }
                self.isLoading = false; self.status = error.localizedDescription
            }
        }
    }

    func stop(message: String = "本段测试已结束") {
        if scanMesh != nil { meshStatus = "下次测试将重新核对原扫描模型" }
        else if isLoading { meshStatus = "已停止准备模型，重新测试时会再次核对" }
        generation = UUID()
        isRunning = false; isLoading = false; localizing = false
        session.pause(); engine.close(); status = message
        alignmentPolicy.reset(); alignmentState = .searching; confidence = nil; markerInMap = nil
        worldFromMap = nil; mapFromScan = nil; scanMesh = nil
    }

    private func prepareMesh(scanDirectory: URL, run: UUID) async {
        do {
            status = "正在读取原扫描网格…"
            if let expected = frozenSource {
                let actual = try await Task.detached(priority: .utility) { try ScanSourceFingerprint.compute(directory: scanDirectory) }.value
                guard generation == run else { return }
                guard actual == expected else { throw ScanSourceFingerprint.Failure.changed }
                commonSourceVerified = true
            }
            let prepared = try await ImmersalMeshOverlayPreparation.prepare(scanDirectory: scanDirectory)
            guard generation == run else { return }
            var candidates: [simd_float4x4] = []
            for (index, frame) in prepared.frames.enumerated() {
                guard generation == run else { return }
                status = "正在核对模型坐标（\(index + 1)/\(prepared.frames.count)）…"
                meshStatus = "用原扫描照片核对模型位置，不计入现场测试"
                let pixels = try await ImmersalMeshOverlayPreparation.pixels(for: frame)
                guard generation == run else { return }
                calibrationUsedEngine = true
                let result = await engine.localize(pixels: pixels, width: frame.width, height: frame.height, intrinsics: frame.intrinsics)
                guard generation == run else { return }
                if let result, let candidate = ImmersalMeshAlignment.candidate(scanFromCamera: frame.scanFromCamera,
                    mapPosition: result.position, mapRotation: result.rotation) {
                    candidates.append(candidate)
                }
            }
            let alignment = try ImmersalMeshAlignment.estimate(candidates)
            guard generation == run else { return }
            scanMesh = prepared.mesh; mapFromScan = alignment.mapFromScan
            meshStatus = "原扫描网格已就绪 · \(alignment.inlierCount) 张照片核对一致"
        } catch {
            guard generation == run else { return }
            scanMesh = nil; mapFromScan = nil
            meshStatus = "网格暂不能叠加：\(error.localizedDescription) 仍可进行定位测试。"
        }
    }

    /// The image, intrinsics and AR camera transform remain bound to exposure.
    /// The shared policy only controls display; SDK successes are recorded raw.
    func process(_ frozen: LocalizationQueryFrame) async {
        guard isRunning else { return }
        checkAlignmentExpiry()
        guard !localizing, frozen.sequence > lastSequence, frozen.timestamp - lastAttempt >= 1.5 else { return }
        let camera = frozen.worldFromCamera; let intrinsics = frozen.intrinsics
        let run = generation
        lastAttempt = frozen.timestamp; lastSequence = frozen.sequence; localizing = true
        let began = now()
        status = "正在本机识别空间…"
        let result = await engine.localize(pixels: frozen.pixels, width: frozen.width, height: frozen.height, intrinsics: intrinsics)
        guard generation == run, isRunning, !Task.isCancelled else { return }
        localizing = false
        let cameraFromMap = result.flatMap { ImmersalPose.worldFromMap(position: $0.position, rotation: $0.rotation,
            worldFromCamera: matrix_identity_float4x4) }
        let alignment = cameraFromMap.map { camera * $0 }
        let position = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let arrived = now(); let latency = max(0, arrived - began)
        accumulator.record(success: alignment != nil, elapsed: began,
            latency: latency, worldFromMap: alignment, cameraPosition: position)
        report = accumulator.report(mapID: mapID, userID: userID)
        let worldFromScan = alignment.map { $0 * (mapFromScan ?? matrix_identity_float4x4) }
        evaluation?.record(sequence: frozen.sequence, captureTime: frozen.timestamp,
            latency: latency, cameraPosition: position,
            worldFromScan: worldFromScan, commonAlignmentValid: commonSourceVerified && mapFromScan != nil)
        evaluationReport = evaluation?.report()
        let accepted = alignmentPolicy.observe(cameraFromScan: cameraFromMap, worldFromCamera: camera,
            sequence: frozen.sequence, captureTime: frozen.timestamp, now: arrived)
        worldFromMap = alignmentPolicy.alignment; alignmentState = alignmentPolicy.state
        confidence = accepted && alignmentState == .confirmed ? result?.confidence : nil
        if let displayed = worldFromMap, alignmentState == .confirmed, markerInMap == nil {
            let target = displayed.inverse * camera * SIMD4<Float>(0, 0, -1.5, 1)
            markerInMap = SIMD3(target.x, target.y, target.z)
        }
        updateAlignmentStatus()
    }

    func checkAlignmentExpiry() {
        let previous = alignmentPolicy.state
        alignmentPolicy.tick(now: now())
        worldFromMap = alignmentPolicy.alignment; alignmentState = alignmentPolicy.state
        if alignmentState != .confirmed { confidence = nil }
        if previous != alignmentState { updateAlignmentStatus() }
    }

    private func updateAlignmentStatus() {
        switch alignmentState {
        case .searching: status = "缓慢移动手机，等待相机追踪就绪"
        case .candidate: status = "找到定位候选 · 保持清晰视角，等待再次确认"
        case .confirmed: status = mapFromScan == nil ? "已识别此空间 · 观察标记是否稳定" : "已识别此空间 · 对照网格与真实边缘"
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
        guard let frozen = try? LocalizationQueryFrame.capture(frame, sequence: evaluationSequence) else { return }
        evaluationSequence += 1
        Task { [weak self] in await self?.process(frozen) }
    }

    func sessionWasInterrupted(_ session: ARSession) { stop(message: "相机被中断，本段测试已结束。") }
    func session(_ session: ARSession, didFailWithError error: Error) { stop(message: "相机暂不可用，请重新开始测试。") }
}
