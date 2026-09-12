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
                        TaskFieldsView(fields: $session.fields, backends: session.backends, folders: session.folders,
                                       wide: wide, minimumHeight: wide ? max(320, geometry.size.height - 120) : max(220, geometry.size.height * 0.45),
                                       draftStatus: session.dirty ? (session.persistedFields == session.fields ? "Draft kept on this device" : "Saving draft on this device…") : "Saved on the computer")
                            .disabled(!session.loaded || session.working)
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


}

private struct TaskEditorPresentation: ViewModifier {
    let embedded: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if embedded { content }
        else { content.modalFrame(width: 1000, height: 760) }
    }
}
