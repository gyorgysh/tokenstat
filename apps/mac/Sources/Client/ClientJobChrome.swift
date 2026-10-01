// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// A labelled fact on a job or graph. Same shape on phone and iPad.
struct ClientFactRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(ClientType.caption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(ClientType.label)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Prompt field plus Run / Stop / Continue, with confirms that name the machine.
struct ClientWorkflowActions: View {
    @Bindable var session: ClientWorkflowSession
    var showsPrompt: Bool = true
    /// When set, only Stop / Continue for that run. Start stays on the graph page.
    var pinnedRunID: String? = nil
    /// False while an editor, history sheet or other cover is up above this
    /// surface. The chord then stays listed but does not fire.
    var shortcutsEnabled = true

    @State private var pending: Pending?

    private enum Pending: Identifiable {
        case run
        case stop
        case continueGate

        var id: String {
            switch self {
            case .run: return "run"
            case .stop: return "stop"
            case .continueGate: return "continue"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if showsPrompt, session.liveRun == nil {
                TextField(L10n.text("apple.clientjobchrome.starting_prompt.407bec2f"), text: $session.input, axis: .vertical)
                    .font(ClientType.body)
                    .lineLimit(3...8)
                    .padding(Theme.Space.s)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
            }
            HStack(spacing: Theme.Space.s) {
                if let run = session.liveRun, pinnedRunID == nil || pinnedRunID == run.id {
                    if run.isWaiting {
                        Button(session.working ? L10n.text("common.working") : L10n.text("apple.clientjobchrome.continue.31fbef16"), .next) {
                            pending = .continueGate
                        }
                        .clientProminentStyle()
                        .disabled(session.working)
                    }
                    Button(L10n.text("common.stop"), .stop) { pending = .stop }
                        .clientGlassStyle()
                        .disabled(session.working)
                } else if pinnedRunID == nil {
                    Button(session.working ? L10n.text("apple.clientjobchrome.starting.aeed4d26") : L10n.text("common.run"), .run) { pending = .run }
                        .clientProminentStyle()
                        .disabled(session.working || session.selectedGraph == nil)
                }
                if pinnedRunID == nil, let graph = session.selectedGraph, graph.schedule.repeats {
                    BrandToggleChip(
                        title: graph.enabled ? L10n.text("apple.clientjobchrome.on.13001175") : L10n.text("apple.clientjobchrome.off.ca7981b4"),
                        isOn: Binding(
                            get: { graph.enabled },
                            set: { _ in Task { await session.toggleSchedule() } }
                        )
                    )
                    .accessibilityLabel(L10n.text("common.enabled"))
                }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: confirmPresented, titleVisibility: .visible) {
            switch pending {
            case .run:
                Button(L10n.text("common.run")) { Task { await session.run() } }
                Button(L10n.text("common.cancel"), role: .cancel) { pending = nil }
            case .stop:
                Button(L10n.text("common.stop"), role: .destructive) { Task { await session.stop() } }
                Button(L10n.text("apple.clientjobchrome.keep_it.fdce5da2"), role: .cancel) { pending = nil }
            case .continueGate:
                Button(L10n.text("apple.clientjobchrome.continue.31fbef16")) { Task { await session.continueGate() } }
                Button(L10n.text("common.cancel"), role: .cancel) { pending = nil }
            case nil:
                Button(L10n.text("common.cancel"), role: .cancel) { pending = nil }
            }
        } message: {
            Text(confirmMessage)
        }
        .onChange(of: session.working) { _, working in
            if !working { pending = nil }
        }
        // Focused Run: the same confirm tapping Run opens, reachable from
        // the keyboard and listed in discovery. Never bare Return, and never
        // while a live run, a cover, or another start owns the surface.
        .clientShortcuts([
            .workbench(.run, id: "run-workflow", title: L10n.text("apple.clientjobchrome.run_workflow.4b5897af"),
                       enabled: WorkbenchShortcutPolicy.canRun(JobRunShortcutState(
                           working: session.working,
                           hasSelection: session.selectedGraph != nil,
                           hasLiveRun: session.liveRun != nil,
                           modalPresented: !shortcutsEnabled || pinnedRunID != nil
                       ))) {
                pending = .run
            },
        ])
    }

    private var confirmPresented: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var confirmTitle: String {
        let name = session.selectedGraph?.name ?? L10n.text("apple.clientjobchrome.this_workflow.a7b5fc94")
        switch pending {
        case .run: return L10n.text("apple.clientjobchrome.run_0.52ecce8a", "\(name)")
        case .stop: return L10n.text("apple.clientjobchrome.stop_0.0d85fcc3", "\(name)")
        case .continueGate: return L10n.text("apple.clientjobchrome.continue_0.c6506423", "\(name)")
        case nil: return L10n.text("apple.clientjobchrome.confirm.eebdd24a")
        }
    }

    private var confirmMessage: String {
        let name = session.selectedGraph?.name ?? L10n.text("apple.clientjobchrome.this_workflow.a7b5fc94")
        switch pending {
        case .run:
            return ClientJobCopy.run(name, folder: session.folderName, host: session.hostName)
        case .stop:
            return ClientJobCopy.stop(name, folder: session.folderName, host: session.hostName)
        case .continueGate:
            return ClientJobCopy.continueGate(name, folder: session.folderName, host: session.hostName)
        case nil:
            return ""
        }
    }
}

/// Run now / Stop / pause, with the same confirms as workflows.
struct ClientAutomationActions: View {
    @Bindable var session: ClientAutomationSession
    /// When set, only Stop for that run. Start stays on the job page.
    var pinnedRunID: String? = nil
    /// False while an editor, history sheet or other cover is up above this
    /// surface. The chord then stays listed but does not fire.
    var shortcutsEnabled = true

    @State private var pending: Pending?

    private enum Pending: Identifiable {
        case run
        case stop

        var id: String {
            switch self {
            case .run: return "run"
            case .stop: return "stop"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
        HStack(spacing: Theme.Space.s) {
            if let run = session.liveRun, pinnedRunID == nil || pinnedRunID == run.id {
                Button(L10n.text("common.stop"), .stop) { pending = .stop }
                    .clientGlassStyle()
                    .disabled(session.working)
            } else if pinnedRunID == nil, let job = session.selectedJob, session.pendingLaunch(for: job) != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.s) { launchRecovery(for: job) }
                    VStack(alignment: .leading, spacing: Theme.Space.s) { launchRecovery(for: job) }
                }
            } else if pinnedRunID == nil {
                Button(session.working ? L10n.text("apple.clientjobchrome.starting.aeed4d26") : L10n.text("apple.clientjobchrome.run_now.09913977"), .run) { pending = .run }
                    .clientProminentStyle()
                    .disabled(session.working || session.selectedJob == nil)
            }
            if pinnedRunID == nil, let job = session.selectedJob, job.schedule.repeats {
                BrandToggleChip(
                    title: job.enabled ? L10n.text("apple.clientjobchrome.on.13001175") : L10n.text("apple.clientjobchrome.off.ca7981b4"),
                    isOn: Binding(
                        get: { job.enabled },
                        set: { _ in Task { await session.toggleSchedule() } }
                    )
                )
                .accessibilityLabel(L10n.text("common.enabled"))
            }
        }
        if pinnedRunID == nil, let job = session.selectedJob, session.pendingLaunch(for: job) != nil, session.liveRun == nil {
            Text(L10n.text("apple.clientjobchrome.this_run_is_not_confirmed_yet_check_it_bef.46c377ae"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
        }
        .confirmationDialog(confirmTitle, isPresented: confirmPresented, titleVisibility: .visible) {
            switch pending {
            case .run:
                Button(L10n.text("common.run")) { Task { await session.run() } }
                Button(L10n.text("common.cancel"), role: .cancel) { pending = nil }
            case .stop:
                Button(L10n.text("common.stop"), role: .destructive) { Task { await session.stop() } }
                Button(L10n.text("apple.clientjobchrome.keep_it.fdce5da2"), role: .cancel) { pending = nil }
            case nil:
                Button(L10n.text("common.cancel"), role: .cancel) { pending = nil }
            }
        } message: {
            Text(confirmMessage)
        }
        .onChange(of: session.working) { _, working in
            if !working { pending = nil }
        }
        // Focused Run: the same confirm tapping Run now opens, reachable
        // from the keyboard and listed in discovery. Never bare Return, and
        // never while a live run, an unconfirmed launch, or a cover owns it.
        .clientShortcuts([
            .workbench(.run, id: "run-automation", title: L10n.text("apple.clientjobchrome.run_automation.db76d94b"),
                       enabled: WorkbenchShortcutPolicy.canRun(JobRunShortcutState(
                           working: session.working,
                           hasSelection: session.selectedJob != nil,
                           hasLiveRun: session.liveRun != nil,
                           hasPendingLaunch: session.selectedJob
                               .map { session.pendingLaunch(for: $0) != nil } ?? false,
                           modalPresented: !shortcutsEnabled || pinnedRunID != nil
                       ))) {
                pending = .run
            },
        ])
    }

    private var confirmPresented: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var confirmTitle: String {
        let name = selectedName
        switch pending {
        case .run: return L10n.text("apple.clientjobchrome.run_0.52ecce8a", "\(name)")
        case .stop: return L10n.text("apple.clientjobchrome.stop_0.0d85fcc3", "\(name)")
        case nil: return L10n.text("apple.clientjobchrome.confirm.eebdd24a")
        }
    }

    private var confirmMessage: String {
        let name = selectedName
        switch pending {
        case .run:
            return ClientJobCopy.run(name, folder: session.folderName, host: session.hostName)
        case .stop:
            return ClientJobCopy.stop(name, folder: session.folderName, host: session.hostName)
        case nil:
            return ""
        }
    }

    private var selectedName: String {
        if pinnedRunID != nil { return session.selectedRun?.name ?? L10n.text("apple.clientjobchrome.this_run.c35c8157") }
        return session.selectedJob?.name ?? session.selectedRun?.name ?? L10n.text("apple.clientjobchrome.this_job.c627fafe")
    }

    @ViewBuilder
    private func launchRecovery(for job: Automation) -> some View {
        Button(L10n.text("apple.clientjobchrome.check_run.cece2401"), .refresh) { Task { await session.checkLaunch() } }
            .clientGlassStyle()
            .disabled(session.working)
        if session.canRetryLaunch(for: job) {
            Button(L10n.text("apple.clientjobchrome.retry_run.2f9c439b"), .run) { Task { await session.retryLaunch() } }
                .clientProminentStyle()
                .disabled(session.working)
        }
    }
}

/// One past run as a row. Used on the phone list and the iPad column.
struct ClientPastRunRow: View {
    let title: String
    let status: String
    let label: String
    let started: Date
    var timezone: String = ""
    var isSelected: Bool = false
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(RunOutcome.tint(status))
                .frame(width: 8, height: 8)
            Text(title)
                .font(ClientType.label.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            StatusPill(status: status, text: label)
            Text(when)
                .font(ClientType.caption)
                .foregroundStyle(Theme.controlGlyph)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.controlGlyph)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(
            isSelected ? Theme.rowSelected : Theme.panel,
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 1)
        }
        .contentShape(.rect)
        .accessibilityLabel("\(title), \(label), \(when)")
    }

    private var when: String {
        HostScheduleClock.wallClock(started, timezone: timezone)
            ?? started.formatted(date: .omitted, time: .shortened)
    }
}

/// Opens the complete run history from a short preview.
struct ClientAllRunsRow: View {
    let count: Int
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: ActionIcon.history.symbol)
                .font(Theme.callout.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
            Text(count == 1 ? L10n.text("apple.clientjobchrome.all_runs.33866ac3") : L10n.text("apple.clientjobchrome.all_0_runs.8e631c72", "\(count)"))
                .font(ClientType.label.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.controlGlyph)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        .contentShape(.rect)
        .accessibilityLabel(count == 1 ? L10n.text("apple.clientjobchrome.all_runs.33866ac3") : L10n.text("apple.clientjobchrome.all_0_runs.8e631c72", "\(count)"))
        .accessibilityHint(L10n.text("apple.clientjobchrome.opens_every_retained_run_for_this_job.3b8fe390"))
    }
}

#endif
