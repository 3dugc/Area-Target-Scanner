import SwiftUI

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SharePayload: Identifiable {
    let id = UUID()
    let activityItems: [Any]
}

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: ScanViewModel
    @StateObject private var mappingModel: ImmersalMappingModel
    @StateObject private var areaTargetModel: AreaTargetProcessingModel
    @StateObject private var workspace: ScannerWorkspace
    @StateObject private var settings: ScannerSettings
    @State private var showingSettings = false
    @State private var didInitialize = false
    @State private var sharePayload: SharePayload?
    @State private var previewItem: IdentifiableURL?
    @State private var renamingScan: ScanHistoryItem?
    @State private var mappingDestination: MappingDestination?
    @State private var areaTargetDestination: AreaTargetDestination?
    @State private var benchmarkDestination: BenchmarkDestination?
    @State private var benchmarkReadiness = LocalizationBenchmarkReadiness(state: .noScan)
    @State private var benchmarkReadinessRevision = 0

    private struct BenchmarkDestination: Identifiable {
        let id = UUID()
        let directory: URL
        let areaJob: AreaTargetProcessingJob
        let immersalJob: ImmersalMappingJob
    }

    private struct AreaTargetDestination: Identifiable {
        let id = UUID()
        let directory: URL?
        let entry: AreaTargetProcessingView.EntryPoint
    }

    private struct MappingDestination: Identifiable {
        let id = UUID()
        let directory: URL?
        let entry: ImmersalMappingView.EntryPoint
    }

    init(viewModel: ScanViewModel? = nil, mappingModel: ImmersalMappingModel? = nil,
         workspace: ScannerWorkspace? = nil, areaTargetModel: AreaTargetProcessingModel? = nil,
         settings: ScannerSettings? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? ScanViewModel())
        _mappingModel = StateObject(wrappedValue: mappingModel ?? ImmersalMappingModel())
        _areaTargetModel = StateObject(wrappedValue: areaTargetModel ?? AreaTargetProcessingModel.shared)
        _workspace = StateObject(wrappedValue: workspace ?? ScannerWorkspace())
        _settings = StateObject(wrappedValue: settings ?? ScannerSettings.shared)
    }

    private var operationInProgress: Bool {
        viewModel.isCaptureBusy || viewModel.isExporting || mappingModel.isBusy || areaTargetModel.operationInProgress || benchmarkDestination != nil
    }

    private var selectedScan: ScanHistoryItem? {
        viewModel.scanHistory.first { $0.directoryPath == workspace.selectedScanPath }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            if viewModel.state == .scanning {
                ScanCaptureView(viewModel: viewModel, platform: workspace.platform)
            } else {
                VStack(spacing: 0) {
                    platformHeader
                    page.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
            }
        }
        .tint(.blue)
        .onAppear {
            viewModel.setAppActive(scenePhase == .active)
            viewModel.loadScanHistory()
            viewModel.deletionBlocked = { [mapping = mappingModel, area = areaTargetModel] path in
                mapping.blocksDeletion(of: path) || area.deletionBlocked(scanPath: path)
            }
            viewModel.deletionBlockReason = { [mapping = mappingModel, area = areaTargetModel] path in
                let reasons = [area.sourceProtectionReason(scanPath: path),
                    mapping.blocksDeletion(of: path) ? "Immersal 本机任务仍需保留这条扫描，或任务记录暂不可用。请到 Immersal 任务页检查记录；确认不再需要的任务可停止本机跟踪。" : nil].compactMap { $0 }
                return reasons.isEmpty ? nil : reasons.joined(separator: "\n\n")
            }
            if !didInitialize {
                didInitialize = true
                if workspace.selectedScanPath == nil, workspace.tab == .scan,
                   case .preview(let path) = viewModel.state {
                    workspace.selectScan(path)
                }
            }
            updateMappingActivity()
        }
        .task(id: workspace.platform) {
            updateMappingActivity()
            if workspace.platform.supportsCloudMapping { await mappingModel.monitorJobs() }
        }
        .task(id: benchmarkReadinessKey) { await refreshBenchmarkReadiness() }
        .onChange(of: scenePhase) { phase in
            viewModel.setAppActive(phase == .active)
            // Autofill briefly makes the app inactive; only backgrounding cancels work.
            if phase == .background { mappingModel.setAppActive(false); areaTargetModel.setAppActive(false) }
            else if phase == .active { updateMappingActivity(); benchmarkReadinessRevision += 1 }
        }
        .onChange(of: viewModel.state) { state in
            if case .preview(let path) = state {
                viewModel.loadScanHistory()
                workspace.selectScan(path)
            }
        }
        .onChange(of: viewModel.exportShareURL) { url in
            if let url {
                sharePayload = SharePayload(activityItems: [url])
                viewModel.exportShareURL = nil
                viewModel.loadScanHistory()
            }
        }
        .alert("导出失败", isPresented: Binding(get: { viewModel.exportError != nil }, set: { if !$0 { viewModel.exportError = nil } })) {
            Button("好", role: .cancel) { viewModel.exportError = nil }
        } message: { Text(viewModel.exportError ?? "") }
        .alert("无法删除场景", isPresented: Binding(get: { viewModel.deletionError != nil }, set: { if !$0 { viewModel.deletionError = nil } })) {
            Button("好", role: .cancel) { viewModel.deletionError = nil }
        } message: { Text(viewModel.deletionError ?? "") }
        .alert("场景名称未保存", isPresented: Binding(get: { viewModel.namingError != nil && renamingScan == nil }, set: { if !$0 { viewModel.namingError = nil } })) {
            Button("好", role: .cancel) { viewModel.namingError = nil }
        } message: { Text(viewModel.namingError ?? "") }
        .sheet(item: $sharePayload) { ActivityView(activityItems: $0.activityItems) }
        .sheet(isPresented: $showingSettings) { ScannerSettingsView(settings: settings) }
        .sheet(item: $renamingScan, onDismiss: { viewModel.namingError = nil }) { scan in
            SceneNameEditor(name: scan.displayName) { name in
                viewModel.renameScan(at: scan.directoryPath, to: name) ? nil : (viewModel.namingError ?? "保存失败，请重试。")
            }
        }
        .sheet(item: $mappingDestination, onDismiss: { benchmarkReadinessRevision += 1 }) { destination in
            ImmersalMappingView(model: mappingModel, scanDirectory: destination.directory, entryPoint: destination.entry) { id in
                viewModel.scanHistory.first(where: { $0.id == id })?.displayName
            }
        }
        .sheet(item: $areaTargetDestination, onDismiss: { benchmarkReadinessRevision += 1 }) { destination in
            AreaTargetProcessingView(model: areaTargetModel, scanDirectory: destination.directory,
                displayName: destination.directory.flatMap { viewModel.sceneName(for: $0.path) } ?? "扫描记录",
                entryPoint: destination.entry, comparisonJob: { job in
                    ScannerWorkspace.comparisonJob(for: job, in: mappingModel.jobs)
                }, settings: settings)
        }
        .fullScreenCover(item: $benchmarkDestination, onDismiss: { benchmarkReadinessRevision += 1 }) { destination in
            LocalizationBenchmarkView(areaJob: destination.areaJob, immersalJob: destination.immersalJob,
                scanDirectory: destination.directory)
        }
        .fullScreenCover(item: $previewItem) { ModelPreviewView(fileURL: $0.url) }
    }

    private var platformHeader: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(ScannerPlatform.allCases) { platform in
                    Button {
                        if workspace.selectPlatform(platform, operationInProgress: operationInProgress) { updateMappingActivity() }
                    } label: {
                        if platform == workspace.platform { Label(platform.title, systemImage: "checkmark") }
                        else { Text(platform.title) }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: workspace.platform.symbol)
                    Text(workspace.platform.title).font(.headline).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .buttonStyle(.plain).disabled(operationInProgress)
            .accessibilityLabel("当前平台：\(workspace.platform.title)，切换平台")
            .accessibilityHint(operationInProgress ? "请先完成或暂停当前操作" : "选择此场景使用的平台")
            .accessibilityIdentifier("platform-switcher")
            Spacer(minLength: 0)
            if workspace.platform.supportsCloudMapping {
                Button { openMapping(.account) } label: {
                    Image(systemName: "person.crop.circle").font(.title2).frame(width: 44, height: 44)
                }
                .disabled(operationInProgress).accessibilityLabel("Immersal 账号")
                .accessibilityIdentifier("immersal-account")
            }
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape").font(.title2).frame(width: 44, height: 44)
            }
            .accessibilityLabel("设置").accessibilityIdentifier("scanner-open-settings")
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
    }

    @ViewBuilder private var page: some View {
        if viewModel.isStartingScan {
            busyPage("正在准备扫描…")
        } else if case .processing(let status) = viewModel.state {
            busyPage(status)
        } else {
            switch workspace.tab {
            case .scan: scanPage
            case .records:
                ScanHistoryView(viewModel: viewModel, select: selectScan, rename: { renamingScan = $0 },
                    preview: { previewItem = IdentifiableURL(url: $0) },
                    didDelete: { path in
                        workspace.didDeleteScan(path)
                        if case .preview(let selected) = viewModel.state, selected == path { viewModel.resetToReady() }
                    }, startScan: { selectTab(.scan) })
            case .process:
                ScanProcessingView(viewModel: viewModel, platform: workspace.platform, scan: selectedScan,
                    selectRecord: { selectTab(.records) }, rename: { renamingScan = $0 },
                    preview: { previewItem = IdentifiableURL(url: $0) },
                    upload: { directory in
                        if workspace.platform.supportsAreaTargetProcessing { openAreaTarget(.preparation, directory: directory) }
                        else { openMapping(.preparation, directory: directory) }
                    }, showTasks: {
                        if workspace.platform.supportsAreaTargetProcessing { openAreaTarget(.tasks) }
                        else { openMapping(.tasks) }
                    }, benchmarkReadiness: benchmarkReadiness, compareAlgorithms: openBenchmark)
            }
        }
    }

    @ViewBuilder private var scanPage: some View {
        switch viewModel.state {
        case .permissionDenied:
            WorkspacePage {
                WorkspaceHeading(title: "开启摄像头后开始扫描", subtitle: "你仍然可以查看已保存的场景和处理任务。")
                WorkspaceEmptyState(title: "需要摄像头权限", message: "请在系统设置中允许访问摄像头。", symbol: "camera.badge.ellipsis")
                WorkspacePrimaryButton(title: "打开设置", symbol: "gearshape") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("已开启，重新尝试") { viewModel.startScanning() }.frame(minHeight: 44)
            }
        case .requestingPermission:
            WorkspacePage {
                WorkspaceHeading(title: "允许摄像头访问", subtitle: "使用摄像头和 LiDAR 记录空间。")
                WorkspacePrimaryButton(title: "授权并开始扫描", symbol: "camera") { viewModel.requestCameraPermission() }
            }
        case .error(let message):
            WorkspacePage {
                WorkspaceHeading(title: "扫描未完成", subtitle: message)
                WorkspacePrimaryButton(title: "返回扫描", symbol: "arrow.counterclockwise") { viewModel.resetToReady() }
            }
        default:
            ScanHomeView(viewModel: viewModel) { viewModel.startScanning() }
        }
    }

    private func busyPage(_ status: String) -> some View {
        VStack(spacing: 24) {
            ProgressView().controlSize(.large)
            Text(status).font(.title3).multilineTextAlignment(.center)
            Text("请保持 App 在前台，完成后自动进入处理页。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceTab.allCases) { tab in
                Button { selectTab(tab) } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol).font(.system(size: 22))
                        Text(tab.title).font(.caption)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(workspace.tab == tab ? Color.accentColor : .secondary)
                .accessibilityAddTraits(workspace.tab == tab ? .isSelected : [])
                .accessibilityIdentifier("tab-\(tab.rawValue)")
                .disabled(operationInProgress)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay(alignment: .top) { Divider() }
    }

    private func selectTab(_ tab: WorkspaceTab) {
        guard workspace.selectTab(tab, operationInProgress: operationInProgress) else { return }
        if tab == .records { viewModel.loadScanHistory() }
        if tab == .process, let path = workspace.selectedScanPath { viewModel.state = .preview(path) }
    }

    private func selectScan(_ scan: ScanHistoryItem) {
        guard workspace.selectScan(scan.directoryPath, operationInProgress: operationInProgress) else { return }
        viewModel.state = .preview(scan.directoryPath)
    }

    private func openMapping(_ entry: ImmersalMappingView.EntryPoint, directory: URL? = nil) {
        guard workspace.platform.supportsCloudMapping, !operationInProgress else { return }
        mappingDestination = MappingDestination(directory: directory, entry: entry)
    }

    private func openAreaTarget(_ entry: AreaTargetProcessingView.EntryPoint, directory: URL? = nil) {
        guard workspace.platform.supportsAreaTargetProcessing, !operationInProgress else { return }
        if let directory { areaTargetModel.selectJob(areaTargetModel.job(for: directory.path)?.id) }
        areaTargetDestination = AreaTargetDestination(directory: directory, entry: entry)
    }

    private var benchmarkReadinessKey: String {
        let areas = areaTargetModel.jobs.map {
            "\($0.id):\($0.phase.rawValue):\($0.sourceFingerprint ?? ""):\($0.savedAsset?.featuresURL.path ?? "")"
        }.joined(separator: "|")
        let maps = mappingModel.jobs.map {
            "\($0.id):\($0.phase.rawValue):\($0.mapID ?? 0):\($0.sourceFingerprint ?? "")"
        }.joined(separator: "|")
        return "\(workspace.selectedScanPath ?? ""):\(benchmarkReadinessRevision):\(areas):\(maps)"
    }

    private func refreshBenchmarkReadiness() async {
        let path = workspace.selectedScanPath
        let areas = areaTargetModel.jobs
        let maps = mappingModel.jobs
        let candidate = ScannerWorkspace.benchmarkReadiness(for: path, areaJobs: areas, immersalJobs: maps,
            areaAssetReady: { _ in true }, immersalMapReady: { _ in true })
        guard candidate.canOpen, let area = candidate.areaJob, let map = candidate.immersalJob,
              let mapID = map.mapID else { benchmarkReadiness = candidate; return }
        benchmarkReadiness = .init(state: .checking)
        let verified = await Task.detached(priority: .utility) {
            let asset = try? AreaTargetAssetStore().asset(jobID: area.id)
            let mapURL = try? ImmersalMapStore().mapURL(userID: map.userID, mapID: mapID)
            return (asset == area.savedAsset && asset != nil, mapURL != nil)
        }.value
        guard !Task.isCancelled, path == workspace.selectedScanPath else { return }
        benchmarkReadiness = ScannerWorkspace.benchmarkReadiness(for: path, areaJobs: areas, immersalJobs: maps,
            areaAssetReady: { _ in verified.0 }, immersalMapReady: { _ in verified.1 })
    }

    private func openBenchmark() {
        guard !operationInProgress, benchmarkReadiness.canOpen, let scan = selectedScan,
              let area = benchmarkReadiness.areaJob, let immersal = benchmarkReadiness.immersalJob else { return }
        benchmarkDestination = BenchmarkDestination(directory: URL(fileURLWithPath: scan.directoryPath, isDirectory: true),
            areaJob: area, immersalJob: immersal)
    }

    private func updateMappingActivity() {
        mappingModel.setAppActive(workspace.platform.supportsCloudMapping && scenePhase != .background)
        areaTargetModel.setAppActive(workspace.platform.supportsAreaTargetProcessing && scenePhase != .background)
    }
}
