// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct TaskCreationDestination: View {
    let target: TaskEditorTarget
    let workspaceID: String
    var column: String = "backlog"
    let hostName: String
    var onCreated: (TodoCard?) async -> Void
    @State private var session: TaskCreationSession?
    private var identity: Identity { Identity(target: target, folder: workspaceID, column: column) }
    private struct Identity: Hashable { let target: TaskEditorTarget; let folder: String; let column: String }

    var body: some View {
        Group {
            if let session, session.target == target, session.initialFolder == workspaceID, session.column == column {
                TaskCreationView(session: session, hostName: hostName, onCreated: onCreated)
            } else { ProgressView("Opening new task").font(Theme.callout) }
        }
        .modalFrame(width: 1000, height: 760)
        .task(id: identity) {
            session = nil
            if target.peer == nil { await WorkSessionContext.shared.resolveLocalHostIdentity() }
            guard !Task.isCancelled else { return }
            session = TaskCreationSessions.session(target: target, workspaceID: workspaceID, column: column)
        }
    }
}

struct TaskCreationView: View {
    @Bindable var session: TaskCreationSession
    let hostName: String
    var onCreated: (TodoCard?) async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ThemedSheet(title: session.saved.outcome == nil ? "New task" : "Task created", subtitle: hostName, icon: .create,
                    onClose: { Task { await session.flush(); dismiss() } }) {
            GeometryReader { geometry in
                let wide = geometry.size.width >= 760 && !typeSize.isAccessibilitySize
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        notices
                        if let outcome = session.saved.outcome {
                            confirmation(outcome)
                        } else {
                            TaskFieldsView(fields: $session.fields, backends: session.backends, folders: session.folders,
                                           wide: wide, minimumHeight: wide ? max(320, geometry.size.height - 120) : max(220, geometry.size.height * 0.45),
                                           draftStatus: session.persistedFields == session.fields ? "Draft kept on this device" : "Saving draft on this device…",
                                           showValidation: !session.fields.title.isEmpty || !session.fields.prompt.isEmpty,
                                           timeLimitStatus: session.saved.needsDefault ? "Connect to this computer to load its default time limit." : nil)
                                .disabled(!session.canEdit)
                        }
                    }
                }
            }
        } actions: {
            if let outcome = session.saved.outcome {
                Button("Done", .done) {
                    Task {
                        await onCreated(outcome.card)
                        if await session.finish(operationID: outcome.operationID) { dismiss() }
                    }
                }
                .buttonStyle(AccentButtonStyle(comfortable: true))
                .disabled(session.working || session.otherDraft != nil)
            } else if session.saved.pending != nil {
                Button("Check creation", .refresh) { Task { await session.check() } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(session.working)
                if session.canRetry {
                    Button("Retry creation", .create) { Task { await session.retry() } }
                        .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(session.working || session.otherDraft != nil)
                }
            } else {
                Button("Create task", .create) { Task { await session.create() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(!session.canCreate)
            }
        }
        .interactiveDismissDisabled(session.working)
        .task { await session.load() }
        .onDisappear { Task { await session.flush() } }
    }

    @ViewBuilder private var notices: some View {
        if session.working { ProgressView(session.saved.pending == nil ? "Preparing task" : "Confirming creation").font(Theme.callout) }
        if let message = session.noticeMessage {
            Text(message).font(Theme.callout).foregroundStyle(Theme.controlGlyph)
        }
        if let message = session.errorMessage {
            Text(message).font(Theme.callout).foregroundStyle(Theme.danger).textSelection(.enabled)
            if session.saved.pending == nil {
                Button("Reload options", .refresh) { Task { await session.load() } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(session.working)
            }
        }
        if let other = session.otherDraft {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Draft from another window").font(Theme.callout.weight(.semibold))
                Text(other.value.fields.title).font(Theme.callout)
                Text(other.value.fields.prompt).font(Theme.callout).textSelection(.enabled)
                Text("Choose which draft to continue. A creation already sent must be checked first.")
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                Button("Use saved draft", .restore) { Task { await session.resolveDiskConflict(keepMine: false) } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(session.working)
                if other.value.pending == nil {
                    Button("Keep my draft", .edit) { Task { await session.resolveDiskConflict(keepMine: true) } }
                        .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(session.working)
                }
            }
        }
    }

    private func confirmation(_ outcome: TaskCreationOutcome) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(outcome.card?.title ?? session.saved.pending?.fields.title ?? "Task")
                .font(Theme.title3.weight(.semibold))
            if let card = outcome.card {
                let folder = card.workspaceID.isEmpty ? "Uncategorized" : session.folders.first(where: { $0.id == card.workspaceID })?.name ?? "its saved folder"
                Text("Saved to \(folder) on \(hostName).")
                    .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                Text(card.notes).font(Theme.callout).textSelection(.enabled)
            } else {
                Text("The computer confirmed this task was created and later deleted. It has not been recreated.")
                    .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
