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
    @State private var sort: AutomationMobileOrder = .name
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
        .navigationTitle(L10n.text("common.automations"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(L10n.text("apple.clientautomationworkspace.blank_automation.642aebac"), .create) { editor = AutomationEditorRoute(workspaceID: workspaceID, folderName: folderName, job: nil) }
                    Section(L10n.text("apple.clientautomationworkspace.templates.56b564b7")) {
                        ForEach(AutomationTemplate.suggested) { template in
                            Button(template.title, systemImage: template.symbol) {
                                editor = AutomationEditorRoute(workspaceID: workspaceID, folderName: folderName, job: nil, template: template)
                            }
                        }
                    }
                } label: { ActionIcon.create.label(L10n.text("apple.clientautomationworkspace.new_automation.db87a63d")) }
                .labelStyle(.iconOnly)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(editor != nil || showingQueue || showingHistory)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(L10n.text("apple.clientautomationworkspace.sort_automations.449f1e2d"), selection: $sort) { ForEach(AutomationMobileOrder.allCases) { Text(L10n.enumLabel($0)).tag($0) } }
                } label: { ActionIcon.filter.label(L10n.text("apple.clientautomationworkspace.sort_automations.449f1e2d")) }
            }
        }
        .fullScreenCover(item: $editor) { route in
            AutomationEditorDestination(
                target: AutomationEditorTarget(peer: peer),
                workspaceID: route.workspaceID,
                folderName: route.folderName,
                hostName: hostName,
                existing: route.job,
                template: route.template
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
            L10n.text("apple.clientautomationworkspace.delete_0.dc6c5ae4", "\(pendingDelete?.name ?? L10n.text("apple.clientautomationworkspace.this_job.c627fafe"))"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("common.delete"), role: .destructive) {
                if let job = pendingDelete {
                    pendingDelete = nil
                    Task { await session.remove(job) }
                }
            }
            Button(L10n.text("apple.clientautomationworkspace.keep_it.fdce5da2"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L10n.text("apple.clientautomationworkspace.the_schedule_goes_with_it_runs_it_already.a4efc8fe"))
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
        return L10n.text("apple.clientautomationworkspace.0_enabled_1_running.6a231a0e", "\(enabled)", "\(running)")
    }

    private var filteredJobs: [Automation] {
        sort.sorted(session.jobs.filter {
            search.isEmpty
                || $0.name.localizedCaseInsensitiveContains(search)
                || $0.prompt.localizedCaseInsensitiveContains(search)
        })
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
            TextField(L10n.text("apple.clientautomationworkspace.search_automations.bdff71b2"), text: $search)
                .textFieldStyle(.themed)
                .accessibilityLabel(L10n.text("apple.clientautomationworkspace.search_automations.bdff71b2"))
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
                Text(L10n.text("apple.clientautomationworkspace.no_matching_automations.7358d7d9"))
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
                            Button(L10n.text("common.delete"), role: .destructive) { pendingDelete = job }
                            Button(L10n.text("common.edit")) { openEditor(job) }
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
                TextField(L10n.text("apple.clientautomationworkspace.search_automations.bdff71b2"), text: $search).textFieldStyle(.themed)
                    .accessibilityLabel(L10n.text("apple.clientautomationworkspace.search_automations.bdff71b2"))
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
                    Text(L10n.text("apple.clientautomationworkspace.no_matching_automations.7358d7d9"))
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
            text: L10n.text("apple.clientautomationworkspace.nothing_scheduled_here.911c1a9b"),
            art: .automations,
            message: L10n.text("apple.clientautomationworkspace.create_a_job_for_this_folder_it_runs_on_th.96a56e05"),
            actionTitle: L10n.text("apple.clientautomationworkspace.new_automation.db87a63d"),
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
            Button(L10n.text("apple.clientautomationworkspace.edit_automation.b16f31c1")) { openEditor(job) }
            Button(L10n.text("apple.clientautomationworkspace.delete_automation.f71084e7"), role: .destructive) { pendingDelete = job }
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
                    Button(L10n.text("common.edit"), .edit) { openEditor(job) }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                    Button(L10n.text("common.delete"), .delete) { pendingDelete = job }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
                Text(job.prompt)
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ClientFactRow(label: L10n.text("apple.clientautomationworkspace.backend.2fb4019a"), value: job.backend)
                if let model = job.model, !model.isEmpty {
                    ClientFactRow(label: L10n.text("apple.clientautomationworkspace.model.5e2c614c"), value: model)
                }
                ClientFactRow(label: L10n.text("apple.clientautomationworkspace.schedule.f4830a1d"), value: job.schedule.summary)
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    ClientFactRow(label: L10n.text("apple.clientautomationworkspace.budget.1c6225ec"), value: ClientJobCopy.budget(job.budgetSeconds))
                    if let clock = HostScheduleClock.clock(session.schedulerTimezone) {
                        ClientFactRow(label: L10n.text("apple.clientautomationworkspace.time_zone.b9fe1464"), value: clock)
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
                        label: L10n.text("apple.clientautomationworkspace.last.eb970eb0"),
                        value: ClientJobCopy.lastRunWhen(
                            session.lastRun(for: job)?.startedAt ?? job.lastRun
                        )
                    )
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ClientSectionEmpty(text: L10n.text("apple.clientautomationworkspace.pick_a_job.d9572964"), message: L10n.text("apple.clientautomationworkspace.its_schedule_and_its_last_runs_open_here.a6f3e92d"))
                .padding(Theme.Space.m)
        }
    }

    private var runContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.clientautomationworkspace.run_details.7bbc3690")).font(ClientType.sectionTitle)
            ClientAutomationActions(session: session, shortcutsEnabled: editor == nil && !showingHistory)
            if let run = session.selectedRun {
                StatusPill(status: run.status, text: run.endedLabel)
                TranscriptView(
                    text: session.transcriptText,
                    empty: run.isRunning ? L10n.text("apple.clientautomationworkspace.waiting_for_output.f05fefe2") : L10n.text("apple.clientautomationworkspace.no_readable_output.cd218ba3")
                )
            }
            if let job = session.selectedJob {
                let all = session.runs(of: job)
                let history = AutomationRunHistory.preview(
                    all, id: \.id, startedAtMs: \.startedAtMs, isLive: \.isRunning
                )
                if !history.isEmpty {
                    Text(L10n.text("apple.clientautomationworkspace.recent_runs.237112b8"))
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
