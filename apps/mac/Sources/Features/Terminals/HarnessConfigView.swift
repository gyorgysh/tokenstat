// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import SwiftUI

/// The (i) badge's form: the handful of settings that change how a long
/// session goes, and the command path the bubble used to be.
///
/// Save is the only write. Opening this view only reads.
struct HarnessConfigView: View {
    let profile: LaunchProfile

    @State private var config: HarnessConfig?
    @State private var draft: [String: String] = [:]
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(profile.name)
                    .font(.callout.weight(.medium))
                Text(profile.command)
                    .font(Theme.mono(11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let path = config?.path, !path.isEmpty {
                    Text(path)
                        .font(Theme.mono(11))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let config, config.available, !config.fields.isEmpty {
                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(config.fields) { field in
                        fieldRow(field)
                    }
                    HStack {
                        if saving {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                        Button("Save", .save) { Task { await save() } }
                            .buttonStyle(AccentButtonStyle(small: true))
                            .disabled(saving || !dirty)
                    }
                } else if let reason = config.flatMap({ $0.available ? nil : $0.reason }) ?? error {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Space.m)
            .frame(width: 320, alignment: .leading)
        }
        .frame(maxHeight: 480)
        .task { await load() }
    }

    private var dirty: Bool {
        guard let config else { return false }
        return config.fields.contains { field in
            draft[field.key] ?? "" != (field.value ?? "")
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: HarnessConfigField) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            switch field.kind {
            case "bool":
                BrandToggleChip(
                    title: (draft[field.key] ?? "") == "true" ? "On" : "Off",
                    isOn: boolBinding(field.key)
                )
            case "choice":
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(choiceOptions(field), id: \.value) { option in
                        ChoiceChip(
                            title: option.label,
                            isSelected: (draft[field.key] ?? "") == option.value
                        ) {
                            draft[field.key] = option.value
                        }
                    }
                }
            default:
                TextField(field.label, text: stringBinding(field.key))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            if let hint = field.hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func choiceOptions(_ field: HarnessConfigField) -> [(value: String, label: String)] {
        let current = draft[field.key] ?? ""
        var options = field.options
        if !current.isEmpty, !options.contains(current) {
            options.append(current)
        }
        return options.map { (value: $0, label: $0) }
    }

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { draft[key] ?? "" },
            set: { draft[key] = $0 }
        )
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { (draft[key] ?? "") == "true" },
            set: { draft[key] = $0 ? "true" : "false" }
        )
    }

    private func load() async {
        loading = true
        error = nil
        do {
            let loaded = try await Bridge.harnessConfig(id: profile.id)
            config = loaded
            draft = Dictionary(uniqueKeysWithValues: loaded.fields.map {
                ($0.key, $0.value ?? "")
            })
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func save() async {
        guard let config, dirty else { return }
        saving = true
        error = nil
        var values: [String: String] = [:]
        for field in config.fields {
            let next = draft[field.key] ?? ""
            if next != (field.value ?? ""), !next.isEmpty || field.kind == "bool" {
                values[field.key] = next
            }
        }
        do {
            let saved = try await Bridge.saveHarnessConfig(id: profile.id, values: values)
            self.config = saved
            draft = Dictionary(uniqueKeysWithValues: saved.fields.map {
                ($0.key, $0.value ?? "")
            })
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}
#endif
