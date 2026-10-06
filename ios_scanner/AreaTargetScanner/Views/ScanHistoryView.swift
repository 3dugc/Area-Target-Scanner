import SwiftUI

/// 扫描历史列表视图，支持查看、导出和删除
struct ScanHistoryView: View {
    @ObservedObject var viewModel: ScanViewModel
    @State private var itemToDelete: ScanHistoryItem? = nil
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            HStack {
                Button(action: { viewModel.resetToReady() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                    .foregroundStyle(ScannerTheme.accent)
                    .frame(minWidth: 64, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text("扫描历史")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
                Spacer()
                // 与返回按钮等宽，保持标题居中。
                Color.clear.frame(width: 64, height: 44).accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 8)

            if viewModel.scanHistory.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundStyle(ScannerTheme.accent)
                    Text("暂无扫描记录")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.scanHistory) { item in
                            ScanHistoryRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewModel.state = .preview(item.directoryPath)
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        itemToDelete = item
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        viewModel.deleteScan(item)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) { itemToDelete = nil }
            Button("删除", role: .destructive) {
                if let item = itemToDelete {
                    viewModel.deleteScan(item)
                    itemToDelete = nil
                }
            }
        } message: {
            Text("将删除扫描数据和对应的 ZIP 文件，此操作不可撤销。")
        }
        .alert("无法删除扫描", isPresented: Binding(get: { viewModel.deletionError != nil }, set: { if !$0 { viewModel.deletionError = nil } })) {
            Button("好", role: .cancel) { viewModel.deletionError = nil }
        } message: { Text(viewModel.deletionError ?? "") }
    }
}

/// 单条扫描记录行
private struct ScanHistoryRow: View {
    let item: ScanHistoryItem

    var body: some View {
        HStack(spacing: 14) {
            // 图标
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(ScannerTheme.accent.opacity(0.10))
                    .frame(width: 44, height: 44)
                Image(systemName: item.hasTexture ? "cube.fill" : "cube")
                    .font(.system(size: 20))
                    .foregroundStyle(ScannerTheme.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.formattedDate)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                HStack(spacing: 12) {
                    Label {
                        Text("\(item.keyframeCount) 帧")
                    } icon: {
                        Image(systemName: "camera").foregroundStyle(ScannerTheme.accent)
                    }
                    Label {
                        Text(String(format: "%.1f MB", item.totalSizeMB))
                    } icon: {
                        Image(systemName: "doc").foregroundStyle(ScannerTheme.accent)
                    }
                    if item.hasImmersalZip {
                        Text("Immersal")
                    }
                    if item.hasZip {
                        Image(systemName: "doc.zipper")
                            .foregroundStyle(ScannerTheme.accent)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(ScannerTheme.accent)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("扫描记录 \(item.formattedDate), \(item.keyframeCount) 帧, \(String(format: "%.1f", item.totalSizeMB)) MB")
    }
}
