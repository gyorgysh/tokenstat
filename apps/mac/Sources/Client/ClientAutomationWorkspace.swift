// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// iPad workspace for a folder's jobs: list, the job, run column.
struct ClientAutomationWorkspace: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let folderName: String

    @State private var session: ClientAutomationSession

    init(peer: String, workspaceID: String, hostName: String, folderName: String) {
        self.peer = peer
        self.workspaceID = workspaceID
        self.hostName = hostName
        self.folderName = folderName
        _session = State(
            initialValue: ClientAutomationSession(
                peer: peer,
                workspaceID: workspaceID,
                hostName: hostName,
                folderName: folderName
            )
        )
    }

    var body: some View {
        GeometryReader { geo in
            let stackRun = geo.size.width < 800
            HStack(spacing: 0) {
                list
                    .frame(width: min(280, geo.size.width * 0.32))
                Divider()
                if stackRun {
                    VStack(spacing: 0) {
                        jobPane
                        Divider()
                        runColumn
                            .frame(minHeight: 220)
                    }
                } else {
                    jobPane
                    Divider()
                    runColumn
                        .frame(width: min(320, geo.size.width * 0.34))
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Automations")
        .navigationBarTitleDisplayMode(.inline)
        .task { await session.appeared() }
        .onDisappear { session.disappeared() }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let errorMessage = session.errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await session.load() }
                    }
                }
                if !session.loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Space.xl)
                } else if session.jobs.isEmpty {
                    ClientSectionEmpty(
                        text: "Nothing scheduled here",
                        art: .automations,
                        message: "Jobs are set up on the Mac. This folder's runs land here."
                    )
                } else {
                    ForEach(session.jobs) { job in
                        Button {
                            session.selectJob(job.id)
                        } label: {
                            ClientJobRow(
                                title: job.name,
                                subtitle: job.schedule.summary,
                                isLive: session.runs.contains { $0.jobId == job.id && $0.isRunning },
                                isEnabled: job.enabled,
                                cadence: job.schedule,
                                showsChevron: false,
                                isSelected: session.selectedJobID == job.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(Theme.Space.m)
        }
        .refreshable {
            await ClientRefresh.pull("workspace-automations-\(workspaceID)") {
                await session.load()
            }
        }
    }

    @ViewBuilder
    private var jobPane: some View {
        if let job = session.selectedJob {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.s) {
                        CadenceGlyph(
                            schedule: job.schedule,
                            enabled: job.enabled,
                            size: 22,
                            summary: job.schedule.summary
                        )
                        Text(job.name)
                            .font(ClientType.sectionTitle)
                    }
                    Text(job.prompt)
                        .font(ClientType.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ClientFactRow(label: "Backend", value: job.backend)
                    if let model = job.model, !model.isEmpty {
                        ClientFactRow(label: "Model", value: model)
                    }
                    ClientFactRow(label: "Schedule", value: job.schedule.summary)
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
            }
        } else {
            ClientSectionEmpty(text: "Pick a job", message: "Its schedule and its last runs open here.")
                .padding(Theme.Space.m)
        }
    }

    private var runColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ClientAutomationActions(session: session)
                if let run = session.selectedRun {
                    StatusPill(status: run.status, text: run.endedLabel)
                    TranscriptView(
                        text: session.transcriptText,
                        empty: run.isRunning ? "Waiting for output…" : "No readable output."
                    )
                }
                if let job = session.selectedJob {
                    let history = session.runs(of: job).prefix(5)
                    if !history.isEmpty {
                        Text("Recent runs")
                            .font(ClientType.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, Theme.Space.xs)
                        ForEach(Array(history)) { run in
                            Button {
                                session.selectRun(run)
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
            .padding(Theme.Space.m)
        }
        .background(Theme.background)
    }
}

#endif
