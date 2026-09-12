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
            TextField("Task title", text: $fields.title, axis: .vertical)
                .font(Theme.title3.weight(.semibold)).textFieldStyle(.plain)
                .accessibilityLabel("Task title")
            ThemeRule()
            Text(fields.backend == "sh" ? "Command" : "Prompt").font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            TextEditor(text: $fields.prompt)
                .font(Theme.callout).scrollContentBackground(.hidden)
                .frame(minHeight: minimumHeight)
                .accessibilityLabel(fields.backend == "sh" ? "Task command" : "Task prompt")
            Text(draftStatus)
                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Task settings").font(Theme.callout.weight(.semibold))
            AppMenuPicker(title: "Folder", options: folderOptions, selection: $fields.workspaceID)
            AppMenuPicker(title: "Priority", options: [("low", "Low"), ("normal", "Normal"), ("high", "High")], selection: $fields.priority)
            AppMenuPicker(title: "Agent", options: backendOptions, selection: Binding(
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
                    AppMenuPicker(title: "Effort", options: options(backend.efforts, preserving: fields.effort), selection: $fields.effort)
                }
                if !fields.model.isEmpty && !backend.models.contains(fields.model) {
                    Text("This computer does not list the saved model. Keep it or choose another.")
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
                Toggle("No time limit", isOn: $fields.noTimeLimit).toggleStyle(BrandCheckboxStyle())
                if !fields.noTimeLimit {
                    TextField("Time limit", text: $fields.budgetValue).textFieldStyle(.themed)
                        .accessibilityLabel("Time limit")
                    AppMenuPicker(title: "Unit", options: [("minutes", "Minutes"), ("seconds", "Seconds")], selection: $fields.budgetUnit)
                }
            }
            if showValidation, let validation = fields.validation {
                Text(validation).font(Theme.caption).foregroundStyle(Theme.danger)
            }
        }
    }

    private var folderOptions: [(value: String, label: String)] {
        var values = [(value: "", label: "Uncategorized")] + folders.map { (value: $0.id, label: $0.name) }
        if !values.contains(where: { $0.value == fields.workspaceID }) { values.append((fields.workspaceID, "Unavailable folder")) }
        return values
    }
    private var backendOptions: [(value: String, label: String)] {
        var values = [(value: "", label: "Choose later")] + backends.map { (value: $0.id, label: $0.label) }
        if !values.contains(where: { $0.value == fields.backend }) { values.append((fields.backend, "\(fields.backend) · Unavailable")) }
        return values
    }
    private func options(_ values: [String], preserving value: String) -> [(value: String, label: String)] {
        [(value: "", label: "Default")] + (values.contains(value) || value.isEmpty ? values : values + [value]).map { (value: $0, label: values.contains($0) ? $0 : "\($0) · Saved choice") }
    }
}
