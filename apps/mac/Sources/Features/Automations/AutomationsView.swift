// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

/// The agent automations screen.
///
/// The automations are the screen. Runs are what they produced, and creating
/// one is a sheet, because a permanent form standing over the list made an
/// empty screen look like a form to fill in rather than a place where nothing
/// had been set up yet.
///
/// A job is a backend, a prompt, a workspace and a schedule, exactly like
/// launching `claude -p "…"` in a terminal but owned by the daemon and stopped
/// at a budget. With Always-on host it runs after this window closes. On a
/// laptop that switch is off, so a job runs while tokenstat is open.
struct AutomationsView: View {
    @Bindable var model: AutomationsModel
    /// The registered folders, shared with the workspaces screen. Passed in so
    /// this screen never runs a second `workspace.list`.
    var folders: [WorkspaceFolder]
    var onNavigate: ((NavigationRequest) -> Void)? = nil
    /// A run to open on arrival, requested from Tasks. Cleared once opened.
    @Binding var pendingRunID: String?

    @State private var creating = false
    @State private var template: AutomationTemplate?
    @State private var search = ""
    @State private var schedulerJustSaved = false
    @State private var schedulerSaving = false
    @State private var showingScheduler = false
    /// Jobs, or what they produced. One table at a time: the two lists used
    /// to share a scroll, and the runs at the bottom were found by accident.
    @State private var showingRuns = false
    @State private var filter: JobFilter = .all
    @State private var jobOrder = [KeyPathComparator(\Automation.name)]
    @State private var runOrder = [KeyPathComparator(\RunRecord.startedAtMs, order: .reverse)]
    @State private var editingJob: Automation?
    @State private var historyJob: Automation?
    @State private var jobPendingDelete: Automation?

    /// The quick cuts through the job list, counted in the menu.
    enum JobFilter: String, CaseIterable, Identifiable {
        case all, enabled, paused, failing
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return L10n.text("apple.automationsview.all.a52ace42")
            case .enabled: return L10n.text("common.enabled")
            case .paused: return L10n.text("common.paused")
            case .failing: return L10n.text("apple.automationsview.last_run_failed.d86e53b5")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailChromeBar(scope: scopeChip) {
                EmptyView()
            }
            toolbar
            ThemeRule()
            if let error = model.errorMessage {
                ErrorBanner(message: error) { Task { await model.load() } }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.s)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle(L10n.text("common.automations"))
        .background(Theme.background)
        .sheet(isPresented: $creating) {
            NewAutomationSheet(model: model, folders: folders, onNavigate: onNavigate)
        }
        .sheet(item: $template) { suggestion in
            NewAutomationSheet(
                model: model,
                folders: folders,
                onNavigate: onNavigate,
                template: suggestion
            )
        }
        .sheet(item: $editingJob) { job in
            NewAutomationSheet(model: model, folders: folders, existing: job)
        }
        .sheet(item: $historyJob) { job in
            AutomationHistorySheet(job: job, model: model) { run in
                showingRuns = true
                model.selectRun(run)
            }
        }
        .confirmationDialog(
            L10n.text("apple.automationsview.delete_0.dc6c5ae4", "\(jobPendingDelete?.name ?? L10n.text("apple.automationsview.this_automation.0941cb02"))"),
            isPresented: Binding(
                get: { jobPendingDelete != nil },
                set: { if !$0 { jobPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: jobPendingDelete
        ) { job in
            Button(L10n.text("common.delete"), role: .destructive) { Task { await model.remove(job) } }
            Button(L10n.text("apple.automationsview.keep_it.fdce5da2"), role: .cancel) {}
        } message: { _ in
            Text(L10n.text("apple.automationsview.the_schedule_goes_with_it_runs_it_already.a4efc8fe"))
        }
        .overlay(alignment: .bottomTrailing) {
            TransientToast(message: $model.noticeMessage, severity: .success)
                .padding(Theme.Space.l)
        }
        .task {
            await model.appeared()
            // A delegated task navigated here asking for its transcript.
            guard let id = pendingRunID else { return }
            // The run usually arrives with the list, but a run that finished
            // moments ago can land a tick later; give it a beat before giving
            // up rather than dropping the request silently.
            for _ in 0..<6 {
                guard !Task.isCancelled else { return }
                if let run = model.runs.first(where: { $0.id == id }) {
                    pendingRunID = nil
                    showingRuns = true
                    model.selectRun(run)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            pendingRunID = nil
        }
        // The model outlives this view, and the transcript tail must not.
        .onDisappear { model.disappeared() }
        #if DEBUG && os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: DebugUIHooks.keyRequested)) { note in
            switch note.object as? String {
            case "automations.runs": showingRuns.toggle()
            case "automations.scheduler": showingScheduler.toggle()
            default: break
            }
        }
        #endif
    }

    /// Search and the cuts on the left, the ways to add on the right.
    private var toolbar: some View {
        HStack(spacing: Theme.Space.s) {
            SearchField(text: $search, prompt: showingRuns ? L10n.text("apple.automationsview.search_runs.26d6d37f") : L10n.text("apple.automationsview.search_automations.bdff71b2"))
                .frame(minWidth: 140, maxWidth: 260)
            if !showingRuns {
                filterMenu
            }
            Spacer(minLength: Theme.Space.s)
            SegmentedCapsulePicker(
                options: [
                    (value: false, label: L10n.text("apple.automationsview.jobs.2f17a0f8"), symbol: "bolt"),
                    (value: true, label: L10n.text("apple.automationsview.runs.848f54e8"), symbol: ActionIcon.history.symbol),
                ],
                selection: $showingRuns
            )
            .fixedSize()
            templatesMenu
            // A setting, not a daily action, so it takes a glyph's width and
            // leaves the words to the things people press every day.
            ToolbarIconButton(
                systemImage: ActionIcon.settings.symbol,
                help: L10n.text("apple.automationsview.scheduler_time_limit_and_how_many_jobs_run.63c8f49a"),
                isAccent: showingScheduler
            ) { showingScheduler.toggle() }
                .popover(isPresented: $showingScheduler, arrowEdge: .bottom) {
                    schedulerCard
                        .frame(width: 380)
                        .padding(Theme.Space.s)
                }
            Button(L10n.text("apple.automationsview.new_automation.db87a63d"), .create) { creating = true }
                .buttonStyle(AccentButtonStyle(small: true))
                .fixedSize()
                .disabled(folders.isEmpty)
                .help(folders.isEmpty ? L10n.text("apple.automationsview.add_a_project_first_an_agent_runs_somewher.6ab06aa6") : L10n.text("apple.automationsview.schedule_an_agent_job.224ec5fa"))
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    private var filterMenu: some View {
        Menu {
            Picker(L10n.text("apple.automationsview.show.0df6f1ca"), selection: $filter) {
                ForEach(JobFilter.allCases) { option in
                    Text("\(option.label)  \(jobs(matching: option).count)").tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(filter == .all ? L10n.text("apple.automationsview.filter.638e249f") : filter.label, systemImage: ActionIcon.filter.symbol)
                .font(Theme.font(12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.text("apple.automationsview.show_only_some_automations.74fe7a0c"))
    }

    /// Ready-made jobs, one menu away rather than a section of their own.
    private var templatesMenu: some View {
        Menu {
            ForEach(Self.suggestedTemplates) { suggestion in
                Button(suggestion.title, systemImage: suggestion.symbol) { template = suggestion }
            }
        } label: {
            Label(L10n.text("apple.automationsview.templates.56b564b7"), systemImage: "square.on.square")
                .font(Theme.font(12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(folders.isEmpty)
        .help(L10n.text("apple.automationsview.start_from_a_ready_made_job.72bf97a5"))
    }

    @ViewBuilder
    private var content: some View {
        if isWarming {
            // "Nothing yet" is an answer, and it must not be given before the
            // question has been asked. Grey rows say the daemon is being read.
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Skeleton.CardPlaceholder(rows: 2)
                Skeleton.CardPlaceholder(rows: 2)
            }
            .padding(Theme.Space.m)
            .transition(.opacity)
        } else if showingRuns {
            if visibleRuns.isEmpty {
                if isSearching {
                    ContentUnavailableView.search(text: search)
                } else {
                    EmptyState(
                        symbol: "text.append",
                        title: L10n.text("apple.automationsview.nothing_has_run_yet.45d9f27c"),
                        message: L10n.text("apple.automationsview.a_run_appears_here_the_moment_an_automatio.a7ef255f")
                    )
                    .padding(Theme.Space.xl)
                }
            } else {
                runsTable
            }
        } else if model.scoped.isEmpty {
            ScrollView { nothingYet.padding(Theme.Space.m) }
        } else if visibleJobs.isEmpty {
            if isSearching {
                ContentUnavailableView.search(text: search)
            } else {
                EmptyState(
                    symbol: ActionIcon.filter.symbol,
                    title: L10n.text("apple.automationsview.no_automations_match.f2d793e6"),
                    message: L10n.text("apple.automationsview.nothing_here_is_0_right_now.81efd682", "\(filter.label.lowercased())")
                ) {
                    Button(L10n.text("apple.automationsview.show_all.2150d8df"), .filter) { filter = .all }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(Theme.Space.xl)
            }
        } else {
            jobsTable
        }
    }

    // MARK: - Jobs

    /// One row per job, with the facts people compare across jobs in columns:
    /// when it runs, where, when it next fires and how it went last time.
    /// Columns resize and the sortable ones sort, because that is what a
    /// table is for.
    private var jobsTable: some View {
        Table(visibleJobs, selection: jobSelection, sortOrder: $jobOrder) {
            // The agent's mark leads the name: it says who does the job, and
            // the Schedule column already says when in words.
            TableColumn(L10n.text("apple.automationsview.name.dcd1d522"), value: \.name) { job in
                HStack(spacing: Theme.Space.s) {
                    HarnessMark(id: job.backend, size: 16)
                        .help(backendLabel(job.backend))
                        .accessibilityLabel(backendLabel(job.backend))
                    Text(job.name)
                        .font(Theme.font(13, weight: .medium))
                        .foregroundStyle(job.enabled ? Color.primary : Color.secondary)
                        .lineLimit(1)
                }
                .help(job.prompt)
            }
            .width(min: 120, ideal: 160)
            // Ideal widths add up to what a 1100 pt window leaves beside the
            // sidebar, so every column is on screen without scrolling sideways.
            TableColumn(L10n.text("apple.automationsview.schedule.f4830a1d")) { job in
                cell(model.scheduleSummary(job.schedule))
            }
            .width(min: 90, ideal: 116)
            TableColumn(L10n.text("apple.automationsview.project.98595978")) { job in
                cell(folderLabel(job.workspaceID))
            }
            .width(min: 70, ideal: 96)
            // A paused job has no next run, so its status sits where the
            // time would: one column answers "when does this go next".
            TableColumn(L10n.text("apple.automationsview.next_run.b3c0ab96"), value: \.nextRunOrder) { job in
                nextRunCell(job)
            }
            .width(min: 90, ideal: 110)
            TableColumn(L10n.text("apple.automationsview.last_run.512a4821"), value: \.lastRunOrder) { job in
                lastRunCell(job)
            }
            .width(min: 80, ideal: 110)
            TableColumn("") { job in
                actionsCell(job)
            }
            .width(min: 62, ideal: 64)
        }
        .quietTableStyle()
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            if let job = ids.first.flatMap(job(withID:)) {
                jobMenu(job)
            }
        } primaryAction: { ids in
            if let job = ids.first.flatMap(job(withID:)) { editingJob = job }
        }
    }

    private var jobSelection: Binding<String?> {
        Binding(
            get: { model.selectedJobID },
            set: { id in if let id { model.selectJob(id) } }
        )
    }

    private func cell(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
    }

    @ViewBuilder
    private func nextRunCell(_ job: Automation) -> some View {
        if !job.enabled {
            statusCell(job)
        } else if let next = job.nextRun {
            cell(HostScheduleClock.wallClock(next, timezone: model.schedulerTimezone)
                ?? next.formatted(date: .abbreviated, time: .shortened))
        } else {
            cell(L10n.text("apple.automationsview.when_you_run_it.5d06a91f"))
        }
    }

    @ViewBuilder
    private func lastRunCell(_ job: Automation) -> some View {
        if let last = model.lastRun(for: job) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Self.statusTint(last.status))
                    .frame(width: 6, height: 6)
                Text(last.isRunning ? last.endedLabel : "\(last.endedLabel) \(CompactAge.ago(last.startedAt))")
                    .font(Theme.font(12))
                    .foregroundStyle(last.isRunning ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .help(last.startedAt.formatted(date: .abbreviated, time: .shortened))
        } else {
            cell(L10n.text("common.never"))
        }
    }

    /// On or off, and a press flips it. The words say what it is, not what
    /// the switch would do.
    private func statusCell(_ job: Automation) -> some View {
        Button {
            Task { await model.toggle(job) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: job.enabled ? "circle.fill" : "pause.circle")
                    .font(Theme.font(job.enabled ? 6 : 11, weight: .semibold))
                Text(job.enabled ? L10n.text("common.enabled") : L10n.text("common.paused"))
                    .font(Theme.font(12, weight: .medium))
            }
            .foregroundStyle(job.enabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                (job.enabled ? Theme.accentSoft : Theme.controlSeat),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(job.enabled ? L10n.text("apple.automationsview.running_on_its_schedule_click_to_pause.02cdad86") : L10n.text("apple.automationsview.paused_it_will_not_fire_click_to_enable.49b58042"))
    }

    private func actionsCell(_ job: Automation) -> some View {
        HStack(spacing: 0) {
            if let last = model.lastRun(for: job), last.isRunning {
                ToolbarIconButton(systemImage: ActionIcon.stop.symbol, help: L10n.text("apple.automationsview.stop_this_run.7647f899")) {
                    Task { await model.stop(last) }
                }
            } else {
                ToolbarIconButton(systemImage: ActionIcon.run.symbol, help: L10n.text("apple.automationsview.run_now.09913977")) {
                    Task { await model.run(job) }
                }
            }
            ToolbarMenuButton(help: L10n.text("apple.automationsview.actions_for_0.29a5141b", "\(job.name)")) {
                jobMenu(job)
            }
        }
    }

    @ViewBuilder
    private func jobMenu(_ job: Automation) -> some View {
        Button(L10n.text("apple.automationsview.run_now.09913977"), .run) { Task { await model.run(job) } }
        Button(job.enabled ? L10n.text("apple.automationsview.pause.858e4ba7") : L10n.text("apple.automationsview.enable.5342e09f"), job.enabled ? .stop : .run) {
            Task { await model.toggle(job) }
        }
        Button(L10n.text("apple.automationsview.run_history.addf321b"), .history) { historyJob = job }
        Button(L10n.text("apple.automationsview.edit_automation.b16f31c1"), .edit) { editingJob = job }
        Divider()
        Button(L10n.text("apple.automationsview.delete_automation.f71084e7"), .delete, role: .destructive) { jobPendingDelete = job }
    }

    // MARK: - Runs

    /// Every run in scope, newest first by default. Selecting one reads its
    /// output in the inspector.
    private var runsTable: some View {
        Table(visibleRuns, selection: runSelection, sortOrder: $runOrder) {
            TableColumn(L10n.text("apple.automationsview.automation.d909750b"), value: \.name) { run in
                HStack(spacing: Theme.Space.s) {
                    Circle()
                        .fill(Self.statusTint(run.status))
                        .frame(width: 7, height: 7)
                    Text(run.name)
                        .font(Theme.font(13, weight: .medium))
                        .lineLimit(1)
                }
            }
            .width(min: 140, ideal: 210)
            TableColumn(L10n.text("apple.automationsview.agent.11b39c93")) { run in
                HStack(spacing: 6) {
                    HarnessMark(id: run.backend, size: 16)
                    cell(backendLabel(run.backend))
                }
            }
            .width(min: 90, ideal: 130)
            TableColumn(L10n.text("apple.automationsview.project.98595978")) { run in
                cell(folderLabel(run.workspaceID))
            }
            .width(min: 80, ideal: 120)
            TableColumn(L10n.text("apple.automationsview.started.ecbc89cd"), value: \.startedAtMs) { run in
                cell(run.startedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 110, ideal: 150)
            TableColumn(L10n.text("apple.automationsview.duration.4fc52a3c")) { run in
                cell(durationLabel(run))
            }
            .width(min: 70, ideal: 90)
            TableColumn(L10n.text("apple.automationsview.result.6e7d50e8"), value: \.status) { run in
                StatusPill(status: run.status, text: run.endedLabel)
            }
            .width(min: 80, ideal: 100)
        }
        .quietTableStyle()
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            if let run = ids.first.flatMap({ id in model.runs.first { $0.id == id } }), run.isRunning {
                Button(L10n.text("common.stop"), .stop) { Task { await model.stop(run) } }
            }
        }
    }

    private var runSelection: Binding<String?> {
        Binding(
            get: { model.selectedRunID },
            set: { id in
                if let id, let run = model.runs.first(where: { $0.id == id }) { model.selectRun(run) }
            }
        )
    }

    private func durationLabel(_ run: RunRecord) -> String {
        guard run.endedAtMs != nil else { return run.isRunning ? L10n.text("common.running") : "" }
        let total = Int(seconds(of: run).rounded())
        if total < 60 { return L10n.text("apple.automationsview.0_s.c4c041f8", "\(total)") }
        if total < 3600 { return L10n.text("apple.automationsview.0_m_1_s.661f2349", "\(total / 60)", "\(total % 60)") }
        return L10n.text("apple.automationsview.0_h_1_m.d426ce3b", "\(total / 3600)", "\((total % 3600) / 60)")
    }

    // MARK: - Data

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func jobs(matching option: JobFilter) -> [Automation] {
        switch option {
        case .all: return model.scoped
        case .enabled: return model.scoped.filter(\.enabled)
        case .paused: return model.scoped.filter { !$0.enabled }
        case .failing:
            return model.scoped.filter { job in
                model.lastRun(for: job)?.status == "error"
            }
        }
    }

    private var visibleJobs: [Automation] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = jobs(matching: filter)
        let found = query.isEmpty ? cut : cut.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.prompt.localizedCaseInsensitiveContains(query)
                || backendLabel($0.backend).localizedCaseInsensitiveContains(query)
                || folderLabel($0.workspaceID).localizedCaseInsensitiveContains(query)
        }
        return found.sorted(using: jobOrder)
    }

    private var visibleRuns: [RunRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = query.isEmpty ? model.scopedRuns : model.scopedRuns.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || backendLabel($0.backend).localizedCaseInsensitiveContains(query)
                || folderLabel($0.workspaceID).localizedCaseInsensitiveContains(query)
        }
        return found.sorted(using: runOrder)
    }

    private func job(withID id: String) -> Automation? {
        model.scoped.first { $0.id == id }
    }

    private func backendLabel(_ id: String) -> String {
        model.backends.first { $0.id == id }?.label ?? id
    }

    private func folderLabel(_ id: String) -> String {
        guard let folder = folders.first(where: { $0.id == id }) else { return L10n.text("common.unknown") }
        return folder.isRemote ? "\(folder.machineLabel ?? L10n.text("apple.automationsview.remote.ffa98e02")) / \(folder.name)" : folder.name
    }

    /// The folder this board is scoped to, named on the chrome bar.
    private var scopeChip: ScopeChip? {
        guard let id = model.scope else { return nil }
        guard let folder = folders.first(where: { $0.id == id }) else { return nil }
        return ScopeChip(
            label: folder.isRemote
                ? "\(folder.machineLabel ?? L10n.text("apple.automationsview.remote.ffa98e02")) / \(folder.name)"
                : folder.name,
            symbol: folder.isRemote ? "network" : "folder.fill"
        )
    }

    /// Waiting on the first read of the daemon's job list.
    private var isWarming: Bool {
        !model.hasLoaded && model.errorMessage == nil
    }

    private var schedulerCard: some View {
        Card(
            title: L10n.text("apple.automationsview.scheduler.d3a27d96"),
            subtitle: L10n.text("apple.automationsview.how_queued_jobs_run_on_this_mac.917fd2c7"),
            mark: "mark_scheduler"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text(L10n.text("apple.automationsview.time_limit.e592a9ca"))
                        .font(Theme.callout)
                    Spacer()
                    TextField("180", text: $model.queueBudgetMinutes)
                        .textFieldStyle(.themed)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .disabled(model.queueNoLimit)
                        .onChange(of: model.queueBudgetMinutes) { _, _ in
                            schedulerJustSaved = false
                        }
                    Text(L10n.text("apple.automationsview.minutes.90e63d85"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                TimeLimitChips(
                    minutesText: $model.queueBudgetMinutes,
                    noLimit: $model.queueNoLimit,
                    onChange: { schedulerJustSaved = false }
                )
                HStack {
                    Text(L10n.text("apple.automationsview.max_concurrent_jobs.86a5921e"))
                        .font(Theme.callout)
                    Spacer()
                    // Places at the table, filled by what is running now, so
                    // "the next job waits" is visible rather than inferred.
                    SlotGauge(
                        filled: runningCount,
                        total: Int(model.queueMaxConcurrent) ?? 0,
                        uncapped: (Int(model.queueMaxConcurrent) ?? 0) == 0
                    )
                    TextField("2", text: $model.queueMaxConcurrent)
                        .textFieldStyle(.themed)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: model.queueMaxConcurrent) { _, _ in
                            schedulerJustSaved = false
                        }
                }
                Text(L10n.text("apple.automationsview.new_jobs_inherit_the_time_limit_0_concurre.54dc3738"))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: Theme.Space.s) {
                    if model.queueDirty {
                        Text(L10n.text("apple.automationsview.unsaved.6250d572"))
                            .font(Theme.caption.weight(.medium))
                            .foregroundStyle(Theme.warning)
                    } else if schedulerJustSaved {
                        Label(L10n.text("apple.automationsview.saved.b5c120b3"), systemImage: "checkmark")
                            .font(Theme.caption.weight(.medium))
                            .foregroundStyle(Theme.success)
                    }
                    Spacer()
                    if model.queueDirty {
                        Button(schedulerSaving ? L10n.text("apple.automationsview.saving.096b7362") : L10n.text("apple.automationsview.save_scheduler.24ffd545"), .save) {
                            schedulerSaving = true
                            Task {
                                await model.saveQueue()
                                schedulerSaving = false
                                schedulerJustSaved = model.errorMessage == nil && !model.queueDirty
                            }
                        }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(schedulerSaving)
                    } else {
                        Button(L10n.text("apple.automationsview.save_scheduler.24ffd545"), .save) {}
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(true)
                    }
                }
            }
        }
    }

    /// Jobs occupying a slot right now. Queued ones are waiting for one, so
    /// they are not counted as filling it.
    private var runningCount: Int {
        model.runs.filter { $0.status == "running" }.count
    }

    private static let suggestedTemplates = AutomationTemplate.suggested

    // MARK: - Nothing set up yet

    /// The first thing somebody sees, and the only chance to say what this
    /// screen is for. An automation is not a familiar object, so the empty
    /// state describes the thing rather than announcing its absence, and the
    /// ready-made jobs sit right under it.
    private var nothingYet: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            EmptyState(
                symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                title: L10n.text("apple.automationsview.nothing_scheduled_yet.0fee713f"),
                message: L10n.text("apple.automationsview.an_automation_is_a_prompt_a_folder_and_a_t.8d7bb063")
            ) {
                if folders.isEmpty {
                    Text(L10n.text("apple.automationsview.add_a_folder_on_the_projects_screen_first.8be8d447"))
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Button(L10n.text("apple.automationsview.new_automation.db87a63d"), .create) { creating = true }
                        .buttonStyle(AccentButtonStyle())
                }
            }
            if !folders.isEmpty {
                Text(L10n.text("apple.automationsview.or_start_from_one_of_these.cd7237a8"))
                    .font(Theme.sectionHeader)
                    .foregroundStyle(.tertiary)
                templatesGrid
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private var templatesGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220), spacing: Theme.Space.s)],
            spacing: Theme.Space.s
        ) {
            ForEach(Self.suggestedTemplates) { suggestion in
                Button {
                    template = suggestion
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: suggestion.symbol)
                            .font(Theme.font(16, weight: .medium))
                            .foregroundStyle(Theme.accent)
                        Text(suggestion.title)
                            .font(Theme.font(13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(suggestion.subtitle)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Seconds a run took, or has taken so far.
    private func seconds(of run: RunRecord) -> Double {
        guard let ended = run.endedAtMs else { return 0 }
        return max(0, Double(ended - run.startedAtMs) / 1000)
    }

    static func statusTint(_ status: String) -> Color {
        RunOutcome.tint(status)
    }
}

extension View {
    /// Plain rows on the Mac: no zebra stripes, which on a dark surface read
    /// as a second grid laid over the first. Other platforms keep their own.
    @ViewBuilder
    func quietTableStyle() -> some View {
        #if os(macOS)
        tableStyle(.inset(alternatesRowBackgrounds: false))
        #else
        tableStyle(.automatic)
        #endif
    }
}

/// Sort keys for the job table. A job that never fires sorts after every
/// dated one, and a job that never ran before every one that has.
extension Automation {
    var nextRunOrder: Int64 { enabled ? (nextRunAtMs ?? .max) : .max }
    var lastRunOrder: Int64 { lastRunAtMs ?? 0 }
}

/// The outcome of a run, in the one shape it takes everywhere on this screen.
struct StatusPill: View {
    var status: String
    var text: String

    var body: some View {
        Text(text)
            .font(Theme.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AutomationsView.statusTint(status).opacity(0.15), in: Capsule())
            .foregroundStyle(AutomationsView.statusTint(status))
    }
}

private struct AutomationHistorySheet: View {
    let job: Automation
    @Bindable var model: AutomationsModel
    var onView: (RunRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ThemedSheet(
            title: job.name,
            subtitle: L10n.text("apple.automationsview.run_history.addf321b"),
            icon: .history,
            scrolls: true,
            onClose: { dismiss() }
        ) {
            if model.runs(of: job).isEmpty {
                EmptyState(
                    symbol: "clock",
                    title: L10n.text("apple.automationsview.no_runs_yet.306b45db"),
                    message: L10n.text("apple.automationsview.the_first_run_will_appear_here_with_its_re.0f89a5fa")
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(model.runs(of: job)) { run in
                        HStack(spacing: Theme.Space.s) {
                            Circle().fill(AutomationsView.statusTint(run.status)).frame(width: 8, height: 8)
                            Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(Theme.callout)
                            Spacer()
                            StatusPill(status: run.status, text: run.endedLabel)
                            Button(L10n.text("apple.automationsview.view.dcc839a4"), .preview) {
                                onView(run)
                                dismiss()
                            }
                            .buttonStyle(SecondaryButtonStyle(small: true))
                        }
                        .padding(.vertical, Theme.Space.s)
                        ThemeRule()
                    }
                }
            }
        } actions: {
            Spacer()
            Button(L10n.text("common.done"), .done) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .modalFrame(width: 560, height: 440)
    }
}

// MARK: - Creating one

/// Setting up an automation, in a sheet.
///
/// A sheet rather than a card at the bottom of the screen: this is a form with
/// six decisions in it, and standing it permanently under the list meant an
/// empty screen was mostly an empty form. It also gives Cancel somewhere to be,
/// which a permanent form never had.
struct NewAutomationSheet: View {
    @Bindable var model: AutomationsModel
    var folders: [WorkspaceFolder]
    var onNavigate: ((NavigationRequest) -> Void)?
    var existing: Automation? = nil
    /// Pre-fills the form when the sheet was opened from a suggestion.
    var template: AutomationTemplate? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var backendID = ""
    @State private var workspaceID = ""
    @State private var prompt = ""
    /// The selected backend's model alias and effort level. Empty means the
    /// backend's default, which is also what the pickers start on.
    @State private var modelChoice = ""
    @State private var effortChoice = ""
    @State private var scheduleKind: ScheduleKind = .once
    @State private var intervalMinutes = "60"
    /// Raw host interval until the picker is touched, so 90 seconds survives a
    /// round trip instead of being shown as and saved back as one minute.
    @State private var intervalSeconds: UInt64 = 0
    @State private var intervalTouched = false
    @State private var scheduleTime = Date()
    @State private var scheduleWeekday = 0
    /// Custom multi-day pick, Monday = bit 0. Defaults to Mon–Fri.
    @State private var customDays = AutomationSchedule.weekdaysMask
    /// The mask of a multi-day weekly pick, kept unless the day menu is used.
    @State private var weeklyDays = 0
    @State private var weeklyDayEdited = false
    @State private var budgetMinutes = "180"
    @State private var noTimeLimit = false
    @State private var working = false
    @State private var step = 0
    @State private var jobRevision: UInt64 = 0
    @State private var conflictJob: Automation?

    /// Monday first, and zero-based, matching `AutomationSchedule.weekday` and
    /// the daemon's `to_monday_zero_offset`. The picker used to be one-based
    /// with Sunday at zero, so choosing Monday scheduled a Tuesday.
    private let weekdays = [
        (0, L10n.text("apple.automationsview.monday.6a00dfc1")), (1, L10n.text("apple.automationsview.tuesday.7d8af1de")), (2, L10n.text("apple.automationsview.wednesday.c0a6cc82")), (3, L10n.text("apple.automationsview.thursday.fc266206")),
        (4, L10n.text("apple.automationsview.friday.e21f3f37")), (5, L10n.text("apple.automationsview.saturday.dbe35c73")), (6, L10n.text("apple.automationsview.sunday.873fef76")),
    ]
    private let dayShort = [L10n.text("apple.automationsview.mo.d23e867e"), L10n.text("apple.automationsview.tu.62afcc74"), L10n.text("apple.automationsview.we.f3fe997b"), L10n.text("apple.automationsview.th.3bff939c"), L10n.text("apple.automationsview.fr.eed8f901"), L10n.text("apple.automationsview.sa.a951efc7"), L10n.text("apple.automationsview.su.2d88a3a2")]
    private let intervalPresets = [15, 30, 60, 120, 360, 720, 1440]

    /// Presets plus the current value when it is not one of them, so editing an
    /// older "every 45 minutes" job still shows a truthful label.
    private var intervalMenuMinutes: [Int] {
        let seconds = intervalCurrentSeconds
        guard seconds % 60 == 0 else { return intervalPresets }
        let current = max(1, Int(seconds / 60))
        if intervalPresets.contains(current) { return intervalPresets }
        return (intervalPresets + [current]).sorted()
    }

    /// The interval the picker stands for: the raw host value until a preset
    /// is chosen, then whole minutes. Never traps on a huge typed number.
    private var intervalCurrentSeconds: UInt64 {
        if !intervalTouched, intervalSeconds > 0 {
            return max(intervalSeconds, 60)
        }
        let minutes = min(UInt64(intervalMinutes) ?? 60, UInt64.max / 60)
        return max(minutes * 60, 60)
    }

    private func intervalMenuLabel(_ seconds: UInt64) -> String {
        if seconds % 60 != 0 {
            return L10n.text("apple.automationsview.0_seconds.e549e94b", "\(seconds)")
        }
        return intervalPresetLabel(Int(seconds / 60))
    }

    /// What the weekly day menu shows: every masked day while a loaded
    /// multi-day pick is untouched, otherwise the single chosen day.
    private var weeklyDayLabel: String {
        if !weeklyDayEdited, weeklyDays != 0 {
            return (0..<7).compactMap { bit in
                (weeklyDays & (1 << bit)) != 0 ? weekdays[bit].1 : nil
            }.joined(separator: ", ")
        }
        return weekdays.first { $0.0 == scheduleWeekday }?.1 ?? L10n.text("apple.automationsview.day.8f2364e1")
    }

    private func weeklyDaySelected(_ day: Int) -> Bool {
        if weeklyDayEdited { return scheduleWeekday == day }
        if weeklyDays != 0 { return (weeklyDays & (1 << day)) != 0 }
        return scheduleWeekday == day
    }

    var body: some View {
        ThemedSheet(
            title: sheetTitle,
            subtitle: L10n.text("apple.automationsview.an_agent_run_headless_in_a_folder_like_a_p.b64c2cae"),
            icon: sheetIcon,
            scrolls: true,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let error = model.errorMessage, conflictJob == nil {
                    ErrorBanner(message: error) { Task { await model.load() } }
                }
                if let pending = model.unconfirmedCreate, existing == nil {
                    pendingCreateBody(pending)
                } else {
                    if let existing, model.lastRun(for: existing)?.isRunning == true {
                        Text(L10n.text("apple.automationsview.a_run_is_going_this_save_is_for_the_next_o.82358bf1"))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.controlGlyph)
                    }
                    if let conflictJob {
                        conflictBody(conflictJob)
                    }
                    stepHeader
                    fields
                        .disabled(conflictJob != nil || working)
                }
            }
        } actions: {
            Button(L10n.text("common.cancel"), .dismiss, role: .cancel) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            if model.hasUnconfirmedCreate, existing == nil {
                Spacer()
                Button(L10n.text("apple.automationsview.check_creation.61fe51e6"), .refresh) {
                    Task {
                        working = true
                        await model.checkCreate()
                        working = false
                        if !model.hasUnconfirmedCreate, model.errorMessage == nil { dismiss() }
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(working)
                Button(L10n.text("apple.automationsview.retry_creation.0bb084c1"), .create) {
                    Task {
                        working = true
                        await model.retryCreate()
                        working = false
                        if !model.hasUnconfirmedCreate, model.errorMessage == nil { dismiss() }
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(working)
            } else if conflictJob == nil {
                if step > 0 {
                    Button(L10n.text("common.back"), .back) { step -= 1 }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button {
                    if step < 2 {
                        step += 1
                    } else {
                        working = true
                        Task {
                            await save()
                            working = false
                            if model.errorMessage == nil, conflictJob == nil { dismiss() }
                        }
                    }
                } label: {
                    let icon: ActionIcon = step < 2 ? .next : (existing == nil ? .create : .save)
                    let title = step < 2 ? L10n.text("apple.automationsview.continue.31fbef16") : (existing == nil ? L10n.text("apple.automationsview.create.4759498a") : L10n.text("common.save"))
                    icon.label(title)
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue || working)
            } else if let conflictJob {
                Spacer()
                Button(L10n.text("apple.automationsview.use_computer_version.f0d6599f"), .restore) {
                    apply(conflictJob)
                    self.conflictJob = nil
                    model.errorMessage = nil
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(working)
                Button(L10n.text("apple.automationsview.keep_my_draft.cdb80bb9"), .edit) {
                    jobRevision = conflictJob.revision
                    self.conflictJob = nil
                    model.errorMessage = nil
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(working)
            }
        }
        .modalFrame(width: 560, height: 640)
        .onAppear {
            if let existing, name.isEmpty {
                apply(existing)
            }
            if let template {
                name = template.name
                prompt = template.prompt
                applySchedule(template.schedule)
                applyBudget(template.budgetSeconds)
                if model.backends.contains(where: { $0.id == template.backendID }) {
                    backendID = template.backendID
                }
            }
            if backendID.isEmpty, let agent = model.defaultBackend(keeping: existing?.backend) {
                backendID = agent.id
            }
            if workspaceID.isEmpty {
                workspaceID = model.scope ?? folders.first?.id ?? ""
            }
            if existing == nil && template == nil {
                applyBudget(
                    model.queueNoLimit
                        ? 0
                        : min(UInt64(model.queueBudgetMinutes) ?? 180, UInt64.max / 60) * 60
                )
            }
        }
        .onChange(of: backendID) { old, new in
            // Opening the editor sets backendID from the existing job.
            // That is not a change of agent, and must not wipe the model
            // the job already had. Only a later pick resets the pair.
            guard !old.isEmpty, old != new else { return }
            modelChoice = ""
            effortChoice = ""
        }
    }

    private var sheetTitle: String {
        if existing == nil, model.hasUnconfirmedCreate { return L10n.text("apple.automationsview.check_creation.61fe51e6") }
        return existing == nil ? L10n.text("apple.automationsview.new_automation.db87a63d") : L10n.text("apple.automationsview.edit_automation.b16f31c1")
    }

    private var sheetIcon: ActionIcon {
        if existing == nil, model.hasUnconfirmedCreate { return .refresh }
        return .scheduled
    }

    private func pendingCreateBody(_ job: Automation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.automationsview.a_new_job_was_sent_and_is_not_confirmed_ye.e2fd3d45"))
                .font(Theme.callout.weight(.semibold))
            Text(job.name)
                .font(Theme.callout)
            Text(model.scheduleSummary(job.schedule))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
            Text(L10n.text("apple.automationsview.check_creation_before_making_another_retry.ac4fe226"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    private func conflictBody(_ job: Automation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(L10n.text("apple.automationsview.changed_on_the_computer.aefb92cf"))
                    .font(Theme.callout.weight(.semibold))
                Text(job.name).font(Theme.callout)
                Text(job.prompt).font(Theme.callout).textSelection(.enabled)
                Text("\(model.scheduleSummary(job.schedule)) · \(job.backend)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
            Text(L10n.text("apple.automationsview.this_job_changed_since_you_opened_it_compa.ae02b985"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
    }

    private func apply(_ job: Automation) {
        name = job.name
        backendID = job.backend
        workspaceID = job.workspaceID
        prompt = job.prompt
        modelChoice = TodoCard.cleanModelID(job.model ?? "")
        effortChoice = job.effort ?? ""
        applySchedule(job.schedule)
        applyBudget(job.budgetSeconds)
        jobRevision = job.revision
    }

    private var stepHeader: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Theme.accent : Theme.border)
                    .frame(height: 4)
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            switch step {
            case 0:
                TextField(L10n.text("apple.automationsview.name.dcd1d522"), text: $name, prompt: Text(L10n.text("apple.automationsview.e_g_nightly_docs_check.138c63aa")))
                promptEditor
            case 1:
                if !Bridge.isHosted {
                    setupHint(L10n.text("apple.automationsview.background_helper_is_not_running_set_it_up.2b501242"), action: L10n.text("apple.automationsview.open_devices.39961a55")) {
                        dismiss()
                        onNavigate?(.global(.machines))
                    }
                } else if model.backends.isEmpty {
                    setupHint(L10n.text("apple.automationsview.no_supported_agent_cli_is_installed_yet_in.e39f6dc7"), action: L10n.text("apple.automationsview.refresh_agents.381e4a82")) {
                        Task { await model.load() }
                    }
                } else if model.pickerBackends(keeping: backendID).isEmpty {
                    setupHint(L10n.text("apple.automationsview.every_installed_agent_is_hidden_on_project.d9f3e2ec"), action: L10n.text("apple.automationsview.go_to_projects.cad12684")) {
                        dismiss()
                        onNavigate?(.launcher)
                    }
                } else if folders.isEmpty {
                    setupHint(L10n.text("apple.automationsview.add_a_project_before_choosing_where_this_t.28418f03"), action: L10n.text("apple.automationsview.go_to_projects.cad12684")) {
                        dismiss()
                        onNavigate?(.workspaces)
                    }
                }
                AppMenuPicker(
                    title: L10n.text("apple.automationsview.agent.11b39c93"),
                    options: model.pickerBackends(keeping: existing?.backend ?? backendID).map { (value: $0.id, label: $0.label) },
                    selection: $backendID
                )
                AppMenuPicker(
                    title: L10n.text("apple.automationsview.project.98595978"),
                    options: [(value: "", label: L10n.text("apple.automationsview.choose_a_project.8ba607b1"))]
                        + folders.map { (value: $0.id, label: $0.name) },
                    selection: $workspaceID
                )
                if let backend = model.backends.first(where: { $0.id == backendID }),
                   !backend.models.isEmpty || !backend.efforts.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        if !backend.models.isEmpty {
                            FavoriteModelPicker(
                                backendID: backend.id,
                                models: backend.models,
                                extra: modelChoice,
                                selection: $modelChoice
                            )
                        }
                        if !backend.efforts.isEmpty {
                            AppMenuPicker(
                                title: L10n.text("apple.automationsview.effort.4387e5d3"),
                                options: [(value: "", label: L10n.text("apple.automationsview.default.21b111cb"))]
                                    + backend.efforts.map { (value: $0, label: $0) },
                                selection: $effortChoice
                            )
                        }
                    }
                }
                Text(L10n.text("apple.automationsview.the_agent_runs_on_this_device_in_the_selec.c02bc47c"))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            default:
                scheduleControls
                HStack(spacing: 4) {
                    Text(L10n.text("apple.automationsview.time_limit.e592a9ca"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                    TextField("180", text: $budgetMinutes)
                        .frame(width: 56)
                        .disabled(noTimeLimit)
                    Text(L10n.text("apple.automationsview.minutes.90e63d85"))
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                    BrandToggleChip(title: L10n.text("apple.automationsview.no_limit.f7fcff0d"), isOn: $noTimeLimit)
                }
            }
        }
        .textFieldStyle(.themed)
        .controlSize(.small)
    }

    private func setupHint(_ message: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                // `.link` is AppKit's. Plain plus the accent reads the same
                // and is the nearest thing iOS has.
                #if os(macOS)
                Button(action, action: perform)
                    .buttonStyle(.link)
                    .font(Theme.caption)
                #else
                Button(action, action: perform)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .font(Theme.caption)
                #endif
            }
        }
        .padding(Theme.Space.s)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    private var promptEditor: some View {
        TextEditor(text: $prompt)
            .font(Theme.mono(12))
            .frame(minHeight: 90)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text(L10n.text("apple.automationsview.what_the_agent_should_do_sent_as_the_promp.aab6a4cf"))
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 10)
                        .padding(.leading, 10)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Frequency block shaped like the familiar local-scheduler form: one
    /// Repeat row, then the fields that kind needs (Every / On / At).
    @ViewBuilder
    private var scheduleControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("apple.automationsview.frequency.16b6668d"))
                .font(Theme.sectionHeader)
                .foregroundStyle(.tertiary)
                .padding(.bottom, Theme.Space.xs)

            VStack(spacing: 0) {
                frequencyRow(L10n.text("apple.automationsview.repeat.b6b7a006")) {
                    Menu {
                        ForEach(ScheduleKind.allCases, id: \.self) { kind in
                            Button {
                                scheduleKind = kind
                            } label: {
                                if scheduleKind == kind {
                                    Label(kind.label, systemImage: "checkmark")
                                } else {
                                    Text(kind.label)
                                }
                            }
                        }
                    } label: {
                        frequencyMenuLabel(scheduleKind.label)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }

                if scheduleKind == .interval {
                    ThemeRule()
                    frequencyRow(L10n.text("apple.automationsview.every.9b8617fd")) {
                        Menu {
                            ForEach(intervalMenuMinutes, id: \.self) { minutes in
                                Button {
                                    intervalMinutes = String(minutes)
                                    intervalTouched = true
                                } label: {
                                    if intervalCurrentSeconds == UInt64(minutes) * 60 {
                                        Label(intervalPresetLabel(minutes), systemImage: "checkmark")
                                    } else {
                                        Text(intervalPresetLabel(minutes))
                                    }
                                }
                            }
                        } label: {
                            frequencyMenuLabel(intervalMenuLabel(intervalCurrentSeconds))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                    }
                }

                if scheduleKind == .weekly {
                    ThemeRule()
                    frequencyRow(L10n.text("apple.automationsview.on.13001175")) {
                        Menu {
                            ForEach(weekdays, id: \.0) { day in
                                Button {
                                    scheduleWeekday = day.0
                                    weeklyDayEdited = true
                                } label: {
                                    if weeklyDaySelected(day.0) {
                                        Label(day.1, systemImage: "checkmark")
                                    } else {
                                        Text(day.1)
                                    }
                                }
                            }
                        } label: {
                            frequencyMenuLabel(weeklyDayLabel)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                    }
                }

                if scheduleKind == .custom {
                    ThemeRule()
                    frequencyRow(L10n.text("apple.automationsview.on.13001175")) {
                        HStack(spacing: 4) {
                            ForEach(0..<7, id: \.self) { bit in
                                let on = (customDays & (1 << bit)) != 0
                                Button {
                                    if on {
                                        customDays &= ~(1 << bit)
                                    } else {
                                        customDays |= (1 << bit)
                                    }
                                } label: {
                                    Text(dayShort[bit])
                                        .font(Theme.caption2.weight(.medium))
                                        .frame(width: 28, height: 24)
                                        .background(
                                            on ? Theme.accent.opacity(0.2) : Theme.background,
                                            in: RoundedRectangle(cornerRadius: 6)
                                        )
                                        .foregroundStyle(on ? Theme.accent : .secondary)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(on ? Theme.accent.opacity(0.5) : Theme.border)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(weekdays[bit].1)
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }
                }

                if scheduleKind == .daily
                    || scheduleKind == .weekdays
                    || scheduleKind == .weekly
                    || scheduleKind == .custom {
                    ThemeRule()
                    frequencyRow(L10n.text("apple.automationsview.at.c72c5404")) {
                        DatePicker(L10n.text("apple.automationsview.time.33b93476"), selection: $scheduleTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }

                if scheduleKind == .once {
                    ThemeRule()
                    Text(L10n.text("apple.automationsview.runs_only_when_you_press_run_now_nothing_i.d8d3b24d"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Space.s)
                        .padding(.horizontal, Theme.Space.s)
                }
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
        }
    }

    private func frequencyRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(Theme.callout)
                .foregroundStyle(.primary)
            Spacer(minLength: Theme.Space.s)
            content()
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 10)
    }

    private func frequencyMenuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(Theme.callout)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(Theme.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }

    private func intervalPresetLabel(_ minutes: Int) -> String {
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? L10n.text("apple.automationsview.1_hour.f8b8883f") : L10n.text("apple.automationsview.0_hours.4d0aa096", "\(hours)")
        }
        return minutes == 1 ? L10n.text("apple.automationsview.1_minute.e67b6f61") : L10n.text("apple.automationsview.0_minutes.87086105", "\(minutes)")
    }

    private func applySchedule(_ schedule: AutomationSchedule) {
        scheduleKind = schedule.kind
        intervalTouched = false
        intervalSeconds = schedule.kind == .interval ? schedule.everySeconds : 0
        intervalMinutes = String(max(1, schedule.everySeconds / 60))
        scheduleTime = Calendar.current.date(
            bySettingHour: schedule.hour,
            minute: schedule.minute,
            second: 0,
            of: Date()
        ) ?? Date()
        scheduleWeekday = schedule.weekday
        weeklyDayEdited = false
        weeklyDays = schedule.kind == .weekly ? schedule.weekdays & 0b0111_1111 : 0
        if schedule.weekdays != 0 {
            customDays = schedule.weekdays
        } else if schedule.kind == .custom || schedule.kind == .weekdays {
            customDays = AutomationSchedule.weekdaysMask
        } else if schedule.kind == .weekly, schedule.weekday >= 0, schedule.weekday <= 6 {
            customDays = 1 << schedule.weekday
        }
    }

    private func builtSchedule() -> AutomationSchedule {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: scheduleTime)
        let hour = comps.hour ?? 9
        let minute = comps.minute ?? 0
        switch scheduleKind {
        case .once:
            return AutomationSchedule(kind: .once)
        case .interval:
            return AutomationSchedule(kind: .interval, everySeconds: intervalCurrentSeconds)
        case .daily:
            return AutomationSchedule(kind: .daily, hour: hour, minute: minute)
        case .weekdays:
            return AutomationSchedule(
                kind: .weekdays, hour: hour, minute: minute,
                weekdays: AutomationSchedule.weekdaysMask
            )
        case .weekly:
            // A loaded multi-day weekly keeps its mask until the day menu is
            // used; writing `weekdays: 0` here collapsed Mon/Wed to Monday.
            return AutomationSchedule(
                kind: .weekly, hour: hour, minute: minute, weekday: scheduleWeekday,
                weekdays: weeklyDayEdited ? 0 : weeklyDays
            )
        case .custom:
            // Do not invent days when none are selected. The host rejects an
            // empty custom schedule, and the form blocks Continue instead.
            return AutomationSchedule(
                kind: .custom, hour: hour, minute: minute, weekdays: customDays
            )
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespaces).isEmpty
            && !workspaceID.isEmpty
            && !backendID.isEmpty
    }

    private var canContinue: Bool {
        switch step {
        case 0:
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
                && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 1:
            return !workspaceID.isEmpty && !backendID.isEmpty
        default:
            // Custom with every day cleared is not a schedule. Block Continue
            // rather than silently rewriting the pick to weekdays.
            if scheduleKind == .custom, (customDays & 0b0111_1111) == 0 {
                return false
            }
            return canCreate
        }
    }

    private var savedBudget: UInt64 {
        if noTimeLimit { return 0 }
        let minutes = min(UInt64(budgetMinutes) ?? 180, UInt64.max / 60)
        return max(minutes, 1) * 60
    }

    private func applyBudget(_ seconds: UInt64) {
        noTimeLimit = seconds == 0
        if seconds > 0 {
            budgetMinutes = String(max(1, seconds / 60))
        }
    }

    private func save() async {
        let spec = builtSchedule()
        if let existing {
            await model.update(Automation(
                id: existing.id,
                name: name.trimmingCharacters(in: .whitespaces),
                backend: backendID,
                model: {
                    let cleaned = TodoCard.cleanModelID(modelChoice)
                    return cleaned.isEmpty ? nil : cleaned
                }(),
                effort: effortChoice.isEmpty ? nil : effortChoice,
                workspaceID: workspaceID,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                schedule: spec,
                budgetSeconds: savedBudget,
                enabled: existing.enabled,
                lastRunAtMs: existing.lastRunAtMs,
                // Host recomputes next run from the new schedule on update.
                nextRunAtMs: nil,
                lastRunID: existing.lastRunID,
                revision: jobRevision
            ))
            if AutomationsModel.isConcurrentEdit(model.errorMessage) {
                conflictJob = model.jobs.first { $0.id == existing.id }
            }
        } else {
            await model.create(
                name: name.trimmingCharacters(in: .whitespaces),
                backend: backendID,
                model: {
                    let cleaned = TodoCard.cleanModelID(modelChoice)
                    return cleaned.isEmpty ? nil : cleaned
                }(),
                effort: effortChoice.isEmpty ? nil : effortChoice,
                workspaceID: workspaceID,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                schedule: spec,
                budget: savedBudget
            )
        }
    }
}
