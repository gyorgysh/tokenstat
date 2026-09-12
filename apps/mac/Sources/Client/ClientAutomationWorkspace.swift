// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI
import UIKit

/// A folder's jobs keep the same session across phone and iPad layouts.
struct ClientAutomationWorkspace: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let folderName: String

    @State private var session: ClientAutomationSession
    @State private var search = ""
    @State private var navigation = ClientJobNavigation()
    @Environment(\.dynamicTypeSize) private var typeSize

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

    init(session: ClientAutomationSession, opensDetail: Bool = false) {
        peer = session.peer
        workspaceID = session.workspaceID
        hostName = session.hostName
        folderName = session.folderName
        _session = State(initialValue: session)
        var initialNavigation = ClientJobNavigation()
        if opensDetail { initialNavigation.openDetail() }
        _navigation = State(initialValue: initialNavigation)
    }

    var body: some View {
        GeometryReader { geo in
            let layout = ClientJobLayout.resolve(
                width: geo.size.width,
                prefersStack: UIDevice.current.userInterfaceIdiom != .pad || typeSize.isAccessibilitySize
            )
            workspace(layout)
                .navigationDestination(isPresented: Binding(
                    get: { navigation.presentsDetail(in: layout) },
                    set: { navigation.presentedDetailChanged($0, in: layout) }
                )) {
                    ClientAutomationDetailView(session: session)
                }
        }
        .background(Theme.background)
        .navigationTitle("Automations")
        .navigationBarTitleDisplayMode(.inline)
        .task { await session.appeared() }
        .onDisappear { session.disappeared() }
    }

    @ViewBuilder
    private func workspace(_ layout: ClientJobLayout) -> some View {
        if layout.arrangement == .compact {
            list(layout)
        } else {
            HStack(spacing: 0) {
                list(layout).frame(width: layout.listWidth)
                ThemeRule.vertical
                if layout.arrangement == .twoColumns {
                    ScrollView {
                        VStack(spacing: 0) {
                            jobContent
                            ThemeRule()
                            runContent
                        }
                    }
                } else {
                    ScrollView { jobContent }
                    ThemeRule.vertical
                    ScrollView { runContent }.frame(width: layout.runWidth)
                }
            }
        }
    }

    private func list(_ layout: ClientJobLayout) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField("Search automations", text: $search).textFieldStyle(.themed)
                    .accessibilityLabel("Search automations")
                if session.loaded {
                    Text("\(session.jobs.filter(\.enabled).count) enabled · \(session.runs.filter(\.isRunning).count) running")
                        .font(ClientType.caption).foregroundStyle(.secondary)
                }
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
                    ForEach(session.jobs.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.prompt.localizedCaseInsensitiveContains(search) }) { job in
                        Button {
                            session.selectJob(job.id)
                            navigation.openDetail()
                        } label: {
                            ClientJobRow(
                                title: job.name,
                                subtitle: job.schedule.summary,
                                isLive: session.runs.contains { $0.jobId == job.id && $0.isRunning },
                                isEnabled: job.enabled,
                                cadence: job.schedule,
                                showsChevron: layout.arrangement == .compact,
                                isSelected: layout.arrangement != .compact && session.selectedJobID == job.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    if !search.isEmpty && !session.jobs.contains(where: { $0.name.localizedCaseInsensitiveContains(search) || $0.prompt.localizedCaseInsensitiveContains(search) }) {
                        Text("No matching automations")
                            .font(ClientType.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Theme.Space.l)
                    }
                }
            }
            .padding(Theme.Space.m)
        }
        .scrollBounceBehavior(.always)
        .refreshable {
            await ClientRefresh.pull("workspace-automations-\(workspaceID)") {
                await session.load()
            }
        }
    }

    @ViewBuilder
    private var jobContent: some View {
        if let job = session.selectedJob {
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
        } else {
            ClientSectionEmpty(text: "Pick a job", message: "Its schedule and its last runs open here.")
                .padding(Theme.Space.m)
        }
    }

    private var runContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Run details").font(ClientType.sectionTitle)
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
                            navigation.openDetail()
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
        .background(Theme.background)
    }
}

#endif
