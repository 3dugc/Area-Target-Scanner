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

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = ScanViewModel()
    @StateObject private var mappingModel = ImmersalMappingModel()
    @StateObject private var areaTargetModel = AreaTargetProcessingModel.shared
    @State private var showingAreaTarget = false
    @State private var areaTargetDirectory: URL?
    @State private var showingImmersal = false
    @State private var uploadDirectory: URL?
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
            // Shared scanning background.
            LinearGradient(
                colors: [Color(red: 0.0, green: 0.05, blue: 0.3),
                         Color(red: 0.0, green: 0.02, blue: 0.12)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

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
        .sheet(isPresented: $showingImmersal) {
            ImmersalMappingView(model: mappingModel, scanDirectory: uploadDirectory, selectScan: {
                showingImmersal = false
                viewModel.showHistory()
            })
        }
        .sheet(isPresented: $showingAreaTarget) {
            AreaTargetProcessingView(model: areaTargetModel, scanDirectory: areaTargetDirectory,
                displayName: areaTargetDirectory.map { ScanHistoryItem.displayName(for: $0.lastPathComponent) } ?? "",
                entryPoint: areaTargetDirectory == nil ? .tasks : .preparation,
                selectScan: {
                    showingAreaTarget = false
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
                    Image(systemName: platform.symbol)
                    Text(platform.title).font(.headline).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .disabled(platformSwitchingDisabled)
            .accessibilityLabel("当前平台：\(platform.title)，切换平台")
            .accessibilityHint(platformSwitchingDisabled ? "请先完成当前扫描或导出" : "切换平台后继续使用同一扫描")
            .accessibilityIdentifier("platform-switcher")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
    }

    private var scanHistoryButton: some View {
        Button(action: { viewModel.showHistory() }) {
            Label("扫描历史", systemImage: "clock.arrow.circlepath")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
        }
        .buttonStyle(.bordered).tint(.white)
        .disabled(platformSwitchingDisabled)
        .accessibilityIdentifier("scan-history")
    }

    private var permissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill").font(.system(size: 48)).foregroundStyle(.white)
            Text("需要摄像头权限").font(.title2).foregroundStyle(.white)
            Text("需要使用摄像头和 LiDAR 来扫描 3D 场景")
                .font(.body).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Button("授权摄像头") { viewModel.requestCameraPermission() }
                .buttonStyle(.borderedProminent).tint(.red)
            scanHistoryButton.padding(.horizontal, 40)
            cloudTasksButton.padding(.horizontal, 40)
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.badge.ellipsis").font(.system(size: 48)).foregroundStyle(.red)
            Text("摄像头权限被拒绝").font(.title2).foregroundStyle(.white)
            Text("请在系统设置中开启摄像头权限").font(.body).foregroundStyle(.white.opacity(0.6))
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }.buttonStyle(.borderedProminent).tint(.orange)
            scanHistoryButton.padding(.horizontal, 40)
            cloudTasksButton.padding(.horizontal, 40)
        }
    }

    private var readyView: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "arkit").font(.system(size: 64)).foregroundStyle(.red)
            Text("Area Target Scanner").font(.largeTitle.weight(.semibold)).foregroundStyle(.white)
            Text("一次扫描，可用于当前平台的云处理。")
                .font(.body).foregroundStyle(.white.opacity(0.8))
            Spacer()
            VStack(spacing: 12) {
                Button(action: { scanStartPending = true; viewModel.startScanning() }) {
                    Label("开始扫描", systemImage: "record.circle")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }.buttonStyle(.borderedProminent).tint(.red)
                .disabled(scanStartPending)

                scanHistoryButton
                cloudTasksButton
            }
            .padding(.horizontal, 40).padding(.bottom, 40)
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
            ProgressView().scaleEffect(2.0).tint(.red)
            Text(status).font(.title3).foregroundStyle(.white)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
    }

    private func previewView(exportPath: String) -> some View {
        let files = viewModel.exportedFiles(for: exportPath)
        let foundModel = viewModel.modelURL(for: exportPath)
        let immersalReason = viewModel.immersalUnavailableReason

        return ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48)).foregroundStyle(.green)
                    .padding(.top, 60)

                Text("扫描已保存").font(.title2.weight(.semibold)).foregroundStyle(.white)
                Text(ScanHistoryItem.displayName(for: URL(fileURLWithPath: exportPath).lastPathComponent))
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8))

                #if DEBUG
                if isDebugDiagnosticsEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DEBUG 导出路径:").font(.caption.weight(.bold)).foregroundStyle(.yellow)
                        Text(exportPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
                        Text("DEBUG 文件 (\(files.count)):").font(.caption.weight(.bold)).foregroundStyle(.yellow)
                        ForEach(files, id: \.self) { file in
                            Text("  • \(file)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
                        }
                        Text("DEBUG 模型:").font(.caption.weight(.bold)).foregroundStyle(.yellow)
                        Text(foundModel?.lastPathComponent ?? "nil")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(foundModel != nil ? .green : .red)
                    }
                    .padding(.horizontal, 20)
                }
                #endif

                VStack(spacing: 12) {
                    Button(action: {
                        if let url = foundModel {
                            previewItem = IdentifiableURL(url: url)
                        }
                    }) {
                        Label("预览 3D 模型", systemImage: "cube")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .disabled(foundModel == nil || viewModel.isExporting)

                    Button {
                        viewModel.beginExport(format: platform.exportFormat, from: exportPath)
                    } label: {
                        Label(platform == .areaTarget ? "导出 Area Target 原始扫描" : "导出 Immersal 扫描包", systemImage: "square.and.arrow.up")
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered).tint(.white)
                    .disabled(viewModel.isExporting || (platform == .immersal && immersalReason != nil))
                    if let status = viewModel.exportStatus {
                        ProgressView().tint(.white)
                        Text(status).font(.callout).foregroundStyle(.white)
                        Button("取消导出", role: .cancel) { viewModel.cancelExport() }
                            .buttonStyle(.bordered).tint(.white)
                    }

                    if platform == .areaTarget {
                        Button {
                            areaTargetDirectory = URL(fileURLWithPath: exportPath, isDirectory: true)
                            showingAreaTarget = true
                        } label: {
                            Label("Area Target 云处理", systemImage: "icloud.and.arrow.up")
                                .font(.title3.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent).tint(.teal)
                        .disabled(viewModel.isExporting)
                        .accessibilityIdentifier("area-target-open-upload")
                    } else {
                        Button {
                            uploadDirectory = URL(fileURLWithPath: exportPath)
                            showingImmersal = true
                        } label: {
                            Label("上传到 Immersal 并建图", systemImage: "icloud.and.arrow.up")
                                .font(.title3.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent).tint(.indigo)
                        .disabled(viewModel.isExporting || immersalReason != nil)
                        if let immersalReason {
                            Text("Immersal 暂不可用：\(immersalReason)")
                                .font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                    }

                    Button(action: { viewModel.resetToReady() }) {
                        Label("重新扫描", systemImage: "arrow.counterclockwise")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered).tint(.white)
                    .disabled(viewModel.isExporting)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
        }
        .task(id: exportPath) { await viewModel.prepareExportAvailability(for: exportPath) }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(.yellow)
            Text("出错了").font(.title2).foregroundStyle(.white)
            Text(message).font(.body).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Button("返回") { viewModel.resetToReady() }
                .buttonStyle(.borderedProminent).tint(.red)
        }
    }

    private var cloudTasksButton: some View {
        Group {
            if platform == .areaTarget {
                Button {
                    areaTargetDirectory = nil
                    showingAreaTarget = true
                } label: {
                    Label("Area Target 账号与任务", systemImage: "icloud")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .accessibilityIdentifier("area-target-open-tasks")
            } else {
                Button {
                    uploadDirectory = nil
                    showingImmersal = true
                } label: {
                    Label("Immersal 账号与任务", systemImage: "icloud")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .accessibilityIdentifier("immersal-open-tasks")
            }
        }
        .buttonStyle(.bordered).tint(.white)
        .disabled(platformSwitchingDisabled)
    }
}
