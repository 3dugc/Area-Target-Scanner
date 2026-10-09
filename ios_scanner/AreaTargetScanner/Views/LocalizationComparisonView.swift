import SwiftUI
import simd

@MainActor
struct LocalizationComparisonView: View {
    let areaJob: AreaTargetProcessingJob
    let immersalJob: ImmersalMappingJob
    let scanDirectory: URL
    private let mapStore: ImmersalMapStore
    private let reportStore: LocalizationReportStore
    @StateObject private var localizer: LocalizationComparisonSession
    @State private var mapURL: URL?
    @State private var checking = true
    @State private var enhancedRecognition = false
    @State private var validationMessage: String?
    @State private var savedReport: LocalizationComparisonReport?
    @State private var savedReportURL: URL?
    @State private var leaving = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(areaJob: AreaTargetProcessingJob, immersalJob: ImmersalMappingJob, scanDirectory: URL,
         localizer: LocalizationComparisonSession? = nil,
         mapStore: ImmersalMapStore = ImmersalMapStore(),
         reportStore: LocalizationReportStore = LocalizationReportStore()) {
        self.areaJob = areaJob; self.immersalJob = immersalJob; self.scanDirectory = scanDirectory
        self.mapStore = mapStore; self.reportStore = reportStore
        _localizer = StateObject(wrappedValue: localizer ?? LocalizationComparisonSession())
    }
    private var report: LocalizationComparisonReport? { localizer.report ?? (localizer.active ? nil : savedReport) }
    private var exportURL: URL? { localizer.report == nil ? savedReportURL : localizer.reportURL }
    private var recognitionMode: AreaTargetRecognitionMode { enhancedRecognition ? .enhanced : .standard }
    private var canStart: Bool {
        !checking && mapURL != nil && areaJob.savedAsset != nil &&
            ScanSourceFingerprint.valid(areaJob.sourceFingerprint) && areaJob.sourceFingerprint == immersalJob.sourceFingerprint
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    WorkspaceHeading(title: "同一扫描 · 同帧对比", subtitle: areaJob.displayName)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("增强识别", isOn: $enhancedRecognition)
                            .accessibilityIdentifier("comparison-enhanced-recognition")
                        Text("普通定位失败时追加识别尝试，可能增加等待和耗电。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.disabled(checking || localizer.active || leaving)
                    Text("Area Target 和 Immersal 使用同一个原始扫描。先录制一段新相机帧，再依次交给两个本机引擎识别。两家的建图预处理可能不同，报告记录各自的构建身份。")
                        .foregroundStyle(.secondary)
                    if localizer.stage == .capturing {
                        ImmersalCameraPreview(session: localizer.session, worldFromMap: nil, markerInMap: nil,
                            scanMesh: nil, mapFromScan: nil, showMesh: false, meshOpacity: 0)
                            .frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 20))
                        Text("\(localizer.frameCount) / 32 帧 · \(Int(localizer.duration)) 秒")
                            .font(.headline.monospacedDigit())
                    } else if localizer.stage == .replaying {
                        ProgressView(value: localizer.replayProgress)
                        Text("本次按 Area Target → Immersal 顺序回放。采集帧已冻结，校准照片不计入评分。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Label("回到原扫描空间并缓慢走动", systemImage: "viewfinder").font(.headline)
                        Text("保持正常相机追踪，走动至少 3 米并改变角度。建议采集满 32 帧（约 47 秒）；评分至少需要 20 帧和 30 秒。")
                            .foregroundStyle(.secondary)
                    }
                    if checking { HStack { ProgressView(); Text("正在核对本机地图与扫描来源…") } }
                    if let validationMessage { Text(validationMessage).foregroundStyle(.orange) }
                    Text(localizer.status).font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("comparison-status")
                    if let report {
                        Text(report.hasComparableScores ? "本次表现分可比较" : "本次证据不足，查看原始测量结果")
                            .font(.title3.bold())
                        ForEach(report.results, id: \.identity.provider) { LocalizationEvaluationView(report: $0) }
                        if !localizer.active, let exportURL {
                            ShareLink(item: exportURL) { Label("导出对比报告", systemImage: "square.and.arrow.up") }
                        }
                        Text("报告使用相同测试帧和相同 AR 运动参考。顺序回放减少同时运行的资源竞争，但仍受设备温度与执行顺序影响。应重复测试并查看每项指标。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("新测试图片只在本次录制与回放期间保留于内存，不上传，也不写入报告。表现分用于筛查，不代表绝对精度或所有场景下的优劣。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("算法对比").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { finishAndDismiss() }.disabled(leaving) } }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if localizer.stage == .capturing {
                        WorkspacePrimaryButton(title: "结束录制并对比", symbol: "chart.bar") { localizer.finishCapture() }
                            .disabled(localizer.frameCount == 0)
                        Button("停止本次对比") { localizer.cancel() }.frame(minHeight: 44)
                    } else if localizer.active {
                        WorkspacePrimaryButton(title: "停止本次对比", symbol: "stop.circle") { localizer.cancel() }
                    } else {
                        if localizer.report != nil, localizer.reportURL == nil {
                            Button("重试保存报告") { Task { _ = await localizer.ensureReportSaved() } }.frame(minHeight: 44)
                        }
                        WorkspacePrimaryButton(title: report == nil ? "录制共同测试帧" : "重新录制并对比", symbol: "camera") { start() }
                            .disabled(!canStart).accessibilityIdentifier("comparison-start")
                    }
                }.disabled(leaving).padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
        .task { await restoreAndVerify() }
        .onChange(of: enhancedRecognition) { _ in
            savedReport = nil; savedReportURL = nil
            Task { await restoreAndVerify() }
        }
        .interactiveDismissDisabled(localizer.active || leaving || (localizer.report != nil && localizer.reportURL == nil))
        .onChange(of: scenePhase) { if $0 == .background, localizer.active { localizer.cancel(message: "已停止：请回到前台重新录制一段共同帧。") } }
        .onDisappear { localizer.cancel() }
    }
    private var areaConfiguration: String {
        "\(areaJob.localizationBuildConfiguration);continuous-replay"
    }
    private func start() {
        guard canStart, let asset = areaJob.savedAsset, let mapURL else { return }
        localizer.start(engines: [
            AreaTargetReplayAdapter(asset: asset, sourceFingerprint: areaJob.sourceFingerprint,
                assetDigest: areaJob.remote?.result?.sha256, buildConfiguration: areaConfiguration,
                recognitionMode: recognitionMode),
            ImmersalReplayAdapter(mapURL: mapURL, job: immersalJob, scanDirectory: scanDirectory)
        ])
    }
    private func finishAndDismiss() {
        guard !leaving else { return }
        if localizer.report == nil { localizer.cancel(); dismiss(); return }
        leaving = true
        Task {
            if await localizer.ensureReportSaved() { localizer.cancel(); dismiss() }
            leaving = false
        }
    }
    private func restoreAndVerify() async {
        let requestedMode = recognitionMode
        defer { checking = false }
        guard let mapID = immersalJob.mapID, let source = areaJob.sourceFingerprint,
              ScanSourceFingerprint.valid(source), source == immersalJob.sourceFingerprint else {
            validationMessage = LocalizationComparisonError.sourceMismatch.localizedDescription; return
        }
        do {
            let userID = immersalJob.userID
            let mapStore = self.mapStore; let store = reportStore
            let localMap = try await Task.detached(priority: .utility) {
                try mapStore.mapURL(userID: userID, mapID: mapID)
            }.value
            guard !Task.isCancelled, recognitionMode == requestedMode else { return }
            mapURL = localMap
            if localMap == nil { validationMessage = "请先在 Immersal 任务中下载这张地图，再回来对比。" }
            let saved = try await Task.detached(priority: .utility) {
                return (try store.latestComparison(sourceFingerprint: source), try store.latestComparisonURL(sourceFingerprint: source))
            }.value
            guard !Task.isCancelled, recognitionMode == requestedMode else { return }
            if let measured = saved.0, let asset = areaJob.savedAsset, let localMap,
               measured.matches(identities: [
                AreaTargetReplayAdapter.assetIdentity(asset: asset, sourceFingerprint: source,
                    assetDigest: areaJob.remote?.result?.sha256, buildConfiguration: areaConfiguration,
                    recognitionMode: requestedMode),
                ImmersalReplayAdapter.assetIdentity(mapURL: localMap, job: immersalJob)
               ]) {
                savedReport = measured; savedReportURL = saved.1
            }
        } catch { validationMessage = error.localizedDescription }
    }
}
