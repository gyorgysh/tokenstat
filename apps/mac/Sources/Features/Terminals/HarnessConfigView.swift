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
        ThemedSheet(
            title: L10n.text("apple.harnessconfigview.configure_0.76d41ce7", "\(profile.name)"),
            subtitle: L10n.text("apple.harnessconfigview.model_effort_and_compaction_for_the_next_s.7b884582"),
            icon: .settings,
            scrolls: true,
            onClose: close
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.command)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.controlGlyph)
                        .textSelection(.enabled)
                    if let path = config?.path, !path.isEmpty {
                        Text(path)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.controlGlyph)
                            .textSelection(.enabled)
                    }
                }

                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Space.l)
                } else if let config, config.available, !config.fields.isEmpty {
                    if let error {
                        Banner(text: error, severity: .warning)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(config.fields) { field in
                            fieldRow(field)
                        }
                    }
                } else {
                    Text(config.flatMap { $0.available ? nil : $0.reason } ?? error
                         ?? L10n.text("apple.harnessconfigview.this_tool_has_no_settings_tokenstat_can_ch.3288645e"))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            Button(L10n.text("common.cancel"), .dismiss, role: .cancel) { close() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            if saving {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.accent)
            }
            Spacer()
            Button(L10n.text("common.save"), .save) {
                Task {
                    await save()
                    if error == nil { close() }
                }
            }
            .buttonStyle(AccentButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(saving || loading || !dirty)
        }
        .modalFrame(width: 560, height: 560)
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
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            switch field.kind {
            case "bool":
                BrandToggleChip(
                    title: (draft[field.key] ?? "") == "true" ? L10n.text("apple.harnessconfigview.on.13001175") : L10n.text("apple.harnessconfigview.off.ca7981b4"),
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
            case "number" where field.min != nil && field.max != nil:
                numberSlider(field)
            default:
                TextField(field.label, text: stringBinding(field.key))
                    .textFieldStyle(.themed)
                    .font(Theme.font(13))
            }
            if let hint = field.hint {
                Text(hint)
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A compaction threshold, as a dial rather than as digits.
    ///
    /// The band and the step come from the host, which reads them from what
    /// the tool documents. An empty value is not zero: it means the key is
    /// absent and the tool is using its own default, so the handle starts
    /// there and the number beside it says so.
    @ViewBuilder
    private func numberSlider(_ field: HarnessConfigField) -> some View {
        let low = Double(field.min ?? 0)
        let high = Double(field.max ?? 100)
        let step = Double(max(field.step ?? 1, 1))
        let current = draft[field.key] ?? ""
        let fallback = Double(field.fallback ?? field.min ?? 0)
        let number = Double(current) ?? fallback
        HStack(spacing: Theme.Space.s) {
            Slider(
                value: Binding(
                    get: { min(max(number, low), high) },
                    set: { draft[field.key] = String(Int($0.rounded())) }
                ),
                in: low...high,
                step: step
            )
            Text(current.isEmpty ? L10n.text("apple.harnessconfigview.0_default.bf9cca93", "\(Int(fallback))") : numberLabel(field, current))
                .font(Theme.mono(11))
                .foregroundStyle(current.isEmpty ? .secondary : .primary)
                .frame(minWidth: 92, alignment: .trailing)
                .monospacedDigit()
        }
    }

    /// Percentages read as they are written. Token counts get separators,
    /// because 900000 and 90000 are the same shape at a glance.
    private func numberLabel(_ field: HarnessConfigField, _ value: String) -> String {
        guard let number = Int(value) else { return value }
        if (field.max ?? 0) <= 100 { return "\(number)" }
        return number.formatted(.number.grouping(.automatic))
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
