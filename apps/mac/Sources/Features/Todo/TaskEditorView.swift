// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct TaskEditorDestination: View {
    let target: TaskEditorTarget
    let card: TodoCard
    let hostName: String
    var onSaved: () async -> Void
    var onClose: (() -> Void)? = nil
    var onViewRun: ((String, String) -> Void)? = nil
    var onOpenTerminal: ((PtySessionInfo) -> Void)? = nil
    @State private var session: TaskEditorSession?

    var body: some View {
        Group {
            if let session, session.target == target, session.saved.baseline.id == card.id {
                TaskEditorView(session: session, hostName: hostName, onSaved: onSaved, onClose: onClose,
                               onViewRun: onViewRun, onOpenTerminal: onOpenTerminal)
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

/// Chat launches create ordinary workspace conversations. Sending uses the
/// chat composer's durable draft and receipt handling, including uncertain
/// replies, rather than starting an automation behind the chat surface.
struct TaskChatLaunchView: View {
    let card: TodoCard
    let peer: String?
    @State private var model = ChatModel()
    @State private var started = false
    @State private var opened = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ThemedSheet(title: card.title, subtitle: "Task chat", icon: .preview,
                    onClose: { dismiss() }) {
            if opened {
                ChatView(model: model, workspaceID: card.workspaceID,
                         showingOverview: .constant(false), loadsWorkspace: false)
            } else if let failure {
                Text(failure).font(Theme.callout).foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
            } else {
                ProgressView("Starting chat…")
            }
        }
        .modalFrame(width: 960, height: 760)
        .interactiveDismissDisabled(!opened && failure == nil)
        .task {
            guard !started else { return }
            started = true
            do {
                await model.load(workspaceID: card.workspaceID, peer: peer, selectFirst: false)
                guard !Task.isCancelled else { return }
                guard let backend = model.backends.first(where: { $0.id == card.backend }) else {
                    failure = model.error ?? "This backend does not support chat on this computer. Choose another backend or run in Terminal."
                    return
                }
                let chat = try await Bridge.createChat(
                    workspaceID: card.workspaceID, backend: card.backend, title: card.title,
                    mode: "execute", autonomy: backend.gateTier == "bypassOnly" ? "bypass" : "standard",
                    model: card.cleanedModel.isEmpty ? nil : card.cleanedModel,
                    effort: card.effort, budgetSeconds: card.budgetSeconds, peer: peer
                )
                guard !Task.isCancelled else { return }
                await model.select(chat)
                model.draft = card.promptForRun
                opened = true
                guard !Task.isCancelled else { return }
                guard model.holdDraftForSending(card.promptForRun) else { return }
                await model.sendFromComposer()
            } catch {
                // Creation is not replayed after an uncertain reply: the
                // workspace's chat list is the place to check what was made.
                failure = "Could not confirm the new chat. Check this workspace’s chats before starting another. \(error.localizedDescription)"
            }
        }
    }
}

private struct TaskEditorDestinationID: Hashable {
    let target: TaskEditorTarget
    let cardID: String
}

struct TaskEditorView: View {
    @State private var chatTask: TodoCard?
    @Bindable var session: TaskEditorSession
    let hostName: String
    var onSaved: () async -> Void
    var onClose: (() -> Void)? = nil
    var onViewRun: ((String, String) -> Void)? = nil
    var onOpenTerminal: ((PtySessionInfo) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ThemedSheet(title: "Task", subtitle: hostName, icon: .edit, embedded: onClose != nil,
                    onClose: { Task { await session.flush(); if let onClose { onClose() } else { dismiss() } } }) {
            GeometryReader { geometry in
                let wide = geometry.size.width >= 760 && !typeSize.isAccessibilitySize
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        if onClose != nil {
                            Text(hostName).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                        }
                        notices
                        runSummary
                        TaskFieldsView(fields: $session.fields, backends: session.backends, folders: session.folders,
                                       wide: wide, minimumHeight: wide ? max(320, geometry.size.height - 120) : (onClose != nil ? 160 : max(220, geometry.size.height * 0.45)),
                                       draftStatus: session.dirty ? (session.persistedFields == session.fields ? "Draft kept on this device" : "Saving draft on this device…") : "Saved on the computer")
                            .disabled(!session.loaded || session.working || session.saved.pendingRun != nil)
                    }
                }
            }
        } actions: {
            if session.saved.pending != nil {
                Button("Check saved task", .refresh) { Task { await session.refresh(); await onSaved() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(session.working)
            } else if session.saved.pendingRun != nil {
                Button("Check run", .refresh) { Task { await session.reconcileRun(); await openLastRun() } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(session.working)
                Button("Retry same request", .run) { Task { await open(session.retryRun()) } }
                    .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(session.working)
            } else {
                if let delegate = session.saved.baseline.delegate, delegate.isRunning {
                    Button(delegate.status == "stopping" ? "Stopping…" : "Stop", .stop) {
                        Task { await session.stop(); await onSaved() }
                    }
                        .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(!session.canStop)
                    Button("View run", .preview) { onViewRun?(delegate.runId, session.saved.baseline.workspaceID) }
                        .buttonStyle(AccentButtonStyle(comfortable: true))
                } else if session.supportsExecution {
                    if let delegate = session.saved.baseline.delegate {
                        Button("View last result", .preview) {
                            onViewRun?(delegate.runId, session.saved.baseline.workspaceID)
                        }
                        .buttonStyle(SecondaryButtonStyle(comfortable: true))
                    }
                    TaskRunBar(canRun: session.canRun, running: session.working) { placement in
                        if placement == .chat {
                            chatTask = session.saved.baseline
                        } else {
                            Task { await open(session.run(placement == .foreground ? .foreground : .background)) }
                        }
                    }
                }
                Button("Save task", .save) { Task { await session.save(); await onSaved() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(!session.canSave)
            }
        }
        .modifier(TaskEditorPresentation(embedded: onClose != nil))
        .interactiveDismissDisabled(session.working)
        .sheet(item: $chatTask) { card in
            TaskChatLaunchView(card: card, peer: session.target.peer)
        }
        .task { await session.load() }
        .onDisappear { Task { await session.flush() } }
    }

    private func openLastRun() async { await open(session.lastRun) }

    private func open(_ outcome: TaskRunOutcome?) async {
        guard let outcome else { return }
        await onSaved()
        if outcome.placement == .foreground, let terminal = await session.terminal(for: outcome) {
            onOpenTerminal?(terminal)
        } else {
            onViewRun?(outcome.runID, outcome.run?.workspaceID ?? session.saved.baseline.workspaceID)
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
        if session.loaded && !session.supportsExecution {
            Text("Update \(hostName)'s tokenstat to run and stop tasks from here.")
                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
        }
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

    @ViewBuilder private var runSummary: some View {
        if let run = session.saved.baseline.delegate {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: run.isRunning ? "waveform.path" : run.status == "ok" ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                    .foregroundStyle(runTint(run))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.isRunning ? run.label : "Last run · \(run.label)")
                        .font(Theme.callout.weight(.semibold))
                    if let error = run.error, !error.isEmpty {
                        Text(error).font(Theme.caption).foregroundStyle(Theme.danger).lineLimit(3)
                    } else {
                        Text(run.isRunning ? "This run continues on the connected computer." : "The result remains linked to this task.")
                            .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accentSoft.opacity(0.58), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(runTint(run).opacity(0.35)))
        }
    }

    private func runTint(_ run: TodoDelegate) -> Color {
        switch run.status {
        case "ok": Theme.success
        case "error": Theme.danger
        case "stopped", "interrupted": Theme.warning
        default: Theme.accent
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
