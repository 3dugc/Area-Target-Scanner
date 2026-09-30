import SwiftUI

struct ImmersalMappingView: View {
    @ObservedObject var model: ImmersalMappingModel
    let scanDirectory: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var mapName = "MyScan"
    @State private var selectedJobID: UUID?
    @State private var showHistory = false
    @State private var sheet: Sheet?
    @State private var abandonJob: ImmersalMappingJob?
    @State private var summaryFrameCount: Int?
    @State private var summaryLoading = true

    private enum Sheet: String, Identifiable {
        case account, details
        var id: String { rawValue }
    }

    private enum Confirmation {
        case workspace(ImmersalWorkspaceConfirmation)
        case abandon(ImmersalMappingJob)

        var title: String {
            switch self {
            case .workspace: return "清空并上传本次扫描？"
            case .abandon: return "停止这项本机任务的跟踪？"
            }
        }

        var message: String {
            switch self {
            case .workspace(let prompt): return prompt.message + " 请停止其他设备的上传。"
            case .abandon(let job):
                return job.pendingOperation == .construct ?
                    "云端可能已经创建地图。请先在 Portal 核实，再停止本机跟踪；此操作不会取消云端建图。重新上传可能产生重复地图。扫描数据会保留。" :
                    "本地扫描会保留，已上传的图片也会保留在云端工作区。之后重新上传可能需要确认清空工作区。"
            }
        }
    }

    private var currentJob: ImmersalMappingJob? {
        if let selectedJobID, let selected = model.jobs.first(where: { $0.id == selectedJobID }) { return selected }
        guard let scanName = scanDirectory?.lastPathComponent else { return nil }
        return model.jobs.first(where: { $0.scanName == scanName && $0.needsSource }) ??
            model.jobs.first(where: { $0.scanName == scanName && $0.phase != .abandoned })
    }

    private var sourceDirectory: URL? {
        guard let job = currentJob else { return scanDirectory }
        let parent = scanDirectory?.deletingLastPathComponent() ??
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return parent?.appendingPathComponent(job.scanName)
    }

    private var frameCount: Int? {
        if let job = currentJob, job.frameCount > 0 { return job.frameCount }
        return summaryFrameCount
    }

    private var blockingJob: ImmersalMappingJob? {
        model.jobs.first { $0.needsSource && $0.id != currentJob?.id }
    }

    private var confirmation: Confirmation? {
        if let prompt = model.workspaceConfirmation { return .workspace(prompt) }
        return abandonJob.map { .abandon($0) }
    }

    var body: some View {
        // Capture the displayed prompt so an old dismissal cannot cancel a later confirmation.
        let presentedConfirmation = confirmation
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    stepIndicator
                    introduction
                    if sourceDirectory != nil { scanSummary }
                    if let job = currentJob { jobStatus(job) }
                    if let blockingJob { unfinishedTaskNotice(blockingJob) }
                    if let error = model.errorMessage { errorNotice(error) }
                    if sourceDirectory == nil && currentJob == nil { emptyScanNotice }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { actionFooter }
            .navigationTitle("Immersal 建图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("历史") { showHistory = true }.disabled(model.isBusy) }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    moreMenu.disabled(model.isBusy)
                    Button("完成") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showHistory) { historyView }
            .sheet(item: $sheet) { value in
                NavigationStack {
                    Group {
                        switch value {
                        case .account: accountView
                        case .details: detailsView
                        }
                    }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } }
                }
            }
            .confirmationDialog(presentedConfirmation?.title ?? "", isPresented: Binding(
                get: { confirmation != nil },
                set: { visible in
                    guard !visible else { return }
                    switch presentedConfirmation {
                    case .workspace(let prompt): model.cancelWorkspaceConfirmation(prompt)
                    case .abandon(let job): if abandonJob?.id == job.id { abandonJob = nil }
                    case nil: break
                    }
                }), titleVisibility: .visible, presenting: presentedConfirmation) { value in
                switch value {
                case .workspace(let prompt):
                    Button("清空并上传 \(prompt.frameCount) 帧", role: .destructive) {
                        model.restartAfterClearingWorkspace(jobID: prompt.jobID, confirmation: prompt)
                    }
                    Button("暂不上传", role: .cancel) { model.cancelWorkspaceConfirmation(prompt) }
                case .abandon(let job):
                    Button("确认停止本机任务", role: .destructive) { model.abandon(jobID: job.id); abandonJob = nil }
                    Button("取消", role: .cancel) { abandonJob = nil }
                }
            } message: { Text($0.message) }
            .task(id: sourceDirectory) { await readScanSummary() }
            .onAppear {
                email = model.email ?? ""
                if let prompt = model.workspaceConfirmation { selectedJobID = prompt.jobID }
                else if let id = model.activeJobID { selectedJobID = id }
            }
            .onChange(of: model.activeJobID) { id in if let id { selectedJobID = id } }
            .onChange(of: model.workspaceConfirmation) { prompt in
                if let prompt { selectedJobID = prompt.jobID }
            }
            .onChange(of: model.isLoggedIn) { loggedIn in
                if loggedIn { password = ""; if sheet == .account { sheet = nil } }
                else { selectedJobID = nil }
            }
            .onDisappear { password = ""; model.cancelWorkspaceConfirmation() }
        }
    }

    private var stepIndicator: some View {
        let stage = currentJob?.stage.rawValue ?? 1
        return HStack(alignment: .top, spacing: 0) {
            step(number: 1, name: "准备", current: stage)
            stepConnector(completed: stage > 1)
            step(number: 2, name: "上传", current: stage)
            stepConnector(completed: stage > 2)
            step(number: 3, name: "建图", current: stage)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(stage) 步，共 3 步：\(["准备", "上传", "建图"][stage - 1])")
    }

    private func step(number: Int, name: String, current: Int) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(number <= current ? Color.accentColor : Color(uiColor: .systemGray4))
                if number < current || (number == 3 && currentJob?.phase == .done) {
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                }
            }.frame(width: 36, height: 36)
            Text(name).font(.subheadline).foregroundStyle(number == current ? Color.accentColor : Color.secondary)
        }.frame(minWidth: 52)
    }

    private func stepConnector(completed: Bool) -> some View {
        Rectangle().fill(completed ? Color.accentColor : Color(uiColor: .systemGray4))
            .frame(height: 2).padding(.horizontal, 10).padding(.top, 17)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mainTitle).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.body).foregroundStyle(.secondary)
        }
    }

    private var mainTitle: String {
        guard let job = currentJob else { return "准备上传" }
        switch job.phase {
        case .paused: return job.uploadedCount > 0 ? "上传已暂停" : "准备上传"
        case .workspaceConflict: return "准备上传"
        case .captureUncertain: return "确认上传结果"
        case .uploading: return "上传中"
        case .constructing: return "提交建图"
        case .constructionUncertain: return "确认建图结果"
        case .pending: return "等待建图"
        case .processing, .sparse: return "建图中"
        case .done: return "地图已完成"
        case .failed: return "建图未完成"
        case .abandoned: return "准备上传"
        }
    }

    private var subtitle: String {
        guard let job = currentJob else { return "先确认本次扫描和云端工作区。" }
        switch job.phase {
        case .paused: return job.uploadedCount > 0 ? "进度已保存在本机，可以继续上传。" : "先确认本次扫描和云端工作区。"
        case .workspaceConflict: return "确认工作区后，继续上传本次扫描。"
        case .captureUncertain: return "先检查云端工作区，避免重复上传图片。"
        case .uploading: return "全部图片上传成功后会自动建图。请保持 App 在前台。"
        case .constructing: return "正在向 Immersal 提交本次建图。"
        case .constructionUncertain: return "正在核对云端结果，不会重复提交建图。"
        case .pending, .processing, .sparse: return "云端正在处理，离开此页面后建图会继续。"
        case .done: return "在 Immersal Portal 中查看和管理地图。"
        case .failed: return "在 Immersal Portal 查看失败原因和处理建议。"
        case .abandoned: return "本地扫描已保留，可以重新创建上传任务。"
        }
    }

    private var scanSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("本次扫描")
            VStack(spacing: 0) {
                summaryRow("扫描时间", symbol: "clock", value: scanDate)
                Divider().padding(.horizontal, 16)
                summaryRow("图片数量", symbol: "photo", value: frameCount.map { "\($0) 帧" } ?? (summaryLoading ? "读取中…" : "无法读取"))
                Divider().padding(.horizontal, 16)
                HStack(spacing: 14) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary).frame(width: 24)
                    Text("地图名称")
                    Spacer(minLength: 12)
                    if let job = currentJob, job.phase != .abandoned {
                        Text(job.displayName).multilineTextAlignment(.trailing)
                    } else {
                        TextField("MyScan", text: $mapName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .multilineTextAlignment(.trailing).frame(minWidth: 80)
                            .disabled(model.isBusy)
                            .accessibilityLabel("地图名称，1 至 24 个英文字母或数字")
                    }
                }.padding(16).frame(minHeight: 54)
            }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var scanDate: String {
        let name = currentJob?.scanName ?? scanDirectory?.lastPathComponent ?? ""
        guard let date = ScanHistoryItem.parseDate(from: name) else { return "时间未知" }
        return date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private func summaryRow(_ title: String, symbol: String, value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 24)
            Text(title)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }.padding(16).frame(minHeight: 54)
    }

    @ViewBuilder private func jobStatus(_ job: ImmersalMappingJob) -> some View {
        if job.canRestart {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading("云端工作区")
                notice(symbol: "exclamationmark.circle", color: .orange,
                       title: job.workspaceImageCount.map { "云端已有 \($0) 张图片" } ?? "需要检查云端工作区",
                       message: "清空后上传本次扫描，已有地图保留。")
            }
        } else if job.phase == .uploading || (job.phase == .paused && job.uploadedCount > 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionHeading("上传进度")
                    Spacer()
                    Text("\(job.uploadedCount) / \(job.frameCount) 帧").font(.subheadline.monospacedDigit())
                }
                ProgressView(value: Double(job.uploadedCount), total: Double(max(job.frameCount, 1)))
                    .accessibilityLabel("已确认上传 \(job.uploadedCount) 帧，共 \(job.frameCount) 帧")
                if model.activeJobID == job.id && !model.progressText.isEmpty {
                    Text(model.progressText).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } else if job.stage == .construction {
            notice(symbol: job.phase == .done ? "checkmark.circle" : (job.phase == .failed ? "exclamationmark.circle" : "cloud"),
                   color: job.phase == .done ? .green : (job.phase == .failed ? .orange : .accentColor),
                   title: job.phase.title, message: job.mapID.map { "地图 ID：\($0)" } ?? "可以刷新状态，或前往 Portal 核实。")
        }
        if model.isBusy && job.phase != .uploading && job.phase != .constructing {
            HStack(spacing: 10) { ProgressView(); Text(model.progressText).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title).font(.headline).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
    }

    private func notice(symbol: String, color: Color, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
    }

    private func unfinishedTaskNotice(_ job: ImmersalMappingJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            notice(symbol: "clock.badge.exclamationmark", color: .orange, title: "还有未完成的任务",
                   message: "请先处理“\(job.displayName)”，再上传新的扫描。")
            Button("去历史处理") { showHistory = true }.frame(minHeight: 44)
        }
    }

    private func errorNotice(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            notice(symbol: "exclamationmark.circle", color: .red, title: "暂时无法继续", message: error)
            Button("关闭提示") { model.errorMessage = nil }.frame(minHeight: 44)
        }
    }

    private var emptyScanNotice: some View {
        notice(symbol: "viewfinder", color: .accentColor, title: "尚未选择扫描",
               message: "可在历史中继续已有任务，或从扫描预览页创建新地图。")
    }

    private var actionFooter: some View {
        VStack(spacing: 8) {
            primaryAction
                .buttonStyle(.borderedProminent).controlSize(.large)
                .frame(maxWidth: .infinity).tint(.accentColor)
            Button(currentJob?.phase == .done ? "关闭" : "稍后处理") {
                if model.isBusy { model.pause() }
                dismiss()
            }.frame(minHeight: 44)
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 8)
        .frame(maxWidth: 640).frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    @ViewBuilder private var primaryAction: some View {
        if !model.isLoggedIn {
            fullWidthButton("登录并继续", symbol: "person.crop.circle") { sheet = .account }
                .disabled(model.isBusy)
        } else if model.isBusy {
            if currentJob?.phase == .uploading {
                fullWidthButton("暂停上传", symbol: "pause") { model.pause() }
            } else {
                Button {} label: { HStack { ProgressView().tint(.white); Text("正在处理…") }.frame(maxWidth: .infinity, minHeight: 24) }
                    .disabled(true)
            }
        } else if let job = currentJob, job.canRestart {
            fullWidthButton("检查并继续", symbol: "arrow.right") { model.requestWorkspaceRestart(jobID: job.id) }
        } else if let job = currentJob, job.canResume {
            fullWidthButton("继续上传", symbol: "icloud.and.arrow.up") { model.resume(jobID: job.id) }
        } else if let job = currentJob, job.phase == .constructionUncertain || job.phase == .constructing {
            fullWidthButton(model.isRefreshing ? "正在查询…" : "查询建图结果", symbol: "arrow.clockwise") {
                Task { await model.refreshJobs() }
            }.disabled(model.isRefreshing)
        } else if let job = currentJob, job.stage == .construction {
            Link(destination: portalURL) { Label("查看 Immersal Portal", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity, minHeight: 24) }
        } else if blockingJob != nil {
            fullWidthButton("处理未完成任务", symbol: "clock.arrow.circlepath") { showHistory = true }
        } else if let directory = sourceDirectory {
            fullWidthButton("上传并建图", symbol: "icloud.and.arrow.up") { model.start(scanDirectory: directory, mapName: mapName) }
        } else {
            fullWidthButton("查看历史任务", symbol: "clock.arrow.circlepath") { showHistory = true }
        }
    }

    private func fullWidthButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 24) }
    }

    private var portalURL: URL { URL(string: "https://developers.immersal.com/")! }

    private var moreMenu: some View {
        Menu {
            Button { sheet = .account } label: { Label(model.isLoggedIn ? "账号" : "登录账号", systemImage: "person.crop.circle") }
            Button { sheet = .details } label: { Label("扫描与任务详情", systemImage: "info.circle") }
            Link(destination: portalURL) { Label("打开 Immersal Portal", systemImage: "arrow.up.right.square") }
            if currentJob?.stage == .construction {
                Button { Task { await model.refreshJobs() } } label: { Label("刷新建图状态", systemImage: "arrow.clockwise") }
                    .disabled(model.isBusy || model.isRefreshing)
            }
            if let job = currentJob, [.done, .failed, .abandoned].contains(job.phase), blockingJob == nil {
                Button { mapName = job.displayName; startAnotherUpload(job) } label: {
                    Label("再次上传此扫描", systemImage: "icloud.and.arrow.up")
                }.disabled(model.isBusy || !model.isLoggedIn)
            }
            if let job = currentJob, job.canAbandon {
                Divider()
                Button(role: .destructive) { abandonJob = job } label: {
                    Label(job.pendingOperation == .construct ? "停止本机跟踪…" : "停止本机任务…", systemImage: "stop.circle")
                }.disabled(model.isBusy)
            }
        } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
        .accessibilityLabel("更多选项")
    }

    private func startAnotherUpload(_ job: ImmersalMappingJob) {
        let parent = scanDirectory?.deletingLastPathComponent() ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        model.start(scanDirectory: parent.appendingPathComponent(job.scanName), mapName: job.displayName)
    }

    private var accountView: some View {
        Form {
            Section {
                if let account = model.email {
                    Label(account, systemImage: "person.crop.circle").textSelection(.enabled)
                    Button("退出登录", role: .destructive) { model.logout() }
                } else {
                    TextField("邮箱", text: $email).keyboardType(.emailAddress).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.isBusy)
                    SecureField("密码", text: $password).textContentType(.password).disabled(model.isBusy)
                    Button(model.isBusy ? "正在登录…" : "登录") {
                        let submitted = password; password = ""
                        model.login(email: email, password: submitted)
                    }.disabled(model.isBusy || email.isEmpty || password.isEmpty)
                    if model.isBusy { Button("取消登录", role: .cancel) { model.pause() } }
                }
            } footer: { Text("使用 Immersal 邮箱和密码登录。登录凭据保存在本机钥匙串，下次自动使用；App 不保存密码。") }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Immersal 账号").navigationBarTitleDisplayMode(.inline)
    }

    private var detailsView: some View {
        Form {
            Section("扫描文件") {
                Text(currentJob?.scanName ?? scanDirectory?.lastPathComponent ?? "未选择扫描").textSelection(.enabled)
                if let frameCount { LabeledContent("图片数量", value: "\(frameCount) 帧") }
                Text("上传扫描图片、相机位姿及扫描时采集的 GPS；无需先导出 ZIP。地图名称会自动添加唯一编号。")
                    .foregroundStyle(.secondary)
            }
            if let job = currentJob {
                Section("完整任务信息") {
                    LabeledContent("状态", value: job.phase.title)
                    Text(job.mapName).textSelection(.enabled)
                    Text(job.id.uuidString).font(.caption).textSelection(.enabled)
                    LabeledContent("已确认上传", value: "\(job.uploadedCount) / \(job.frameCount) 帧")
                    if let count = job.workspaceImageCount { LabeledContent("最近检查的工作区图片", value: "\(count) 张") }
                    if let mapID = job.mapID { LabeledContent("地图 ID", value: "\(mapID)") }
                    if let message = job.message { Text(message).foregroundStyle(.secondary) }
                }
            }
            Section("使用提示") {
                Text("上传时请保持 App 在前台，并避免在其他设备操作同一账号的工作区。进入后台会暂停本机上传，回到前台后可继续。")
                Text("已经提交的云端建图会继续运行；停止本机任务不会清空云端图片或取消建图。")
            }
        }.navigationTitle("扫描与任务详情").navigationBarTitleDisplayMode(.inline)
    }

    private var historyView: some View {
        List {
            if !model.isLoggedIn {
                Section {
                    Text("登录后查看此账号在本机发起的任务。").foregroundStyle(.secondary)
                    Button("登录 Immersal 账号") { sheet = .account }
                }
            } else if model.jobs.isEmpty {
                Text("暂无本机任务").foregroundStyle(.secondary)
            } else {
                ForEach(model.jobs) { job in
                    Button {
                        selectedJobID = job.id; mapName = job.displayName; showHistory = false
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: historySymbol(job)).foregroundStyle(job.phase == .done ? Color.green : Color.accentColor)
                                .frame(width: 24).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(job.displayName).font(.headline).foregroundStyle(.primary)
                                Text(job.phase.title).font(.subheadline).foregroundStyle(.secondary)
                                Text(historyDate(job)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 5)
                    }.buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("上传历史").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await model.refreshJobs() } } label: {
                    Image(systemName: "arrow.clockwise").frame(minWidth: 32, minHeight: 44)
                }.accessibilityLabel("刷新建图状态").disabled(!model.isLoggedIn || model.isBusy || model.isRefreshing)
            }
        }
        .refreshable { await model.refreshJobs() }
    }

    private func historySymbol(_ job: ImmersalMappingJob) -> String {
        if job.phase == .done { return "checkmark.circle" }
        if job.phase == .failed || job.canRestart { return "exclamationmark.circle" }
        if job.phase == .abandoned { return "stop.circle" }
        return job.stage == .construction ? "cloud" : "icloud.and.arrow.up"
    }

    private func historyDate(_ job: ImmersalMappingJob) -> String {
        (ScanHistoryItem.parseDate(from: job.scanName) ?? job.createdAt).formatted(date: .abbreviated, time: .shortened)
    }

    private func readScanSummary() async {
        summaryFrameCount = nil
        summaryLoading = true
        guard let directory = sourceDirectory else { summaryLoading = false; return }
        let count = await Task.detached(priority: .utility) {
            struct IgnoredFrame: Decodable {}
            struct Summary: Decodable { let frames: [IgnoredFrame] }
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONDecoder().decode(Summary.self, from: data) else { return nil as Int? }
            return manifest.frames.count
        }.value
        guard !Task.isCancelled, sourceDirectory == directory else { return }
        summaryFrameCount = count
        summaryLoading = false
    }
}
