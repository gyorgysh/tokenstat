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
    @State private var editor: AutomationEditorRoute?
    @State private var showingQueue = false
    @State private var showingHistory = false
    @State private var pendingDelete: Automation?
    @Environment(\.dynamicTypeSize) private var typeSize
    private let opensDetailWhenReady: Bool

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
        opensDetailWhenReady = false
    }

    init(session: ClientAutomationSession, opensDetail: Bool = false) {
        peer = session.peer
        workspaceID = session.workspaceID
        hostName = session.hostName
        folderName = session.folderName
        _session = State(initialValue: session)
        _navigation = State(initialValue: ClientJobNavigation())
        opensDetailWhenReady = opensDetail
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New automation", .create) {
                    editor = AutomationEditorRoute(
                        workspaceID: workspaceID, folderName: folderName, job: nil
                    )
                }
                .labelStyle(.iconOnly)
            }
        }
        .fullScreenCover(item: $editor) { route in
            AutomationEditorDestination(
                target: AutomationEditorTarget(peer: peer),
                workspaceID: route.workspaceID,
                folderName: route.folderName,
                hostName: hostName,
                existing: route.job
            ) { created in
                await session.load()
                if let created { session.selectJob(created.id) }
            }
        }
        .sheet(isPresented: $showingQueue) {
            AutomationQueueDestination(
                peer: peer,
                hostName: hostName,
                folderName: folderName,
                service: session.queueService()
            ) {
                await session.load()
            }
            .modifier(QueueSheetPresentation())
        }
        .sheet(isPresented: $showingHistory) {
            if let job = session.selectedJob {
                ClientAutomationHistorySheet(session: session, jobID: job.id) { run in
                    session.selectRun(run)
                }
                .modifier(HistorySheetPresentation())
            }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "this job")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let job = pendingDelete {
                    pendingDelete = nil
                    Task { await session.remove(job) }
                }
            }
            Button("Keep it", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The schedule goes with it. Runs it already produced stay.")
        }
        .onReceive(NotificationCenter.default.publisher(for: AutomationEditorSession.didChange)) { _ in
            Task { await session.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AutomationQueueSession.didChange)) { _ in
            Task { await session.load() }
        }
        .task {
            await session.appeared()
            if opensDetailWhenReady { navigation.openDetail() }
            #if WORKBENCH_QA
            if ProcessInfo.processInfo.environment["WORKBENCH_QUEUE"] == "1" {
                showingQueue = true
            }
            if ProcessInfo.processInfo.environment["WORKBENCH_HISTORY"] == "1" {
                showingHistory = true
            }
            #endif
        }
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

    private var listSummary: String {
        let enabled = session.jobs.filter(\.enabled).count
        let running = session.runs.filter { run in
            run.isRunning && session.jobs.contains(where: { $0.id == run.jobId })
        }.count
        return "\(enabled) enabled · \(running) running"
    }

    private var filteredJobs: [Automation] {
        session.jobs.filter {
            search.isEmpty
                || $0.name.localizedCaseInsensitiveContains(search)
                || $0.prompt.localizedCaseInsensitiveContains(search)
        }
    }

    @ViewBuilder
    private func list(_ layout: ClientJobLayout) -> some View {
        if layout.arrangement == .compact {
            compactList
        } else {
            splitList(layout)
        }
    }

    private var compactList: some View {
        List {
            TextField("Search automations", text: $search)
                .textFieldStyle(.themed)
                .accessibilityLabel("Search automations")
                .clientCardRow()
            if session.loaded {
                schedulerCard(compactCopy: false).clientCardRow()
            }
            if session.loaded, !session.jobs.isEmpty {
                Text(listSummary)
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .clientCardRow()
            }
            if let errorMessage = session.errorMessage {
                ClientErrorCard(message: errorMessage) {
                    Task { await session.load() }
                }
                .clientCardRow()
            }
            if !session.loaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Space.xl)
                    .clientCardRow()
            } else if session.jobs.isEmpty {
                emptyState.clientCardRow()
            } else if filteredJobs.isEmpty {
                Text("No matching automations")
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Space.l)
                    .clientCardRow()
            } else {
                ForEach(filteredJobs) { job in
                    jobButton(job, showsChevron: true, isSelected: false)
                        .clientCardRow()
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) { pendingDelete = job }
                            Button("Edit") { openEditor(job) }
                                .tint(Theme.accent)
                        }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .contentMargins(.top, Theme.Space.m, for: .scrollContent)
        .refreshable {
            await ClientRefresh.pull("workspace-automations-\(workspaceID)") {
                await session.load()
            }
        }
    }

    private func splitList(_ layout: ClientJobLayout) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField("Search automations", text: $search).textFieldStyle(.themed)
                    .accessibilityLabel("Search automations")
                if session.loaded {
                    schedulerCard(compactCopy: true)
                }
                if session.loaded, !session.jobs.isEmpty {
                    Text(listSummary)
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.controlGlyph)
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
                    emptyState
                } else if filteredJobs.isEmpty {
                    Text("No matching automations")
                        .font(ClientType.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Space.l)
                } else {
                    ForEach(filteredJobs) { job in
                        jobButton(
                            job,
                            showsChevron: false,
                            isSelected: session.selectedJobID == job.id
                        )
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

    private func schedulerCard(compactCopy: Bool) -> some View {
        ClientSchedulerCard(
            hostName: hostName,
            folderName: folderName,
            queue: session.queue,
            compactCopy: compactCopy
        ) {
            showingQueue = true
        }
    }

    private var emptyState: some View {
        ClientSectionEmpty(
            text: "Nothing scheduled here",
            art: .automations,
            message: "Create a job for this folder. It runs on the connected computer.",
            actionTitle: "New automation",
            actionIcon: .create,
            action: {
                editor = AutomationEditorRoute(
                    workspaceID: workspaceID, folderName: folderName, job: nil
                )
            }
        )
    }

    private func jobButton(_ job: Automation, showsChevron: Bool, isSelected: Bool) -> some View {
        Button {
            session.selectJob(job.id)
            navigation.openDetail()
        } label: {
            ClientJobRow(
                title: job.name,
                subtitle: HostScheduleClock.listSubtitle(
                    cadence: job.schedule.summary,
                    next: job.nextRun,
                    enabled: job.enabled,
                    repeats: job.schedule.repeats,
                    timezone: session.schedulerTimezone
                ),
                isLive: session.runs.contains { $0.jobId == job.id && $0.isRunning },
                isEnabled: job.enabled,
                cadence: job.schedule,
                showsChevron: showsChevron,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit automation") { openEditor(job) }
            Button("Delete automation", role: .destructive) { pendingDelete = job }
        }
    }

    private func openEditor(_ job: Automation) {
        editor = AutomationEditorRoute(
            workspaceID: workspaceID, folderName: folderName, job: job
        )
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
                    Spacer(minLength: 0)
                    Button("Edit", .edit) { openEditor(job) }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                    Button("Delete", .delete) { pendingDelete = job }
                        .buttonStyle(SecondaryButtonStyle(small: true))
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
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    ClientFactRow(label: "Budget", value: ClientJobCopy.budget(job.budgetSeconds))
                    if let clock = HostScheduleClock.clock(session.schedulerTimezone) {
                        ClientFactRow(label: "Time zone", value: clock)
                    }
                }
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    if let next = job.nextRun, job.enabled {
                        ClientFactRow(
                            label: "Next",
                            value: HostScheduleClock.nextRun(next, timezone: session.schedulerTimezone)
                        )
                    }
                    ClientFactRow(
                        label: "Last",
                        value: ClientJobCopy.lastRunWhen(
                            session.lastRun(for: job)?.startedAt ?? job.lastRun
                        )
                    )
                }
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
                let all = session.runs(of: job)
                let history = AutomationRunHistory.preview(
                    all, id: \.id, startedAtMs: \.startedAtMs, isLive: \.isRunning
                )
                if !history.isEmpty {
                    Text("Recent runs")
                        .font(ClientType.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, Theme.Space.xs)
                    if AutomationRunHistory.showsAllRuns(all.count) {
                        Button {
                            showingHistory = true
                        } label: {
                            ClientAllRunsRow(count: all.count)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(history) { run in
                        Button {
                            session.selectRun(run)
                            navigation.openDetail()
                        } label: {
                            ClientPastRunRow(
                                title: run.name,
                                status: run.status,
                                label: run.endedLabel,
                                started: run.startedAt,
                                timezone: session.schedulerTimezone,
                                isSelected: session.selectedRunID == run.id
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
