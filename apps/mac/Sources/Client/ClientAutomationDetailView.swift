// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// One scheduled job on a phone: the prompt, Run / Stop, pause.
struct ClientAutomationDetailView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let folderName: String
    let jobID: String

    @State private var session: ClientAutomationSession
    @State private var editor: AutomationEditorRoute?
    @State private var pendingDelete = false

    init(peer: String, workspaceID: String, hostName: String, folderName: String, jobID: String) {
        self.peer = peer
        self.workspaceID = workspaceID
        self.hostName = hostName
        self.folderName = folderName
        self.jobID = jobID
        _session = State(
            initialValue: ClientAutomationSession(
                peer: peer,
                workspaceID: workspaceID,
                hostName: hostName,
                folderName: folderName,
                jobID: jobID
            )
        )
    }

    init(session: ClientAutomationSession) {
        peer = session.peer
        workspaceID = session.workspaceID
        hostName = session.hostName
        folderName = session.folderName
        jobID = session.selectedJobID ?? ""
        _session = State(initialValue: session)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let errorMessage = session.errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await session.load() }
                    }
                }
                if let job = session.selectedJob {
                    facts(job)
                    prompt(job)
                    ClientAutomationActions(session: session, shortcutsEnabled: editor == nil)
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface()
                    runs(of: job)
                } else if session.loaded {
                    ClientSectionEmpty(
                        text: L10n.text("apple.clientautomationdetailview.this_job_is_gone.b3e6a44a"),
                        message: L10n.text("apple.clientautomationdetailview.it_is_not_in_the_folder_any_more.ff5d54d4")
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Space.xl)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .navigationTitle(session.selectedJob?.name ?? L10n.text("apple.clientautomationdetailview.automation.d909750b"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let job = session.selectedJob {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("common.edit"), .edit) {
                        editor = AutomationEditorRoute(
                            workspaceID: workspaceID, folderName: folderName, job: job
                        )
                    }
                    .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("common.delete"), .delete, role: .destructive) { pendingDelete = true }
                        .labelStyle(.iconOnly)
                }
            }
        }
        .fullScreenCover(item: $editor) { route in
            AutomationEditorDestination(
                target: AutomationEditorTarget(peer: peer),
                workspaceID: route.workspaceID,
                folderName: route.folderName,
                hostName: hostName,
                existing: route.job
            ) { _ in
                await session.load()
            }
        }
        .confirmationDialog(
            L10n.text("apple.clientautomationdetailview.delete_0.dc6c5ae4", "\(session.selectedJob?.name ?? L10n.text("apple.clientautomationdetailview.this_job.c627fafe"))"),
            isPresented: $pendingDelete,
            titleVisibility: .visible
        ) {
            Button(L10n.text("common.delete"), role: .destructive) {
                if let job = session.selectedJob {
                    Task { await session.remove(job) }
                }
            }
            Button(L10n.text("apple.clientautomationdetailview.keep_it.fdce5da2"), role: .cancel) {}
        } message: {
            Text(L10n.text("apple.clientautomationdetailview.the_schedule_goes_with_it_runs_it_already.a4efc8fe"))
        }
        .refreshable {
            await ClientRefresh.pull("automation-detail-\(jobID)") { await session.load() }
        }
        .task { await session.appeared() }
        .onDisappear { session.disappeared() }
    }

    private func facts(_ job: Automation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                CadenceGlyph(
                    schedule: job.schedule,
                    enabled: job.enabled,
                    size: 22,
                    summary: job.schedule.summary
                )
                Text(hostName)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: Theme.Space.m) {
                ClientFactRow(label: L10n.text("apple.clientautomationdetailview.backend.2fb4019a"), value: job.backend)
                ClientFactRow(label: L10n.text("apple.clientautomationdetailview.schedule.f4830a1d"), value: job.schedule.summary)
            }
            if let model = job.model, !model.isEmpty {
                ClientFactRow(label: L10n.text("apple.clientautomationdetailview.model.5e2c614c"), value: model)
            }
            HStack(alignment: .top, spacing: Theme.Space.m) {
                ClientFactRow(label: L10n.text("apple.clientautomationdetailview.budget.1c6225ec"), value: ClientJobCopy.budget(job.budgetSeconds))
                if let clock = HostScheduleClock.clock(session.schedulerTimezone) {
                    ClientFactRow(label: L10n.text("apple.clientautomationdetailview.time_zone.b9fe1464"), value: clock)
                }
            }
            HStack(alignment: .top, spacing: Theme.Space.m) {
                if let next = job.nextRun, job.enabled {
                    ClientFactRow(
                        label: L10n.text("common.next"),
                        value: HostScheduleClock.nextRun(next, timezone: session.schedulerTimezone)
                    )
                }
                ClientFactRow(
                    label: L10n.text("apple.clientautomationdetailview.last.eb970eb0"),
                    value: ClientJobCopy.lastRunWhen(
                        session.lastRun(for: job)?.startedAt ?? job.lastRun
                    )
                )
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func prompt(_ job: Automation) -> some View {
        Text(job.prompt)
            .font(ClientType.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }

    @ViewBuilder
    private func runs(of job: Automation) -> some View {
        let all = session.runs(of: job)
        let history = AutomationRunHistory.preview(
            all, id: \.id, startedAtMs: \.startedAtMs, isLive: \.isRunning
        )
        if !history.isEmpty {
            Text(L10n.text("apple.clientautomationdetailview.recent_runs.237112b8"))
                .font(ClientType.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, Theme.Space.xs)
            if AutomationRunHistory.showsAllRuns(all.count) {
                NavigationLink {
                    ClientAutomationHistoryView(session: session, jobID: job.id)
                } label: {
                    ClientAllRunsRow(count: all.count)
                }
                .buttonStyle(.plain)
            }
            ForEach(history) { run in
                NavigationLink {
                    ClientAutomationRunView(session: session, runID: run.id)
                } label: {
                    ClientPastRunRow(
                        title: run.name,
                        status: run.status,
                        label: run.endedLabel,
                        started: run.startedAt,
                        timezone: session.schedulerTimezone,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#endif
