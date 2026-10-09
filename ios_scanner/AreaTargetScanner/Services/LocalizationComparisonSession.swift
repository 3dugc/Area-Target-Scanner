import ARKit
import AVFoundation
import Combine

@MainActor
final class LocalizationComparisonSession: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    enum Stage: Equatable { case idle, preparing, capturing, replaying, finished }
    let session = ARSession()
    let runner = LocalizationComparisonRunner()
    @Published private(set) var stage = Stage.idle
    @Published private(set) var status = "回到原扫描空间，录制一段新的共同测试帧"
    @Published private(set) var frameCount = 0
    @Published private(set) var duration = 0.0
    @Published private(set) var replayProgress = 0.0
    @Published private(set) var report: LocalizationComparisonReport?
    @Published private(set) var reportURL: URL?
    private var recorder = LocalizationQueryRecorder()
    private var generation = UUID()
    private var hasTracked = false
    private var worker: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var engines: [LocalizationReplayEngine] = []
    private let requestCamera: () async -> Bool
    private let runSession: (ARSession) -> Void
    private let store: LocalizationReportStore
    var active: Bool { [.preparing, .capturing, .replaying].contains(stage) }

    init(requestCamera: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .video) },
         runSession: @escaping (ARSession) -> Void = { $0.run(ARWorldTrackingConfiguration(), options: [.resetTracking,.removeExistingAnchors]) },
         store: LocalizationReportStore = LocalizationReportStore()) {
        self.requestCamera = requestCamera; self.runSession = runSession; self.store = store
        super.init(); session.delegate = self; session.delegateQueue = .main
        runner.$progress.sink { [weak self] in self?.replayProgress = $0 }.store(in: &subscriptions)
        runner.$status.sink { [weak self] in
            guard let self, self.stage == .replaying else { return }; self.status = $0
        }.store(in: &subscriptions)
    }
    func start(engines: [LocalizationReplayEngine]) {
        guard !active else { return }
        guard engines.map({ $0.identity.provider }) == [.areaTarget, .immersal], let source = engines.first?.identity.sourceFingerprint,
              ScanSourceFingerprint.valid(source), engines.allSatisfy({ $0.identity.sourceFingerprint == source }) else {
            status = LocalizationComparisonError.sourceMismatch.localizedDescription; return
        }
        self.engines = engines; recorder = .init(); frameCount = 0; duration = 0; replayProgress = 0
        hasTracked = false; report = nil; reportURL = nil
        let run = UUID(); generation = run; stage = .preparing; status = "正在准备相机…"
        worker = Task { [weak self] in
            guard let self else { return }
            let allowed = await requestCamera()
            guard generation == run else { return }
            guard allowed else { stage = .idle; status = "请在系统设置中允许相机访问后重试。"; return }
            stage = .capturing; status = "等待正常追踪；缓慢走动至少 3 米，录制 30–45 秒"
            runSession(session)
        }
    }
    func finishCapture() {
        guard stage == .capturing else { return }
        session.pause()
        guard !recorder.frames.isEmpty else { cancel(message: "尚未采集到可用帧，请重新开始。"); return }
        let frames = recorder.frames; recorder = .init()
        let run = generation; let batchEngines = engines
        stage = .replaying; status = "正在准备两套本机引擎…"
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let measured = try await runner.run(frames: frames, engines: batchEngines)
                guard generation == run, !Task.isCancelled else { return }
                report = measured
                let storage = store
                do {
                    let url = try await Task.detached(priority: .utility) { try storage.save(comparison: measured) }.value
                    guard generation == run else { return }
                    reportURL = url; status = "共同测试帧已回放，报告已保存"
                } catch {
                    guard generation == run else { return }
                    status = "对比完成，但报告未保存：\(error.localizedDescription)"
                }
                stage = .finished; engines = []
            } catch {
                guard generation == run else { return }
                stage = .idle; status = error.localizedDescription; engines = []
            }
        }
    }
    func cancel(message: String = "已停止本次对比，重新开始时会录制新帧") {
        generation = UUID(); worker?.cancel(); worker = nil
        runner.cancel(); engines.forEach { $0.close() }; engines = []; recorder = .init()
        frameCount = 0; duration = 0; replayProgress = 0; hasTracked = false
        session.pause(); stage = .idle; status = message
    }
    /// A completed measurement remains available when publication fails. Callers
    /// keep the screen open until this succeeds, rather than exporting old history.
    func ensureReportSaved() async -> Bool {
        if stage == .replaying, report != nil { await worker?.value }
        guard let measured = report else { return true }
        if reportURL != nil { return true }
        let run = generation; let storage = store
        do {
            let url = try await Task.detached(priority: .utility) { try storage.save(comparison: measured) }.value
            guard generation == run else { return false }
            reportURL = url; status = "对比报告已保存"
            return true
        } catch {
            guard generation == run else { return false }
            status = "对比报告未保存，请重试保存后退出。"
            return false
        }
    }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard stage == .capturing else { return }
        guard case .normal = frame.camera.trackingState else {
            if hasTracked { cancel(message: "追踪中断，共同测试帧已丢弃。请重新录制完整的一段。") }
            return
        }
        guard recorder.frames.last.map({ frame.timestamp - $0.timestamp >= 1.5 }) ?? true,
              let frozen = try? LocalizationQueryFrame.capture(frame, sequence: frameCount) else { return }
        record(frozen, trackingNormal: true)
    }
    func record(_ frozen: LocalizationQueryFrame, trackingNormal: Bool) {
        guard stage == .capturing else { return }
        guard trackingNormal else {
            if hasTracked { cancel(message: "追踪中断，共同测试帧已丢弃。请重新录制完整的一段。") }
            return
        }
        hasTracked = true
        if recorder.append(frozen, trackingNormal: true) {
            frameCount = recorder.frames.count; duration = recorder.duration
            status = "已录制 \(frameCount)/32 帧 · \(Int(duration)) 秒，请持续走动改变观察角度"
            if recorder.isFull { finishCapture() }
        } else if recorder.pixelBytes + frozen.pixels.count > LocalizationQueryRecorder.maximumPixelBytes { finishCapture() }
    }
    func sessionWasInterrupted(_ session: ARSession) { if active { cancel(message: "相机中断，请重新录制共同测试帧。") } }
    func session(_ session: ARSession, didFailWithError error: Error) { if active { cancel(message: "相机暂不可用，请重新开始。") } }
}

extension LocalizationQueryFrame {
    static func capture(_ frame: ARFrame, sequence: Int) throws -> LocalizationQueryFrame {
        let buffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { throw LocalizationComparisonError.invalidFrame }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0); let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { throw LocalizationComparisonError.invalidFrame }
        let pixels = try ImmersalImagePacking.copyRows(base: base, width: width, height: height,
                                                      bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
        let k = frame.camera.intrinsics
        return try .init(sequence: sequence, timestamp: frame.timestamp, pixels: pixels, width: width, height: height,
                         intrinsics: SIMD4(k[0][0],k[1][1],k[2][0],k[2][1]), worldFromCamera: frame.camera.transform)
    }
}
