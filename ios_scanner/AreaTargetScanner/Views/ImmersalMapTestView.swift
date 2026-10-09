import SwiftUI
import ARKit
import SceneKit

struct ImmersalMapTestView: View {
    let sceneName: String
    let scanDirectory: URL?
    let sourceFingerprint: String?
    let buildConfiguration: String
    private let reportStore: LocalizationReportStore
    @State private var showMesh = true
    @State private var meshOpacity = 0.6
    @State private var savedEvaluation: LocalizationEvaluationReport?
    @State private var evaluationURL: URL?
    @State private var savingEvaluation = false
    @State private var evaluationSaveError: String?
    @State private var evaluationSaveTask: Task<Bool, Never>?
    @State private var leaving = false
    @StateObject private var model: ImmersalMapTestModel
    @StateObject private var localizer = ImmersalLocalizationSession()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(mapID: Int, userID: Int, sceneName: String, scanDirectory: URL? = nil, sourceFingerprint: String? = nil,
         buildConfiguration: String = "cloud-default;continuous-live;no-ar-prior", model: ImmersalMapTestModel? = nil,
         reportStore: LocalizationReportStore = LocalizationReportStore()) {
        self.sceneName = sceneName
        self.reportStore = reportStore
        self.scanDirectory = scanDirectory
        self.sourceFingerprint = sourceFingerprint; self.buildConfiguration = buildConfiguration
        _model = StateObject(wrappedValue: model ?? ImmersalMapTestModel(mapID: mapID, userID: userID))
    }

    private var active: Bool { localizer.isRunning || localizer.isLoading }
    private var report: ImmersalLocalizationQualityReport? { localizer.report ?? (active ? nil : model.savedReport) }
    private var evaluationReport: LocalizationEvaluationReport? { localizer.evaluationReport ?? (active ? nil : savedEvaluation) }
    private var evaluationExportURL: URL? { evaluationReport == savedEvaluation ? evaluationURL : nil }
    private var identity: LocalizationAssetIdentity {
        let digest = model.mapURL?.deletingPathExtension().lastPathComponent
        return .init(provider: .immersal, assetID: "\(model.userID)/\(model.mapID)",
            sourceFingerprint: ScanSourceFingerprint.valid(sourceFingerprint) ? sourceFingerprint : nil,
            engineVersion: ImmersalLocalizationSession.engineVersion,
            assetDigest: ScanSourceFingerprint.valid(digest) ? digest : nil,
            buildConfiguration: LocalizationCoreMetadata.immersalLiveBuildConfiguration(base: buildConfiguration))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sceneName).font(.largeTitle.bold())
                        Text("地图 #\(model.mapID) · Immersal").font(.subheadline).foregroundStyle(.secondary)
                        Label(model.mapURL == nil ? "先下载地图，再现场测试" : "地图已在本机 · 可离线测试",
                              systemImage: model.mapURL == nil ? "arrow.down.circle" : "checkmark.circle.fill")
                            .foregroundStyle(model.mapURL == nil ? Color.secondary : Color.green)
                    }
                    if localizer.isRunning { camera }
                    else if localizer.isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在准备离线测试").font(.headline)
                            Text("完成准备后将打开相机。").foregroundStyle(.secondary)
                        }.padding(28).frame(maxWidth: .infinity)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("回到扫描过的空间", systemImage: "viewfinder").font(.title3.bold())
                            Text("对准有细节的墙面或固定物体，缓慢走动至少 3 米并改变观察角度。建议测试 60–90 秒。")
                            Text(scanDirectory == nil ? "识别成功后会出现蓝色测试标记。边走边观察它是否稳定停在同一位置。" : "识别成功后叠加原扫描网格，对照墙角、门框和地面边缘是否重合。")
                                .foregroundStyle(.secondary)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    }
                    if scanDirectory != nil {
                        ImmersalMeshOverlayControls(showMesh: $showMesh, opacity: $meshOpacity,
                            isReady: localizer.scanMesh != nil, status: localizer.meshStatus)
                    }
                    Text(localizer.status).font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("localization-status")
                    if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                    if let evaluationReport {
                        LocalizationEvaluationView(report: evaluationReport, isLive: localizer.isRunning && localizer.evaluationReport != nil)
                        if !active, let evaluationExportURL {
                            ShareLink(item: evaluationExportURL) { Label("导出测试报告", systemImage: "square.and.arrow.up") }
                        }
                    } else if let report {
                        ImmersalQualityReportView(report: report, isLive: localizer.isRunning)
                        if !active, let url = model.reportURL, model.savedReport != nil {
                            ShareLink(item: url) { Label("导出测试报告", systemImage: "square.and.arrow.up") }
                        }
                    } else {
                        Label("尚未测试，暂不能评价地图质量", systemImage: "chart.bar.xaxis").foregroundStyle(.secondary)
                    }
                    if let evaluationSaveError {
                        Text(evaluationSaveError).foregroundStyle(.red)
                        Button("重试保存报告") { saveEvaluation() }.disabled(savingEvaluation)
                    }
                    if !active, let url = model.mapURL {
                        HStack {
                            ShareLink(item: url) { Label("导出地图", systemImage: "square.and.arrow.up") }
                            Spacer()
                            Button("重新下载") { model.download() }.disabled(model.isDownloading)
                        }
                    }
                    Text("测试使用新拍摄的相机帧在手机本机定位，不上传测试图片。下载需要联网，已下载地图无需网络。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("离线定位测试").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { finishAndDismiss() }.disabled(leaving) } }
            .safeAreaInset(edge: .bottom) { controls }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background, active { finish(message: "已暂停：返回前台后可重新开始一段测试。") }
        }
        .onChange(of: localizer.isRunning) { running in
            if !running { model.save(localizer.report); saveEvaluation() }
        }
        .interactiveDismissDisabled(active || savingEvaluation || leaving || (localizer.evaluationReport != nil && localizer.evaluationReport != savedEvaluation))
        .task(id: model.mapURL) { await restoreEvaluation() }
        .onDisappear { finish(); model.cancelDownload() }
    }

    private var camera: some View {
        ZStack(alignment: .bottomLeading) {
            ImmersalCameraPreview(session: localizer.session, worldFromMap: localizer.worldFromMap, markerInMap: localizer.markerInMap,
                                  scanMesh: localizer.scanMesh, mapFromScan: localizer.mapFromScan, showMesh: showMesh, meshOpacity: meshOpacity)
                .frame(height: 320)
            VStack(alignment: .leading, spacing: 8) {
                Image("ImmersalLogo").resizable().scaledToFit().frame(width: 116)
                    .accessibilityLabel("Powered by Immersal")
                Label(localizer.worldFromMap == nil ? "等待识别" : "空间已识别", systemImage: "viewfinder")
                    .font(.subheadline.bold()).foregroundStyle(.white)
            }.padding(16).background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
        }.clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if model.isRestoring {
                HStack { ProgressView(); Text("正在检查本机地图…") }
            } else if model.isDownloading {
                HStack { ProgressView(); Text("正在下载并校验地图…") }
                Button("取消下载") { model.cancelDownload() }
            } else if active {
                Button { finish() } label: { Label(localizer.isLoading ? "停止准备" : "结束并保存本段测试", systemImage: "stop.circle").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            } else if let url = model.mapURL {
                Button { localizer.start(url: url, mapID: model.mapID, userID: model.userID, scanDirectory: scanDirectory,
                    sourceFingerprint: sourceFingerprint, assetDigest: identity.assetDigest, buildConfiguration: buildConfiguration) } label: {
                    Label(report == nil ? "开始离线测试" : "重新测试", systemImage: "viewfinder").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(savingEvaluation || leaving)
            } else {
                Button { model.download() } label: { Label("下载地图到本机", systemImage: "arrow.down.circle").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }.padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
            .background(.regularMaterial)
    }

    private func finish(message: String = "本段测试已结束") {
        if active { localizer.stop(message: message) }
        model.save(localizer.report)
        saveEvaluation()
    }
    private func restoreEvaluation() async {
        let requested = identity
        let store = reportStore
        do {
            let saved = try await Task.detached(priority: .utility) {
                return (try store.latest(identity: requested), try store.latestURL(identity: requested))
            }.value
            guard !Task.isCancelled, !active, localizer.evaluationReport == nil else { return }
            savedEvaluation = saved.0; evaluationURL = saved.1
        } catch { evaluationSaveError = "报告暂不能读取：\(error.localizedDescription)" }
    }
    private func saveEvaluation() {
        guard !savingEvaluation, let measured = localizer.evaluationReport, measured != savedEvaluation else { return }
        savingEvaluation = true
        let store = reportStore
        evaluationSaveTask = Task {
            do {
                let url = try await Task.detached(priority: .utility) { try store.save(report: measured) }.value
                savedEvaluation = measured; evaluationURL = url; evaluationSaveError = nil
                savingEvaluation = false; return true
            } catch {
                evaluationSaveError = "本段报告未保存：\(error.localizedDescription)"
                savingEvaluation = false; return false
            }
        }
    }
    private func finishAndDismiss() {
        guard !leaving else { return }
        leaving = true
        if active { localizer.stop() }
        model.save(localizer.report)
        guard let measured = localizer.evaluationReport, measured != savedEvaluation else { leaving = false; dismiss(); return }
        saveEvaluation()
        Task {
            let saved = await evaluationSaveTask?.value ?? false
            leaving = false
            if saved { dismiss() }
        }
    }
}

struct ImmersalQualityReportView: View {
    let report: ImmersalLocalizationQualityReport
    var isLive = false
    @Environment(\.sizeCategory) private var sizeCategory
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isLive ? "本段实时结果" : "最近一次测试").font(.headline)
            Text(report.qualitySummary).font(.title3.bold())
            if !isLive { Text(report.date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour().minute())).font(.caption).foregroundStyle(.secondary) }
            VStack(spacing: 12) {
                row("定位成功率", String(format: "%.0f%% · %d / %d 帧", report.successRate * 100, report.successCount, report.attemptCount))
                row("首次定位", seconds(report.firstSuccessSeconds))
                row("定位耗时 · 中位 / P95", "\(seconds(report.medianLatencySeconds)) / \(seconds(report.p95LatencySeconds))")
                row("对齐位置变化 · P95", report.p95TranslationDeltaMeters.map { String(format: "%.2f m", $0) } ?? "—")
                row("对齐角度变化 · P95", report.p95RotationDeltaDegrees.map { String(format: "%.1f°", $0) } ?? "—")
                row("已测试时长 / 走动", String(format: "%.0f s / %.1f m", report.duration, report.testedTravelMeters))
            }.font(.subheadline)
            ForEach(report.recommendations, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.secondary) }
            DisclosureGroup("评价依据与限制") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(report.thresholdsSummary)
                    Text(report.metricLimitations)
                }.font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.subheadline)
        }.padding(20).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
    private func seconds(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0) } ?? "—" }
    @ViewBuilder private func row(_ name: String, _ value: String) -> some View {
        if sizeCategory.isAccessibilityCategory {
            VStack(alignment: .leading, spacing: 4) { Text(name).foregroundStyle(.secondary); Text(value) }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline) { Text(name).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing) }
        }
    }
}
