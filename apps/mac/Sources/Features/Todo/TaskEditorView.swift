// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct TaskEditorDestination: View {
    let target: TaskEditorTarget
    let card: TodoCard
    let hostName: String
    var onSaved: () async -> Void
    var onClose: (() -> Void)? = nil
    var onRun: ((TodoCard) -> Void)? = nil
    @State private var session: TaskEditorSession?

    var body: some View {
        Group {
            if let session, session.target == target, session.saved.baseline.id == card.id {
                TaskEditorView(session: session, hostName: hostName, onSaved: onSaved, onClose: onClose, onRun: onRun)
            }
            else { ProgressView("Opening task").font(Theme.callout) }
        }
        .task(id: TaskEditorDestinationID(target: target, cardID: card.id)) {
            session = nil
            if target.peer == nil { await WorkSessionContext.shared.resolveLocalHostIdentity() }
            guard !Task.isCancelled else { return }
            session = TaskEditorSessions.session(target: target, card: card)
        }
        .onChange(of: card.revision) { _, _ in Task { await session?.refresh() } }
    }
}

private struct TaskEditorDestinationID: Hashable {
    let target: TaskEditorTarget
    let cardID: String
}

struct TaskEditorView: View {
    @Bindable var session: TaskEditorSession
    let hostName: String
    var onSaved: () async -> Void
    var onClose: (() -> Void)? = nil
    var onRun: ((TodoCard) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ThemedSheet(title: "Task", subtitle: hostName, icon: .edit,
                    onClose: { Task { await session.flush(); if let onClose { onClose() } else { dismiss() } } }) {
            GeometryReader { geometry in
                let wide = geometry.size.width >= 760 && !typeSize.isAccessibilitySize
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        notices
                        Group {
                            if wide {
                                HStack(alignment: .top, spacing: Theme.Space.l) {
                                    writing(minimumHeight: max(320, geometry.size.height - 120))
                                    ThemeRule.vertical
                                    settings.frame(width: 280)
                                }
                            } else {
                                writing(minimumHeight: max(220, geometry.size.height * 0.45))
                                settings
                            }
                        }.disabled(!session.loaded || session.working)
                    }
                }
            }
        } actions: {
            if session.saved.pending != nil {
                Button("Check saved task", .refresh) { Task { await session.refresh(); await onSaved() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(session.working)
            } else {
                if let onRun {
                    Button("Run…", .run) { onRun(session.saved.baseline) }
                        .buttonStyle(SecondaryButtonStyle(comfortable: true))
                        .disabled(session.working || session.dirty || !session.loaded || session.missing || session.conflict)
                }
                Button("Save task", .save) { Task { await session.save(); await onSaved() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(!session.canSave)
            }
        }
        .modifier(TaskEditorPresentation(embedded: onClose != nil))
        .interactiveDismissDisabled(session.working)
        .task { await session.load() }
        .onDisappear { Task { await session.flush() } }
    }

    private func writing(minimumHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            TextField("Task title", text: $session.fields.title, axis: .vertical)
                .font(Theme.title3.weight(.semibold)).textFieldStyle(.plain)
                .accessibilityLabel("Task title")
            ThemeRule()
            Text(session.fields.backend == "sh" ? "Command" : "Prompt").font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            TextEditor(text: $session.fields.prompt)
                .font(Theme.callout).scrollContentBackground(.hidden)
                .frame(minHeight: minimumHeight)
                .accessibilityLabel(session.fields.backend == "sh" ? "Task command" : "Task prompt")
            Text(session.dirty ? (session.persistedFields == session.fields ? "Draft kept on this device" : "Saving draft on this device…") : "Saved on the computer")
                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Task settings").font(Theme.callout.weight(.semibold))
            AppMenuPicker(title: "Folder", options: folderOptions, selection: $session.fields.workspaceID)
            AppMenuPicker(title: "Priority", options: [("low", "Low"), ("normal", "Normal"), ("high", "High")], selection: $session.fields.priority)
            AppMenuPicker(title: "Agent", options: backendOptions, selection: Binding(
                get: { session.fields.backend },
                set: { value in
                    guard value != session.fields.backend else { return }
                    session.fields.backend = value
                    session.fields.model = ""
                    session.fields.effort = ""
                }))
            if let backend = session.backends.first(where: { $0.id == session.fields.backend }) {
                if !backend.models.isEmpty || !session.fields.model.isEmpty {
                    FavoriteModelPicker(backendID: backend.id, models: backend.models, extra: session.fields.model,
                                        preservesSavedSelection: true, selection: $session.fields.model)
                }
                if !backend.efforts.isEmpty || !session.fields.effort.isEmpty {
                    AppMenuPicker(title: "Effort", options: options(backend.efforts, preserving: session.fields.effort), selection: $session.fields.effort)
                }
                if !session.fields.model.isEmpty && !backend.models.contains(session.fields.model) {
                    Text("This computer does not list the saved model. Keep it or choose another.")
                        .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                }
            } else if !session.fields.model.isEmpty || !session.fields.effort.isEmpty {
                Text([session.fields.model, session.fields.effort].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            }
            ThemeRule()
            Toggle("No time limit", isOn: $session.fields.noTimeLimit).toggleStyle(BrandCheckboxStyle())
            if !session.fields.noTimeLimit {
                TextField("Time limit", text: $session.fields.budgetValue).textFieldStyle(.themed)
                    .accessibilityLabel("Time limit")
                AppMenuPicker(title: "Unit", options: [("minutes", "Minutes"), ("seconds", "Seconds")], selection: $session.fields.budgetUnit)
            }
            if let validation = session.fields.validation {
                Text(validation).font(Theme.caption).foregroundStyle(Theme.danger)
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if let error = session.errorMessage {
            Text(error).font(Theme.callout).foregroundStyle(Theme.danger).textSelection(.enabled)
            if session.saved.pending == nil {
                Button("Reload task", .refresh) { Task { await session.load() } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(session.working)
            }
        }
        if session.working { ProgressView("Updating task").font(Theme.callout) }
        if session.conflict, let current = session.current {
            comparison(title: "Changed on the computer", draft: TaskEditorDraft(current))
            ViewThatFits(in: .horizontal) {
                HStack { conflictActions }
                VStack(alignment: .leading) { conflictActions }
            }
        }
        if let other = session.otherDraft {
            comparison(title: "Draft from another window", draft: other.value.fields)
            Button("Use saved draft", .restore) { Task { await session.resolveDiskConflict(keepMine: false) } }
                .buttonStyle(SecondaryButtonStyle(comfortable: true))
            if other.value.pending == nil {
                Button("Keep my draft", .edit) { Task { await session.resolveDiskConflict(keepMine: true) } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true))
            }
        }
    }

    @ViewBuilder private var conflictActions: some View {
        Button("Use computer version", .restore) { Task { await session.resolveConflict(keepMine: false) } }
            .buttonStyle(SecondaryButtonStyle(comfortable: true))
        Button("Keep my draft", .edit) { Task { await session.resolveConflict(keepMine: true) } }
            .buttonStyle(SecondaryButtonStyle(comfortable: true))
    }

    private func comparison(title: String, draft: TaskEditorDraft) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(Theme.callout.weight(.semibold))
            Text(draft.title).font(Theme.callout)
            Text(draft.prompt).font(Theme.callout).textSelection(.enabled)
            Text([draft.workspaceID.isEmpty ? "Uncategorized" : session.folders.first(where: { $0.id == draft.workspaceID })?.name ?? "Unavailable folder",
                  draft.priority.capitalized, draft.backend, draft.model, draft.effort,
                  draft.noTimeLimit ? "No time limit" : "\(draft.budgetValue) \(draft.budgetUnit)"].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    private var folderOptions: [(value: String, label: String)] {
        var values = [(value: "", label: "Uncategorized")] + session.folders.map { (value: $0.id, label: $0.name) }
        if !values.contains(where: { $0.value == session.fields.workspaceID }) { values.append((session.fields.workspaceID, "Unavailable folder")) }
        return values
    }
    private var backendOptions: [(value: String, label: String)] {
        var values = [(value: "", label: "Choose later")] + session.backends.map { (value: $0.id, label: $0.label) }
        if !values.contains(where: { $0.value == session.fields.backend }) { values.append((session.fields.backend, "\(session.fields.backend) · Unavailable")) }
        return values
    }
    private func options(_ values: [String], preserving value: String) -> [(value: String, label: String)] {
        [(value: "", label: "Default")] + (values.contains(value) || value.isEmpty ? values : values + [value]).map { (value: $0, label: values.contains($0) ? $0 : "\($0) · Saved choice") }
    }
}

private struct TaskEditorPresentation: ViewModifier {
    let embedded: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if embedded { content }
        else { content.modalFrame(width: 1000, height: 760) }
    }
}
