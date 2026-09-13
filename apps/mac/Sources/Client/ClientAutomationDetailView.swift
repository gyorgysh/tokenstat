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
                    ClientAutomationActions(session: session)
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface()
                    runs(of: job)
                } else if session.loaded {
                    ClientSectionEmpty(
                        text: "This job is gone",
                        message: "It is not in the folder any more."
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
        .navigationTitle(session.selectedJob?.name ?? "Automation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let job = session.selectedJob {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit", .edit) {
                        editor = AutomationEditorRoute(
                            workspaceID: workspaceID, folderName: folderName, job: job
                        )
                    }
                    .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Delete", .delete, role: .destructive) { pendingDelete = true }
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
            "Delete \(session.selectedJob?.name ?? "this job")?",
            isPresented: $pendingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let job = session.selectedJob {
                    Task { await session.remove(job) }
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The schedule goes with it. Runs it already produced stay.")
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
                ClientFactRow(label: "Backend", value: job.backend)
                ClientFactRow(label: "Schedule", value: job.schedule.summary)
            }
            if let model = job.model, !model.isEmpty {
                ClientFactRow(label: "Model", value: model)
            }
            ClientFactRow(label: "Budget", value: ClientJobCopy.budget(job.budgetSeconds))
            if let next = job.nextRun, job.enabled {
                ClientFactRow(
                    label: "Next",
                    value: next.formatted(date: .abbreviated, time: .shortened)
                )
            }
            ClientFactRow(
                label: "Last",
                value: ClientJobCopy.lastRunWhen(
                    session.lastRun(for: job)?.startedAt ?? job.lastRun
                )
            )
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
        let history = session.runs(of: job).prefix(6)
        if !history.isEmpty {
            Text("Recent runs")
                .font(ClientType.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, Theme.Space.xs)
            ForEach(Array(history)) { run in
                NavigationLink {
                    ClientAutomationRunView(session: session, runID: run.id)
                } label: {
                    ClientPastRunRow(
                        title: run.name,
                        status: run.status,
                        label: run.endedLabel,
                        started: run.startedAt
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#endif
