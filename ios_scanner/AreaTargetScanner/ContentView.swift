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

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingExportFormats = false
    @StateObject private var viewModel = ScanViewModel()
    @State private var sharePayload: SharePayload? = nil
    @State private var previewItem: IdentifiableURL? = nil

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
            // ★ 深蓝色渐变背景 — v6 (sampleBilinear Y-flip fix)
            LinearGradient(
                colors: [Color(red: 0.0, green: 0.05, blue: 0.3),
                         Color(red: 0.0, green: 0.02, blue: 0.12)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

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
        .onAppear { viewModel.checkCameraPermission() }
        .onChange(of: scenePhase) { phase in viewModel.setAppActive(phase == .active) }
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
        .fullScreenCover(item: $previewItem) { item in
            ModelPreviewView(fileURL: item.url)
        }
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
        }
    }

    private var readyView: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "arkit").font(.system(size: 64)).foregroundStyle(.red)
            Text("Area Target Scanner").font(.largeTitle.weight(.semibold)).foregroundStyle(.white)
            Text("v6 — 纹理采样修复版").font(.body).foregroundStyle(.white.opacity(0.6))
            Spacer()
            VStack(spacing: 12) {
                Button(action: { viewModel.startScanning() }) {
                    Label("开始扫描", systemImage: "record.circle")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }.buttonStyle(.borderedProminent).tint(.red)

                Button(action: { viewModel.showHistory() }) {
                    Label("扫描历史", systemImage: "clock.arrow.circlepath")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }.buttonStyle(.bordered).tint(.white)
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

                Text("处理完成").font(.title2.weight(.semibold)).foregroundStyle(.white)

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

                    Button(action: { showingExportFormats = true }) {
                        Label("导出", systemImage: "square.and.arrow.up")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent).tint(.blue)
                    .disabled(viewModel.isExporting)
                    .confirmationDialog("选择导出格式", isPresented: $showingExportFormats, titleVisibility: .visible) {
                        Button("Area Target 原格式") { viewModel.beginExport(format: .areaTarget, from: exportPath) }
                        Button("Immersal 格式") { viewModel.beginExport(format: .immersal, from: exportPath) }
                            .disabled(immersalReason != nil)
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text(immersalReason.map { "Immersal 暂不可用：\($0)" } ?? "同一次扫描可分别导出两种格式。")
                    }
                    if let status = viewModel.exportStatus {
                        ProgressView().tint(.white)
                        Text(status).font(.callout).foregroundStyle(.white)
                        Button("取消导出", role: .cancel) { viewModel.cancelExport() }
                            .buttonStyle(.bordered).tint(.white)
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
}
