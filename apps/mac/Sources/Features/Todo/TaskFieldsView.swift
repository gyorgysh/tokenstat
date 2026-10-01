// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Creation and editing use the same writing space and settings vocabulary.
struct TaskFieldsView: View {
    @Binding var fields: TaskEditorDraft
    let backends: [AgentBackend]
    let folders: [WorkspaceFolder]
    let wide: Bool
    let minimumHeight: CGFloat
    let draftStatus: String
    var showValidation = true
    var timeLimitStatus: String? = nil

    var body: some View {
        if wide {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                writing(minimumHeight: minimumHeight)
                ThemeRule.vertical
                settings.frame(width: 280)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                writing(minimumHeight: minimumHeight)
                settings
            }
        }
    }

    private func writing(minimumHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            TextField(L10n.text("apple.taskfieldsview.task_title.11622e0f"), text: $fields.title, axis: .vertical)
                .font(Theme.title3.weight(.semibold)).textFieldStyle(.plain)
                .accessibilityLabel(L10n.text("apple.taskfieldsview.task_title.11622e0f"))
            ThemeRule()
            Text(fields.backend == "sh" ? L10n.text("apple.taskfieldsview.command.71316697") : L10n.text("apple.taskfieldsview.prompt.5c391238")).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            TextEditor(text: $fields.prompt)
                .font(Theme.callout).scrollContentBackground(.hidden)
                .frame(minHeight: minimumHeight)
                .accessibilityLabel(fields.backend == "sh" ? L10n.text("apple.taskfieldsview.task_command.476db803") : L10n.text("apple.taskfieldsview.task_prompt.d00bc8b0"))
            Text(draftStatus)
                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(L10n.text("apple.taskfieldsview.task_settings.b8a028c3")).font(Theme.callout.weight(.semibold))
            AppMenuPicker(title: L10n.text("apple.taskfieldsview.folder.74ccd433"), options: folderOptions, selection: $fields.workspaceID)
            AppMenuPicker(title: L10n.text("apple.taskfieldsview.priority.d60dbba0"), options: [("low", L10n.text("apple.taskfieldsview.low.f793de20")), ("normal", L10n.text("apple.taskfieldsview.normal.a7248eeb")), ("high", L10n.text("apple.taskfieldsview.high.c4ebc6d4"))], selection: $fields.priority)
            AppMenuPicker(title: L10n.text("apple.taskfieldsview.agent.11b39c93"), options: backendOptions, selection: Binding(
                get: { fields.backend },
                set: { value in
                    guard value != fields.backend else { return }
                    fields.backend = value
                    fields.model = ""
                    fields.effort = ""
                }))
            if let backend = backends.first(where: { $0.id == fields.backend }) {
                if !backend.models.isEmpty || !fields.model.isEmpty {
                    FavoriteModelPicker(backendID: backend.id, models: backend.models, extra: fields.model,
                                        preservesSavedSelection: true, selection: $fields.model)
                }
                if !backend.efforts.isEmpty || !fields.effort.isEmpty {
                    AppMenuPicker(title: L10n.text("apple.taskfieldsview.effort.4387e5d3"), options: options(backend.efforts, preserving: fields.effort), selection: $fields.effort)
                }
                if !fields.model.isEmpty && !backend.models.contains(fields.model) {
                    Text(L10n.text("apple.taskfieldsview.this_computer_does_not_list_the_saved_mode.479cd2e2"))
                        .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                }
            } else if !fields.model.isEmpty || !fields.effort.isEmpty {
                Text([fields.model, fields.effort].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            }
            ThemeRule()
            if let timeLimitStatus {
                Text(timeLimitStatus).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            } else {
                Toggle(L10n.text("apple.taskfieldsview.no_time_limit.436b4b94"), isOn: $fields.noTimeLimit).toggleStyle(BrandCheckboxStyle())
                if !fields.noTimeLimit {
                    TextField(L10n.text("apple.taskfieldsview.time_limit.e592a9ca"), text: $fields.budgetValue).textFieldStyle(.themed)
                        .accessibilityLabel(L10n.text("apple.taskfieldsview.time_limit.e592a9ca"))
                    AppMenuPicker(title: L10n.text("apple.taskfieldsview.unit.4e545960"), options: [("minutes", L10n.text("apple.taskfieldsview.minutes.4f846a84")), ("seconds", L10n.text("apple.taskfieldsview.seconds.381a8e96"))], selection: $fields.budgetUnit)
                }
            }
            if showValidation, let validation = fields.validation {
                Text(validation).font(Theme.caption).foregroundStyle(Theme.danger)
            }
        }
    }

    private var folderOptions: [(value: String, label: String)] {
        var values = [(value: "", label: L10n.text("apple.taskfieldsview.uncategorized.8d40d123"))] + folders.map { (value: $0.id, label: $0.name) }
        if !values.contains(where: { $0.value == fields.workspaceID }) { values.append((fields.workspaceID, L10n.text("apple.taskfieldsview.unavailable_folder.6454a349"))) }
        return values
    }
    private var backendOptions: [(value: String, label: String)] {
        var values = [(value: "", label: L10n.text("apple.taskfieldsview.choose_later.64f99c1c"))] + backends.map { (value: $0.id, label: $0.label) }
        if !values.contains(where: { $0.value == fields.backend }) { values.append((fields.backend, L10n.text("apple.taskfieldsview.0_unavailable.1212b25c", "\(fields.backend)"))) }
        return values
    }
    private func options(_ values: [String], preserving value: String) -> [(value: String, label: String)] {
        [(value: "", label: L10n.text("apple.taskfieldsview.default.21b111cb"))] + (values.contains(value) || value.isEmpty ? values : values + [value]).map { (value: $0, label: values.contains($0) ? $0 : L10n.text("apple.taskfieldsview.0_saved_choice.8193b80c", "\($0)")) }
    }
}
