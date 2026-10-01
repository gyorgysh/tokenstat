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
            } else { ProgressView(L10n.text("apple.taskcreationview.opening_new_task.f5798e7b")).font(Theme.callout) }
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
        ThemedSheet(title: session.saved.outcome == nil ? L10n.text("apple.taskcreationview.new_task.3e992276") : L10n.text("apple.taskcreationview.task_created.a3e3e968"), subtitle: hostName, icon: .create,
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
                                           draftStatus: session.persistedFields == session.fields ? L10n.text("apple.taskcreationview.draft_kept_on_this_device.980c4050") : L10n.text("apple.taskcreationview.saving_draft_on_this_device.40996e62"),
                                           showValidation: !session.fields.title.isEmpty || !session.fields.prompt.isEmpty,
                                           timeLimitStatus: session.saved.needsDefault ? L10n.text("apple.taskcreationview.connect_to_this_computer_to_load_its_defau.811c4f8f") : nil)
                                .disabled(!session.canEdit)
                        }
                    }
                }
            }
        } actions: {
            if let outcome = session.saved.outcome {
                Button(L10n.text("common.done"), .done) {
                    Task {
                        await onCreated(outcome.card)
                        if await session.finish(operationID: outcome.operationID) { dismiss() }
                    }
                }
                .buttonStyle(AccentButtonStyle(comfortable: true))
                .disabled(session.working || session.otherDraft != nil)
            } else if session.saved.pending != nil {
                Button(L10n.text("apple.taskcreationview.check_creation.61fe51e6"), .refresh) { Task { await session.check() } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(session.working)
                if session.canRetry {
                    Button(L10n.text("apple.taskcreationview.retry_creation.0bb084c1"), .create) { Task { await session.retry() } }
                        .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(session.working || session.otherDraft != nil)
                }
            } else {
                Button(L10n.text("apple.taskcreationview.create_task.6f541e1b"), .create) { Task { await session.create() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(!session.canCreate)
            }
        }
        .interactiveDismissDisabled(session.working)
        .task { await session.load() }
        .onDisappear { Task { await session.flush() } }
    }

    @ViewBuilder private var notices: some View {
        if session.working { ProgressView(session.saved.pending == nil ? L10n.text("apple.taskcreationview.preparing_task.8ae683d9") : L10n.text("apple.taskcreationview.confirming_creation.d539f921")).font(Theme.callout) }
        if let message = session.noticeMessage {
            Text(message).font(Theme.callout).foregroundStyle(Theme.controlGlyph)
        }
        if let message = session.errorMessage {
            Text(message).font(Theme.callout).foregroundStyle(Theme.danger).textSelection(.enabled)
            if session.saved.pending == nil {
                Button(L10n.text("apple.taskcreationview.reload_options.e9ed25ed"), .refresh) { Task { await session.load() } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(session.working)
            }
        }
        if let other = session.otherDraft {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(L10n.text("apple.taskcreationview.draft_from_another_window.8b70bae9")).font(Theme.callout.weight(.semibold))
                Text(other.value.fields.title).font(Theme.callout)
                Text(other.value.fields.prompt).font(Theme.callout).textSelection(.enabled)
                Text(L10n.text("apple.taskcreationview.choose_which_draft_to_continue_a_creation.6be102c4"))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                Button(L10n.text("apple.taskcreationview.use_saved_draft.31f362c2"), .restore) { Task { await session.resolveDiskConflict(keepMine: false) } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(session.working)
                if other.value.pending == nil {
                    Button(L10n.text("apple.taskcreationview.keep_my_draft.cdb80bb9"), .edit) { Task { await session.resolveDiskConflict(keepMine: true) } }
                        .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(session.working)
                }
            }
        }
    }

    private func confirmation(_ outcome: TaskCreationOutcome) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(outcome.card?.title ?? session.saved.pending?.fields.title ?? L10n.text("apple.taskcreationview.task.4bc74b21"))
                .font(Theme.title3.weight(.semibold))
            if let card = outcome.card {
                let folder = card.workspaceID.isEmpty ? L10n.text("apple.taskcreationview.uncategorized.8d40d123") : session.folders.first(where: { $0.id == card.workspaceID })?.name ?? L10n.text("apple.taskcreationview.its_saved_folder.6cb0b217")
                Text(L10n.text("apple.taskcreationview.saved_to_0_on_1.6c8c44f7", "\(folder)", "\(hostName)"))
                    .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                Text(card.notes).font(Theme.callout).textSelection(.enabled)
            } else {
                Text(L10n.text("apple.taskcreationview.the_computer_confirmed_this_task_was_creat.44f7ed5f"))
                    .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
