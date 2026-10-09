import SwiftUI

struct ScanHomeView: View {
    @ObservedObject var viewModel: ScanViewModel
    let start: () -> Void

    var body: some View {
        WorkspacePage {
            WorkspaceHeading(title: "扫描新场景", subtitle: "记录空间，保存为可重复使用的扫描数据。")
            VStack(alignment: .leading, spacing: 10) {
                Text("场景名称").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                TextField("例如：一楼大厅", text: $viewModel.draftSceneName)
                    .font(.body).padding(16)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("new-scene-name")
                Text(viewModel.draftSceneName.count > 60 ? "名称最多 60 个字符" : "可稍后命名，保存后也能随时改名。")
                    .font(.caption).foregroundStyle(viewModel.draftSceneName.count > 60 ? Color.red : .secondary)
            }
            Image(systemName: "viewfinder")
                .font(.system(size: 72, weight: .light)).foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity).padding(.vertical, 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 16) {
                Label("缓慢移动，覆盖不同角度", systemImage: "move.3d")
                Label("保持光线充足，避开大面积反光", systemImage: "sun.max")
                Label("使用支持 LiDAR 的 iPhone 或 iPad", systemImage: "camera")
            }
            .font(.subheadline).foregroundStyle(.secondary)
            WorkspacePrimaryButton(title: "开始扫描", symbol: "record.circle", action: start)
                .disabled(viewModel.draftSceneName.count > 60)
                .accessibilityIdentifier("start-scan")
        }
    }
}

struct ScanCaptureView: View {
    @ObservedObject var viewModel: ScanViewModel
    let platform: ScannerPlatform

    var body: some View {
        ZStack {
            ARScanningView(session: viewModel.arSession).ignoresSafeArea()
            VStack(spacing: 14) {
                HStack {
                    Label(platform.title, systemImage: platform.symbol).font(.subheadline.weight(.semibold))
                    Spacer()
                    Label("扫描中", systemImage: "record.circle.fill").foregroundStyle(.red)
                }
                .padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                ScanProgressView(progress: viewModel.progress)
                Text(viewModel.draftSceneName.isEmpty ? "新场景" : viewModel.draftSceneName)
                    .font(.headline).foregroundStyle(.white)
                    .padding(10).background(.black.opacity(0.6), in: Capsule())
                Text(viewModel.gpsStatus).font(.caption).foregroundStyle(.white)
                    .padding(8).background(.black.opacity(0.6), in: Capsule())
                Spacer()
                Text("缓慢移动，尽量覆盖空间中的不同视角")
                    .font(.subheadline).foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding(12).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                WorkspacePrimaryButton(title: "结束并保存", symbol: "stop.circle.fill") { viewModel.stopAndProcess() }
                    .tint(.red)
                    .accessibilityIdentifier("stop-scan")
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
        }
    }
}
