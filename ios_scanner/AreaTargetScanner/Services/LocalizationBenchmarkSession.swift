import ARKit
import AVFoundation
import Combine
import UIKit

/// Recording is independent of either recognition engine. A saved package is
/// loaded and verified before each replay, so retries use exactly the same input.
@MainActor
final class LocalizationBenchmarkSession: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    enum Stage: Equatable { case idle, preparing, capturing, saving, ready, replaying, finished }
    let session = ARSession()
    let runner = LocalizationComparisonRunner()
    @Published private(set) var stage = Stage.idle
    @Published private(set) var status = "录制同一段测试录像，再依次比较两套地图"
    @Published private(set) var frameCount = 0
    @Published private(set) var duration = 0.0
    @Published private(set) var replayProgress = 0.0
    @Published private(set) var recordings: [LocalizationRecording] = []
    @Published private(set) var otherRecordings: [LocalizationRecording] = []
    @Published private(set) var invalidRecordingIDs: [UUID] = []
    @Published private(set) var selectedRecording: LocalizationRecording?
    @Published private(set) var report: LocalizationComparisonReport?
    @Published private(set) var reportURL: URL?
    @Published private(set) var markdownURL: URL?
    @Published private(set) var videoURL: URL?
    var active: Bool { [.preparing, .capturing, .saving, .replaying].contains(stage) }
    var canRetrySave: Bool { pendingCapture != nil && stage == .ready && selectedRecording == nil }

    private let recordingStore: LocalizationRecordingStore
    private let reportStore: LocalizationReportStore
    private let requestCamera: () async -> Bool
    private let runSession: (ARSession) -> Void
    private var generation = UUID()
    private var sourceFingerprint = ""
    private var identities: [LocalizationAssetIdentity]?
    private var recorder = LocalizationQueryRecorder()
    private var video: LocalizationVideoRecorder?
    private var captureContext: LocalizationBenchmarkRuntimeContext?
    private var captureBegan: Double?
    private var pendingCapture: (frames: [LocalizationQueryFrame], url: URL, dropped: Int, reason: String)?
    private var worker: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var deleting = false
    @MainActor private final class SaveLease {
        private var identifier = UIBackgroundTaskIdentifier.invalid
        init() {
            identifier = UIApplication.shared.beginBackgroundTask(withName: "保存测试录像") { [weak self] in self?.end() }
        }
        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier); identifier = .invalid
        }
    }

    init(recordingStore: LocalizationRecordingStore = .init(), reportStore: LocalizationReportStore = .init(),
         requestCamera: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .video) },
         runSession: @escaping (ARSession) -> Void = { $0.run(ARWorldTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors]) }) {
        self.recordingStore = recordingStore; self.reportStore = reportStore
        self.requestCamera = requestCamera; self.runSession = runSession
        super.init()
        session.delegate = self; session.delegateQueue = .main
        runner.$progress.sink { [weak self] in self?.replayProgress = $0 }.store(in: &subscriptions)
        runner.$status.sink { [weak self] in
            guard let self, self.stage == .replaying else { return }; self.status = $0
        }.store(in: &subscriptions)
    }

    func refresh(sourceFingerprint: String, identities: [LocalizationAssetIdentity]? = nil) {
        guard !active else { return }
        guard ScanSourceFingerprint.valid(sourceFingerprint), identities?.allSatisfy({ $0.sourceFingerprint == sourceFingerprint }) ?? true else {
            status = LocalizationComparisonError.sourceMismatch.localizedDescription; return
        }
        self.sourceFingerprint = sourceFingerprint; self.identities = identities
        let run = UUID(); generation = run; let storage = recordingStore
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let library = try await Task.detached(priority: .utility) { (try storage.listAll(), try storage.invalidRecordingIDs()) }.value
                let all = library.0
                let available = all.filter { $0.sourceFingerprint == sourceFingerprint }
                guard generation == run, !Task.isCancelled else { return }
                invalidRecordingIDs = library.1
                recordings = available; otherRecordings = all.filter { $0.sourceFingerprint != sourceFingerprint }
                if let selected = selectedRecording, available.contains(selected) { select(selected) }
                else if let first = available.first { select(first) }
                else { selectedRecording = nil; videoURL = nil; clearReport(); stage = .idle }
            } catch { if generation == run { status = "读取录像失败：\(error.localizedDescription)" } }
        }
    }

    func start(sourceFingerprint: String) {
        guard !active else { return }
        guard ScanSourceFingerprint.valid(sourceFingerprint) else { status = LocalizationComparisonError.sourceMismatch.localizedDescription; return }
        clearPending(); clearReport(); selectedRecording = nil; videoURL = nil
        self.sourceFingerprint = sourceFingerprint
        recorder = .init(); frameCount = 0; duration = 0; replayProgress = 0; captureBegan = nil
        captureContext = .capture()
        let run = UUID(); generation = run; stage = .preparing; status = "正在准备相机…"
        worker = Task { [weak self] in
            guard let self else { return }
            let allowed = await requestCamera()
            guard generation == run, !Task.isCancelled else { return }
            guard allowed else { stage = .idle; status = "请在系统设置中允许相机访问后重试。"; return }
            stage = .capturing; status = "等待正常追踪；缓慢走动至少 3 米，录制 30–47 秒"
            runSession(session)
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self, self.generation == run, self.stage == .capturing else { return }
                self.finishCapture(reason: "durationLimit")
            }
        }
    }

    func finishCapture() { finishCapture(reason: "manualStop") }
    func stopForInterruption() { finishCapture(reason: "trackingInterrupted") }
    private func finishCapture(reason: String) {
        guard stage == .capturing else { return }
        timeout?.cancel(); timeout = nil; session.pause()
        guard !recorder.frames.isEmpty, let writer = video else { cancel(); status = "尚未采集到可用录像，请重新开始。"; return }
        let frames = recorder.frames; recorder = .init(); video = nil
        let run = generation; stage = .saving; status = "正在保存录像和相机参数…"
        let lease = SaveLease()
        worker = Task { [weak self] in
            defer { lease.end() }
            guard let self else { writer.cancel(); return }
            do {
                let completed = try await writer.finish()
                guard generation == run, !Task.isCancelled else { try? FileManager.default.removeItem(at: completed.url); return }
                pendingCapture = (frames, completed.url, completed.droppedFrames, reason)
                await savePending(run: run)
            } catch {
                writer.cancel()
                guard generation == run else { return }
                stage = .idle; status = "录像编码失败，请重新录制：\(error.localizedDescription)"
            }
        }
    }

    func retrySave() {
        guard canRetrySave else { return }
        stage = .saving; let run = generation
        worker = Task { [weak self] in await self?.savePending(run: run) }
    }
    private func savePending(run: UUID) async {
        let lease = SaveLease(); defer { lease.end() }
        guard let pending = pendingCapture, let captured = captureContext else { return }
        var context = LocalizationRecordingContext(deviceModel: captured.deviceModel, systemVersion: captured.systemVersion,
            appVersion: captured.appVersion, appBuild: captured.appBuild, previewDroppedFrames: pending.dropped)
        context.captureEndReason = pending.reason
        let storage = recordingStore; let source = sourceFingerprint
        do {
            let saved = try await Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return try storage.save(frames: pending.frames, videoURL: pending.url, sourceFingerprint: source, context: context)
            }.value
            // A package that has already committed remains durable even if the
            // screen closes during the disk operation. Never update a new screen generation.
            guard generation == run, !Task.isCancelled else { return }
            clearPending(); selectedRecording = saved
            let loaded = try await Task.detached(priority: .utility) { (try storage.listAll(), try storage.videoURL(for: saved), try storage.invalidRecordingIDs()) }.value
            guard generation == run else { return }
            recordings = loaded.0.filter { $0.sourceFingerprint == source }; otherRecordings = loaded.0.filter { $0.sourceFingerprint != source }; videoURL = loaded.1; invalidRecordingIDs = loaded.2
            stage = .ready; status = "录像已保存。可以回看，再点击开始比较。"
        } catch {
            guard generation == run else { return }
            if let library = try? await Task.detached(priority: .utility, operation: { (try storage.listAll(), try storage.invalidRecordingIDs()) }).value {
                guard generation == run else { return }
                let all = library.0; invalidRecordingIDs = library.1
                recordings = all.filter { $0.sourceFingerprint == source }; otherRecordings = all.filter { $0.sourceFingerprint != source }
            }
            stage = .ready; status = "录像未保存，保留本次数据，请重试保存：\(error.localizedDescription)"
        }
    }

    func select(_ recording: LocalizationRecording) {
        guard !active, recording.sourceFingerprint == sourceFingerprint else { return }
        clearPending(); clearReport(); videoURL = nil
        let run = UUID(); generation = run; stage = .preparing; status = "正在核对保存的录像…"
        let storage = recordingStore, reports = reportStore, pair = identities
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await Task.detached(priority: .utility) { () -> (URL, LocalizationComparisonReport?, URL?, URL?) in
                    let clip = try storage.videoURL(for: recording)
                    guard let pair, let saved = try? reports.latestComparison(identities: pair, recordingID: recording.id) else { return (clip, nil, nil, nil) }
                    return (clip, saved, try? reports.latestComparisonURL(identities: pair, recordingID: recording.id), try? reports.saveMarkdown(comparison: saved))
                }.value
                guard generation == run, !Task.isCancelled else { return }
                selectedRecording = recording; videoURL = loaded.0
                frameCount = recording.frameCount; duration = recording.duration
                report = loaded.1; reportURL = loaded.2; markdownURL = loaded.3
                stage = report == nil ? .ready : .finished
                status = "已选择保存的录像，可以复测同一批输入"
            } catch {
                guard generation == run else { return }
                selectedRecording = nil; stage = .idle; status = "录像或报告无法读取：\(error.localizedDescription)"
            }
        }
    }

    func run(engines: [LocalizationReplayEngine]) {
        guard !active, let recording = selectedRecording else { return }
        guard engines.map({ $0.identity.provider }) == [.areaTarget, .immersal],
              engines.allSatisfy({ $0.identity.sourceFingerprint == recording.sourceFingerprint }) else {
            engines.forEach { $0.close() }; status = LocalizationComparisonError.sourceMismatch.localizedDescription; return
        }
        clearReport(); identities = engines.map(\.identity); replayProgress = 0
        let run = UUID(); generation = run; stage = .replaying; status = "正在验证录像数据…"
        let runtime = LocalizationBenchmarkRuntimeContext.capture(); let storage = recordingStore
        worker = Task { [weak self] in
            guard let self else { engines.forEach { $0.close() }; return }
            do {
                let frames = try await Task.detached(priority: .utility) { try storage.load(recording) }.value
                guard generation == run, !Task.isCancelled else { return }
                var measured = try await runner.run(frames: frames, engines: engines)
                guard generation == run, !Task.isCancelled else { return }
                measured.recording = recording; measured.runtimeContext = runtime
                measured.analysis = LocalizationBenchmarkAnalysis(comparison: measured)
                report = measured
                await saveReport(run: run)
            } catch {
                guard generation == run else { return }
                engines.forEach { $0.close() }
                stage = .ready; status = "比较未完成：\(error.localizedDescription)"
            }
        }
    }

    func retryReportSave() {
        guard stage == .finished, report != nil, reportURL == nil || markdownURL == nil else { return }
        let run = generation; stage = .saving
        worker = Task { [weak self] in await self?.saveReport(run: run) }
    }
    private func saveReport(run: UUID) async {
        let lease = SaveLease(); defer { lease.end() }
        guard let measured = report else { return }
        let storage = reportStore
        do {
            let urls = try await Task.detached(priority: .utility) {
                (try storage.save(comparison: measured), try storage.saveMarkdown(comparison: measured))
            }.value
            guard generation == run else { return }
            reportURL = urls.0; markdownURL = urls.1; stage = .finished; status = "比较完成，数据报告和优化建议已保存"
        } catch {
            guard generation == run else { return }
            stage = .finished; status = "比较完成，报告保存失败，请重试：\(error.localizedDescription)"
        }
    }

    func delete(_ recording: LocalizationRecording) {
        deleteFromLibrary(id: recording.id) { try $0.delete(recording) }
    }
    func deleteInvalid(_ id: UUID) {
        deleteFromLibrary(id: id) { try $0.deleteInvalid(id: id) }
    }
    private func deleteFromLibrary(id: UUID, action: @escaping (LocalizationRecordingStore) throws -> Void) {
        guard !active else { return }
        let run = UUID(); generation = run; stage = .saving; deleting = true
        status = "正在删除所选录像…"
        let storage = recordingStore, source = sourceFingerprint
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let library = try await Task.detached(priority: .utility) {
                    try action(storage); return (try storage.listAll(), try storage.invalidRecordingIDs())
                }.value
                guard generation == run else { return }
                if selectedRecording?.id == id { selectedRecording = nil; videoURL = nil; clearReport() }
                recordings = library.0.filter { $0.sourceFingerprint == source }; otherRecordings = library.0.filter { $0.sourceFingerprint != source }
                invalidRecordingIDs = library.1; deleting = false
                stage = selectedRecording == nil && pendingCapture == nil ? .idle : .ready
                status = pendingCapture == nil ? "录像已删除，已导出的报告仍保留" : "已释放存储空间，可以重试保存本次录像"
            } catch {
                guard generation == run else { return }
                deleting = false; stage = selectedRecording == nil && pendingCapture == nil ? .idle : .ready; status = "删除失败：\(error.localizedDescription)"
            }
        }
    }
    func cancel() {
        generation = UUID(); worker?.cancel(); worker = nil; timeout?.cancel(); timeout = nil
        runner.cancel(); video?.cancel(); video = nil; recorder = .init(); session.pause()
        if deleting {
            deleting = false; stage = pendingCapture != nil || selectedRecording != nil ? .ready : .idle
            status = "已停止当前操作，未保存录像仍可重试"
        } else {
            clearPending(); stage = selectedRecording == nil ? .idle : .ready
            status = "已停止，可重新录制或复测保存的录像"
        }
    }
    private func clearPending() {
        if let pending = pendingCapture { try? FileManager.default.removeItem(at: pending.url) }
        pendingCapture = nil
    }
    private func clearReport() { report = nil; reportURL = nil; markdownURL = nil }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard stage == .capturing else { return }
        guard case .normal = frame.camera.trackingState else {
            if captureBegan != nil { finishCapture(reason: "trackingInterrupted") }
            return
        }
        do { try appendVideoFrame(pixelBuffer: frame.capturedImage, timestamp: frame.timestamp) }
        catch { cancel(); status = "无法开始录像：\(error.localizedDescription)"; return }
        guard recorder.frames.last.map({ frame.timestamp - $0.timestamp >= 1.5 }) ?? true else { return }
        do { record(try .capture(frame, sequence: frameCount), trackingNormal: true) }
        catch { finishCapture(reason: "cameraFailure") }
    }
    /// The same raw camera buffer supplies the continuous preview. Evaluation
    /// frames are frozen separately once, without decoding the compressed video.
    func appendVideoFrame(pixelBuffer: CVPixelBuffer, timestamp: Double) throws {
        guard stage == .capturing, timestamp.isFinite, timestamp >= 0 else { throw LocalizationComparisonError.invalidFrame }
        if captureBegan == nil {
            video = try LocalizationVideoRecorder(outputURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4"))
            captureBegan = timestamp
        }
        video?.append(pixelBuffer: pixelBuffer, timestamp: timestamp)
    }
    /// Also used by deterministic session tests; production supplies an ARFrame.
    func record(_ frozen: LocalizationQueryFrame, trackingNormal: Bool) {
        guard stage == .capturing else { return }
        guard trackingNormal else { if !recorder.frames.isEmpty { finishCapture(reason: "trackingInterrupted") }; return }
        if recorder.append(frozen, trackingNormal: true) {
            frameCount = recorder.frames.count; duration = recorder.duration
            status = "录制中 · \(frameCount)/32 评测帧 · \(Int(duration)) 秒，请缓慢走动"
            if recorder.isFull { finishCapture(reason: "frameLimit") }
        } else if recorder.pixelBytes + frozen.pixels.count > LocalizationQueryRecorder.maximumPixelBytes { finishCapture(reason: "byteLimit") }
    }
    func sessionWasInterrupted(_ session: ARSession) { if stage == .capturing { finishCapture(reason: "trackingInterrupted") } }
    func session(_ session: ARSession, didFailWithError error: Error) { if stage == .capturing { finishCapture(reason: "cameraFailure") } }
}
