import SwiftUI

/// 扫描历史列表视图，支持查看、分享和删除
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
                    .foregroundStyle(.white)
                }
                Spacer()
                Text("扫描历史")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                // 占位，保持标题居中
                Text("返回").opacity(0).accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if viewModel.scanHistory.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("暂无扫描记录")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.5))
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
                    .fill(item.hasTexture ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
                    .frame(width: 44, height: 44)
                Image(systemName: item.hasTexture ? "cube.fill" : "cube")
                    .font(.system(size: 20))
                    .foregroundStyle(item.hasTexture ? .green : .blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.formattedDate)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                HStack(spacing: 12) {
                    Label("\(item.keyframeCount) 帧", systemImage: "camera")
                    Label(String(format: "%.1f MB", item.totalSizeMB), systemImage: "doc")
                    if item.hasZip {
                        Image(systemName: "doc.zipper")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .cornerRadius(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("扫描记录 \(item.formattedDate), \(item.keyframeCount) 帧, \(String(format: "%.1f", item.totalSizeMB)) MB")
    }
}
