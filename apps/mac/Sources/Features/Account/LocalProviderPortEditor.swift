// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

#if os(macOS)
struct LocalProviderPortEditor: View {
    let provider: LocalProvider
    let save: (Int) async throws -> Void
    @State private var text: String
    @State private var saving = false
    @State private var error: String?

    init(provider: LocalProvider, save: @escaping (Int) async throws -> Void) {
        self.provider = provider
        self.save = save
        _text = State(initialValue: String(provider.currentPort))
    }

    private var port: Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(value), (1...65_535).contains(number) else { return nil }
        return number
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Text(L10n.text("common.local_provider_port")).font(Theme.caption)
                TextField(String(provider.standardPort), text: $text)
                    .font(Theme.mono(12))
                    .textFieldStyle(.themedMono(12))
                    .frame(width: 84)
                    .accessibilityLabel(L10n.text("common.local_provider_port_label", provider.name))
                    .onSubmit { if let port, port != provider.currentPort { apply(port) } }
                Button(L10n.text("common.save"), .save) { if let port { apply(port) } }
                    .disabled(port == nil || port == provider.currentPort || saving)
                Button(L10n.text("common.local_provider_use_default"), .restore) {
                    text = String(provider.standardPort)
                    error = nil
                    if provider.standardPort != provider.currentPort { apply(provider.standardPort) }
                }
                    .disabled(text == String(provider.standardPort) || saving)
                if saving { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Text(provider.baseURL).font(Theme.mono(11)).foregroundStyle(.secondary).textSelection(.enabled)
            if let error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.danger)
            } else if port == nil {
                Text(L10n.text("common.local_provider_port_invalid")).font(Theme.caption).foregroundStyle(Theme.danger)
            }
        }
        .onChange(of: provider.currentPort) { _, value in text = String(value) }
    }

    private func apply(_ value: Int) {
        guard !saving else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await save(value)
                text = String(value)
            } catch { self.error = FriendlyError.from(error.localizedDescription).message }
        }
    }
}
#endif
