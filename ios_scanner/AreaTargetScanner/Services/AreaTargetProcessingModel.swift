import Foundation
import Combine
import CryptoKit
import Security

/// Owns local transfers and the durable identity used to reconcile cloud work.
@MainActor
final class AreaTargetProcessingModel: ObservableObject {
    /// One production journal writer for the UI and explicitly persistent QA.
    static let shared = AreaTargetProcessingModel()

    @Published private(set) var jobs: [AreaTargetProcessingJob] = []
    @Published private(set) var selectedJobID: String?
    @Published private(set) var operationInProgress = false
    @Published private(set) var isRestoringAssets = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var authenticationMessage: String?
    @Published private(set) var serviceSessions: [AreaTargetServerOrigin: AreaTargetServiceSession] = [:]
    @Published var message: String?

    private let api: AreaTargetAPI
    private let legacyAPI: AreaTargetAPI
    private let archiver: AreaTargetArchiving
    private let jobStore: AreaTargetJobStoring
    private let tokenStore: AreaTargetTokenStoring
    private let assetStore: AreaTargetAssetStoring
    private let pollInterval: TimeInterval
    private let uploadDirectory: URL
    private var restoration: Task<Void, Never>?
    private var active = false
    private var storageUnavailable = false
    private var transfer: Task<Void, Never>?
    private var transferID: String?
    private var generation: UUID?
    private var cancellation: ScanExportCancellation?
    private var monitoring: Task<Void, Never>?
    private var statusRequestIDs: [String: UUID] = [:]
    private var resumeStatusRequestIDs: [String: UUID] = [:]

    init(api: AreaTargetAPI? = nil, legacyAPI: AreaTargetAPI? = nil, archiver: AreaTargetArchiving = AreaTargetScanArchive(),
         jobStore: AreaTargetJobStoring = AreaTargetJobStore(), tokenStore: AreaTargetTokenStoring = AreaTargetKeychainStore(),
         assetStore: AreaTargetAssetStoring = AreaTargetAssetStore(), pollInterval: TimeInterval = 5,
         uploadDirectory: URL? = nil) {
        self.api = api ?? AreaTargetAPIClient(origin: .current)
        // A single injected fake continues to cover both routes without networking.
        self.legacyAPI = legacyAPI ?? api ?? AreaTargetAPIClient(origin: .legacy)
        self.archiver = archiver
        self.jobStore = jobStore
        self.tokenStore = tokenStore
        self.assetStore = assetStore
        self.pollInterval = max(0.02, pollInterval)
        self.uploadDirectory = uploadDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AreaTargetCloud/uploads", isDirectory: true)
        for origin in AreaTargetServerOrigin.allCases {
            do { serviceSessions[origin] = try self.api(for: origin).savedServiceSession() }
            catch { authenticationMessage = error.localizedDescription }
        }
        do {
            jobs = try jobStore.load().map { original in
                var job = original
                if job.phase == .uploading { job.phase = .submissionUnknown }
                if job.phase == .preparing { job.phase = .paused }
                if job.phase == .downloading { job.phase = .ready }
                return job
            }.sorted { $0.createdAt > $1.createdAt }
            selectedJobID = jobs.first?.id
            if !jobs.isEmpty {
                isRestoringAssets = true
                restoration = Task { [weak self] in await self?.restoreAssets() }
            }
        } catch {
            storageUnavailable = true
            message = AreaTargetLocalError.invalidJournal.localizedDescription
        }
    }

    deinit { transfer?.cancel(); monitoring?.cancel(); restoration?.cancel(); cancellation?.cancel() }

    var selectedJob: AreaTargetProcessingJob? { jobs.first { $0.id == selectedJobID } }

    func serviceSession(for origin: AreaTargetServerOrigin) -> AreaTargetServiceSession? {
        serviceSessions[origin].flatMap { $0.isUsable ? $0 : nil }
    }

    func requiresServiceAuthentication(for origin: AreaTargetServerOrigin) -> Bool {
        api(for: origin).requiresServiceAuthentication
    }

    func signIn(username: String, password: String, origin: AreaTargetServerOrigin) async {
        guard !operationInProgress, !isAuthenticating else { return }
        isAuthenticating = true
        authenticationMessage = nil
        defer { isAuthenticating = false }
        do {
            serviceSessions[origin] = try await api(for: origin).signIn(username: username, password: password)
            message = nil
            startMonitoring()
        } catch { authenticationMessage = safeMessage(error) }
    }

    func restoreServiceLogin(origin: AreaTargetServerOrigin) async {
        guard requiresServiceAuthentication(for: origin), !isAuthenticating, !operationInProgress,
              serviceSession(for: origin) != nil else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            serviceSessions[origin] = try await api(for: origin).validateServiceSession()
            authenticationMessage = nil
            startMonitoring()
        } catch {
            if Self.isServiceAuthenticationError(error) { serviceSessions[origin] = nil; stopMonitoring() }
            authenticationMessage = safeMessage(error)
        }
    }

    func signOut(origin: AreaTargetServerOrigin) async {
        guard !operationInProgress, !isAuthenticating else { return }
        isAuthenticating = true
        authenticationMessage = nil
        stopMonitoring()
        defer { isAuthenticating = false }
        do { try await api(for: origin).signOut(); serviceSessions[origin] = nil }
        catch let signOutError {
            do {
                serviceSessions[origin] = try api(for: origin).savedServiceSession()
                authenticationMessage = serviceSession(for: origin) == nil
                    ? "已在本机退出登录。服务端会话撤销未完成，将在到期后失效。"
                    : safeMessage(signOutError)
            } catch {
                // Keep the prior state when Keychain cannot confirm whether deletion succeeded.
                authenticationMessage = safeMessage(error)
            }
        }
    }

    func selectJob(_ id: String?) {
        guard !operationInProgress else { return }
        selectedJobID = id.flatMap { candidate in jobs.contains { $0.id == candidate } ? candidate : nil }
        message = nil
    }

    func job(for scanPath: String) -> AreaTargetProcessingJob? {
        jobs.first { $0.scanDirectoryPath == scanPath }
    }

    func sourceProtectionReason(scanPath: String) -> String? {
        if storageUnavailable { return "本机 Area Target 任务记录暂不可用，请先恢复任务记录后再删除扫描。" }
        guard let job = jobs.first(where: { $0.scanDirectoryPath == scanPath && $0.needsSource }) else { return nil }
        return "Area Target 任务「\(job.displayName)」仍需要这条扫描。请在 Area Target 任务页继续处理，或停止本机跟踪。"
    }

    func deletionBlocked(scanPath: String) -> Bool { sourceProtectionReason(scanPath: scanPath) != nil }

    /// Stops only this journal's tracking. It does not revoke the job capability,
    /// cancel cloud processing, or remove the original scan, upload copy, or local assets.
    func stopLocalTracking(jobID: String) {
        guard !storageUnavailable, let job = jobs.first(where: { $0.id == jobID }), job.canStopLocalTracking else { return }
        guard !operationInProgress else {
            message = "请先暂停本机操作，待暂停完成后再停止跟踪。"
            return
        }
        do {
            try edit(jobID) {
                $0.phase = .stopped
                $0.detail = "已停止本机跟踪。原扫描和已下载资产保留；云端任务可能仍会继续。可以重新处理原扫描。"
            }
            message = nil
            // An in-flight status read may finish, but its response cannot revive this task.
            // The monitor naturally excludes stopped tasks while continuing other jobs.
            startMonitoring()
        } catch {
            storageUnavailable = true
            message = AreaTargetLocalError.diskPersistence.localizedDescription
        }
    }

    func setAppActive(_ value: Bool) {
        active = value
        if value { startMonitoring() }
        else { stopMonitoring(); pause() }
    }

    func start(scanDirectory: URL, displayName: String, profile: AreaTargetProcessingProfile = .quality, uvUnwrap: Bool = true, mapCLAHE: Bool = false) async {
        await restoration?.value
        guard !operationInProgress, !isAuthenticating, !storageUnavailable, requireSignIn(origin: .current) else { return }
        message = nil
        if let existing = jobs.first(where: { $0.scanDirectoryPath == scanDirectory.path && $0.isPending }) {
            selectedJobID = existing.id
            if existing.profile != profile.rawValue || existing.uvUnwrap != uvUnwrap || existing.mapCLAHE != mapCLAHE {
                let title = AreaTargetProcessingProfile(rawValue: existing.profile)?.title ?? existing.profile
                let uvState = existing.uvUnwrap ? "开启" : "关闭"
                let mapState = existing.mapCLAHE ? "开启" : "关闭"
                message = "该扫描已有未完成任务，使用 \(title) 模式，UV 与纹理重建已\(uvState)，光照增强已\(mapState)。继续原任务会保留这些设置，完成后可新建任务调整。"
            }
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scanDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            message = AreaTargetLocalError.missingScan.localizedDescription
            return
        }
        let id = UUID().uuidString.lowercased()
        do {
            let token = try Self.makeToken()
            try tokenStore.save(token, jobID: id)
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            var job = AreaTargetProcessingJob(id: id, scanDirectoryPath: scanDirectory.path,
                displayName: String((name.isEmpty ? scanDirectory.lastPathComponent : name).prefix(120)), createdAt: Date(), serverOrigin: .current)
            job.profile = profile.rawValue
            job.uvUnwrap = uvUnwrap
            job.mapCLAHE = mapCLAHE
            do { try replace(job) }
            catch { try? tokenStore.remove(jobID: id); throw error }
            selectedJobID = id
            await runTransfer(jobID: id) { generation in await self.prepareAndUpload(jobID: id, generation: generation) }
        } catch { message = safeMessage(error) }
    }

    func resume(jobID: String) async {
        await restoration?.value
        guard !operationInProgress, !storageUnavailable, let job = jobs.first(where: { $0.id == jobID }) else { return }
        selectedJobID = jobID
        message = nil
        guard ![.downloaded, .stopped].contains(job.phase) else { return }
        guard !isAuthenticating, requireSignIn(origin: job.serverOrigin) else { return }
        let statusRequestID = beginStatusRequest(jobID: jobID)
        resumeStatusRequestIDs[jobID] = statusRequestID
        defer {
            if resumeStatusRequestIDs[jobID] == statusRequestID { resumeStatusRequestIDs.removeValue(forKey: jobID) }
            finishStatusRequest(statusRequestID, jobID: jobID)
        }
        do {
            let token = try requiredToken(jobID)
            do {
                let remote = try await api(for: job).status(jobID: jobID, token: token)
                try Task.checkCancellation()
                guard isCurrentStatusRequest(statusRequestID, jobID: jobID) else { return }
                try accept(remote, jobID: jobID)
                return
            } catch {
                guard isCurrentStatusRequest(statusRequestID, jobID: jobID) else { return }
                guard isNotFound(error), !job.accepted else { throw error }
            }
            // The ID and capability are unchanged even when the first response was lost.
            guard !storageUnavailable, isCurrentStatusRequest(statusRequestID, jobID: jobID) else { return }
            await runTransfer(jobID: jobID) { generation in await self.prepareAndUpload(jobID: jobID, generation: generation) }
        } catch {
            guard isCurrentStatusRequest(statusRequestID, jobID: jobID) else { return }
            markExpiredIfNeeded(error, jobID: jobID)
            message = safeMessage(error)
        }
    }

    func refresh(jobID: String) async {
        await restoration?.value
        // A status poll must not supersede the reconciliation of an explicit retry.
        guard !storageUnavailable, transferID != jobID, resumeStatusRequestIDs[jobID] == nil,
              let job = jobs.first(where: { $0.id == jobID }), ![.downloaded, .stopped].contains(job.phase) else { return }
        guard !isAuthenticating, requireSignIn(origin: job.serverOrigin) else { return }
        let statusRequestID = beginStatusRequest(jobID: jobID)
        defer { finishStatusRequest(statusRequestID, jobID: jobID) }
        do {
            let remote = try await api(for: job).status(jobID: jobID, token: requiredToken(jobID))
            try Task.checkCancellation()
            guard isCurrentStatusRequest(statusRequestID, jobID: jobID) else { return }
            try accept(remote, jobID: jobID)
        } catch {
            if Self.isCancellation(error) || !isCurrentStatusRequest(statusRequestID, jobID: jobID) { return }
            if var stored = jobs.first(where: { $0.id == jobID }) {
                stored.detail = safeMessage(error)
                if stored.accepted && (isNotFound(error) || isExpired(error)) {
                    stored.phase = .failed
                    stored.detail = "云端任务或结果已过期。已下载的资产仍保存在本机；需要新的结果时请重新上传。"
                }
                try? replace(stored)
            }
            message = safeMessage(error)
        }
    }

    func download(jobID: String) async {
        await restoration?.value
        guard !operationInProgress, !storageUnavailable,
              let job = jobs.first(where: { $0.id == jobID }), job.phase != .stopped else { return }
        selectedJobID = jobID
        // An already verified local artifact does not depend on cloud retention.
        if job.phase == .downloaded, job.savedAsset != nil { return }
        guard !isAuthenticating, requireSignIn(origin: job.serverOrigin) else { return }
        message = nil
        await runTransfer(jobID: jobID) { generation in
            let statusRequestID = self.beginStatusRequest(jobID: jobID)
            defer { self.finishStatusRequest(statusRequestID, jobID: jobID) }
            var temporary: URL?
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            do {
                let token = try self.requiredToken(jobID)
                let remote = try await self.api(for: job).status(jobID: jobID, token: token)
                try Task.checkCancellation()
                guard self.isCurrentStatusRequest(statusRequestID, jobID: jobID) else { return }
                try self.accept(remote, jobID: jobID)
                guard remote.status == .completed, let result = remote.result else {
                    throw AreaTargetAPIError.server(statusCode: 409,
                        problem: .init(code: "result_not_ready", message: "处理尚未完成", retryable: true), retryAfter: nil)
                }
                guard result.expiresAt > Date() else {
                    throw AreaTargetAPIError.server(statusCode: 410,
                        problem: .init(code: "result_expired", message: "结果已过期", retryable: false), retryAfter: nil)
                }
                try self.edit(jobID) { $0.phase = .downloading; $0.transferProgress = 0; $0.detail = "正在下载资产包…" }
                let file = try await self.api(for: job).download(jobID: jobID, token: token, result: result) { [weak self] progress in
                    Task { @MainActor in self?.updateProgress(progress, jobID: jobID, generation: generation) }
                }
                temporary = file
                try Task.checkCancellation()
                let work = AreaTargetAssetWork(store: self.assetStore)
                let saved = try await Task.detached(priority: .utility) {
                    try work.store.save(downloadURL: file, jobID: jobID, result: result)
                }.value
                // Atomic publication has committed: record the verified local asset even
                // when cancellation arrived while the store was saving it.
                try self.edit(jobID) { $0.savedAsset = saved; $0.phase = .downloaded; $0.transferProgress = 1; $0.detail = "资产包已保存到本机" }
            } catch {
                guard self.generation == generation, self.isCurrentStatusRequest(statusRequestID, jobID: jobID) else { return }
                let text = Self.isCancellation(error) ? "下载已暂停，可以继续下载" : self.safeMessage(error)
                try? self.edit(jobID) {
                    $0.phase = $0.savedAsset == nil ? .ready : .downloaded
                    $0.detail = text
                }
                self.markExpiredIfNeeded(error, jobID: jobID)
                if !Self.isCancellation(error) { self.message = text }
            }
        }
    }

    func pause() {
        guard let id = transferID, let job = jobs.first(where: { $0.id == id }) else { return }
        cancellation?.cancel()
        transfer?.cancel()
        do {
            try edit(id) { stored in
                switch job.phase {
                case .uploading:
                    stored.phase = .submissionUnknown
                    stored.detail = "本机上传已暂停。继续时会先确认云端是否已接收。"
                case .preparing:
                    stored.phase = .paused
                    stored.detail = "准备已暂停，可继续上传"
                case .downloading:
                    stored.phase = stored.savedAsset == nil ? .ready : .downloaded
                    stored.detail = "下载已暂停，可以继续下载"
                default: break
                }
            }
        } catch { storageUnavailable = true; message = AreaTargetLocalError.diskPersistence.localizedDescription }
    }

    func startMonitoring() {
        guard active, monitoring == nil, !storageUnavailable, jobs.contains(where: {
            ((!requiresServiceAuthentication(for: $0.serverOrigin) || serviceSession(for: $0.serverOrigin) != nil)) &&
            (($0.accepted && $0.phase == .processing) || $0.phase == .submissionUnknown)
        }) else { return }
        monitoring = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active else { return }
                let pending = self.jobs.filter {
                    (!self.requiresServiceAuthentication(for: $0.serverOrigin) || self.serviceSession(for: $0.serverOrigin) != nil) &&
                    (($0.accepted && $0.phase == .processing) || $0.phase == .submissionUnknown)
                }
                if pending.isEmpty { self.monitoring = nil; return }
                for job in pending {
                    if Task.isCancelled { return }
                    await self.refresh(jobID: job.id)
                }
                do { try await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    func stopMonitoring() { monitoring?.cancel(); monitoring = nil }

    private func beginStatusRequest(jobID: String) -> UUID {
        // Ignore older success and error responses once a newer read has begun.
        let id = UUID()
        statusRequestIDs[jobID] = id
        return id
    }

    private func isCurrentStatusRequest(_ id: UUID, jobID: String) -> Bool {
        statusRequestIDs[jobID] == id && jobs.contains { $0.id == jobID && $0.phase != .stopped }
    }

    private func finishStatusRequest(_ id: UUID, jobID: String) {
        if statusRequestIDs[jobID] == id { statusRequestIDs.removeValue(forKey: jobID) }
    }

    private func runTransfer(jobID: String, action: @escaping @MainActor (UUID) async -> Void) async {
        guard !operationInProgress else { return }
        let nextGeneration = UUID()
        generation = nextGeneration
        transferID = jobID
        cancellation = ScanExportCancellation()
        operationInProgress = true
        let task = Task { await action(nextGeneration) }
        transfer = task
        await task.value
        if generation == nextGeneration {
            transfer = nil
            transferID = nil
            cancellation = nil
            generation = nil
            operationInProgress = false
        }
    }

    private func prepareAndUpload(jobID: String, generation: UUID) async {
        var sending = false
        var unretainedArchive: URL?
        defer { if let file = unretainedArchive { try? FileManager.default.removeItem(at: file) } }
        do {
            let token = try requiredToken(jobID)
            guard var job = jobs.first(where: { $0.id == jobID }), let cancellation else { return }
            // Revalidate the opt-in capability even when a prepared archive is reused.
            var negotiatedMapRequirements: AreaTargetProcessingRequirements?
            if job.mapCLAHE {
                try edit(jobID) { $0.detail = "正在确认云端光照增强能力…" }
                let requirements = try await processingRequirements(for: job)
                try Task.checkCancellation()
                guard self.generation == generation, !cancellation.isCancelled else { throw CancellationError() }
                guard requirements.mapCLAHESupported else {
                    let detail = "云端当前不支持光照增强（实验）。请使用关闭选项新建任务，或在服务支持后重新建图。"
                    try edit(jobID) { $0.phase = .failed; $0.detail = detail }
                    message = detail
                    return
                }
                negotiatedMapRequirements = requirements
            }
            var archiveURL: URL
            if let existing = job.archiveURL {
                guard FileManager.default.fileExists(atPath: existing.path), let digest = job.archiveSHA256,
                      try await Task.detached(priority: .utility, operation: { try Self.fileDigest(existing) }).value == digest else {
                    throw AreaTargetLocalError.archiveChanged
                }
                archiveURL = existing
            } else {
                try edit(jobID) { $0.phase = .preparing; $0.detail = "正在获取云端预处理要求…" }
                let requirements: AreaTargetProcessingRequirements
                if let negotiatedMapRequirements { requirements = negotiatedMapRequirements }
                else { requirements = try await processingRequirements(for: job) }
                try Task.checkCancellation()
                guard self.generation == generation, !cancellation.isCancelled else { throw CancellationError() }
                guard requirements.profiles[job.profile] != nil else {
                    let title = AreaTargetProcessingProfile(rawValue: job.profile)?.title ?? job.profile
                    let detail = "云端当前未提供 \(title) 处理模式。请选择其他模式新建任务，或在服务支持后重新处理。"
                    try edit(jobID) { $0.phase = .failed; $0.detail = detail }
                    message = detail
                    return
                }
                guard requirements.preparationPolicy(for: job.profile) != nil else { throw AreaTargetAPIError.invalidResponse }
                let preparationCapability: String?
                if let policy = requirements.preparationPolicy(for: job.profile) {
                    preparationCapability = requirements.policyVersion == 2
                        ? "云端当前支持去重后最多 \(policy.maxFrames) 个工作视角；正在准备全部源帧上传…"
                        : "云端采用旧版处理，最多保留 \(policy.maxFrames) 帧；正在准备上传副本…"
                    try edit(jobID) { $0.detail = preparationCapability! }
                } else { preparationCapability = nil }
                let work = AreaTargetArchiveWork(archiver: archiver)
                let directory = job.scanDirectory
                let unwrap = job.uvUnwrap
                let profile = job.profile
                let progressSink: @Sendable (String) -> Void = { [weak self] detail in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        self.updateDetail(preparationCapability.map { $0 + "\n" + detail } ?? detail, jobID: jobID)
                    }
                }
                let prepared = try await Task.detached(priority: .utility) {
                    let source = try? ScanSourceFingerprint.compute(directory: directory, isCancelled: { cancellation.isCancelled })
                    let file = try work.archiver.archive(scanDirectory: directory, uvUnwrap: unwrap, profile: profile, requirements: requirements,
                        progress: progressSink, isCancelled: { cancellation.isCancelled })
                    do {
                        if let source {
                            guard try ScanSourceFingerprint.compute(directory: directory, isCancelled: { cancellation.isCancelled }) == source else {
                                throw ScanSourceFingerprint.Failure.changed
                            }
                        }
                        return (file, source, try AreaTargetScanArchive.clientPreparation(in: file))
                    } catch { try? FileManager.default.removeItem(at: file); throw error }
                }.value
                let temporary = prepared.0
                unretainedArchive = temporary
                try Task.checkCancellation()
                let destination = uploadDirectory.appendingPathComponent(jobID + "-" + UUID().uuidString.lowercased() + ".zip")
                archiveURL = try await Task.detached(priority: .utility) {
                    let fm = FileManager.default
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    var parent = destination.deletingLastPathComponent()
                    var values = URLResourceValues(); values.isExcludedFromBackup = true
                    try parent.setResourceValues(values)
                    do {
                        try fm.moveItem(at: temporary, to: destination)
                        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
                        return destination
                    } catch {
                        try? fm.removeItem(at: destination)
                        throw error
                    }
                }.value
                unretainedArchive = archiveURL
                let digest = try await Task.detached(priority: .utility, operation: { try Self.fileDigest(archiveURL) }).value
                try edit(jobID) {
                    $0.archivePath = archiveURL.path; $0.archiveSHA256 = digest; $0.sourceFingerprint = prepared.1
                    $0.clientPreparation = prepared.2
                }
                unretainedArchive = nil
            }
            try Task.checkCancellation()
            guard !cancellation.isCancelled else { throw CancellationError() }
            job = jobs.first { $0.id == jobID }!
            try edit(jobID) { $0.phase = .uploading; $0.transferProgress = 0; $0.detail = "正在上传扫描数据…" }
            sending = true
            let remote = try await api(for: job).submit(archiveURL: archiveURL, jobID: jobID, token: token,
                profile: job.profile, uvUnwrap: job.uvUnwrap, mapCLAHE: job.mapCLAHE) { [weak self] progress in
                Task { @MainActor in self?.updateProgress(progress, jobID: jobID, generation: generation) }
            }
            try Task.checkCancellation()
            try accept(remote, jobID: jobID)
        } catch {
            guard self.generation == generation else { return }
            let text: String
            if Self.isCancellation(error) { text = sending ? "本机上传已暂停。继续时会先确认云端是否已接收。" : "准备已暂停，可以继续上传" }
            else if !sending, error is AreaTargetAPIError, jobs.first(where: { $0.id == jobID })?.archiveURL == nil {
                text = "尚未确认云端处理能力，上传尚未开始。" + safeMessage(error)
            } else { text = safeMessage(error) }
            let phase: AreaTargetTaskPhase
            if sending, !definitelyRejected(error) { phase = .submissionUnknown }
            else if Self.isCancellation(error) { phase = .paused }
            else { phase = (error as? AreaTargetLocalError == .archiveChanged || error is AreaTargetScanArchive.ArchiveError || permanentlyRejected(error)) ? .failed : .paused }
            do {
                try edit(jobID) { $0.phase = phase; $0.detail = text }
                if phase == .submissionUnknown { startMonitoring() }
            } catch { storageUnavailable = true }
            if !Self.isCancellation(error) { message = text }
        }
    }

    private func processingRequirements(for job: AreaTargetProcessingJob) async throws -> AreaTargetProcessingRequirements {
        do { return try await api(for: job).fetchProcessingRequirements(policy: "mobile-scan-preparation-v2") }
        catch {
            if case AreaTargetAPIError.server(let status, let problem, _) = error,
               status == 400, problem.code == "unsupported_preparation_policy" {
                return try await api(for: job).fetchProcessingRequirements()
            }
            throw error
        }
    }

    private func accept(_ remote: AreaTargetRemoteJob, jobID: String) throws {
        guard let stored = jobs.first(where: { $0.id == jobID }), stored.phase != .stopped else { return }
        guard remote.jobID == jobID, remote.profile == stored.profile, remote.uvUnwrap == stored.uvUnwrap,
              remote.mapCLAHE == stored.mapCLAHE else { throw AreaTargetAPIError.invalidResponse }
        let archive = stored.archiveURL
        try edit(jobID) {
            $0.accepted = true
            $0.archivePath = nil
            $0.archiveSHA256 = nil
            $0.remote = remote
            $0.detail = Self.stageMessage(remote.stage)
            $0.transferProgress = 1
            switch remote.status {
            case .queued, .extracting, .processing: $0.phase = .processing
            case .completed: $0.phase = $0.savedAsset == nil ? .ready : .downloaded
            case .failed:
                $0.phase = .failed
                switch remote.error?.code {
                case "invalid_scan": $0.detail = "云端检测到扫描数据无效，请检查模型、图像和相机数据后重新提交。"
                case "processing_interrupted": $0.detail = "服务器处理已中断，请重新提交任务。"
                default: $0.detail = "服务器未能完成处理，请稍后重新提交。"
                }
            }
        }
        if let archive { try? FileManager.default.removeItem(at: archive) }
        startMonitoring()
    }

    private func restoreAssets() async {
        let snapshot = jobs
        let work = AreaTargetAssetWork(store: assetStore)
        let restored = await Task.detached(priority: .utility) {
            snapshot.map { job -> (String, AreaTargetSavedAsset?, Bool) in
                do { return (job.id, try work.store.asset(jobID: job.id), false) }
                catch { return (job.id, nil, true) }
            }
        }.value
        for (id, asset, invalid) in restored {
            guard var job = jobs.first(where: { $0.id == id }) else { continue }
            if let asset {
                job.savedAsset = asset
                if job.phase != .stopped { job.phase = .downloaded; job.detail = "资产包已保存到本机" }
            } else if job.savedAsset != nil || job.phase == .downloaded {
                job.savedAsset = nil
                if job.phase != .stopped {
                    job.phase = .ready
                    job.detail = invalid ? "本机资产校验未通过，可以重新下载" : "本机资产文件不存在，可以重新下载"
                } else {
                    job.detail = "已停止本机跟踪。本机资产无法恢复；可以重新处理仍保留的原扫描。"
                }
            }
            guard job != jobs.first(where: { $0.id == id }) else { continue }
            do { try replace(job) }
            catch { storageUnavailable = true; message = AreaTargetLocalError.diskPersistence.localizedDescription }
        }
        isRestoringAssets = false
    }

    private func markExpiredIfNeeded(_ error: Error, jobID: String) {
        guard isExpired(error) || isNotFound(error), let job = jobs.first(where: { $0.id == jobID }), job.accepted, job.phase != .stopped else { return }
        try? edit(jobID) {
            $0.phase = $0.savedAsset == nil ? .failed : .downloaded
            $0.detail = "云端任务或结果已过期。已下载的资产仍保存在本机；需要新的结果时请重新上传。"
        }
    }

    private static func stageMessage(_ stage: String) -> String {
        switch stage {
        case "queued": return "等待云端处理"
        case "extracting": return "正在读取扫描数据"
        case "uv_unwrap": return "正在生成模型纹理"
        case "model_optimization": return "正在优化模型"
        case "feature_extraction": return "正在生成空间定位数据"
        case "packaging": return "正在生成资产包"
        case "completed": return "处理完成，可以下载到本机"
        default: return "云端处理中"
        }
    }

    private func api(for job: AreaTargetProcessingJob) -> AreaTargetAPI {
        api(for: job.serverOrigin)
    }

    private func api(for origin: AreaTargetServerOrigin) -> AreaTargetAPI {
        origin == .legacy ? legacyAPI : api
    }

    private func requireSignIn(origin: AreaTargetServerOrigin) -> Bool {
        guard requiresServiceAuthentication(for: origin) else { return true }
        do {
            serviceSessions[origin] = try api(for: origin).savedServiceSession()
            guard serviceSession(for: origin) != nil else {
                message = AreaTargetAPIError.authenticationRequired.localizedDescription
                stopMonitoring()
                return false
            }
            return true
        } catch { message = safeMessage(error); return false }
    }

    private func requiredToken(_ id: String) throws -> String {
        guard let token = try tokenStore.token(jobID: id), AreaTargetJobStore.validToken(token) else {
            throw AreaTargetLocalError.credentialsUnavailable
        }
        return token
    }

    private func replace(_ job: AreaTargetProcessingJob) throws {
        var next = jobs.filter { $0.id != job.id }
        next.append(job)
        next.sort { $0.createdAt > $1.createdAt }
        do { try jobStore.save(next) }
        catch { throw AreaTargetLocalError.diskPersistence }
        jobs = next
    }

    private func edit(_ id: String, update: (inout AreaTargetProcessingJob) -> Void) throws {
        guard var job = jobs.first(where: { $0.id == id }) else { throw AreaTargetLocalError.invalidJournal }
        update(&job)
        try replace(job)
    }

    private func updateProgress(_ value: Double, jobID: String, generation: UUID) {
        guard self.generation == generation, let index = jobs.firstIndex(where: { $0.id == jobID }), value.isFinite else { return }
        jobs[index].transferProgress = min(1, max(0, value))
    }

    private func updateDetail(_ detail: String, jobID: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].detail = detail
    }

    private func safeMessage(_ error: Error) -> String {
        if Self.isServiceAuthenticationError(error) {
            for origin in AreaTargetServerOrigin.allCases { serviceSessions[origin] = try? api(for: origin).savedServiceSession() }
            stopMonitoring()
        }
        if error is AreaTargetLocalError || error is AreaTargetAPIError || error is AreaTargetScanArchive.ArchiveError { return error.localizedDescription }
        return "本机操作未完成，请检查可用空间和网络连接后重试。"
    }

    private func isNotFound(_ error: Error) -> Bool {
        if case AreaTargetAPIError.server(let status, _, _) = error { return status == 404 }
        return false
    }

    private func isExpired(_ error: Error) -> Bool {
        if case AreaTargetAPIError.server(let status, _, _) = error { return status == 410 }
        return false
    }

    private func permanentlyRejected(_ error: Error) -> Bool {
        if Self.isServiceAuthenticationError(error) { return false }
        if case AreaTargetAPIError.server(let status, _, _) = error { return [400, 401, 409, 413].contains(status) }
        return false
    }

    private func definitelyRejected(_ error: Error) -> Bool {
        if Self.isServiceAuthenticationError(error) { return true }
        if case AreaTargetAPIError.server(let status, _, _) = error { return [400, 401, 404, 409, 413, 429].contains(status) }
        return false
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? AreaTargetScanArchive.ArchiveError) == .cancelled || (error as? AreaTargetAPIError) == .cancelled || ((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled)
    }

    private static func isServiceAuthenticationError(_ error: Error) -> Bool {
        if (error as? AreaTargetAPIError) == .authenticationRequired { return true }
        if case AreaTargetAPIError.server(_, let problem, _) = error { return problem.code == "authentication_required" }
        return false
    }

    private static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AreaTargetLocalError.credentialsUnavailable
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func fileDigest(_ url: URL) throws -> String {
        try AreaTargetFileSafety.digest(url, maximum: AreaTargetFileSafety.maximumZIPBytes,
            isCancelled: { Task.isCancelled }).sha256
    }

}

/// These collaborators are used by one owned transfer at a time, off the UI actor.
private final class AreaTargetArchiveWork: @unchecked Sendable {
    let archiver: AreaTargetArchiving
    init(archiver: AreaTargetArchiving) { self.archiver = archiver }
}

private final class AreaTargetAssetWork: @unchecked Sendable {
    let store: AreaTargetAssetStoring
    init(store: AreaTargetAssetStoring) { self.store = store }
}
