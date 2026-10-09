import SwiftUI

@MainActor
struct ScannerSettingsView: View {
    @ObservedObject var settings: ScannerSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("建图模式").font(.headline)
                    Picker("建图模式", selection: $settings.processingProfile) {
                        ForEach(AreaTargetProcessingProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("scanner-settings-processing-profile")
                    Text(settings.processingProfile.detail)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Area Target 云端处理")
                }
                Section {
                    Toggle("UV 与纹理重建", isOn: $settings.uvUnwrap)
                        .accessibilityIdentifier("scanner-settings-uv-unwrap")
                    Text(settings.uvUnwrap
                        ? "由云端重新展开模型 UV 并生成纹理。"
                        : "沿用原扫描的 UV 与纹理。仅适用于已有完整材质和纹理的扫描；缺少资源时无法上传处理。")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("模型与纹理")
                }
                Section {
                    Button("恢复默认设置") { settings.resetToDefaults() }
                        .frame(minHeight: 44).accessibilityIdentifier("scanner-settings-reset")
                } footer: {
                    Text("设置自动保存，仅用于之后新建的任务。已有任务、地图和暂停续传继续使用各自记录的设置。默认 Quality，开启 UV 与纹理重建。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("scanner-settings-done")
                }
            }
        }
    }
}
