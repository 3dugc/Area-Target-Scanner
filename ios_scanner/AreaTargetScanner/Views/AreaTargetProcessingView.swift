import SwiftUI

@MainActor
struct AreaTargetProcessingView: View {
    enum EntryPoint { case preparation, tasks }
    @ObservedObject var model: AreaTargetProcessingModel
    let scanDirectory: URL?
    let displayName: String
    var entryPoint: EntryPoint = .preparation
    var selectScan: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showingTasks = false
    @State private var sharePayload: SharePayload?
    @State private var stoppingJob: AreaTargetProcessingJob?
    @State private var username = ""
    @State private var password = ""

    private var currentJob: AreaTargetProcessingJob? {
        if entryPoint == .tasks || showingTasks { return model.selectedJob }
        return scanDirectory.flatMap { model.job(for: $0.path) }
    }

    private var serviceOrigin: AreaTargetServerOrigin { currentJob?.serverOrigin ?? .current }
    private var needsServiceLogin: Bool {
        model.requiresServiceAuthentication(for: serviceOrigin) && model.serviceSession(for: serviceOrigin) == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let scanDirectory, entryPoint == .preparation, !showingTasks {
                        if currentJob == nil {
                            preparationSummary(scanDirectory)
                        } else {
                            Label(displayName.isEmpty ? ScanHistoryItem.displayName(for: scanDirectory.lastPathComponent) : displayName,
                                  systemImage: "cube")
                                .font(.headline).accessibilityIdentifier("area-target-scene")
                        }
                    }
                    if model.requiresServiceAuthentication(for: serviceOrigin) { serviceLogin }
                    if entryPoint == .tasks || showingTasks { taskHistory }
                    if let job = currentJob { taskDetails(job) }
                    else if model.jobs.isEmpty && (scanDirectory == nil || entryPoint == .tasks || showingTasks) {
                        AreaTargetEmptyState(title: "暂无处理任务", message: "从扫描记录选择场景，然后上传处理。", symbol: "icloud")
                    }
                    if model.isRestoringAssets {
                        HStack { ProgressView(); Text("正在检查本机资产…") }
                    }
                    if let message = model.message {
                        Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("area-target-message")
                        Button("关闭提示") { model.message = nil }.frame(minHeight: 44)
                    }
                }
                .padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(entryPoint == .tasks || showingTasks ? "Area Target 任务" : "Area Target 处理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if entryPoint == .preparation {
                        Button(showingTasks ? "当前场景" : "任务") { showingTasks.toggle() }
                            .disabled(model.operationInProgress).accessibilityIdentifier("area-target-show-tasks")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.disabled(model.operationInProgress)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { actionFooter }
        }
        .interactiveDismissDisabled(model.operationInProgress)
        .sheet(item: $sharePayload) { ActivityView(activityItems: $0.activityItems) }
        .confirmationDialog("停止本机跟踪？", isPresented: Binding(
            get: { stoppingJob != nil }, set: { if !$0 { stoppingJob = nil } }),
            titleVisibility: .visible, presenting: stoppingJob) { job in
                Button("停止本机跟踪", role: .destructive) {
                    model.stopLocalTracking(jobID: job.id)
                    stoppingJob = nil
                }
                Button("继续保留任务", role: .cancel) { stoppingJob = nil }
            } message: { _ in
                Text("只停止这项任务的本机跟踪，原扫描和已下载资产会保留。此操作不会取消云端处理；云端任务可能仍会继续。之后重新处理会创建新任务。")
            }
        .task(id: serviceOrigin) { await model.restoreServiceLogin(origin: serviceOrigin) }
        .onChange(of: serviceOrigin) { _ in password = "" }
        .onDisappear { password = "" }
    }

    private func preparationSummary(_ directory: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AreaTargetSectionHeading(title: "准备处理扫描", subtitle: "先确认这条扫描，登录后上传云端处理，再下载资产到本机。")
            Label(displayName.isEmpty ? directory.lastPathComponent : displayName, systemImage: "cube")
                .font(.headline).accessibilityIdentifier("area-target-scene")
            Text("上传和下载时请保持 App 在前台。云端处理开始后，可以稍后回来查看。")
                .foregroundStyle(Color(uiColor: .secondaryLabel))
            Text("App 会按服务要求为上传准备扫描副本，保留原始扫描。上传扫描包上限 512 MB。")
                .font(.footnote).foregroundStyle(Color(uiColor: .secondaryLabel))
            Text("结果包含模型、纹理和空间定位数据。请在任务显示的保存期限内下载；下载后会保存在本机。")
                .font(.footnote).foregroundStyle(Color(uiColor: .secondaryLabel))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var serviceLogin: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = model.serviceSession(for: serviceOrigin) {
                Label("已登录 · \(session.username)", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline).accessibilityIdentifier("area-target-signed-in")
                Text(serviceOrigin.baseURL.host ?? "Area Target").font(.caption).foregroundStyle(Color(uiColor: .secondaryLabel))
                Button("退出登录") {
                    password = ""
                    Task { await model.signOut(origin: serviceOrigin) }
                }.frame(minHeight: 44).accessibilityIdentifier("area-target-sign-out")
            } else {
                Text("登录 Area Target 服务").font(.headline)
                Text("使用服务管理员提供的账号登录后，即可上传、查询和下载云端任务。")
                    .font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
                VStack(alignment: .leading, spacing: 6) {
                    Text("服务用户名").font(.subheadline.weight(.semibold))
                    TextField("输入用户名", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("area-target-login-username")
                        .accessibilityLabel("服务用户名")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("服务密码").font(.subheadline.weight(.semibold))
                    SecureField("输入密码", text: $password)
                        .textContentType(.password).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("area-target-login-password").accessibilityLabel("服务密码")
                }
                AreaTargetActionButton(title: "登录", symbol: "person.crop.circle") {
                    let origin = serviceOrigin
                    Task {
                        await model.signIn(username: username, password: password, origin: origin)
                        password = ""
                    }
                }
                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                .accessibilityIdentifier("area-target-sign-in")
            }
            if model.isAuthenticating {
                HStack { ProgressView(); Text("正在验证服务登录…") }.font(.subheadline)
            }
            if let message = model.authenticationMessage {
                Text(message).font(.subheadline).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("area-target-login-message")
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .disabled(model.operationInProgress || model.isAuthenticating)
    }

    private var taskHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.jobs) { job in
                Button { model.selectJob(job.id) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: job.phase == .downloaded ? "checkmark.circle.fill" : "icloud")
                            .foregroundStyle(job.phase == .downloaded ? Color.green : Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.displayName).font(.headline).foregroundStyle(.primary)
                            Text(job.phase.title).font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
                            Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(Color(uiColor: .secondaryLabel))
                        }
                        Spacer()
                        if model.selectedJobID == job.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain).disabled(model.operationInProgress)
                .accessibilityIdentifier("area-target-task-\(job.id)")
            }
        }
    }

    private func taskDetails(_ job: AreaTargetProcessingJob) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AreaTargetSectionHeading(title: job.phase.title, subtitle: job.displayName)
            if [.uploading, .downloading].contains(job.phase) {
                ProgressView(value: job.transferProgress)
                Text("\(Int(job.transferProgress * 100))%").font(.caption.monospacedDigit())
            } else if job.phase == .processing, let remote = job.remote {
                ProgressView(value: Double(remote.progress), total: 100)
                Text("\(remote.progress)%").font(.caption.monospacedDigit())
            }
            Text(job.detail).foregroundStyle(Color(uiColor: .secondaryLabel)).fixedSize(horizontal: false, vertical: true)
            if let result = job.remote?.result, job.savedAsset == nil, job.phase != .stopped {
                Text("请在 \(result.expiresAt.formatted(date: .abbreviated, time: .shortened)) 前下载。")
                    .font(.footnote).foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            if job.phase == .downloaded {
                Label("模型和定位数据已保存，可导出资产包。", systemImage: "checkmark.shield")
                    .font(.subheadline).foregroundStyle(.green)
            }
            if job.phase == .submissionUnknown {
                Text("继续时会先确认云端是否已接收本次上传。")
                    .font(.footnote).foregroundStyle(Color(uiColor: .secondaryLabel))
            }
        }.accessibilityIdentifier("area-target-task-detail")
    }

    private var actionFooter: some View {
        VStack(spacing: 8) {
            if model.operationInProgress {
                AreaTargetActionButton(title: "暂停本机操作", symbol: "pause.circle") { model.pause() }
                    .accessibilityIdentifier("area-target-pause")
                Text("暂停本机传输后，已经开始的云端处理会继续。")
                    .font(.caption).foregroundStyle(Color(uiColor: .secondaryLabel))
            } else if currentJob == nil, scanDirectory == nil, let selectScan {
                AreaTargetActionButton(title: "选择扫描", symbol: "square.stack.3d.up") {
                    dismiss()
                    selectScan()
                }.accessibilityIdentifier("area-target-select-scan")
            } else if needsServiceLogin && ![.downloaded, .stopped].contains(currentJob?.phase ?? .preparing) {
                Text("请先登录服务，再继续云端任务。")
                    .font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel)).accessibilityIdentifier("area-target-login-required")
            } else if let job = currentJob {
                switch job.phase {
                case .ready, .downloading:
                    AreaTargetActionButton(title: "下载到本机", symbol: "icloud.and.arrow.down") {
                        Task { await model.download(jobID: job.id) }
                    }.accessibilityIdentifier("area-target-download")
                case .downloaded:
                    if let asset = job.savedAsset {
                        AreaTargetActionButton(title: "导出资产包", symbol: "square.and.arrow.up") {
                            sharePayload = SharePayload(activityItems: [asset.bundleURL])
                        }.accessibilityIdentifier("area-target-share-result")
                    }
                case .paused, .submissionUnknown, .preparing, .uploading:
                    AreaTargetActionButton(title: "检查并继续上传", symbol: "icloud.and.arrow.up") {
                        Task { await model.resume(jobID: job.id) }
                    }.accessibilityIdentifier("area-target-resume")
                case .processing:
                    AreaTargetActionButton(title: "刷新处理进度", symbol: "arrow.clockwise") {
                        Task { await model.refresh(jobID: job.id) }
                    }.accessibilityIdentifier("area-target-refresh")
                case .stopped:
                    if let asset = job.savedAsset {
                        AreaTargetActionButton(title: "导出资产包", symbol: "square.and.arrow.up") {
                            sharePayload = SharePayload(activityItems: [asset.bundleURL])
                        }.accessibilityIdentifier("area-target-share-result")
                    }
                    if FileManager.default.fileExists(atPath: job.scanDirectoryPath) {
                        if needsServiceLogin {
                            Text("请先登录服务，再重新处理这条扫描。")
                                .font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
                                .accessibilityIdentifier("area-target-login-required")
                        } else {
                            AreaTargetActionButton(title: "重新处理此扫描", symbol: "icloud.and.arrow.up") {
                                Task { await model.start(scanDirectory: job.scanDirectory, displayName: job.displayName) }
                            }.accessibilityIdentifier("area-target-process-again")
                        }
                    }
                case .failed:
                    if FileManager.default.fileExists(atPath: job.scanDirectoryPath) {
                        AreaTargetActionButton(title: "重新上传处理", symbol: "icloud.and.arrow.up") {
                            Task { await model.start(scanDirectory: job.scanDirectory, displayName: job.displayName) }
                        }.accessibilityIdentifier("area-target-restart")
                    }
                }
            } else if let scanDirectory, entryPoint == .preparation, !showingTasks {
                AreaTargetActionButton(title: "上传并处理", symbol: "icloud.and.arrow.up") {
                    Task { await model.start(scanDirectory: scanDirectory, displayName: displayName) }
                }.accessibilityIdentifier("area-target-submit")
            }
            if !model.operationInProgress, let job = currentJob, job.canStopLocalTracking {
                Button("停止本机跟踪…", role: .destructive) { stoppingJob = job }
                    .frame(minHeight: 44).accessibilityIdentifier("area-target-stop-local-tracking")
            }
        }
        .disabled(model.isRestoringAssets || model.isAuthenticating)
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: 640).frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct AreaTargetSectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(subtitle).foregroundStyle(Color(uiColor: .secondaryLabel))
        }
    }
}

private struct AreaTargetActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
    }
}

private struct AreaTargetEmptyState: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(Color(uiColor: .secondaryLabel))
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message).foregroundStyle(Color(uiColor: .secondaryLabel)).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
