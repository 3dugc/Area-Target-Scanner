import SwiftUI

/// Shared native surfaces for the three workspace pages.
struct WorkspacePage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

struct WorkspaceHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.body).foregroundStyle(.secondary)
        }
    }
}

struct WorkspacePrimaryButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}

struct WorkspaceRow: View {
    let title: String
    let symbol: String
    var value: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 24)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let value { Text(value).multilineTextAlignment(.trailing).foregroundStyle(.secondary) }
        }
        .font(.body)
        .padding(16)
        .frame(minHeight: 54)
        .accessibilityElement(children: .combine)
    }
}

struct WorkspaceEmptyState: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct SceneNameEditor: View {
    let originalName: String
    let save: (String) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    @FocusState private var isFocused: Bool

    init(name: String, save: @escaping (String) -> String?) {
        originalName = name
        self.save = save
        _name = State(initialValue: name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：一楼大厅", text: $name)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit { commit() }
                        .accessibilityIdentifier("scene-name-field")
                } header: { Text("场景名称") } footer: {
                    Text("支持中文，最多 60 个字符。两个平台共用此名称。")
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("rename-error") }
            }
            .navigationTitle("重命名场景")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commit() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 60)
                        .accessibilityIdentifier("save-scene-name")
                }
            }
            .onAppear { isFocused = true }
        }
    }

    private func commit() {
        error = save(name)
        if error == nil { dismiss() }
    }
}
