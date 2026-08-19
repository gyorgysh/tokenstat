// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import SwiftUI

/// How this harness starts a long session: model, effort, compaction.
///
/// A sheet, same shape as New automation, because a bubble next to a 22pt
/// badge could only show one line at a time. Save is the only write.
struct HarnessConfigView: View {
    let profile: LaunchProfile
    var onClose: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var config: HarnessConfig?
    @State private var draft: [String: String] = [:]
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Configure \(profile.name)")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Model, effort and compaction for the next session. Saved into this tool's own config.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                InspectorCloseButton(
                    action: close,
                    help: "Close",
                    label: "Close"
                )
            }

            VStack(alignment: .leading, spacing: 2) {
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
            }

            if loading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Space.l)
            } else if let config, config.available, !config.fields.isEmpty {
                if let error {
                    Banner(text: error, severity: .warning)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(config.fields) { field in
                            fieldRow(field)
                        }
                    }
                }
                .frame(maxHeight: 420)
            } else {
                Text(config.flatMap { $0.available ? nil : $0.reason } ?? error
                     ?? "This tool has no settings tokenstat can change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Theme.Space.m)
            }

            HStack {
                Button("Cancel", .dismiss, role: .cancel) { close() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                if saving {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Save", .save) {
                    Task {
                        await save()
                        if error == nil { close() }
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(saving || loading || !dirty)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 520)
        .background(Theme.panel)
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
        VStack(alignment: .leading, spacing: 6) {
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
                    .font(.system(size: 13))
            }
            if let hint = field.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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

    private func close() {
        dismiss()
        onClose()
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
            if next != (field.value ?? "") {
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
