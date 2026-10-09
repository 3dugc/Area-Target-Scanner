import SwiftUI

struct ScanProcessingView: View {
    @ObservedObject var viewModel: ScanViewModel
    let platform: ScannerPlatform
    let scan: ScanHistoryItem?
    let selectRecord: () -> Void
    let rename: (ScanHistoryItem) -> Void
    let preview: (URL) -> Void
    let upload: (URL) -> Void
    let showTasks: () -> Void
    var benchmarkReadiness = LocalizationBenchmarkReadiness(state: .noScan)
    var compareAlgorithms: () -> Void = {}

    var body: some View {
        WorkspacePage {
            if let scan {
                WorkspaceHeading(title: "扫描已保存", subtitle: platform.supportsCloudMapping ? "上传扫描图片，创建空间地图。" : "上传扫描数据，处理后下载到本机。")
                sceneSummary(scan)
                previewRow(scan)
            } else {
                WorkspaceHeading(title: "处理场景", subtitle: "从扫描记录中选择一个场景。")
                WorkspaceEmptyState(title: "还没有选择场景", message: "扫描完成后可直接处理，也可以选择已有扫描。", symbol: "cube")
                WorkspacePrimaryButton(title: "选择扫描记录", symbol: "list.bullet.rectangle", action: selectRecord)
            }
            benchmarkEntry
            if platform.supportsCloudMapping || platform.supportsAreaTargetProcessing {
                Button(action: showTasks) {
                    HStack(spacing: 14) {
                        Image(systemName: "icloud").font(.system(size: 20)).frame(width: 24)
                        Text(platform.supportsAreaTargetProcessing ? "处理任务" : "建图任务")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .padding(16).frame(minHeight: 54)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityIdentifier(platform.supportsAreaTargetProcessing ? "area-target-tasks" : "immersal-tasks")
                if platform.supportsCloudMapping, let scan, let reason = viewModel.immersalUnavailableReason {
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                        .id(scan.id)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let scan { actionFooter(scan) }
        }
        .task(id: availabilityKey) {
            if platform.supportsCloudMapping, let scan { await viewModel.prepareExportAvailability(for: scan.directoryPath) }
        }
    }

    private var availabilityKey: String { "\(platform.rawValue):\(scan?.id ?? "")" }

    private var benchmarkEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: compareAlgorithms) {
                HStack(spacing: 14) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 20)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("算法比较").font(.headline)
                        Text("录制视频 · 保存 · 运行两套算法 · 查看报告")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            .disabled(!benchmarkReadiness.canOpen || viewModel.isExporting)
            .accessibilityIdentifier("localization-benchmark-entry")
            Text(benchmarkReadiness.message).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("localization-benchmark-readiness")
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func sceneSummary(_ scan: ScanHistoryItem) -> some View {
        VStack(spacing: 0) {
            Button { rename(scan) } label: {
                HStack(spacing: 14) {
                    Image(systemName: "cube").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 24)
                    Text(scan.displayName).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "pencil").foregroundStyle(Color.accentColor)
                }.padding(16).frame(minHeight: 54)
            }
            .buttonStyle(.plain).accessibilityLabel("场景：\(scan.displayName)，重命名")
            .accessibilityIdentifier("rename-selected-scene")
            Divider().padding(.horizontal, 16)
            WorkspaceRow(title: scan.date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)), symbol: "clock")
            Divider().padding(.horizontal, 16)
            WorkspaceRow(title: "\(scan.keyframeCount) 帧", symbol: "photo", value: String(format: "%.1f MB", scan.totalSizeMB))
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func previewRow(_ scan: ScanHistoryItem) -> some View {
        let model = viewModel.modelURL(for: scan.directoryPath)
        return Button {
            if let model { preview(model) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "cube").font(.system(size: 20)).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model == nil ? "暂无可预览的模型" : "预览 3D 模型")
                    Text(model == nil ? "扫描数据已保存" : "本地模型已就绪")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }
            .padding(16).frame(minHeight: 54)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(model == nil || viewModel.isExporting)
        .accessibilityIdentifier("preview-model")
    }

    private func actionFooter(_ scan: ScanHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if platform == .areaTarget {
                WorkspacePrimaryButton(title: "上传并处理", symbol: "icloud.and.arrow.up") {
                    upload(URL(fileURLWithPath: scan.directoryPath))
                }
                .disabled(viewModel.isExporting).accessibilityIdentifier("upload-area-target")
                Button("导出扫描数据") { viewModel.beginExport(format: .areaTarget, from: scan.directoryPath) }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(viewModel.isExporting).accessibilityIdentifier("export-area-target")
            } else {
                WorkspacePrimaryButton(title: "上传并建图", symbol: "icloud.and.arrow.up") {
                    upload(URL(fileURLWithPath: scan.directoryPath))
                }
                .disabled(viewModel.isExporting || viewModel.immersalUnavailableReason != nil)
                .accessibilityIdentifier("upload-immersal")
                Button("导出 Immersal 数据") {
                    viewModel.beginExport(format: .immersal, from: scan.directoryPath)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(viewModel.isExporting || viewModel.immersalUnavailableReason != nil)
                .accessibilityIdentifier("export-immersal")
            }
            if let status = viewModel.exportStatus {
                HStack { ProgressView(); Text(status).font(.subheadline) }
                Button("取消导出", role: .cancel) { viewModel.cancelExport() }.frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: 640).frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
