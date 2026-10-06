import SwiftUI
import AVFoundation

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Identifiable wrapper for immutable share payloads.
struct SharePayload: Identifiable {
    let id = UUID()
    let activityItems: [Any]
}

/// Identifiable wrapper for URL so we can use fullScreenCover(item:)
struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// Present the destination and selected source as one immutable sheet payload.
struct ScanProcessingRequest: Identifiable {
    let id = UUID()
    let directory: URL?
}

/// The icon's blue is reserved for actions; surfaces follow the system appearance.
enum ScannerTheme {
    static let actionBlue = Color(red: 0, green: 102.0 / 255, blue: 245.0 / 255)
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 69.0 / 255, green: 160.0 / 255, blue: 1, alpha: 1)
            : UIColor(red: 0, green: 102.0 / 255, blue: 245.0 / 255, alpha: 1)
    })
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
}

private struct ScannerPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(.white)
            .background(ScannerTheme.actionBlue, in: RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

private struct ScannerRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = ScanViewModel()
    @StateObject private var mappingModel = ImmersalMappingModel()
    @StateObject private var areaTargetModel = AreaTargetProcessingModel.shared
    @State private var areaTargetRequest: ScanProcessingRequest?
    @State private var immersalRequest: ScanProcessingRequest?
    @State private var sharePayload: SharePayload? = nil
    @State private var previewItem: IdentifiableURL? = nil
    @State private var scanStartPending = false
    @AppStorage("scanner.selectedPlatform") private var platformID = "areaTarget"

    private enum CloudPlatform: String, CaseIterable, Identifiable {
        case areaTarget, immersal
        var id: String { rawValue }
        var title: String { self == .areaTarget ? "Area Target" : "Immersal" }
        var symbol: String { self == .areaTarget ? "scope" : "globe" }
        var exportFormat: ScanExportFormat { self == .areaTarget ? .areaTarget : .immersal }
    }

    private var platform: CloudPlatform { CloudPlatform(rawValue: platformID) ?? .areaTarget }

    private var platformSwitchingDisabled: Bool {
        if scanStartPending || viewModel.isExporting { return true }
        switch viewModel.state {
        case .scanning, .processing: return true
        default: return false
        }
    }

    #if DEBUG
    private var isDebugDiagnosticsEnabled: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("-ModelPreviewDebug")
            || processInfo.arguments.contains("-ScannerDebug")
            || processInfo.environment["MODEL_PREVIEW_DEBUG"] == "1"
            || processInfo.environment["SCANNER_DEBUG"] == "1"
    }
    #endif

    var body: some View {
        ZStack {
            ScannerTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                platformHeader.zIndex(1)
                switch viewModel.state {
                case .requestingPermission:
                    permissionView
                case .permissionDenied:
                    permissionDeniedView
                case .ready:
                    readyView
                case .scanning:
                    scanningView
                case .processing(let status):
                    processingView(status: status)
                case .preview(let path):
                    previewView(exportPath: path)
                case .error(let message):
                    errorView(message: message)
                case .history:
                    ScanHistoryView(viewModel: viewModel)
                }
            }
        }
        .accentColor(ScannerTheme.accent)
        .tint(ScannerTheme.actionBlue)
        .onAppear {
            viewModel.setAppActive(scenePhase == .active)
            viewModel.deletionBlocked = { [mapping = mappingModel, areaTarget = areaTargetModel] path in
                mapping.blocksDeletion(of: path) || areaTarget.deletionBlocked(scanPath: path)
            }
            viewModel.deletionBlockReason = { [mapping = mappingModel, areaTarget = areaTargetModel] path in
                let reasons = [
                    areaTarget.sourceProtectionReason(scanPath: path),
                    mapping.blocksDeletion(of: path) ? "Immersal 本机任务仍需保留这条扫描，或任务记录暂不可用。请到 Immersal 任务页检查记录；确认不再需要的任务可停止本机跟踪。" : nil
                ].compactMap { $0 }
                return reasons.isEmpty ? nil : reasons.joined(separator: "\n\n")
            }
        }
        .task {
            areaTargetModel.setAppActive(scenePhase == .active)
            await mappingModel.monitorJobs()
        }
        .onChange(of: viewModel.state) { state in
            if state != .ready { scanStartPending = false }
        }
        .onChange(of: scenePhase) { phase in
            viewModel.setAppActive(phase == .active)
            // Temporary inactive states (e.g. password autofill) must not cancel login.
            if phase == .background {
                mappingModel.setAppActive(false)
                areaTargetModel.setAppActive(false)
            } else if phase == .active {
                mappingModel.setAppActive(true)
                areaTargetModel.setAppActive(true)
            }
        }
        .onChange(of: viewModel.exportShareURL) { url in
            if let url {
                sharePayload = SharePayload(activityItems: [url])
                viewModel.exportShareURL = nil
            }
        }
        .alert("导出失败", isPresented: Binding(get: { viewModel.exportError != nil }, set: { if !$0 { viewModel.exportError = nil } })) {
            Button("好", role: .cancel) { viewModel.exportError = nil }
        } message: { Text(viewModel.exportError ?? "") }
        .sheet(item: $sharePayload) { payload in
            ActivityView(activityItems: payload.activityItems)
        }
        .sheet(item: $immersalRequest) { request in
            ImmersalMappingView(model: mappingModel, scanDirectory: request.directory, selectScan: {
                immersalRequest = nil
                viewModel.showHistory()
            })
        }
        .sheet(item: $areaTargetRequest) { request in
            AreaTargetProcessingView(model: areaTargetModel, scanDirectory: request.directory,
                displayName: request.directory.map { ScanHistoryItem.displayName(for: $0.lastPathComponent) } ?? "",
                entryPoint: request.directory == nil ? .tasks : .preparation,
                selectScan: {
                    areaTargetRequest = nil
                    viewModel.showHistory()
                })
        }
        .fullScreenCover(item: $previewItem) { item in
            ModelPreviewView(fileURL: item.url)
        }
    }

    private var platformHeader: some View {
        HStack {
            Menu {
                ForEach(CloudPlatform.allCases) { candidate in
                    Button {
                        guard !platformSwitchingDisabled else { return }
                        platformID = candidate.rawValue
                    } label: {
                        if candidate == platform { Label(candidate.title, systemImage: "checkmark") }
                        else { Text(candidate.title) }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: platform.symbol).foregroundStyle(ScannerTheme.accent)
                    Text(platform.title).font(.headline).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(ScannerTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain).foregroundStyle(.primary)
            .disabled(platformSwitchingDisabled)
            .accessibilityLabel("当前平台：\(platform.title)，切换平台")
            .accessibilityHint(platformSwitchingDisabled ? "请先完成当前扫描或导出" : "切换平台后继续使用同一扫描")
            .accessibilityIdentifier("platform-switcher")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private func actionRow(_ title: String, symbol: String, subtitle: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(ScannerTheme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var scanHistoryButton: some View {
        Button(action: { viewModel.showHistory() }) {
            actionRow("扫描历史", symbol: "clock.arrow.circlepath")
        }
        .buttonStyle(ScannerRowButtonStyle())
        .background(ScannerTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .disabled(platformSwitchingDisabled)
        .accessibilityLabel("扫描历史")
        .accessibilityIdentifier("scan-history")
    }

    private var permissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill").font(.system(size: 48)).foregroundStyle(.primary)
            Text("需要摄像头权限").font(.title2).foregroundStyle(.primary)
            Text("需要使用摄像头和 LiDAR 来扫描 3D 场景")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Button("授权摄像头") { viewModel.requestCameraPermission() }
                .buttonStyle(.borderedProminent).tint(ScannerTheme.actionBlue)
            scanHistoryButton.padding(.horizontal, 40)
            cloudTasksButton.padding(.horizontal, 40)
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.badge.ellipsis").font(.system(size: 48)).foregroundStyle(.red)
            Text("摄像头权限被拒绝").font(.title2).foregroundStyle(.primary)
            Text("请在系统设置中开启摄像头权限").font(.body).foregroundStyle(.secondary)
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }.buttonStyle(.borderedProminent).tint(ScannerTheme.actionBlue)
            scanHistoryButton.padding(.horizontal, 40)
            cloudTasksButton.padding(.horizontal, 40)
        }
    }

    private var readyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("场景扫描").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text(platform == .areaTarget ? "采集场景，生成模型与空间定位资产。" : "采集场景，上传图像并创建定位地图。")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Label(platform == .areaTarget ? "Area Target 处理流程" : "Immersal 建图流程", systemImage: "icloud")
                        .font(.headline)
                    Text(platform == .areaTarget ? "扫描 → 预览 → 上传处理 → 下载资产" : "扫描 → 预览 → 上传图像 → 云端建图")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("扫描记录和预览共用，可从顶部切换处理平台。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(ScannerTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                Button(action: { scanStartPending = true; viewModel.startScanning() }) {
                    Label("开始扫描", systemImage: "viewfinder")
                }
                .buttonStyle(ScannerPrimaryButtonStyle()).disabled(scanStartPending)
                VStack(spacing: 10) {
                    scanHistoryButton
                    cloudTasksButton
                }
            }
            .padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
    }

    private var scanningView: some View {
        ZStack {
            ARScanningView(session: viewModel.arSession).ignoresSafeArea()
            VStack {
                ScanProgressView(progress: viewModel.progress).padding(.top, 60)
                Text(viewModel.gpsStatus).font(.caption).foregroundStyle(.white)
                    .padding(8).background(.black.opacity(0.6), in: Capsule())
                Spacer()
                Button(action: { viewModel.stopAndProcess() }) {
                    Label("停止扫描", systemImage: "stop.circle.fill")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }.buttonStyle(.borderedProminent).tint(.red)
                .padding(.horizontal, 40).padding(.bottom, 40)
            }
        }
    }

    private func processingView(status: String) -> some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView().scaleEffect(2.0).tint(ScannerTheme.actionBlue)
            Text(status).font(.title3).foregroundStyle(.primary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
    }

    private func previewView(exportPath: String) -> some View {
        let files = viewModel.exportedFiles(for: exportPath)
        let foundModel = viewModel.modelURL(for: exportPath)
        let immersalReason = viewModel.immersalUnavailableReason
        let scan = viewModel.scanHistory.first { $0.directoryPath == exportPath }

        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("扫描已保存", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.green)
                    Text(ScanHistoryItem.displayName(for: URL(fileURLWithPath: exportPath).lastPathComponent))
                        .font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    if let scan {
                        HStack(spacing: 18) {
                            Label("\(scan.keyframeCount) 帧", systemImage: "photo")
                            Label(String(format: "%.1f MB", scan.totalSizeMB), systemImage: "doc")
                        }.font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("原始扫描已保存在本机，可用于两种处理流程。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                #if DEBUG
                if isDebugDiagnosticsEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DEBUG 导出路径:").font(.caption.weight(.bold)).foregroundStyle(.yellow)
                        Text(exportPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        Text("DEBUG 文件 (\(files.count)):").font(.caption.weight(.bold)).foregroundStyle(.yellow)
                        ForEach(files, id: \.self) { file in
                            Text("  • \(file)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Text("DEBUG 模型:").font(.caption.weight(.bold)).foregroundStyle(.yellow)
                        Text(foundModel?.lastPathComponent ?? "nil")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(foundModel != nil ? .green : .red)
                    }
                    .padding(.horizontal, 20)
                }
                #endif

                VStack(spacing: 0) {
                    Button {
                        if let url = foundModel { previewItem = IdentifiableURL(url: url) }
                    } label: {
                        actionRow("预览 3D 模型", symbol: "cube")
                    }
                    .disabled(foundModel == nil || viewModel.isExporting)
                    Divider().padding(.leading, 54)
                    Button {
                        viewModel.beginExport(format: platform.exportFormat, from: exportPath)
                    } label: {
                        actionRow("导出扫描数据", symbol: "square.and.arrow.up",
                                  subtitle: platform == .areaTarget ? "Area Target 原始扫描" : "Immersal 扫描包")
                    }
                    .disabled(viewModel.isExporting || (platform == .immersal && immersalReason != nil))
                }
                .buttonStyle(ScannerRowButtonStyle())
                .background(ScannerTheme.surface, in: RoundedRectangle(cornerRadius: 12))

                if let status = viewModel.exportStatus {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { ProgressView(); Text(status).font(.callout) }
                        Button("取消导出", role: .cancel) { viewModel.cancelExport() }.frame(minHeight: 44)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(platform == .areaTarget ? "Area Target 处理" : "Immersal 建图").font(.headline)
                    Text(platform == .areaTarget ? "上传扫描，云端处理后下载模型与定位资产。" : "上传扫描图像与位姿，在云端创建定位地图。")
                        .font(.callout).foregroundStyle(.secondary)
                    if platform == .areaTarget {
                        Button {
                            areaTargetRequest = ScanProcessingRequest(directory: URL(fileURLWithPath: exportPath, isDirectory: true))
                        } label: {
                            Label("上传并处理", systemImage: "icloud.and.arrow.up")
                        }
                        .buttonStyle(ScannerPrimaryButtonStyle()).disabled(viewModel.isExporting)
                        .accessibilityIdentifier("area-target-open-upload")
                    } else {
                        Button {
                            immersalRequest = ScanProcessingRequest(directory: URL(fileURLWithPath: exportPath, isDirectory: true))
                        } label: {
                            Label("上传并建图", systemImage: "icloud.and.arrow.up")
                        }
                        .buttonStyle(ScannerPrimaryButtonStyle())
                        .disabled(viewModel.isExporting || immersalReason != nil)
                        .accessibilityIdentifier("immersal-open-upload")
                        if let immersalReason {
                            Text("Immersal 暂不可用：\(immersalReason)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Button("扫描历史") { viewModel.showHistory() }
                    Spacer()
                    Button("重新扫描") { viewModel.resetToReady() }
                }
                .font(.callout).frame(minHeight: 44).disabled(viewModel.isExporting)
            }
            .padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity, alignment: .top)
        }
        .task(id: exportPath) { await viewModel.prepareExportAvailability(for: exportPath) }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(.orange)
            Text("出错了").font(.title2).foregroundStyle(.primary)
            Text(message).font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Button("返回") { viewModel.resetToReady() }
                .buttonStyle(.borderedProminent).tint(ScannerTheme.actionBlue)
        }
    }

    private var cloudTasksButton: some View {
        Group {
            if platform == .areaTarget {
                Button { areaTargetRequest = ScanProcessingRequest(directory: nil) } label: {
                    actionRow("处理任务", symbol: "icloud")
                }
                .accessibilityLabel("Area Target 处理任务")
                .accessibilityIdentifier("area-target-open-tasks")
            } else {
                Button { immersalRequest = ScanProcessingRequest(directory: nil) } label: {
                    actionRow("建图任务", symbol: "icloud")
                }
                .accessibilityLabel("Immersal 建图任务")
                .accessibilityIdentifier("immersal-open-tasks")
            }
        }
        .buttonStyle(ScannerRowButtonStyle())
        .background(ScannerTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .disabled(platformSwitchingDisabled)
    }
}
