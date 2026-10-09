import SwiftUI

/// One shared library. Platform-specific actions live in the processing page.
struct ScanHistoryView: View {
    @ObservedObject var viewModel: ScanViewModel
    let select: (ScanHistoryItem) -> Void
    let rename: (ScanHistoryItem) -> Void
    let preview: (URL) -> Void
    let didDelete: (String) -> Void
    let startScan: () -> Void
    @State private var itemToDelete: ScanHistoryItem?

    var body: some View {
        WorkspacePage {
            WorkspaceHeading(title: "扫描记录", subtitle: "保存的场景，可随时预览或继续处理。")
            if viewModel.scanHistory.isEmpty {
                WorkspaceEmptyState(title: "还没有扫描记录", message: "完成第一次扫描后，场景会保存在这里。", symbol: "tray")
                WorkspacePrimaryButton(title: "去扫描", symbol: "viewfinder", action: startScan)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.scanHistory) { item in
                        recordRow(item)
                        if item.id != viewModel.scanHistory.last?.id { Divider().padding(.leading, 64) }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .confirmationDialog("删除这个场景？", isPresented: Binding(
            get: { itemToDelete != nil }, set: { if !$0 { itemToDelete = nil } }
        ), titleVisibility: .visible, presenting: itemToDelete) { item in
            Button("删除场景", role: .destructive) {
                viewModel.deleteScan(item)
                if !viewModel.scanHistory.contains(where: { $0.id == item.id }) { didDelete(item.directoryPath) }
                itemToDelete = nil
            }
            Button("取消", role: .cancel) { itemToDelete = nil }
        } message: { item in
            Text("将删除“\(item.displayName)”的本地扫描及导出文件，两个平台都将无法再使用这份本地数据。已有云端地图会保留。")
        }
    }

    private func recordRow(_ item: ScanHistoryItem) -> some View {
        HStack(spacing: 4) {
            Button { select(item) } label: {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "cube").font(.system(size: 24)).foregroundStyle(.secondary).frame(width: 30)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.displayName).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Text(item.date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(item.keyframeCount) 帧 · \(String(format: "%.1f MB", item.totalSizeMB))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.vertical, 16).padding(.leading, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityHint("选择此场景并进入处理页")
            .accessibilityIdentifier("scan-record-\(item.id)")
            Menu {
                Button { select(item) } label: { Label("处理场景", systemImage: "gearshape") }
                if let url = viewModel.modelURL(for: item.directoryPath) {
                    Button { preview(url) } label: { Label("预览模型", systemImage: "cube") }
                }
                Button { rename(item) } label: { Label("重命名", systemImage: "pencil") }
                Button(role: .destructive) { itemToDelete = item } label: { Label("删除", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.body).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .padding(.trailing, 4).accessibilityLabel("\(item.displayName)的更多操作")
        }
    }
}
