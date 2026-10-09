import SwiftUI
import AVKit

@MainActor
struct LocalizationBenchmarkView: View {
    let areaJob: AreaTargetProcessingJob
    let immersalJob: ImmersalMappingJob
    let scanDirectory: URL
    private let areaAssetStore: AreaTargetAssetStoring
    private let mapStore: ImmersalMapStore
    @StateObject private var localizer: LocalizationBenchmarkSession
    @State private var mapURL: URL?
    @State private var checking = true
    @State private var validationMessage: String?
    @State private var player: AVPlayer?
    @State private var savedVideoURL: URL?
    private enum DeletionRequest: Identifiable {
        case saved(LocalizationRecording), invalid(UUID)
        var id: UUID { switch self { case .saved(let recording): return recording.id; case .invalid(let id): return id } }
    }
    @State private var pendingDeletion: DeletionRequest?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(areaJob: AreaTargetProcessingJob, immersalJob: ImmersalMappingJob, scanDirectory: URL,
         localizer: LocalizationBenchmarkSession? = nil,
         areaAssetStore: AreaTargetAssetStoring = AreaTargetAssetStore(),
         mapStore: ImmersalMapStore = ImmersalMapStore()) {
        self.areaJob = areaJob; self.immersalJob = immersalJob; self.scanDirectory = scanDirectory
        self.areaAssetStore = areaAssetStore; self.mapStore = mapStore
        _localizer = StateObject(wrappedValue: localizer ?? LocalizationBenchmarkSession())
    }

    private var active: Bool { [.preparing, .capturing, .saving, .replaying].contains(localizer.stage) }
    private var canStart: Bool { !checking && validationMessage == nil && mapURL != nil && areaJob.savedAsset != nil }
    private var reportNeedsSave: Bool {
        localizer.report != nil && (localizer.reportURL == nil || localizer.markdownURL == nil)
    }
    private var areaConfiguration: String { "\(areaJob.localizationBuildConfiguration);continuous-replay" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    WorkspaceHeading(title: "录像算法比较", subtitle: areaJob.displayName)
                    Text("先录制并保存一段新测试视频，再点击比较。Area Target 和 Immersal 将依次读取同一批冻结评测帧。")
                        .foregroundStyle(.secondary)
                    if checking { HStack { ProgressView(); Text("正在核对本机地图与原扫描来源…") } }
                    if let validationMessage {
                        Text(validationMessage).foregroundStyle(.orange)
                            .accessibilityIdentifier("benchmark-validation")
                    }
                    activity
                    Text(localizer.status).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("benchmark-status")
                    if !active {
                        if localizer.selectedRecording != nil { selectedVideo }
                        savedRecordings
                        if localizer.canRetrySave, !localizer.otherRecordings.isEmpty { otherRecordingStorage }
                        if !localizer.invalidRecordingIDs.isEmpty { invalidRecordingStorage }
                        if let report = localizer.report { reportSection(report) }
                    }
                    samplingGuide
                }
                .padding(24).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("算法比较").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { close() }
                        .disabled(active || localizer.canRetrySave || reportNeedsSave)
                        .accessibilityIdentifier("benchmark-done")
                }
            }
            .safeAreaInset(edge: .bottom) {
                controls.padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
        .task { await restoreAndVerify() }
        .interactiveDismissDisabled(active || localizer.canRetrySave || reportNeedsSave)
        .onChange(of: localizer.selectedRecording?.id) { _ in updatePlayer() }
        .onChange(of: localizer.videoURL) { _ in updatePlayer() }
        .onChange(of: localizer.stage) { _ in if active { player?.pause() } }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                player?.pause()
                if localizer.stage == .capturing { localizer.stopForInterruption() }
                else if active && localizer.stage != .saving { localizer.cancel() }
            }
        }
        .onDisappear { player?.pause(); localizer.cancel() }
        .alert("删除测试录像？", isPresented: Binding(get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { request in
            Button("删除录像", role: .destructive) {
                switch request { case .saved(let recording): localizer.delete(recording); case .invalid(let id): localizer.deleteInvalid(id) }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("将删除这段录像的 MP4 和评测帧。已导出的报告仍保留。")
        }
    }

    @ViewBuilder private var activity: some View {
        switch localizer.stage {
        case .capturing:
            ImmersalCameraPreview(session: localizer.session, worldFromMap: nil, markerInMap: nil,
                scanMesh: nil, mapFromScan: nil, showMesh: false, meshOpacity: 0)
                .frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityLabel("测试录像相机预览")
            Text("\(localizer.frameCount) / 32 评测帧 · \(Int(localizer.duration)) 秒")
                .font(.headline.monospacedDigit()).accessibilityIdentifier("benchmark-capture-count")
        case .preparing, .saving:
            HStack(spacing: 12) {
                ProgressView()
                Text(localizer.stage == .preparing ? "正在准备相机…" : "正在保存本次数据…")
            }
        case .replaying:
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: localizer.replayProgress).accessibilityIdentifier("benchmark-replay-progress")
                Text("按 Area Target → Immersal 顺序比较。校准照片不计入评分。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .idle, .ready, .finished:
            if localizer.selectedRecording == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Label("回到原扫描空间并缓慢走动", systemImage: "viewfinder").font(.headline)
                    Text("改变观察角度并走动至少 3 米，建议录制 47 秒。录制完成后可以回看，也可以以后复测。")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var selectedVideo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已保存的测试视频").font(.headline)
            if let player {
                VideoPlayer(player: player).frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("benchmark-video-preview")
            }
            if let recording = localizer.selectedRecording {
                Text("\(recording.frameCount) 评测帧 · \(Int(recording.duration)) 秒 · \(recording.date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute()))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let savedVideoURL {
                ShareLink(item: savedVideoURL) { Label("分享 MP4 录像", systemImage: "square.and.arrow.up") }
                    .frame(minHeight: 44).accessibilityIdentifier("benchmark-share-video")
            }
            Text("录像无声音，保存在本机。评测使用保存的相机帧和参数；MP4 用于回看。只有点击分享时才导出录像。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var savedRecordings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已保存的测试录像").font(.headline)
            if localizer.recordings.isEmpty {
                Text("这个原扫描还没有测试录像。").font(.subheadline).foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(localizer.recordings) { recording in
                        HStack(spacing: 12) {
                            Button { player?.pause(); localizer.select(recording) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: recording.id == localizer.selectedRecording?.id ? "checkmark.circle.fill" : "play.rectangle")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(recording.date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute().second()))
                                        Text("\(recording.frameCount) 帧 · \(Int(recording.duration)) 秒")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.frame(minHeight: 54).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(localizer.canRetrySave)
                            .accessibilityLabel("选择测试录像，\(recording.frameCount) 帧，\(Int(recording.duration)) 秒")
                            .accessibilityAddTraits(recording.id == localizer.selectedRecording?.id ? .isSelected : [])
                            .accessibilityIdentifier("benchmark-recording-\(recording.id.uuidString)")
                            Button(role: .destructive) { pendingDeletion = .saved(recording) } label: {
                                Image(systemName: "trash").frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("删除这段测试录像")
                            .accessibilityIdentifier("benchmark-delete-\(recording.id.uuidString)")
                        }.padding(.horizontal, 16).padding(.vertical, 6)
                        if recording.id != localizer.recordings.last?.id { Divider().padding(.horizontal, 16) }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var otherRecordingStorage: some View {
        DisclosureGroup("释放空间：其他场景的测试录像") {
            VStack(alignment: .leading, spacing: 12) {
                Text("本机录像共用 2 GiB 容量。可删除其他场景的旧录像，保留当前未保存的录制；其他场景录像不能用于本场景比较。")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(localizer.otherRecordings) { recording in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(recording.date.formatted(.dateTime.month().day().hour().minute()))
                            Text("其他场景 · \(recording.sourceFingerprint.prefix(8)) · \(recording.frameCount) 帧")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { pendingDeletion = .saved(recording) } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                            .accessibilityLabel("删除其他场景的这段录像")
                    }
                }
            }.padding(.top, 8)
        }
    }

    private var invalidRecordingStorage: some View {
        DisclosureGroup("无法读取的测试录像 · 释放空间") {
            VStack(alignment: .leading, spacing: 12) {
                Text("这些录像未通过文件校验，无法用于比较。可以明确删除其录像包以释放本机容量。原扫描和地图保持不变。")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(localizer.invalidRecordingIDs, id: \.self) { id in
                    HStack {
                        Text("录像包 \(id.uuidString.prefix(8))").font(.subheadline.monospaced())
                        Spacer()
                        Button(role: .destructive) { pendingDeletion = .invalid(id) } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                            .accessibilityLabel("删除未通过校验的这段录像包")
                    }
                }
            }.padding(.top, 8)
        }
    }

    private func reportSection(_ report: LocalizationComparisonReport) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(report.hasComparableScores ? "本次表现分可比较" : "本次证据不足，查看原始测量结果").font(.title3.bold())
            ForEach(report.results, id: \.identity.provider) { LocalizationEvaluationView(report: $0) }
            LocalizationBenchmarkAnalysisView(comparison: report)
            VStack(alignment: .leading, spacing: 4) {
                if let url = localizer.reportURL {
                    ShareLink(item: url) { Label("分享 JSON 数据报告", systemImage: "square.and.arrow.up") }
                        .frame(minHeight: 44).accessibilityIdentifier("benchmark-share-json")
                }
                if let url = localizer.markdownURL {
                    ShareLink(item: url) { Label("分享 Markdown 分析报告", systemImage: "doc.text") }
                        .frame(minHeight: 44).accessibilityIdentifier("benchmark-share-markdown")
                }
            }
        }.accessibilityIdentifier("benchmark-report")
    }

    private var samplingGuide: some View {
        DisclosureGroup("采样、评分与数据保存") {
            VStack(alignment: .leading, spacing: 8) {
                Text("连续录制最长 60 秒；正常 ARKit 追踪时，每 1.5 秒保存一个评测帧，最多 32 帧。32 帧通常约需 47 秒。追踪中断后只保留之前连续有效的一段。")
                Text("评分至少需要 20 帧、30 秒和 3 米走动。不足时仍可保存录像并比较原始指标；有返回位姿时还需要可用的共同坐标对齐与稳定性证据。")
                Text("位姿返回率不代表定位正确率；稳定性依据 ARKit 运动参考，无独立真值时绝对定位精度未测量。固定顺序、设备温度和单次采集会影响结果。")
                Text("录像及评测帧保存在本机，可以明确删除。复制或重复回放不会成为新增独立采集。表现分用于筛查，后续优化需要独立采集和重复实验验证。")
            }.font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 8) {
            switch localizer.stage {
            case .capturing:
                WorkspacePrimaryButton(title: "停止录制并保存", symbol: "stop.circle") { localizer.finishCapture() }
                    .disabled(localizer.frameCount == 0).accessibilityIdentifier("benchmark-stop-recording")
                Button("取消本次录制", role: .cancel) { localizer.cancel() }.frame(minHeight: 44)
                    .accessibilityIdentifier("benchmark-cancel")
            case .preparing, .saving, .replaying:
                WorkspacePrimaryButton(title: localizer.stage == .replaying ? "取消比较" : "取消本次操作", symbol: "stop.circle") {
                    localizer.cancel()
                }.accessibilityIdentifier("benchmark-cancel")
            case .idle, .ready, .finished:
                if localizer.canRetrySave {
                    WorkspacePrimaryButton(title: "重试保存录像", symbol: "arrow.clockwise") { localizer.retrySave() }
                        .accessibilityIdentifier("benchmark-retry-save")
                    Button("放弃本次未保存录像", role: .destructive) { localizer.cancel() }.frame(minHeight: 44)
                } else {
                    if localizer.selectedRecording != nil {
                        WorkspacePrimaryButton(title: localizer.report == nil ? "开始比较" : "复测这段录像", symbol: "chart.bar") { runComparison() }
                            .disabled(!canStart).accessibilityIdentifier("benchmark-run-comparison")
                        Button("录制新视频") { startRecording() }.frame(minHeight: 44)
                            .disabled(!canStart).accessibilityIdentifier("benchmark-start-recording")
                    } else {
                        WorkspacePrimaryButton(title: "开始录制视频", symbol: "record.circle") { startRecording() }
                            .disabled(!canStart).accessibilityIdentifier("benchmark-start-recording")
                    }
                    if reportNeedsSave {
                        Button("重试保存报告") { localizer.retryReportSave() }.frame(minHeight: 44)
                            .accessibilityIdentifier("benchmark-retry-report-save")
                        Button("关闭并放弃未保存报告", role: .destructive) { close() }.frame(minHeight: 44)
                    }
                }
            }
        }
    }

    private func startRecording() {
        guard canStart, let source = areaJob.sourceFingerprint else { return }
        player?.pause(); localizer.start(sourceFingerprint: source)
    }

    private func runComparison() {
        guard canStart, let asset = areaJob.savedAsset, let mapURL else { return }
        player?.pause()
        localizer.run(engines: [
            AreaTargetReplayAdapter(asset: asset, sourceFingerprint: areaJob.sourceFingerprint,
                assetDigest: areaJob.remote?.result?.sha256, buildConfiguration: areaConfiguration),
            ImmersalReplayAdapter(mapURL: mapURL, job: immersalJob, scanDirectory: scanDirectory)
        ])
    }

    private func updatePlayer() {
        player?.pause(); savedVideoURL = localizer.videoURL
        player = savedVideoURL.map { AVPlayer(url: $0) }
    }

    private func close() { player?.pause(); localizer.cancel(); dismiss() }

    private func restoreAndVerify() async {
        defer { checking = false }
        let readiness = ScannerWorkspace.benchmarkReadiness(for: scanDirectory.path, areaJobs: [areaJob],
            immersalJobs: [immersalJob], areaAssetReady: { _ in true }, immersalMapReady: { _ in true })
        guard readiness.canOpen, let mapID = immersalJob.mapID, let source = areaJob.sourceFingerprint else {
            validationMessage = readiness.message; return
        }
        do {
            let area = areaJob; let immersal = immersalJob; let directory = scanDirectory
            let areaAssetStore = self.areaAssetStore; let mapStore = self.mapStore
            let verified = try await Task.detached(priority: .utility) {
                guard let asset = try areaAssetStore.asset(jobID: area.id), asset == area.savedAsset else {
                    throw ValidationFailure.areaAsset
                }
                try Task.checkCancellation()
                guard let map = try mapStore.mapURL(userID: immersal.userID, mapID: mapID) else {
                    throw ValidationFailure.immersalMap
                }
                guard try ScanSourceFingerprint.compute(directory: directory, isCancelled: { Task.isCancelled }) == source else {
                    throw ScanSourceFingerprint.Failure.changed
                }
                try Task.checkCancellation()
                return map
            }.value
            guard !Task.isCancelled else { return }
            mapURL = verified
            guard let asset = areaJob.savedAsset else { throw ValidationFailure.areaAsset }
            localizer.refresh(sourceFingerprint: source, identities: [
                AreaTargetReplayAdapter.assetIdentity(asset: asset, sourceFingerprint: source,
                    assetDigest: areaJob.remote?.result?.sha256, buildConfiguration: areaConfiguration),
                ImmersalReplayAdapter.assetIdentity(mapURL: verified, job: immersalJob)
            ])
            updatePlayer()
        } catch {
            guard !Task.isCancelled else { return }
            validationMessage = error.localizedDescription
        }
    }

    private enum ValidationFailure: LocalizedError {
        case areaAsset, immersalMap
        var errorDescription: String? {
            switch self {
            case .areaAsset: return "Area Target 本机资产校验失败，请重新下载这套地图。"
            case .immersalMap: return "请先在 Immersal 任务中下载这张地图，再回来比较。"
            }
        }
    }
}
