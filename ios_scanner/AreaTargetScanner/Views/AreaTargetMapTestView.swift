import SwiftUI
import ARKit
import SceneKit

struct AreaTargetMapTestView: View {
    let job: AreaTargetProcessingJob
    @StateObject private var localizer: AreaTargetLocalizationSession
    @State private var showMesh = true
    @State private var enhancedRecognition = false
    @State private var meshOpacity = 0.6
    @State private var savedReport: LocalizationEvaluationReport?
    @State private var reportURL: URL?
    @State private var saveError: String?
    @State private var saving = false
    @State private var reportSaveTask: Task<Bool, Never>?
    @State private var leaving = false
    @State private var showingSaveFailure = false
    @State private var discardingReport = false
    private let reports: AreaTargetReportAccess
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(job: AreaTargetProcessingJob, localizer: AreaTargetLocalizationSession? = nil,
         reportStore: LocalizationReportStore = LocalizationReportStore()) {
        self.job = job
        self.reports = AreaTargetReportAccess(store: reportStore)
        _localizer = StateObject(wrappedValue: localizer ?? AreaTargetLocalizationSession())
    }

    private var active: Bool { localizer.isLoading || localizer.isRunning }
    private var recognitionMode: AreaTargetRecognitionMode { enhancedRecognition ? .enhanced : .standard }
    private var report: LocalizationEvaluationReport? {
        AreaTargetReportPresentation.report(current: localizer.report, saved: savedReport, isActive: active)
    }
    private var identity: LocalizationAssetIdentity {
        LocalizationAssetIdentity(provider: .areaTarget, assetID: job.savedAsset?.jobID ?? job.id,
            sourceFingerprint: ScanSourceFingerprint.valid(job.sourceFingerprint) ? job.sourceFingerprint : nil,
            engineVersion: AreaTargetLocalizationSession.engineVersion, assetDigest: job.remote?.result?.sha256,
            buildConfiguration: LocalizationCoreMetadata.liveBuildConfiguration(base: buildConfiguration),
            areaTargetRecognitionMode: recognitionMode)
    }
    private var buildConfiguration: String { job.localizationBuildConfiguration }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.displayName).font(.largeTitle.bold())
                        Text("Area Target · 本机离线定位").font(.subheadline).foregroundStyle(.secondary)
                        Label(job.savedAsset == nil ? "请先下载处理结果" : "特征库已在本机 · 可离线测试",
                            systemImage: job.savedAsset == nil ? "arrow.down.circle" : "checkmark.circle.fill")
                            .foregroundStyle(job.savedAsset == nil ? Color.secondary : Color.green)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("增强识别", isOn: $enhancedRecognition)
                            .accessibilityIdentifier("area-target-enhanced-recognition")
                        Text("普通定位失败时追加识别尝试，可能增加等待和耗电。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.disabled(active || saving || leaving)
                    if localizer.isRunning { camera }
                    else if localizer.isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在准备离线测试").font(.headline)
                            Text("载入特征库并核对原扫描后打开相机。").foregroundStyle(.secondary)
                        }.padding(28).frame(maxWidth: .infinity)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    } else { instructions }
                    ImmersalMeshOverlayControls(showMesh: $showMesh, opacity: $meshOpacity,
                        isReady: localizer.scanMesh != nil, status: localizer.meshStatus)
                    Text(localizer.status).font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("area-target-localization-status")
                    if let report {
                        LocalizationEvaluationView(report: report, isLive: localizer.isRunning)
                        if !active, let reportURL {
                            ShareLink(item: reportURL) { Label("导出测试报告", systemImage: "square.and.arrow.up") }
                        }
                    } else {
                        Label("尚未测试，暂不能评价定位表现", systemImage: "chart.bar.xaxis").foregroundStyle(.secondary)
                    }
                    if let saveError {
                        Text(saveError).foregroundStyle(.red).font(.subheadline)
                        if localizer.report != nil, !active { Button("重试保存报告") { saveReport() }.disabled(saving) }
                    }
                    Text("测试使用新拍摄的相机帧在手机本机定位，不上传测试图片。网格是原扫描模型；图像匹配失败时暂时隐藏叠加。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("离线定位测试").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("完成") { finishAndDismiss() }.disabled(leaving)
                    .accessibilityIdentifier("area-target-test-done")
            } }
            .safeAreaInset(edge: .bottom) { controls }
        }
        .task { await restoreReport() }
        .onChange(of: enhancedRecognition) { _ in
            savedReport = nil; reportURL = nil
            Task { await restoreReport() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background, active { finish(message: "已暂停：返回前台后可重新开始一段测试。") }
        }
        .onChange(of: localizer.isRunning) { running in if !running { saveReport() } }
        .onDisappear {
            if active { localizer.stop() }
            if !discardingReport { saveReport() }
        }
        .interactiveDismissDisabled(saving || leaving)
        .alert("测试报告未保存", isPresented: $showingSaveFailure) {
            Button("重试并退出") { finishAndDismiss() }
            Button("仍然退出", role: .destructive) { discardingReport = true; dismiss() }
            Button("留在此页", role: .cancel) {}
        } message: {
            Text("本段测试已结束，但报告保存失败。可以重试保存，或退出并放弃本段报告。")
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("回到扫描过的空间", systemImage: "viewfinder").font(.title3.bold())
            Text("对准有细节的墙面或固定物体，缓慢走动至少 3 米并改变观察角度。建议测试 60–90 秒。")
            Text("识别成功后显示测试标记；已核对来源的原扫描网格可叠加，用于观察墙角、门框和地面边缘是否重合。")
                .foregroundStyle(.secondary)
            if !ScanSourceFingerprint.valid(job.sourceFingerprint) {
                Text("此旧资产尚未记录扫描来源，仍可定位并查看原始指标，暂不生成可比较总分。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var camera: some View {
        ZStack(alignment: .bottomLeading) {
            ImmersalCameraPreview(session: localizer.session, worldFromMap: localizer.worldFromScan,
                markerInMap: localizer.markerInScan, scanMesh: localizer.scanMesh, mapFromScan: matrix_identity_float4x4,
                showMesh: showMesh, meshOpacity: meshOpacity).frame(height: 320)
            Label(localizer.worldFromScan == nil ? "等待识别" : "空间已识别", systemImage: "viewfinder")
                .font(.subheadline.bold()).foregroundStyle(.white).padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
        }.clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if active {
                Button { finish() } label: {
                    Label(localizer.isLoading ? "停止准备" : "结束并保存本段测试", systemImage: "stop.circle").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
            } else if let asset = job.savedAsset {
                Button {
                    saveError = nil; reportURL = nil
                    localizer.start(asset: asset, sourceFingerprint: job.sourceFingerprint, scanDirectory: job.scanDirectory,
                        assetDigest: job.remote?.result?.sha256, buildConfiguration: buildConfiguration,
                        recognitionMode: recognitionMode)
                } label: {
                    Label(report == nil ? "开始离线测试" : "重新测试", systemImage: "viewfinder").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(saving)
            } else {
                Text("返回处理任务下载结果后，即可开始离线测试。").font(.subheadline).foregroundStyle(.secondary)
            }
            if saving { HStack { ProgressView(); Text("正在保存测试报告…") }.font(.footnote) }
        }.padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity).background(.regularMaterial)
    }

    private func finish(message: String = "本段测试已结束") {
        if active { localizer.stop(message: message) }
        saveReport()
    }

    private func finishAndDismiss() {
        guard !leaving else { return }
        leaving = true
        if active { localizer.stop() }
        guard let report = localizer.report, report != savedReport else { leaving = false; dismiss(); return }
        saveReport()
        Task { @MainActor in
            let saved = await reportSaveTask?.value ?? false
            leaving = false
            if saved { dismiss() }
            else { showingSaveFailure = true }
        }
    }

    @MainActor private func restoreReport() async {
        do {
            let requestedIdentity = identity
            let restored = try await reports.latest(identity: requestedIdentity)
            guard !Task.isCancelled, localizer.report == nil, !active, identity == requestedIdentity else { return }
            savedReport = restored.report; reportURL = restored.url
        } catch {
            guard !Task.isCancelled else { return }
            saveError = "暂时无法读取已保存报告，仍可开始新测试。"
        }
    }

    private func saveReport() {
        guard let report = localizer.report, report != savedReport, !saving else { return }
        saving = true
        reportSaveTask = Task { @MainActor in await publish(report) }
    }

    @MainActor private func publish(_ report: LocalizationEvaluationReport) async -> Bool {
        defer { saving = false }
        do {
            let url = try await reports.save(report: report)
            savedReport = report; reportURL = url; saveError = nil
            return true
        } catch {
            saveError = "测试已结束，但报告保存失败，请重试保存。"
            return false
        }
    }
}

enum AreaTargetReportPresentation {
    static func report(current: LocalizationEvaluationReport?, saved: LocalizationEvaluationReport?,
                       isActive: Bool) -> LocalizationEvaluationReport? {
        current ?? (isActive ? nil : saved)
    }
}

/// Disk scans and fsync stay off the view's actor; report writes finish even when
/// navigation dismisses the screen immediately after stopping the camera.
private final class AreaTargetReportAccess: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.areatarget.localization-report-ui", qos: .utility)
    private let store: LocalizationReportStore
    init(store: LocalizationReportStore) { self.store = store }
    struct Saved: @unchecked Sendable { let report: LocalizationEvaluationReport?; let url: URL? }
    func latest(identity: LocalizationAssetIdentity) async throws -> Saved {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do { continuation.resume(returning: try Saved(report: self.store.latest(identity: identity), url: self.store.latestURL(identity: identity))) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func save(report: LocalizationEvaluationReport) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do { continuation.resume(returning: try self.store.save(report: report)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
