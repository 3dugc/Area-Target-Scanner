import Foundation
import Combine

enum ImmersalOperationStage: CaseIterable {
    case login, preparingFrames, checkingWorkspace, clearingWorkspace, uploading, submittingMap

    var title: String {
        switch self {
        case .login: return "正在登录"
        case .preparingFrames: return "正在准备扫描图片"
        case .checkingWorkspace: return "正在检查云端工作区"
        case .clearingWorkspace: return "正在清空云端工作区"
        case .uploading: return "正在上传图片"
        case .submittingMap: return "正在提交建图"
        }
    }
}

struct ImmersalWorkspaceConfirmation: Equatable, Identifiable {
    let id = UUID()
    let jobID: UUID
    let userID: Int
    let imageCount: Int
    let frameCount: Int
    var message: String {
        "云端工作区已有 \(imageCount) 张图片，本次扫描有 \(frameCount) 帧。清空后将上传本次全部图片并建图。此操作会删除当前账号工作区的全部图片和锚点，包含其他设备上传的图片；已生成的地图会保留。"
    }
}

@MainActor
final class ImmersalMappingModel: ObservableObject {
    @Published private(set) var email: String?
    @Published private(set) var jobs: [ImmersalMappingJob] = []
    @Published private(set) var isBusy = false
    @Published private(set) var activeJobID: UUID?
    @Published private(set) var busyJobID: UUID?
    @Published private(set) var operationStage: ImmersalOperationStage?
    @Published private(set) var progressText = ""
    @Published private(set) var isRefreshing = false
    @Published private(set) var workspaceConfirmation: ImmersalWorkspaceConfirmation?
    @Published var errorMessage: String?

    var isLoggedIn: Bool { credential != nil }
    /// Local metadata remains visible without service authentication. Cloud actions
    /// continue to use `jobs`, which is scoped to the current credential's user ID.
    var localJobs: [ImmersalMappingJob] { allJobs.sorted { $0.createdAt > $1.createdAt } }
    private var credential: ImmersalCredential?
    private var allJobs: [ImmersalMappingJob] = []
    private let api: ImmersalAPI
    private let credentials: ImmersalCredentialStoring
    private let store: ImmersalJobStore
    private let frames: ImmersalFramePreparing
    private let documentsDirectory: URL
    private var worker: Task<Void, Never>?
    private var operationID: UUID?
    private var cancellation: ScanExportCancellation?
    private var storageFailed = false
    private var appActive = true

    init(api: ImmersalAPI = ImmersalAPIClient(), credentials: ImmersalCredentialStoring = ImmersalKeychainStore(),
         store: ImmersalJobStore = ImmersalJobStore(), frames: ImmersalFramePreparing = ImmersalScanExporter(),
         documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.api = api; self.credentials = credentials; self.store = store
        self.frames = frames; self.documentsDirectory = documentsDirectory.standardizedFileURL
        do {
            allJobs = try store.load().map { stored in
                var job = stored
                if job.pendingOperation == .construct { job.phase = .constructionUncertain }
                else if job.pendingOperation != nil { job.phase = .captureUncertain }
                else if job.phase == .uploading { job.phase = .paused }
                return job
            }
        } catch {
            storageFailed = true
            errorMessage = "无法读取本机任务记录，已停止新的上传：\(error.localizedDescription)"
        }
        do { credential = try credentials.load(); email = credential?.email }
        catch { errorMessage = error.localizedDescription }
        publishJobs()
    }

    func login(email: String, password: String) {
        guard !isBusy, appActive else { return }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !password.isEmpty else {
            errorMessage = "请输入邮箱和密码。"; return
        }
        let operation = begin(jobID: nil, stage: .login)
        progressText = "正在登录…"
        worker = Task {
            defer { finish(operation) }
            do {
                try ensureCurrent(operation)
                let result = try await api.login(email: email, password: password)
                try ensureCurrent(operation)
                try credentials.save(result)
                credential = result; self.email = result.email
                publishJobs()
            } catch { if operationID == operation { errorMessage = error.localizedDescription } }
        }
    }

    func logout() {
        pause()
        do { try credentials.clear() }
        catch { errorMessage = error.localizedDescription; return }
        credential = nil; email = nil; publishJobs()
    }

    func start(scanDirectory: URL, mapName: String) {
        guard let credential, !isBusy, !storageFailed, appActive else { return }
        guard (1...24).contains(mapName.utf8.count), mapName.utf8.allSatisfy(ImmersalJobStore.isAlphanumeric) else {
            errorMessage = "地图名称请输入 1–24 个英文字母或数字。"; return
        }
        let directory = scanDirectory.standardizedFileURL
        guard directory.deletingLastPathComponent() == documentsDirectory,
              directory.lastPathComponent.hasPrefix("scan_") else {
            errorMessage = "扫描记录路径无效。"; return
        }
        guard !jobs.contains(where: \.needsSource) else {
            errorMessage = "请先继续或停止当前账号尚未完成的上传任务。"; return
        }
        let id = UUID()
        let job = ImmersalMappingJob(id: id, userID: credential.userID, scanName: directory.lastPathComponent,
                                    mapName: mapName + id.uuidString.replacingOccurrences(of: "-", with: ""), createdAt: Date())
        do { try save(allJobs + [job]); launchUpload(jobID: id) }
        catch { errorMessage = error.localizedDescription }
    }

    func resume(jobID: UUID) {
        guard jobs.first(where: { $0.id == jobID })?.canResume == true else { return }
        launchUpload(jobID: jobID)
    }

    /// Call only after the UI confirms deletion of ALL images in the account workspace.
    func restartAfterClearingWorkspace(jobID: UUID, confirmation: ImmersalWorkspaceConfirmation? = nil) {
        guard !isBusy, appActive, !storageFailed, let current = workspaceConfirmation,
              current.jobID == jobID, current.userID == credential?.userID,
              confirmation == nil || confirmation == current,
              jobs.first(where: { $0.id == jobID })?.canRestart == true else { return }
        workspaceConfirmation = nil
        launchUpload(jobID: jobID, clearConfirmation: current)
    }

    /// Refresh the count before asking for destructive authorization. This does not send writes.
    func requestWorkspaceRestart(jobID: UUID) {
        guard let credential, !isBusy, !storageFailed, appActive,
              let job = jobs.first(where: { $0.id == jobID }), job.canRestart else { return }
        // A read-only refresh must not change an uncertain capture or a workspace conflict
        // into a resumable upload if it is interrupted.
        let operation = begin(jobID: nil, stage: .checkingWorkspace, busyJobID: jobID)
        progressText = "正在检查云端工作区…"
        worker = Task {
            defer { finish(operation) }
            do {
                try ensureCurrent(operation)
                let status = try await api.status(token: credential.token)
                try ensureCurrent(operation)
                guard status.userID == credential.userID else { throw ImmersalAPIError.authentication }
                guard status.imageCount >= 0 else { throw ImmersalMappingError.message("云端工作区图片数无效。") }
                guard jobs.first(where: { $0.id == jobID })?.canRestart == true else { throw CancellationError() }
                try presentWorkspaceConfirmation(jobID, imageCount: status.imageCount)
            } catch {
                guard operationID == operation else { return }
                handleAuthentication(error)
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelWorkspaceConfirmation(_ confirmation: ImmersalWorkspaceConfirmation? = nil) {
        guard confirmation == nil || confirmation == workspaceConfirmation else { return }
        workspaceConfirmation = nil
    }

    func pause() {
        workspaceConfirmation = nil
        cancellation?.cancel(); worker?.cancel()
        if let id = activeJobID {
            do {
                try update(id) { job in
                    // A workspace conflict still needs a fresh read and explicit clear confirmation.
                    if job.pendingOperation == .construct { job.phase = .constructionUncertain }
                    else if job.pendingOperation != nil { job.phase = .captureUncertain }
                    else if job.phase != .workspaceConflict { job.phase = .paused }
                    job.message = job.phase == .workspaceConflict ? "操作已暂停，请重新检查云端工作区并确认后继续。" :
                        (job.pendingOperation == nil ? "上传已暂停，可稍后继续。" : "请求已发出但结果尚未确认，不能直接重试。")
                }
            } catch { errorMessage = error.localizedDescription }
        }
        operationID = nil; worker = nil; cancellation = nil
        isBusy = false; activeJobID = nil; busyJobID = nil; operationStage = nil; progressText = ""
    }

    func abandon(jobID: UUID) {
        guard jobs.first(where: { $0.id == jobID })?.canAbandon == true else { return }
        if workspaceConfirmation?.jobID == jobID { workspaceConfirmation = nil }
        if busyJobID == jobID { pause() }
        do {
            try update(jobID) { job in
                let constructionUnconfirmed = job.pendingOperation == .construct
                job.phase = .abandoned; job.pendingOperation = nil
                job.message = constructionUnconfirmed ? "已停止本机跟踪，建图结果仍未确认。云端可能已创建地图，请到 Portal 核实；本操作不会取消云端建图。" :
                    "本机任务已停止，已上传的工作区图片仍保留在云端。"
            }
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func deleteJob(jobID: UUID) -> Bool {
        guard let credential,
              jobs.contains(where: { $0.id == jobID && $0.userID == credential.userID }) else { return false }
        // A read-only workspace check has no activeJobID, but still belongs to this job.
        // pause() preserves any already-sent mutation intent if saving the deletion fails.
        if busyJobID == jobID { pause() }
        do {
            try save(allJobs.filter { !($0.id == jobID && $0.userID == credential.userID) })
            if workspaceConfirmation?.jobID == jobID { workspaceConfirmation = nil }
            errorMessage = nil
            return true
        } catch {
            errorMessage = "无法删除本机任务记录：\(error.localizedDescription)"
            return false
        }
    }

    func blocksDeletion(of path: String) -> Bool {
        if storageFailed { return true }
        return allJobs.contains { $0.needsSource && documentsDirectory.appendingPathComponent($0.scanName).standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path }
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        if !active { pause() }
    }

    func monitorJobs() async {
        while !Task.isCancelled {
            await refreshJobs()
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
        }
    }

    func refreshJobs() async {
        guard let credential, appActive, !isBusy, !isRefreshing, !storageFailed,
              jobs.contains(where: \.shouldQuery) else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let remote = try await api.jobs(token: credential.token)
            guard self.credential == credential, appActive else { return }
            var updated = allJobs
            for index in updated.indices where updated[index].userID == credential.userID && updated[index].shouldQuery {
                let job = updated[index]
                let matches = remote.filter { candidate in
                    if let mapID = job.mapID { return candidate.id == mapID }
                    return candidate.name == job.mapName && candidate.size == job.frameCount
                }
                guard matches.count == 1, let result = matches.first, result.id > 0 else { continue }
                updated[index].mapID = result.id; updated[index].pendingOperation = nil
                updated[index].phase = [.pending, .processing, .sparse, .done, .failed].first { $0.rawValue == result.status } ?? .processing
                updated[index].message = result.status == "failed" ? "云端建图失败，请在 Immersal Portal 查看详情。" : nil
            }
            try save(updated)
        } catch {
            guard self.credential == credential else { return }
            handleAuthentication(error)
            errorMessage = error.localizedDescription
        }
    }

    private func launchUpload(jobID: UUID, clearConfirmation: ImmersalWorkspaceConfirmation? = nil) {
        guard let credential, !isBusy, !storageFailed, appActive,
              jobs.contains(where: { $0.id == jobID }) else { return }
        let operation = begin(jobID: jobID, stage: .preparingFrames)
        let flag = ScanExportCancellation()
        cancellation = flag
        worker = Task {
            defer { finish(operation) }
            do { try await upload(jobID: jobID, credential: credential, operation: operation, flag: flag, clearConfirmation: clearConfirmation) }
            catch {
                guard operationID == operation else { return }
                do {
                    try update(jobID) { job in
                        // Keep the confirmation boundary when preparation or status fails before upload.
                        if job.pendingOperation == .construct { job.phase = .constructionUncertain }
                        else if job.pendingOperation != nil { job.phase = .captureUncertain }
                        else if job.phase != .workspaceConflict { job.phase = .paused }
                        job.message = job.phase == .constructionUncertain ? "建图提交结果尚未确认，将查询云端任务，不会重复提交。" :
                            (job.phase == .captureUncertain ? "上传请求结果尚未确认。请确认工作区后清空重传，避免重复图片。" : error.localizedDescription)
                    }
                } catch { errorMessage = error.localizedDescription }
                handleAuthentication(error)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func upload(jobID: UUID, credential: ImmersalCredential, operation: UUID,
                        flag: ScanExportCancellation, clearConfirmation: ImmersalWorkspaceConfirmation?) async throws {
        try ensureCurrent(operation)
        guard let job = jobs.first(where: { $0.id == jobID }) else { throw CancellationError() }
        progressText = "正在检查扫描图片与元数据…"
        let directory = documentsDirectory.appendingPathComponent(job.scanName)
        let frames = self.frames
        let frozen = try await Task.detached(priority: .userInitiated) {
            let source = try? ScanSourceFingerprint.compute(directory: directory, isCancelled: { flag.isCancelled })
            let prepared = try frames.prepareUpload(scanDirectory: directory, isCancelled: { flag.isCancelled })
            if let source {
                guard try ScanSourceFingerprint.compute(directory: directory, isCancelled: { flag.isCancelled }) == source else {
                    throw ScanSourceFingerprint.Failure.changed
                }
            }
            return (prepared, source)
        }.value
        let prepared = frozen.0
        try ensureCurrent(operation)
        if let source = job.sourceFingerprint, source != frozen.1 { throw ScanSourceFingerprint.Failure.changed }
        guard prepared.frameCount > 0, job.uploadedCount <= prepared.frameCount,
              job.fingerprint.isEmpty || job.fingerprint == prepared.fingerprint else {
            throw ImmersalMappingError.message("扫描源数据已改变，请停止本机任务并重新选择扫描。")
        }
        try update(jobID) {
            // Old partially submitted journals retain unknown provenance rather than being backfilled.
            if job.fingerprint.isEmpty || job.sourceFingerprint != nil { $0.sourceFingerprint = frozen.1 }
            $0.fingerprint = prepared.fingerprint; $0.frameCount = prepared.frameCount; $0.message = nil
        }
        operationStage = .checkingWorkspace
        progressText = "正在检查云端工作区…"
        var status = try await api.status(token: credential.token)
        try ensureCurrent(operation)
        guard status.userID == credential.userID else { throw ImmersalAPIError.authentication }
        guard status.imageCount >= 0 else { throw ImmersalMappingError.message("云端工作区图片数无效。") }
        guard prepared.frameCount <= status.imageMax else { throw ImmersalAPIError.rejected("image limit") }
        if let confirmed = clearConfirmation {
            guard confirmed.jobID == jobID, confirmed.userID == credential.userID else { throw CancellationError() }
            guard status.imageCount == confirmed.imageCount, prepared.frameCount == confirmed.frameCount else {
                try presentWorkspaceConfirmation(jobID, imageCount: status.imageCount); return
            }
            operationStage = .clearingWorkspace
            progressText = "正在清空云端工作区…"
            try await mutate(jobID: jobID, kind: .clear, operation: operation) {
                try await api.clear(token: credential.token)
            }
            try ensureCurrent(operation)
            try update(jobID) { $0.uploadedCount = 0; $0.pendingOperation = nil; $0.workspaceImageCount = nil }
            operationStage = .checkingWorkspace
            progressText = "正在检查云端工作区…"
            status = try await api.status(token: credential.token)
            try ensureCurrent(operation)
            guard status.userID == credential.userID else { throw ImmersalAPIError.authentication }
        }
        guard let current = jobs.first(where: { $0.id == jobID }) else { throw CancellationError() }
        let startIndex = current.uploadedCount
        guard status.imageCount == startIndex else {
            try presentWorkspaceConfirmation(jobID, imageCount: status.imageCount); return
        }
        if startIndex < prepared.frameCount { operationStage = .uploading }
        for index in startIndex..<prepared.frameCount {
            try ensureCurrent(operation)
            progressText = "正在上传第 \(index + 1)/\(prepared.frameCount) 帧"
            let frame = try await Task.detached(priority: .userInitiated) {
                try prepared.readFrame(index, { flag.isCancelled })
            }.value
            try ensureCurrent(operation)
            try await mutate(jobID: jobID, kind: .capture, operation: operation) {
                try await api.capture(frame: frame, token: credential.token)
            }
            try ensureCurrent(operation)
            try update(jobID) { $0.uploadedCount = index + 1; $0.pendingOperation = nil }
        }
        operationStage = .checkingWorkspace
        progressText = "正在核对云端图片数量…"
        status = try await api.status(token: credential.token)
        try ensureCurrent(operation)
        guard status.userID == credential.userID else { throw ImmersalAPIError.authentication }
        guard status.imageCount == prepared.frameCount else { try presentWorkspaceConfirmation(jobID, imageCount: status.imageCount); return }
        operationStage = .submittingMap
        progressText = "正在提交建图…"
        let construction = try await mutate(jobID: jobID, kind: .construct, operation: operation) {
            try await api.construct(name: job.mapName, token: credential.token)
        }
        try ensureCurrent(operation)
        try update(jobID) {
            $0.mapID = construction.id; $0.pendingOperation = nil; $0.phase = .pending
            $0.message = construction.size == prepared.frameCount ? nil : "云端建图图片数与扫描帧数不一致，请在 Portal 核查。"
        }
    }

    /// Persist each request's intent before sending. An explicit rejection restores only the
    /// previous intent, so a failed clear can never erase an earlier uncertain capture.
    private func mutate<T>(jobID: UUID, kind: ImmersalMappingJob.PendingOperation, operation: UUID,
                           send: () async throws -> T) async throws -> T {
        try ensureCurrent(operation)
        guard let job = jobs.first(where: { $0.id == jobID }) else { throw CancellationError() }
        let previousIntent = job.pendingOperation
        try update(jobID) {
            $0.pendingOperation = kind
            if kind == .capture { $0.phase = .uploading }
            if kind == .construct { $0.phase = .constructing }
        }
        do { return try await send() }
        catch {
            if operationID == operation, (error as? ImmersalAPIError)?.definitelyRejected == true {
                try update(jobID) { $0.pendingOperation = previousIntent }
            }
            throw error
        }
    }

    private func presentWorkspaceConfirmation(_ id: UUID, imageCount: Int) throws {
        guard imageCount >= 0, let job = jobs.first(where: { $0.id == id }),
              job.userID == credential?.userID, job.mapID == nil, appActive else { throw CancellationError() }
        let confirmation = ImmersalWorkspaceConfirmation(jobID: id, userID: job.userID,
                                                       imageCount: imageCount, frameCount: job.frameCount)
        try update(id) {
            if $0.pendingOperation == nil { $0.phase = .workspaceConflict }
            $0.workspaceImageCount = imageCount
            $0.message = confirmation.message
        }
        workspaceConfirmation = confirmation
    }
    private func begin(jobID: UUID?, stage: ImmersalOperationStage, busyJobID: UUID? = nil) -> UUID {
        workspaceConfirmation = nil
        let id = UUID(); operationID = id; activeJobID = jobID; isBusy = true; errorMessage = nil
        self.busyJobID = busyJobID ?? jobID
        operationStage = stage
        return id
    }
    private func finish(_ operation: UUID) {
        guard operationID == operation else { return }
        operationID = nil; worker = nil; cancellation = nil; isBusy = false; activeJobID = nil
        busyJobID = nil; operationStage = nil; progressText = ""
    }
    private func ensureCurrent(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard operationID == operation, appActive else { throw CancellationError() }
    }
    private func publishJobs() { jobs = allJobs.filter { $0.userID == credential?.userID }.sorted { $0.createdAt > $1.createdAt } }
    private func update(_ id: UUID, _ change: (inout ImmersalMappingJob) -> Void) throws {
        var updated = allJobs
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
        change(&updated[index]); try save(updated)
    }
    private func save(_ jobs: [ImmersalMappingJob]) throws {
        do { try store.save(jobs) }
        catch { storageFailed = true; throw ImmersalMappingError.message("无法保存上传进度，已停止发送：\(error.localizedDescription)") }
        allJobs = jobs; publishJobs()
    }
    private func handleAuthentication(_ error: Error) {
        guard error as? ImmersalAPIError == .authentication else { return }
        // A /list response can expire the session while another task is awaiting /status.
        // Invalidate that worker before removing its visible account/job state.
        pause()
        do { try credentials.clear() } catch { errorMessage = error.localizedDescription }
        credential = nil; email = nil; publishJobs()
    }
}
