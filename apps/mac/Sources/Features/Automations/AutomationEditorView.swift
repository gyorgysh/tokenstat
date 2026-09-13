// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct AutomationEditorRoute: Identifiable, Hashable {
    let workspaceID: String
    let folderName: String
    let job: Automation?

    var id: String { job?.id ?? "new:\(workspaceID)" }
}

struct AutomationEditorDestination: View {
    let target: AutomationEditorTarget
    let workspaceID: String
    let folderName: String
    let hostName: String
    var existing: Automation? = nil
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
                ProgressView(existing == nil ? "Opening new automation" : "Opening automation")
                    .font(Theme.callout)
            }
        }
        .modalFrame(width: 1000, height: 760)
        .task(id: identity) {
            session = nil
            if target.peer == nil { await WorkSessionContext.shared.resolveLocalHostIdentity() }
            guard !Task.isCancelled else { return }
            session = AutomationEditorSessions.session(
                target: target,
                workspaceID: workspaceID,
                folderName: folderName,
                existing: existing,
                lockedFolder: true
            )
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
        .disabled(!session.loaded || session.working || session.saved.pendingCreate)
    }

    private var title: String {
        if session.saved.created != nil { return "Automation saved" }
        return session.isCreate ? "New automation" : "Edit automation"
    }

    private var draftStatus: String {
        if session.persistedFields == session.fields { return "Draft kept on this device" }
        return "Saving draft on this device…"
    }

    private var showValidation: Bool {
        !session.fields.name.isEmpty || !session.fields.prompt.isEmpty
    }

    private var nextCaption: String? {
        if session.fields.scheduleKind == .once { return nil }
        if session.isCreate || session.dirty { return nil }
        let job = session.current ?? session.saved.baseline
        if job?.enabled == false {
            return "Paused. It will not fire on its own."
        }
        guard let next = job?.nextRun else { return nil }
        return "Next \(HostScheduleClock.nextRun(next, timezone: session.schedulerTimezone))."
    }

    @ViewBuilder private var notices: some View {
        if session.working {
            ProgressView(session.isCreate ? "Creating job" : "Saving job")
                .font(Theme.callout)
        }
        if let message = session.noticeMessage {
            Text(message)
                .font(Theme.callout)
                .foregroundStyle(Theme.controlGlyph)
        }
        if let message = session.errorMessage {
            Text(message)
                .font(Theme.callout)
                .foregroundStyle(Theme.danger)
                .textSelection(.enabled)
            if session.saved.pendingCreate == false, session.saved.created == nil {
                Button("Reload options", .refresh) { Task { await session.load() } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true))
                    .disabled(session.working)
            }
        }
        if session.backends.isEmpty, session.loaded, session.saved.created == nil, session.saved.pendingCreate == false {
            Text("No supported agent CLI is installed on this computer yet. Install one there, then reload.")
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
        if let other = session.otherDraft {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Draft from another window")
                    .font(Theme.callout.weight(.semibold))
                Text(other.value.fields.name)
                    .font(Theme.callout)
                Text(other.value.fields.prompt)
                    .font(Theme.callout)
                    .textSelection(.enabled)
                Text("Choose which draft to continue. A creation already sent must be checked first.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                Button("Use saved draft", .restore) { Task { await session.resolveDiskConflict(keepMine: false) } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true))
                    .disabled(session.working)
                if other.value.pendingCreate == false {
                    Button("Keep my draft", .edit) { Task { await session.resolveDiskConflict(keepMine: true) } }
                        .buttonStyle(SecondaryButtonStyle(comfortable: true))
                        .disabled(session.working)
                }
            }
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(session.saved.created?.name ?? session.fields.name)
                .font(Theme.title3.weight(.semibold))
            Text(session.saved.created?.schedule.summary ?? session.fields.builtSchedule.summary)
                .font(Theme.callout)
                .foregroundStyle(Theme.controlGlyph)
            if let created = session.saved.created, created.enabled, let next = created.nextRun {
                Text("Next \(HostScheduleClock.nextRun(next, timezone: session.schedulerTimezone)).")
                    .font(Theme.callout)
                    .foregroundStyle(Theme.controlGlyph)
            }
            Text("It runs on \(hostName), in \(session.folderName).")
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
            if let place = HostScheduleClock.place(session.schedulerTimezone) {
                Text("Times are \(place) time.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var footer: some View {
        if session.saved.created != nil {
            Button("Done", .done) {
                Task {
                    let created = await session.finishCreated() ?? session.saved.created
                    await onFinished(created)
                    dismiss()
                }
            }
            .buttonStyle(AccentButtonStyle(comfortable: true))
            .disabled(session.working)
        } else if session.saved.pendingCreate {
            Button("Check automations", .refresh) { Task { await session.checkCreated() } }
                .buttonStyle(SecondaryButtonStyle(comfortable: true))
                .disabled(session.working)
        } else if session.isCreate {
            Button("Create automation", .create) { Task { await session.create() } }
                .buttonStyle(AccentButtonStyle(comfortable: true))
                .disabled(!session.canCreate)
        } else {
            Button("Save automation", .save) { Task { await session.save() } }
                .buttonStyle(AccentButtonStyle(comfortable: true))
                .disabled(!session.canSave)
        }
    }
}
