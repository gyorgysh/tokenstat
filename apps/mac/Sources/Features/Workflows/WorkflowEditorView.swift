// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct WorkflowEditorRoute: Identifiable, Hashable {
    let workspaceID: String
    let folderName: String
    let graph: WorkflowGraph?

    var id: String { graph?.id ?? "new:\(workspaceID)" }
}

struct WorkflowEditorDestination: View {
    let target: WorkflowEditorTarget
    let workspaceID: String
    let folderName: String
    let hostName: String
    var existing: WorkflowGraph? = nil
    var onFinished: (WorkflowGraph?) async -> Void
    @State private var session: WorkflowEditorSession?
    private var identity: Identity {
        Identity(peer: target.peer, folder: workspaceID, graphID: existing?.id)
    }
    private struct Identity: Hashable {
        let peer: String?
        let folder: String
        let graphID: String?
    }

    var body: some View {
        Group {
            if let session, session.target == target, session.workspaceID == workspaceID {
                WorkflowEditorView(session: session, hostName: hostName, onFinished: onFinished)
            } else {
                ProgressView(existing == nil ? L10n.text("apple.workfloweditorview.opening_new_workflow.2abc73fe") : L10n.text("apple.workfloweditorview.opening_workflow.82d1c28f"))
                    .font(Theme.callout)
            }
        }
        .modalFrame(width: 1000, height: 760)
        .task(id: identity) {
            session = nil
            if target.peer == nil { await WorkSessionContext.shared.resolveLocalHostIdentity() }
            guard !Task.isCancelled else { return }
            session = WorkflowEditorSessions.session(
                target: target,
                workspaceID: workspaceID,
                folderName: folderName,
                existing: existing,
                lockedFolder: true
            )
        }
    }
}

private enum WorkflowEditorSurface: String, CaseIterable, Hashable {
    case graph = "Graph"
    case settings = "Settings"
}

struct WorkflowEditorView: View {
    @Bindable var session: WorkflowEditorSession
    let hostName: String
    var onFinished: (WorkflowGraph?) async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var surface: WorkflowEditorSurface = .graph
    @State private var stepPath: [String] = []
    @State private var canvasMode: WorkflowCanvasMode = .canvas

    var body: some View {
        ThemedSheet(
            title: title,
            subtitle: hostName,
            icon: session.isCreate ? .create : .edit,
            fills: true,
            onClose: {
                Task {
                    await session.flush()
                    if session.saved.created != nil {
                        let created = await session.finishCreated()
                        await onFinished(created)
                    }
                    dismiss()
                }
            }
        ) {
            GeometryReader { geometry in
                let wide = geometry.size.width >= 760 && !typeSize.isAccessibilitySize
                editorBody(wide: wide)
            }
        } actions: {
            footer
        }
        .interactiveDismissDisabled(session.working)
        .task { await session.load() }
        .onDisappear { Task { await session.flush() } }
        .onChange(of: surface) { _, _ in
            Task { await session.flush() }
            if surface != .graph { stepPath = [] }
        }
        #if WORKBENCH_QA
        .onAppear {
            if ProcessInfo.processInfo.environment["WORKBENCH_SURFACE"] == "settings" {
                surface = .settings
            }
            if ProcessInfo.processInfo.environment["WORKBENCH_CANVAS"] == "list" {
                canvasMode = .list
            }
            if let step = ProcessInfo.processInfo.environment["WORKBENCH_STEP"], !step.isEmpty {
                session.selectStep(step)
                stepPath = [step]
            }
        }
        #endif
    }

    @ViewBuilder
    private func editorBody(wide: Bool) -> some View {
        if session.saved.created != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    notices
                    confirmation
                }
            }
        } else if wide {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                notices
                if showValidation, let validation = session.fields.validation {
                    Text(validation)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        if allowsCanvas {
                            SegmentedTabs(
                                options: WorkflowCanvasMode.allCases,
                                selection: $canvasMode,
                                comfortable: false
                            )
                        }
                        graphColumn
                    }
                    ThemeRule.vertical
                    inspector
                        .frame(width: 340)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if stepPath.isEmpty {
                    notices
                    SegmentedTabs(
                        options: WorkflowEditorSurface.allCases,
                        selection: $surface,
                        comfortable: true
                    )
                    if showValidation, let validation = session.fields.validation {
                        Text(validation)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if surface == .graph {
                    graphStack
                } else {
                    ScrollView {
                        fields(section: .settings, showValidation: false)
                            .padding(.bottom, Theme.Space.xl)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Phone: the list pushes a step. Back sits above the stack so it does
    /// not scroll away with the fields.
    private var graphStack: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let current = stepPath.last {
                stepChrome(id: current)
            }
            NavigationStack(path: $stepPath) {
                graphList(selectsInPlace: false)
                    #if os(iOS)
                    .toolbar(.hidden, for: .navigationBar)
                    #endif
                    .navigationDestination(for: String.self) { id in
                        ScrollView {
                            WorkflowStepDetailView(
                                session: session,
                                nodeID: id,
                                path: $stepPath,
                                showsBack: false
                            )
                            .padding(.bottom, Theme.Space.xl)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        #if os(iOS)
                        .toolbar(.hidden, for: .navigationBar)
                        #endif
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(!session.loaded || session.working || session.creating)
    }

    /// iPad keeps the list. The right pane is the selected step, or settings.
    private func graphList(selectsInPlace: Bool) -> some View {
        ScrollView {
            fields(section: .graph, showValidation: false, selectsInPlace: selectsInPlace)
                .padding(.bottom, Theme.Space.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(!session.loaded || session.working || session.creating)
    }

    private var allowsCanvas: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
#else
        true
#endif
    }

    /// Wide iPad: the touch canvas, or the step list as the accessible
    /// alternate. Both edit the same document and inspector.
    @ViewBuilder
    private var graphColumn: some View {
        if canvasMode == .canvas, allowsCanvas {
            WorkflowTouchCanvas(session: session, stepPath: $stepPath)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            graphList(selectsInPlace: true)
        }
    }

    private var inspector: some View {
        ScrollView {
            if let edgeID = session.selectedConnectionID,
               session.fields.edges.contains(where: { $0.id == edgeID }) {
                WorkflowConnectionInspector(session: session, stepPath: $stepPath)
                    .padding(.bottom, Theme.Space.xl)
            } else if let id = stepPath.last, session.fields.nodes.contains(where: { $0.id == id }) {
                WorkflowStepDetailView(
                    session: session,
                    nodeID: id,
                    path: $stepPath,
                    showsBack: false
                )
                .padding(.bottom, Theme.Space.xl)
            } else {
                fields(section: .settings, showValidation: false)
                    .padding(.bottom, Theme.Space.xl)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .disabled(!session.loaded || session.working || session.creating)
    }

    private func stepChrome(id: String) -> some View {
        let node = session.fields.nodes.first { $0.id == id }
        return HStack(alignment: .center, spacing: Theme.Space.s) {
            Button(L10n.text("apple.workfloweditorview.steps.1de3df70"), .back) {
                session.endGroupedStepEdit()
                if !stepPath.isEmpty { stepPath.removeLast() }
            }
            .buttonStyle(SecondaryButtonStyle(small: true))
            Text(node?.displayTitle ?? L10n.text("apple.workfloweditorview.step.8e6a6cca"))
                .font(Theme.callout.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func fields(
        section: WorkflowFieldsSection?,
        showValidation: Bool,
        selectsInPlace: Bool = false
    ) -> some View {
        WorkflowFieldsView(
            session: session,
            wide: false,
            draftStatus: draftStatus,
            showValidation: showValidation,
            hostName: hostName,
            nextCaption: nextCaption,
            section: section,
            stepPath: $stepPath,
            selectsInPlace: selectsInPlace
        )
        .disabled(!session.loaded || session.working || session.creating)
    }

    private var title: String {
        if session.saved.created != nil { return L10n.text("apple.workfloweditorview.workflow_saved.077e94fd") }
        return session.isCreate ? L10n.text("apple.workfloweditorview.new_workflow.750c4da4") : L10n.text("apple.workfloweditorview.edit_workflow.f5dd71b2")
    }

    private var draftStatus: String {
        if session.persistedFields == session.fields { return L10n.text("apple.workfloweditorview.draft_kept_on_this_device.980c4050") }
        return L10n.text("apple.workfloweditorview.saving_draft_on_this_device.40996e62")
    }

    private var showValidation: Bool {
        !session.fields.name.isEmpty
    }

    private var nextCaption: String? {
        if session.fields.scheduleKind == .once { return nil }
        if session.isCreate || session.dirty { return nil }
        let graph = session.current ?? session.saved.baseline
        if graph?.enabled == false {
            return L10n.text("apple.workfloweditorview.paused_it_will_not_fire_on_its_own.84765e76")
        }
        guard let next = graph?.nextRun else { return nil }
        return L10n.text("apple.workfloweditorview.next_0.383f019f", "\(HostScheduleClock.nextRun(next, timezone: session.schedulerTimezone))")
    }

    @ViewBuilder private var notices: some View {
        if session.working {
            ProgressView(session.creating ? L10n.text("apple.workfloweditorview.creating_workflow.3af3eab9") : L10n.text("apple.workfloweditorview.saving_workflow.3f9c4e68"))
                .font(Theme.callout)
        }
        if let message = session.noticeMessage {
            Text(message)
                .font(Theme.callout)
                .foregroundStyle(Theme.controlGlyph)
        }
        if session.loaded, session.saved.created == nil, !session.isCreate, !session.supportsEdits {
            Text(L10n.text("apple.workfloweditorview.this_computer_cannot_protect_concurrent_ed.d8da54db"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
        if session.liveRun, session.saved.created == nil {
            Text(L10n.text("apple.workfloweditorview.a_run_is_going_this_save_is_for_the_next_o.82358bf1"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
        if let message = session.errorMessage {
            Text(message)
                .font(Theme.callout)
                .foregroundStyle(Theme.danger)
                .textSelection(.enabled)
            if !session.creating, session.saved.created == nil {
                Button(L10n.text("apple.workfloweditorview.reload_options.e9ed25ed"), .refresh) { Task { await session.load() } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true))
                    .disabled(session.working)
            }
        }
        if session.backends.isEmpty, session.loaded, session.isCreate, session.saved.created == nil, !session.creating {
            Text(L10n.text("apple.workfloweditorview.no_supported_agent_cli_is_installed_on_thi.9b9a42fa"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
        if let other = session.otherDraft {
            comparison(title: L10n.text("apple.workfloweditorview.draft_from_another_window.8b70bae9"), draft: other.value.fields)
            Text(L10n.text("apple.workfloweditorview.choose_which_draft_to_continue_a_creation.6be102c4"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
            Button(L10n.text("apple.workfloweditorview.use_saved_draft.31f362c2"), .restore) { Task { await session.resolveDiskConflict(keepMine: false) } }
                .buttonStyle(SecondaryButtonStyle(comfortable: true))
                .disabled(session.working)
            if other.value.pendingCreate == false, other.value.pendingID == nil {
                Button(L10n.text("apple.workfloweditorview.keep_my_draft.cdb80bb9"), .edit) { Task { await session.resolveDiskConflict(keepMine: true) } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true))
                    .disabled(session.working)
            }
        }
        if session.conflict, let computer = session.current {
            comparison(title: L10n.text("apple.workfloweditorview.computer_version.33acfb2b"), draft: WorkflowEditorDraft(computer))
            Text(L10n.text("apple.workfloweditorview.this_workflow_changed_on_the_computer_choo.123691fb"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
    }

    private func comparison(title: String, draft: WorkflowEditorDraft) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(Theme.callout.weight(.semibold))
            Text(draft.name).font(Theme.callout)
            WorkflowStepStrip(nodes: draft.nodes, edges: draft.edges)
            Text(L10n.text("apple.workfloweditorview.0_1_steps.d251d63a", "\(draft.builtSchedule.summary)", "\(draft.nodes.count)"))
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
            WorkflowStepStrip(
                nodes: session.saved.created?.nodes ?? session.fields.nodes,
                edges: session.saved.created?.edges ?? session.fields.edges
            )
            if let created = session.saved.created, created.enabled, let next = created.nextRun {
                Text(L10n.text("apple.workfloweditorview.next_0.383f019f", "\(HostScheduleClock.nextRun(next, timezone: session.schedulerTimezone))"))
                    .font(Theme.callout)
                    .foregroundStyle(Theme.controlGlyph)
            }
            Text(L10n.text("apple.workfloweditorview.it_runs_on_0_in_1.8d815fb3", "\(hostName)", "\(session.folderName)"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
            if let place = HostScheduleClock.place(session.schedulerTimezone) {
                Text(L10n.text("apple.workfloweditorview.times_are_0_time.3e5f6eb5", "\(place)"))
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
            Button(L10n.text("apple.workfloweditorview.use_computer_version.f0d6599f"), .restore) { Task { await session.resolveConflict(keepMine: false) } }
                .buttonStyle(SecondaryButtonStyle(comfortable: true))
                .disabled(session.working)
            Button(L10n.text("apple.workfloweditorview.keep_my_draft.cdb80bb9"), .edit) { Task { await session.resolveConflict(keepMine: true) } }
                .buttonStyle(AccentButtonStyle(comfortable: true))
                .disabled(session.working)
        } else if session.creating {
            Button(L10n.text("apple.workfloweditorview.check_creation.61fe51e6"), .refresh) { Task { await session.checkCreated() } }
                .buttonStyle(SecondaryButtonStyle(comfortable: true))
                .disabled(session.working)
            if session.canRetryCreate {
                Button(L10n.text("apple.workfloweditorview.retry_creation.0bb084c1"), .create) { Task { await session.retryCreate() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true))
                    .disabled(session.working || session.otherDraft != nil)
            }
        } else if session.isCreate {
            Button(L10n.text("apple.workfloweditorview.create_workflow.3a5350ee"), .create) { Task { await session.create() } }
                .buttonStyle(AccentButtonStyle(comfortable: true))
                .disabled(!session.canCreate)
        } else {
            Button(L10n.text("apple.workfloweditorview.save_workflow.e77921c8"), .save) { Task { await session.save() } }
                .buttonStyle(AccentButtonStyle(comfortable: true))
                .disabled(!session.canSave)
        }
    }
}
