// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct AutomationEditorRoute: Identifiable, Hashable {
    let workspaceID: String
    let folderName: String
    let job: Automation?
    var template: AutomationTemplate? = nil

    var id: String { job?.id ?? "new:\(workspaceID)" }
}

struct AutomationEditorDestination: View {
    let target: AutomationEditorTarget
    let workspaceID: String
    let folderName: String
    let hostName: String
    var existing: Automation? = nil
    var template: AutomationTemplate? = nil
    var onFinished: (Automation?) async -> Void
    @State private var session: AutomationEditorSession?
    private var identity: Identity {
        Identity(peer: target.peer, folder: workspaceID, jobID: existing?.id)
    }
    private struct Identity: Hashable {
        let peer: String?
        let folder: String
        let jobID: String?
    }

    var body: some View {
        Group {
            if let session, session.target == target, session.workspaceID == workspaceID {
                AutomationEditorView(session: session, hostName: hostName, onFinished: onFinished)
            } else {
                ProgressView(existing == nil ? L10n.text("apple.automationeditorview.opening_new_automation.f09691b8") : L10n.text("apple.automationeditorview.opening_automation.7be3aa30"))
                    .font(Theme.callout)
            }
        }
        .modalFrame(width: 1000, height: 760)
        .task(id: identity) {
            let owner = WorkSessionContext.shared.scope
            session = nil
            if target.peer == nil { await WorkSessionContext.shared.resolveLocalHostIdentity() }
            guard !Task.isCancelled else { return }
            let loadedSession = AutomationEditorSessions.session(
                target: target,
                workspaceID: workspaceID,
                folderName: folderName,
                existing: existing,
                lockedFolder: true
            )
            if let template, existing == nil {
                await loadedSession.load()
                guard !Task.isCancelled, owner == WorkSessionContext.shared.scope else { return }
                let job = Automation(id: "template", name: template.name, backend: template.backendID,
                    workspaceID: workspaceID, prompt: template.prompt, schedule: template.schedule,
                    budgetSeconds: template.budgetSeconds, enabled: true)
                loadedSession.applyTemplate(AutomationEditorDraft(job))
            }
            guard !Task.isCancelled, owner == WorkSessionContext.shared.scope else { return }
            session = loadedSession
        }
    }
}

private enum AutomationEditorSurface: String, CaseIterable, Hashable {
    case writing = "Writing"
    case settings = "Settings"
}

struct AutomationEditorView: View {
    @Bindable var session: AutomationEditorSession
    let hostName: String
    var onFinished: (Automation?) async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var surface: AutomationEditorSurface = .writing

    var body: some View {
        ThemedSheet(
            title: title,
            subtitle: hostName,
            icon: session.isCreate ? .create : .edit,
            fills: true,
            onClose: {
                Task {
                    await session.flush()
                    if session.saved.created != nil { _ = await session.finishCreated() }
                    dismiss()
                }
            }
        ) {
            GeometryReader { geometry in
                let wide = geometry.size.width >= 760 && !typeSize.isAccessibilitySize
                editorBody(wide: wide, height: geometry.size.height)
            }
        } actions: {
            footer
        }
        .interactiveDismissDisabled(session.working)
        .task { await session.load() }
        .onDisappear { Task { await session.flush() } }
        .onChange(of: surface) { _, _ in
            Task { await session.flush() }
        }
        #if WORKBENCH_QA
        .onAppear {
            if ProcessInfo.processInfo.environment["WORKBENCH_SURFACE"] == "settings" {
                surface = .settings
            }
        }
        #endif
    }

    @ViewBuilder
    private func editorBody(wide: Bool, height: CGFloat) -> some View {
        if session.saved.created != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    notices
                    confirmation
                }
            }
        } else if wide {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    notices
                    fields(
                        wide: true,
                        section: nil,
                        minimumHeight: max(320, height - 120),
                        showValidation: showValidation
                    )
                }
            }
            .scrollDismissesKeyboard(.interactively)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                notices
                SegmentedTabs(
                    options: AutomationEditorSurface.allCases,
                    selection: $surface,
                    comfortable: true
                )
                if showValidation, let validation = session.fields.validation {
                    Text(validation)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if surface == .writing {
                    fields(wide: false, section: .writing, minimumHeight: 0, showValidation: false)
                } else {
                    ScrollView {
                        fields(wide: false, section: .settings, minimumHeight: 0, showValidation: false)
                            .padding(.bottom, Theme.Space.xl)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func fields(
        wide: Bool,
        section: AutomationFieldsSection?,
        minimumHeight: CGFloat,
        showValidation: Bool
    ) -> some View {
        AutomationFieldsView(
            fields: $session.fields,
            backends: session.pickerBackends(),
            folderName: session.folderName,
            folderLocked: session.lockedFolder,
            folders: [],
            wide: wide,
            minimumHeight: minimumHeight,
            draftStatus: draftStatus,
            showValidation: showValidation,
            hostName: hostName,
            timezone: session.schedulerTimezone,
            nextCaption: nextCaption,
            section: section
        )
        .disabled(!session.loaded || session.working || session.creating)
    }

    private var title: String {
        if session.saved.created != nil { return L10n.text("apple.automationeditorview.automation_saved.00a9bf84") }
        return session.isCreate ? L10n.text("apple.automationeditorview.new_automation.db87a63d") : L10n.text("apple.automationeditorview.edit_automation.b16f31c1")
    }

    private var draftStatus: String {
        if session.persistedFields == session.fields { return L10n.text("apple.automationeditorview.draft_kept_on_this_device.980c4050") }
        return L10n.text("apple.automationeditorview.saving_draft_on_this_device.40996e62")
    }

    private var showValidation: Bool {
        !session.fields.name.isEmpty || !session.fields.prompt.isEmpty
    }

    private var nextCaption: String? {
        if session.fields.scheduleKind == .once { return nil }
        if session.isCreate || session.dirty { return nil }
        let job = session.current ?? session.saved.baseline
        if job?.enabled == false {
            return L10n.text("apple.automationeditorview.paused_it_will_not_fire_on_its_own.84765e76")
        }
        guard let next = job?.nextRun else { return nil }
        return L10n.text("apple.automationeditorview.next_0.383f019f", "\(HostScheduleClock.nextRun(next, timezone: session.schedulerTimezone))")
    }

    @ViewBuilder private var notices: some View {
        if session.working {
            ProgressView(session.creating ? L10n.text("apple.automationeditorview.creating_job.745ad37a") : L10n.text("apple.automationeditorview.saving_job.841fc05f"))
                .font(Theme.callout)
        }
        if let message = session.noticeMessage {
            Text(message)
                .font(Theme.callout)
                .foregroundStyle(Theme.controlGlyph)
        }
        if session.loaded, !session.supportsReceipts, session.saved.created == nil, !session.isCreate {
            Text(L10n.text("apple.automationeditorview.this_computer_cannot_protect_concurrent_ed.c272aa01"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
        if session.liveRun, session.saved.created == nil {
            Text(L10n.text("apple.automationeditorview.a_run_is_going_this_save_is_for_the_next_o.82358bf1"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
        if let message = session.errorMessage {
            Text(message)
                .font(Theme.callout)
                .foregroundStyle(Theme.danger)
                .textSelection(.enabled)
            if !session.creating, session.saved.created == nil, session.saved.pendingEdit == nil {
                Button(L10n.text("apple.automationeditorview.reload_options.e9ed25ed"), .refresh) { Task { await session.load() } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true))
                    .disabled(session.working)
            }
        }
        if session.backends.isEmpty, session.loaded, session.saved.created == nil, !session.creating {
            Text(L10n.text("apple.automationeditorview.no_supported_agent_cli_is_installed_on_thi.c6691a59"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
        if session.conflict, let current = session.current {
            comparison(title: L10n.text("apple.automationeditorview.changed_on_the_computer.aefb92cf"), draft: AutomationEditorDraft(current))
            Text(L10n.text("apple.automationeditorview.this_job_changed_since_you_opened_it_compa.ae02b985"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
        if let other = session.otherDraft {
            comparison(title: L10n.text("apple.automationeditorview.draft_from_another_window.8b70bae9"), draft: other.value.fields)
            Text(L10n.text("apple.automationeditorview.choose_which_draft_to_continue_a_creation.6be102c4"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
            Button(L10n.text("apple.automationeditorview.use_saved_draft.31f362c2"), .restore) { Task { await session.resolveDiskConflict(keepMine: false) } }
                .buttonStyle(SecondaryButtonStyle(comfortable: true))
                .disabled(session.working)
            if other.value.pendingCreate == false, other.value.pendingCreation == nil, other.value.pendingEdit == nil {
                Button(L10n.text("apple.automationeditorview.keep_my_draft.cdb80bb9"), .edit) { Task { await session.resolveDiskConflict(keepMine: true) } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true))
                    .disabled(session.working)
            }
        }
    }

    private func comparison(title: String, draft: AutomationEditorDraft) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(Theme.callout.weight(.semibold))
            Text(draft.name).font(Theme.callout)
            Text(draft.prompt).font(Theme.callout).textSelection(.enabled)
            Text("\(draft.builtSchedule.summary) · \(draft.backend)")
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(session.saved.created?.name ?? session.fields.name)
                .font(Theme.title3.weight(.semibold))
            Text(session.saved.created?.schedule.summary ?? session.fields.builtSchedule.summary)
                .font(Theme.callout)
                .foregroundStyle(Theme.controlGlyph)
            if let created = session.saved.created, created.enabled, let next = created.nextRun {
                Text(L10n.text("apple.automationeditorview.next_0.383f019f", "\(HostScheduleClock.nextRun(next, timezone: session.schedulerTimezone))"))
                    .font(Theme.callout)
                    .foregroundStyle(Theme.controlGlyph)
            }
            Text(L10n.text("apple.automationeditorview.it_runs_on_0_in_1.8d815fb3", "\(hostName)", "\(session.folderName)"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
            if let place = HostScheduleClock.place(session.schedulerTimezone) {
                Text(L10n.text("apple.automationeditorview.times_are_0_time.3e5f6eb5", "\(place)"))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var footer: some View {
        if session.saved.created != nil {
            Button(L10n.text("common.done"), .done) {
                Task {
                    let created = await session.finishCreated() ?? session.saved.created
                    await onFinished(created)
                    dismiss()
                }
            }
            .buttonStyle(AccentButtonStyle(comfortable: true))
            .disabled(session.working)
        } else if session.conflict {
            Button(L10n.text("apple.automationeditorview.use_computer_version.f0d6599f"), .restore) { Task { await session.resolveConflict(keepMine: false) } }
                .buttonStyle(SecondaryButtonStyle(comfortable: true))
                .disabled(session.working)
            Button(L10n.text("apple.automationeditorview.keep_my_draft.cdb80bb9"), .edit) { Task { await session.resolveConflict(keepMine: true) } }
                .buttonStyle(AccentButtonStyle(comfortable: true))
                .disabled(session.working)
        } else if session.saved.pendingEdit != nil {
            Button(L10n.text("apple.automationeditorview.check_saved_job.bc689b04"), .refresh) { Task { await session.refresh() } }
                .buttonStyle(AccentButtonStyle(comfortable: true))
                .disabled(session.working)
        } else if session.creating {
            Button(L10n.text("apple.automationeditorview.check_creation.61fe51e6"), .refresh) { Task { await session.checkCreated() } }
                .buttonStyle(SecondaryButtonStyle(comfortable: true))
                .disabled(session.working)
            if session.canRetryCreate {
                Button(L10n.text("apple.automationeditorview.retry_creation.0bb084c1"), .create) { Task { await session.retryCreate() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true))
                    .disabled(session.working || session.otherDraft != nil)
            }
        } else if session.isCreate {
            Button(L10n.text("apple.automationeditorview.create_automation.77947194"), .create) { Task { await session.create() } }
                .buttonStyle(AccentButtonStyle(comfortable: true))
                .disabled(!session.canCreate)
        } else {
            Button(L10n.text("apple.automationeditorview.save_automation.7a7199c9"), .save) { Task { await session.save() } }
                .buttonStyle(AccentButtonStyle(comfortable: true))
                .disabled(!session.canSave)
        }
    }
}
