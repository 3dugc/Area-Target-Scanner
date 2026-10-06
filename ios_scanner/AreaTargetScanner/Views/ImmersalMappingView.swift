import SwiftUI

struct ImmersalMappingView: View {
    @ObservedObject var model: ImmersalMappingModel
    let scanDirectory: URL?
    var selectScan: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var cloudActions = ImmersalCloudActionCoordinator()
    @State private var dismissedAuthenticationID: UUID?
    @State private var loginSubmitted = false
    @State private var email = ""
    @State private var password = ""
    @State private var mapName = ""
    @State private var mapNameSourceID: String?
    @State private var selectedJobID: UUID?
    @State private var showHistory = false
    @State private var sheet: Sheet?
    @State private var abandonJob: ImmersalMappingJob?
    @State private var summaryFrameCount: Int?
    @State private var summaryLoading = true

    private enum Sheet: Identifiable {
        case account(UUID), details
        var id: String {
            switch self {
            case .account(let id): return "account-\(id)"
            case .details: return "details"
            }
        }
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
        if let selectedJobID, let selected = model.localJobs.first(where: { $0.id == selectedJobID }) { return selected }
        guard let scanName = scanDirectory?.lastPathComponent else { return nil }
        let available = model.isLoggedIn ? model.jobs : model.localJobs
        return available.first(where: { $0.scanName == scanName && $0.needsSource }) ??
            available.first(where: { $0.scanName == scanName && $0.phase != .abandoned })
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
                ToolbarItem(placement: .navigationBarLeading) { Button("任务") { showHistory = true }.disabled(model.isBusy) }
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
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") {
                                if case .account(let id) = value { cancelAuthentication(id: id) }
                                sheet = nil
                            }
                        }
                    }
                }
                .onDisappear {
                    if case .account(let id) = value { authenticationDismissed(id: id) }
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
                        requestCloudAction(.confirmedWorkspace(prompt))
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
                if loggedIn {
                    password = ""
                    if case .account(let id) = sheet, id == cloudActions.pendingID { sheet = nil }
                } else {
                    cloudActions.operationFinished(using: model)
                }
            }
            .onChange(of: model.isBusy) { busy in
                if !busy {
                    continueDismissedAuthentication()
                    cloudActions.operationFinished(using: model)
                }
            }
            .onChange(of: model.isRefreshing) { refreshing in
                if !refreshing {
                    continueDismissedAuthentication()
                    cloudActions.operationFinished(using: model)
                }
            }
            .onChange(of: cloudActions.needsAuthentication) { needed in
                if needed, scenePhase != .background, let id = cloudActions.pendingID {
                    dismissedAuthenticationID = nil
                    sheet = .account(id)
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .background {
                    cancelAuthentication()
                    cloudActions.cancelPendingAuthentication(cancelActiveAction: true)
                    sheet = nil
                }
            }
            .onDisappear {
                cancelAuthentication()
                cloudActions.cancelPendingAuthentication(cancelActiveAction: true)
                model.cancelWorkspaceConfirmation()
            }
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
                summaryRow("场景名称", symbol: "cube", value: ScanHistoryItem.displayName(for: currentJob?.scanName ?? scanDirectory?.lastPathComponent ?? ""))
                Divider().padding(.horizontal, 16)
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
                        TextField("地图名称", text: $mapName)
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
               message: "请从扫描历史选择已保存的扫描。已有云端任务可在本页任务列表中查看。")
    }

    private var actionFooter: some View {
        VStack(spacing: 8) {
            primaryAction
                .buttonStyle(.borderedProminent).controlSize(.large)
                .frame(maxWidth: .infinity).tint(ScannerTheme.actionBlue)
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
        if sourceDirectory == nil && currentJob == nil {
            fullWidthButton("选择扫描", symbol: "clock.arrow.circlepath") {
                dismiss()
                selectScan?()
            }.disabled(model.isBusy)
        } else if model.isBusy {
            if currentJob?.phase == .uploading {
                fullWidthButton("暂停上传", symbol: "pause") { model.pause() }
            } else {
                Button {} label: { HStack { ProgressView().tint(.white); Text("正在处理…") }.frame(maxWidth: .infinity, minHeight: 24) }
                    .disabled(true)
            }
        } else if let job = currentJob, job.canRestart {
            fullWidthButton("检查并继续", symbol: "arrow.right") { requestCloudAction(.checkWorkspace(jobID: job.id, userID: job.userID)) }
        } else if let job = currentJob, job.canResume {
            fullWidthButton("继续上传", symbol: "icloud.and.arrow.up") { requestCloudAction(.resume(jobID: job.id, userID: job.userID)) }
        } else if let job = currentJob, job.phase == .constructionUncertain || job.phase == .constructing {
            fullWidthButton(model.isRefreshing ? "正在查询…" : "查询建图结果", symbol: "arrow.clockwise") {
                requestCloudAction(.refresh(jobID: job.id, userID: job.userID))
            }.disabled(model.isRefreshing)
        } else if let job = currentJob, job.stage == .construction {
            Link(destination: portalURL) { Label("查看 Immersal Portal", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity, minHeight: 24) }
        } else if blockingJob != nil {
            fullWidthButton("处理未完成任务", symbol: "clock.arrow.circlepath") { showHistory = true }
        } else if let directory = sourceDirectory {
            fullWidthButton("上传并建图", symbol: "icloud.and.arrow.up") { requestCloudAction(.upload(scanDirectory: directory, mapName: mapName)) }
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
            if model.isLoggedIn {
                Button(role: .destructive) {
                    logout()
                } label: { Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right") }
            }
            Button { sheet = .details } label: { Label("扫描与任务详情", systemImage: "info.circle") }
            Link(destination: portalURL) { Label("打开 Immersal Portal", systemImage: "arrow.up.right.square") }
            if let job = currentJob, job.stage == .construction {
                Button { requestCloudAction(.refresh(jobID: job.id, userID: job.userID)) } label: { Label("刷新建图状态", systemImage: "arrow.clockwise") }
                    .disabled(model.isBusy || model.isRefreshing)
            }
            if let job = currentJob, [.done, .failed, .abandoned].contains(job.phase), blockingJob == nil {
                Button { mapName = job.displayName; startAnotherUpload(job) } label: {
                    Label("再次上传此扫描", systemImage: "icloud.and.arrow.up")
                }.disabled(model.isBusy)
            }
            if let job = currentJob, job.canAbandon,
               model.jobs.contains(where: { $0.id == job.id && $0.userID == job.userID }) {
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
        requestCloudAction(.uploadAgain(jobID: job.id, userID: job.userID,
            scanDirectory: parent.appendingPathComponent(job.scanName), mapName: job.displayName))
    }

    private var accountView: some View {
        Form {
            Section {
                if let account = model.email {
                    Label(account, systemImage: "person.crop.circle").textSelection(.enabled)
                    Button("退出登录", role: .destructive) { logout() }
                } else {
                    TextField("邮箱", text: $email).keyboardType(.emailAddress).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.isBusy)
                        .accessibilityLabel("Immersal 邮箱")
                    SecureField("密码", text: $password).textContentType(.password).disabled(model.isBusy)
                        .accessibilityLabel("Immersal 密码")
                    Button(model.isBusy ? "正在登录…" : "登录") {
                        let submitted = password; password = ""
                        loginSubmitted = true
                        model.login(email: email, password: submitted)
                    }.disabled(model.isBusy || email.isEmpty || password.isEmpty)
                    if model.isBusy {
                        Button("取消登录", role: .cancel) { cancelAuthentication(); sheet = nil }
                    }
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
            if model.localJobs.isEmpty {
                Text("暂无本机任务").foregroundStyle(.secondary)
            } else {
                ForEach(model.localJobs) { job in
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
                Button { requestCloudAction(.refreshJobs) } label: {
                    Image(systemName: "arrow.clockwise").frame(minWidth: 32, minHeight: 44)
                }.accessibilityLabel("刷新建图状态").disabled(model.isBusy || model.isRefreshing || model.localJobs.isEmpty)
            }
        }
        .refreshable {
            if !model.localJobs.isEmpty { requestCloudAction(.refreshJobs) }
        }
    }

    private func requestCloudAction(_ action: ImmersalCloudAction) {
        cloudActions.request(action, using: model)
    }

    private func logout() {
        cancelAuthentication()
        cloudActions.cancelPendingAuthentication(cancelActiveAction: true)
        model.logout()
        sheet = nil
    }

    private func cancelAuthentication(id: UUID? = nil) {
        if let id, id != cloudActions.pendingID { return }
        cloudActions.cancelPendingAuthentication(requestID: id)
        dismissedAuthenticationID = nil
        password = ""
        if loginSubmitted && model.isBusy { model.pause() }
        loginSubmitted = false
    }

    private func authenticationDismissed(id: UUID) {
        guard id == cloudActions.pendingID else { return }
        if model.isLoggedIn {
            dismissedAuthenticationID = id
            continueDismissedAuthentication()
        } else {
            cancelAuthentication(id: id)
        }
    }

    private func continueDismissedAuthentication() {
        guard let id = dismissedAuthenticationID, model.isLoggedIn, !model.isBusy, !model.isRefreshing else { return }
        dismissedAuthenticationID = nil
        loginSubmitted = false
        cloudActions.continueAfterLogin(requestID: id, using: model)
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
        let sourceID = sourceDirectory?.standardizedFileURL.path
        if sourceID != mapNameSourceID {
            mapNameSourceID = sourceID
            mapName = currentJob?.displayName ?? sourceDirectory.map {
                ScanHistoryItem.defaultImmersalMapName(for: $0.lastPathComponent)
            } ?? ""
        }
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


/// Each authenticated continuation holds the source or task selected by its explicit action.
/// A changed selection or a later account cannot replace that action.
enum ImmersalCloudAction: Equatable {
    case upload(scanDirectory: URL, mapName: String)
    case uploadAgain(jobID: UUID, userID: Int, scanDirectory: URL, mapName: String)
    case resume(jobID: UUID, userID: Int)
    case checkWorkspace(jobID: UUID, userID: Int)
    case confirmedWorkspace(ImmersalWorkspaceConfirmation)
    case refresh(jobID: UUID, userID: Int)
    case refreshJobs

    var jobIdentity: (id: UUID, userID: Int)? {
        switch self {
        case .resume(let id, let userID), .checkWorkspace(let id, let userID), .refresh(let id, let userID):
            return (id, userID)
        case .uploadAgain(let id, let userID, _, _): return (id, userID)
        case .confirmedWorkspace(let prompt): return (prompt.jobID, prompt.userID)
        case .upload, .refreshJobs: return nil
        }
    }
}

@MainActor
final class ImmersalCloudActionCoordinator: ObservableObject {
    @Published private(set) var pendingAction: ImmersalCloudAction?
    @Published private(set) var pendingID: UUID?
    @Published private(set) var needsAuthentication = false
    private var activeAction: ImmersalCloudAction?

    func request(_ action: ImmersalCloudAction, using model: ImmersalMappingModel) {
        guard !model.isBusy, !model.isRefreshing else { return }
        cancelPendingAuthentication()
        if model.isLoggedIn { perform(action, using: model) }
        else { requireAuthentication(for: action) }
    }

    func cancelPendingAuthentication(requestID: UUID? = nil, cancelActiveAction: Bool = false) {
        if let requestID, requestID != pendingID { return }
        pendingAction = nil
        pendingID = nil
        needsAuthentication = false
        if cancelActiveAction { activeAction = nil }
    }

    func continueAfterLogin(requestID: UUID? = nil, using model: ImmersalMappingModel) {
        guard model.isLoggedIn, !model.isBusy, !model.isRefreshing, let action = pendingAction,
              requestID == nil || requestID == pendingID else { return }
        cancelPendingAuthentication()
        perform(action, using: model)
    }

    /// Authentication expiry prompts only for this explicit operation, never a background poll.
    func operationFinished(using model: ImmersalMappingModel) {
        guard !model.isBusy, !model.isRefreshing, let action = activeAction else { return }
        activeAction = nil
        guard !model.isLoggedIn else { return }
        if let identity = action.jobIdentity {
            guard let job = model.localJobs.first(where: { $0.id == identity.id && $0.userID == identity.userID }) else { return }
            if job.canRestart { requireAuthentication(for: .checkWorkspace(jobID: job.id, userID: job.userID)) }
            else if job.canResume { requireAuthentication(for: .resume(jobID: job.id, userID: job.userID)) }
            else if job.shouldQuery { requireAuthentication(for: .refresh(jobID: job.id, userID: job.userID)) }
        } else if action == .refreshJobs {
            requireAuthentication(for: action)
        }
    }

    private func requireAuthentication(for action: ImmersalCloudAction) {
        // A login can never replay destructive authorization from a prior session.
        if case .confirmedWorkspace(let prompt) = action {
            pendingAction = .checkWorkspace(jobID: prompt.jobID, userID: prompt.userID)
        } else { pendingAction = action }
        pendingID = UUID()
        needsAuthentication = true
    }

    private func perform(_ action: ImmersalCloudAction, using model: ImmersalMappingModel) {
        guard model.isLoggedIn, !model.isBusy, !model.isRefreshing else { return }
        activeAction = nil
        let job: ImmersalMappingJob?
        if let identity = action.jobIdentity {
            guard let matching = model.jobs.first(where: { $0.id == identity.id && $0.userID == identity.userID }) else {
                model.errorMessage = "这项本机任务属于其他 Immersal 账号，或记录已改变。请检查任务记录并使用原账号；扫描和本机记录已保留。"
                return
            }
            job = matching
        } else { job = nil }
        switch action {
        case .upload(let directory, let mapName), .uploadAgain(_, _, let directory, let mapName):
            model.start(scanDirectory: directory, mapName: mapName)
            if let id = model.activeJobID, let started = model.jobs.first(where: { $0.id == id }) {
                activeAction = .resume(jobID: started.id, userID: started.userID)
            }
        case .resume:
            guard job?.canResume == true else { taskChanged(model); return }
            activeAction = action
            model.resume(jobID: job!.id)
        case .checkWorkspace:
            guard job?.canRestart == true else { taskChanged(model); return }
            activeAction = action
            model.requestWorkspaceRestart(jobID: job!.id)
        case .confirmedWorkspace(let prompt):
            guard job?.canRestart == true, model.workspaceConfirmation == prompt else {
                model.errorMessage = "工作区确认已失效，请重新检查并确认。未清空或上传。"
                return
            }
            activeAction = action
            model.restartAfterClearingWorkspace(jobID: prompt.jobID, confirmation: prompt)
        case .refresh, .refreshJobs:
            activeAction = action
            Task {
                await model.refreshJobs()
                operationFinished(using: model)
            }
        }
    }

    private func taskChanged(_ model: ImmersalMappingModel) {
        model.errorMessage = "任务状态已改变，请检查当前任务后再继续。未重新上传或清空云端工作区。"
    }
}
