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
    var onNavigate: ((Destination) -> Void)? = nil
    /// A run to open on arrival, requested from Tasks. Cleared once opened.
    @Binding var pendingRunID: String?

    @State private var creating = false
    @State private var template: AutomationTemplate?
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    /// Empty means follow the default: open when there are no jobs yet.
    @AppStorage("automations.examplesExpanded") private var examplesExpandedStored = ""
    @State private var schedulerJustSaved = false
    @State private var schedulerSaving = false

    var body: some View {
        VStack(spacing: 0) {
            DetailChromeBar {
                ToolbarIconButton(
                    systemImage: "plus",
                    help: "Schedule a job"
                ) {
                    creating = true
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let error = model.errorMessage {
                        Banner(text: error, severity: .warning)
                    }
                    intro
                    schedulerCard
                    // A search box, not a rounded text field with the icon glued
                    // on top: the overlay sat on the field's leading edge and
                    // overlapped the placeholder and the first typed characters.
                    // The icon lives inside the box now, so the text can never
                    // collide with it.
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)
                        TextField("Search automations", text: $search)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($searchFocused)
                    }
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, 6)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Space.s))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Space.s)
                            .strokeBorder(
                                searchFocused ? Theme.accent.opacity(0.7) : Theme.border,
                                lineWidth: searchFocused ? 1.5 : 1
                            )
                    )
                    .padding(.leading, 4)
                    if isWarming {
                        // "Nothing yet" is an answer, and it must not be given
                        // before the question has been asked. Sharp grey job rows
                        // say the daemon is being read; real cards replace them.
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Skeleton.CardPlaceholder(rows: 2)
                            Skeleton.CardPlaceholder(rows: 2)
                        }
                        .transition(.opacity)
                    } else if filteredJobs.isEmpty {
                        nothingYet
                    } else {
                        taskSection("Active", jobs: filteredJobs.filter(\.enabled))
                        taskSection("Paused", jobs: filteredJobs.filter { !$0.enabled })
                    }
                    if !model.runs.isEmpty {
                        recentRuns
                    }
                    examples
                }
                .padding(Theme.Space.m)
            }
        }
        .navigationTitle("Automations")
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
                if let run = model.runs.first(where: { $0.id == id }) {
                    pendingRunID = nil
                    model.selectRun(run)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            pendingRunID = nil
        }
        // The model outlives this view, and the transcript tail must not.
        .onDisappear { model.disappeared() }
        .onChange(of: model.hasLoaded) { _, loaded in
            // Write the first-visit default so a later appear does not
            // recompute it from an empty in-flight list.
            guard loaded, examplesExpandedStored.isEmpty else { return }
            examplesExpandedStored = model.jobs.isEmpty ? "1" : "0"
        }
    }

    /// Waiting on the first read of the daemon's job list.
    private var isWarming: Bool {
        !model.hasLoaded && model.errorMessage == nil
    }

    private var intro: some View {
        HStack(alignment: .top) {
            FeatureMark(name: "mark_automation", tint: Theme.accent, size: 28)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Automations")
                    .font(.system(size: 24, weight: .semibold))
                Text("Schedule an agent a job, a folder, and a time. It runs in the background and stops at your limit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Schedule a job", .create) { creating = true }
            .buttonStyle(AccentButtonStyle())
        }
    }

    private var schedulerCard: some View {
        Card(
            title: "Scheduler",
            subtitle: "How queued jobs run on this Mac",
            mark: "mark_scheduler"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text("Time limit")
                        .font(.callout)
                    Spacer()
                    TextField("180", text: $model.queueBudgetMinutes)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .disabled(model.queueNoLimit)
                        .onChange(of: model.queueBudgetMinutes) { _, _ in
                            schedulerJustSaved = false
                        }
                    Text("minutes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    BrandToggleChip(title: "No limit", isOn: $model.queueNoLimit)
                        .onChange(of: model.queueNoLimit) { _, _ in
                            schedulerJustSaved = false
                        }
                }
                HStack {
                    Text("Max concurrent jobs")
                        .font(.callout)
                    Spacer()
                    TextField("2", text: $model.queueMaxConcurrent)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: model.queueMaxConcurrent) { _, _ in
                            schedulerJustSaved = false
                        }
                }
                Text("New jobs inherit the time limit. 0 concurrent means no cap. Extra jobs wait in the queue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: Theme.Space.s) {
                    if model.queueDirty {
                        Text("Unsaved")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.warning)
                    } else if schedulerJustSaved {
                        Label("Saved", systemImage: "checkmark")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.success)
                    }
                    Spacer()
                    if model.queueDirty {
                        Button(schedulerSaving ? "Saving" : "Save scheduler", .save) {
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
                        Button("Save scheduler", .save) {}
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(true)
                    }
                }
            }
        }
    }

    /// Suggested setups sit under the user's own jobs. Open by default only
    /// when the list is empty, so first visit still teaches the screen.
    ///
    /// The stored value is the last tap. Until that exists, wait for the
    /// jobs list to load: treating an unloaded list as empty flashed the
    /// section open and forgot a collapse on the next appear.
    private var examplesExpanded: Bool {
        switch examplesExpandedStored {
        case "1": return true
        case "0": return false
        default: return model.hasLoaded && model.jobs.isEmpty
        }
    }

    /// Ready-made jobs, collapsed the same way Devices hides its keys.
    private var examples: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    examplesExpandedStored = examplesExpanded ? "0" : "1"
                }
            } label: {
                HStack(alignment: .center, spacing: Theme.Space.s) {
                    FeatureMark(name: "mark_examples", tint: Theme.accent, size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Examples")
                            .font(.system(size: DisplayFit.dp(13), weight: .semibold))
                        Text(examplesExpanded
                            ? "Create one, then press Run now"
                            : "Ready-made jobs you can create and run yourself")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Theme.Space.s)
                    Image(systemName: examplesExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(examplesExpanded
                ? "Hides the example jobs"
                : "Shows the example jobs")

            if examplesExpanded {
                templatesGrid
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private var templatesGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: Theme.Space.s), GridItem(.flexible(), spacing: Theme.Space.s)],
            spacing: Theme.Space.s
        ) {
            ForEach(Self.suggestedTemplates) { suggestion in
                Button {
                    template = suggestion
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: suggestion.symbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.accent)
                        Text(suggestion.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(suggestion.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
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

    private static let suggestedTemplates: [AutomationTemplate] = [
        AutomationTemplate(
            title: "Daily brief",
            subtitle: "Every morning at 8:00",
            symbol: "sunrise",
            name: "Daily brief",
            prompt: "Summarise yesterday's usage and flag anything that needs attention.",
            backendID: "claude",
            schedule: AutomationSchedule(kind: .daily, everySeconds: 0, hour: 8, minute: 0, weekday: 0),
            budgetSeconds: 600
        ),
        AutomationTemplate(
            title: "System health check",
            subtitle: "Every hour",
            symbol: "heart.text.square",
            name: "System health check",
            prompt: "Check disk, memory and CPU, and confirm the tokenstat daemon is running. Report anything abnormal.",
            backendID: "sh",
            schedule: AutomationSchedule(kind: .interval, everySeconds: 3600, hour: 0, minute: 0, weekday: 0),
            budgetSeconds: 120
        ),
        AutomationTemplate(
            title: "Dependency check",
            subtitle: "Every week",
            symbol: "shippingbox",
            name: "Dependency check",
            prompt: "Check for outdated or vulnerable dependencies (npm audit and the package managers this project uses) and summarise what needs a bump.",
            backendID: "sh",
            schedule: AutomationSchedule(kind: .weekly, hour: 9, minute: 0, weekday: 0),
            budgetSeconds: 900
        ),
        AutomationTemplate(
            title: "Weekday standup",
            subtitle: "Weekdays at 9:00",
            symbol: "person.3",
            name: "Weekday standup",
            prompt: "Summarise open work and anything that blocked progress yesterday. Keep it short.",
            backendID: "claude",
            schedule: AutomationSchedule(
                kind: .weekdays, hour: 9, minute: 0,
                weekdays: AutomationSchedule.weekdaysMask
            ),
            budgetSeconds: 600
        ),
        AutomationTemplate(
            title: "Release",
            subtitle: "Once, when you run it",
            symbol: "tag",
            name: "Release",
            prompt: AutomationsModel.releasePrompt(),
            backendID: "claude",
            schedule: AutomationSchedule(kind: .once),
            budgetSeconds: 1800
        ),
    ]

    private var filteredJobs: [Automation] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.jobs }
        return model.jobs.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.prompt.localizedCaseInsensitiveContains(query)
                || $0.backend.localizedCaseInsensitiveContains(query)
        }
    }

    private func taskSection(_ title: String, jobs: [Automation]) -> AnyView {
        guard !jobs.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(Theme.sectionHeader)
                .foregroundStyle(.tertiary)
                .padding(.bottom, Theme.Space.xs)
            VStack(spacing: 0) {
                ForEach(jobs) { job in
                    AutomationRow(job: job, model: model,
                                  folders: folders,
                                  folder: folders.first { $0.id == job.workspaceID },
                                  isSelected: model.selectedJobID == job.id,
                                  onSelect: { model.selectJob(job.id) },
                                  onViewRun: { model.selectRun($0) })
                    if job.id != jobs.last?.id { Divider() }
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
        })
    }

    private var recentRuns: some View {
        Card(
            title: "Recent runs",
            subtitle: "The latest result from each scheduled job.",
            mark: "mark_automation"
        ) {
            VStack(spacing: 0) {
                ForEach(Array(model.runs.prefix(5))) { run in
                    runRow(run)
                    if run.id != model.runs.prefix(5).last?.id { Divider() }
                }
            }
        }
    }

    // MARK: - Nothing set up yet

    /// The first thing somebody sees, and the only chance to say what this
    /// screen is for. An automation is not a familiar object, so the empty
    /// state describes the thing rather than announcing its absence.
    private var nothingYet: some View {
        Card(title: "Automations", subtitle: nil, mark: "mark_automation") {
            EmptyState(
                symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                title: "Nothing scheduled yet",
                message: """
                Schedule an agent a job: a prompt, a folder and a time. \
                The host helper runs it, and stops it at your time limit. \
                On a laptop that helper stops when you quit tokenstat unless Always-on host is on.
                """
            ) {
                if folders.isEmpty {
                    Text("Add a folder on the Workspaces screen first. An agent runs somewhere.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Button("Schedule a job", .create) { creating = true }
                    .buttonStyle(AccentButtonStyle())
                }
            }
        }
    }

    // MARK: - The automations

    private var automationsCard: some View {
        Card(
            title: "Automations",
            subtitle: "Owned by the host helper. They run after you quit only if Always-on host is on.",
            mark: "mark_automation",
            accessory: AnyView(
                Button("New", .create) { creating = true }
                .buttonStyle(AccentButtonStyle(small: true))
            )
        ) {
            VStack(spacing: Theme.Space.s) {
                if model.jobs.isEmpty {
                    Text("""
                    Every automation has been deleted. The runs below are what \
                    they left behind.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(model.jobs) { job in
                        AutomationRow(
                            job: job,
                            model: model,
                            folders: folders,
                            folder: folders.first { $0.id == job.workspaceID },
                            isSelected: model.selectedJobID == job.id,
                            onSelect: { model.selectJob(job.id) },
                            onViewRun: { model.selectRun($0) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Runs

    private var runsCard: some View {
        Card(
            title: "Runs",
            subtitle: "Select a run to read its output in the inspector.",
            mark: "mark_automation"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if model.runs.isEmpty {
                    EmptyState(
                        symbol: "text.append",
                        title: "Nothing has run yet",
                        message: """
                        A run appears here the moment an automation fires, or as \
                        soon as you press Run now on one.
                        """
                    )
                } else {
                    ForEach(Array(model.runs.prefix(6))) { run in
                        runRow(run)
                    }
                }
            }
        }
    }

    private func runRow(_ run: RunRecord) -> some View {
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(Self.statusTint(run.status))
                .frame(width: 8, height: 8)
            Text(run.name)
                .font(.callout.weight(.medium))
            Text(model.backends.first { $0.id == run.backend }?.label ?? run.backend)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(run.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
            StatusPill(status: run.status, text: run.endedLabel)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .background(model.selectedRunID == run.id ? Theme.accentSoft : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Space.xs))
        .contentShape(.rect)
        .onTapGesture {
            model.selectRun(run)
        }
    }



    static func statusTint(_ status: String) -> Color {
        switch status {
        case "running": return Theme.accent
        case "ok": return Theme.success
        case "stopped": return Theme.warning
        case "error": return Theme.danger
        case "interrupted": return Theme.warning
        default: return .secondary
        }
    }
}

// MARK: - One automation

/// A row that answers the two questions somebody has about a job: when does it
/// run, and how did it go last time.
///
/// Both used to be somewhere else. The schedule was a caption and the result
/// was in the run list, so checking a nightly job meant reading a history and
/// working out which entry belonged to it.
private struct AutomationRow: View {
    var job: Automation
    @Bindable var model: AutomationsModel
    var folders: [WorkspaceFolder]
    var folder: WorkspaceFolder?
    var isSelected: Bool = false
    var onSelect: () -> Void = {}
    /// Opens the selected run in the inspector.
    var onViewRun: (RunRecord) -> Void

    @State private var confirmingDelete = false
    @State private var showingHistory = false
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            header
            Text(job.prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                // Reserved space keeps every row the same height whatever the
                // prompt length, the same matched-rows rule the cards use.
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            facts
        }
        .padding(.vertical, Theme.Space.s)
        .padding(.horizontal, Theme.Space.xs)
        .background(isSelected ? Theme.rowSelected : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Space.s))
        .contentShape(.rect)
        .onTapGesture { onSelect() }
        .opacity(job.enabled ? 1 : 0.6)
        .confirmationDialog(
            "Delete \(job.name)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await model.remove(job) } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The schedule goes with it. Runs it already produced stay.")
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            FeatureMark(name: "mark_automation", tint: Theme.accent, size: 16)
            Text(job.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(model.backends.first { $0.id == job.backend }?.label ?? job.backend)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.accent.opacity(0.12), in: Capsule())
                .foregroundStyle(Theme.accent)
            if let last = model.lastRun(for: job) {
                StatusPill(status: last.status, text: last.endedLabel)
            }
            Spacer()
            BrandToggleChip(
                title: job.enabled ? "On" : "Off",
                isOn: Binding(
                    get: { job.enabled },
                    set: { _ in Task { await model.toggle(job) } }
                )
            )
            .accessibilityLabel("Enabled")
            .help(job.enabled ? "Running on its schedule" : "Paused. It will not fire.")
        }
    }

    /// When it runs, where it runs, and how it went. One line, because these
    /// three facts are read together or not at all.
    private var facts: some View {
        HStack(spacing: Theme.Space.m) {
            Label(model.scheduleSummary(job.schedule), systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if job.enabled, let next = job.nextRun {
                Text("Next \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if let last = model.lastRun(for: job) {
                // The time is the useful half. The outcome is already a pill up
                // in the header, so repeating the word here would say it twice.
                Text("Last ran \(last.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text("Never run")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if let folder {
                Label(folder.name, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if let last = model.lastRun(for: job), last.isRunning {
                Button("Stop", .stop) { Task { await model.stop(last) } }
                    .buttonStyle(AccentButtonStyle(small: true))
                    .help("Kill this run now")
            } else {
                Button("Run now", .run) { Task { await model.run(job) } }
                    .buttonStyle(AccentButtonStyle(small: true))
            }
            Button("History", .history) { showingHistory = true }
                .buttonStyle(.borderless)
                .controlSize(.small)
            Button("Edit", .edit) { editing = true }
                .buttonStyle(.borderless)
                .controlSize(.small)
            Button(role: .destructive) { confirmingDelete = true } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this automation")
            .accessibilityLabel("Delete \(job.name)")
        }
        .sheet(isPresented: $showingHistory) {
            AutomationHistorySheet(job: job, model: model, onView: onViewRun)
        }
        .sheet(isPresented: $editing) {
            NewAutomationSheet(model: model, folders: folders, existing: job)
        }
    }
}

/// The outcome of a run, in the one shape it takes everywhere on this screen.
struct StatusPill: View {
    var status: String
    var text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.name).font(.title3.weight(.semibold))
                    Text("Run history").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                InspectorCloseButton(
                    action: { dismiss() },
                    help: "Close",
                    label: "Close run history"
                )
                Button("Done", .done) { dismiss() }
                    .buttonStyle(.borderless)
            }
            if model.runs(of: job).isEmpty {
                EmptyState(symbol: "clock", title: "No runs yet", message: "The first run will appear here with its result and output.")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.runs(of: job)) { run in
                            HStack(spacing: Theme.Space.s) {
                                Circle().fill(AutomationsView.statusTint(run.status)).frame(width: 8, height: 8)
                                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.callout)
                                Spacer()
                                StatusPill(status: run.status, text: run.endedLabel)
                                Button("View", .preview) {
                                    onView(run)
                                    dismiss()
                                }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.vertical, Theme.Space.s)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 520, height: 360)
    }
}

// MARK: - Creating one

/// A suggested setup on the Automations screen, pre-filling the sheet.
struct AutomationTemplate: Identifiable {
    var id: String { title }
    var title: String
    var subtitle: String
    var symbol: String
    var name: String
    var prompt: String
    var backendID: String
    var schedule: AutomationSchedule
    var budgetSeconds: UInt64
}

/// Setting up an automation, in a sheet.
///
/// A sheet rather than a card at the bottom of the screen: this is a form with
/// six decisions in it, and standing it permanently under the list meant an
/// empty screen was mostly an empty form. It also gives Cancel somewhere to be,
/// which a permanent form never had.
struct NewAutomationSheet: View {
    @Bindable var model: AutomationsModel
    var folders: [WorkspaceFolder]
    var onNavigate: ((Destination) -> Void)?
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
    @State private var scheduleTime = Date()
    @State private var scheduleWeekday = 0
    /// Custom multi-day pick, Monday = bit 0. Defaults to Mon–Fri.
    @State private var customDays = AutomationSchedule.weekdaysMask
    @State private var budgetMinutes = "180"
    @State private var noTimeLimit = false
    @State private var working = false
    @State private var step = 0

    /// Monday first, and zero-based, matching `AutomationSchedule.weekday` and
    /// the daemon's `to_monday_zero_offset`. The picker used to be one-based
    /// with Sunday at zero, so choosing Monday scheduled a Tuesday.
    private let weekdays = [
        (0, "Monday"), (1, "Tuesday"), (2, "Wednesday"), (3, "Thursday"),
        (4, "Friday"), (5, "Saturday"), (6, "Sunday"),
    ]
    private let dayShort = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
    private let intervalPresets = [15, 30, 60, 120, 360, 720, 1440]

    /// Presets plus the current value when it is not one of them, so editing an
    /// older "every 45 minutes" job still shows a truthful label.
    private var intervalMenuMinutes: [Int] {
        let current = max(1, Int(intervalMinutes) ?? 60)
        if intervalPresets.contains(current) { return intervalPresets }
        return (intervalPresets + [current]).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing == nil ? "New automation" : "Edit automation")
                        .font(.system(size: 15, weight: .semibold))
                    Text("An agent run headless in a folder, like a person launching it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                InspectorCloseButton(
                    action: { dismiss() },
                    help: "Close",
                    label: "Close"
                )
            }

            if let error = model.errorMessage {
                Banner(text: error, severity: .warning)
            }

            stepHeader
            fields

            HStack {
                Button("Cancel", .dismiss, role: .cancel) { dismiss() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 {
                    Button("Back", .back) { step -= 1 }
                        .buttonStyle(.borderless)
                }
                Button {
                    if step < 2 {
                        step += 1
                    } else {
                        working = true
                        Task {
                            await save()
                            working = false
                            if model.errorMessage == nil { dismiss() }
                        }
                    }
                } label: {
                    let icon: ActionIcon = step < 2 ? .next : (existing == nil ? .create : .save)
                    let title = step < 2 ? "Continue" : (existing == nil ? "Create" : "Save")
                    icon.label(title)
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue || working)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 520)
        .background(Theme.panel)
        .onAppear {
            if let existing, name.isEmpty {
                name = existing.name
                backendID = existing.backend
                workspaceID = existing.workspaceID
                prompt = existing.prompt
                modelChoice = TodoCard.cleanModelID(existing.model ?? "")
                effortChoice = existing.effort ?? ""
                applySchedule(existing.schedule)
                applyBudget(existing.budgetSeconds)
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
            if backendID.isEmpty, let first = model.pickerBackends(keeping: existing?.backend).first {
                backendID = first.id
            }
            if workspaceID.isEmpty, let first = folders.first {
                workspaceID = first.id
            }
            if existing == nil && template == nil {
                applyBudget(
                    model.queueNoLimit
                        ? 0
                        : (UInt64(model.queueBudgetMinutes) ?? 180) * 60
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
                TextField("Name", text: $name, prompt: Text("e.g. Nightly docs check"))
                promptEditor
            case 1:
                if !Bridge.isHosted {
                    setupHint("Background helper is not running. Set it up from Machines before scheduling this task.", action: "Open Devices") {
                        dismiss()
                        onNavigate?(.machines)
                    }
                } else if model.backends.isEmpty {
                    setupHint("No supported agent CLI is installed yet. Install one, then reload this screen.", action: "Refresh agents") {
                        Task { await model.load() }
                    }
                } else if model.pickerBackends(keeping: backendID).isEmpty {
                    setupHint("Every installed agent is hidden on Workspaces. Show one there to pick it here.", action: "Go to Workspaces") {
                        dismiss()
                        onNavigate?(.workspaces)
                    }
                } else if folders.isEmpty {
                    setupHint("Add a workspace before choosing where this task should run.", action: "Go to Workspaces") {
                        dismiss()
                        onNavigate?(.workspaces)
                    }
                }
                AppMenuPicker(
                    title: "Agent",
                    options: model.pickerBackends(keeping: existing?.backend ?? backendID).map { (value: $0.id, label: $0.label) },
                    selection: $backendID
                )
                AppMenuPicker(
                    title: "Workspace",
                    options: [(value: "", label: "Choose a workspace")]
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
                                title: "Effort",
                                options: [(value: "", label: "Default")]
                                    + backend.efforts.map { (value: $0, label: $0) },
                                selection: $effortChoice
                            )
                        }
                    }
                }
                Text("The agent runs on this device, in the selected workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                scheduleControls
                HStack(spacing: 4) {
                    Text("Time limit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("180", text: $budgetMinutes)
                        .frame(width: 56)
                        .disabled(noTimeLimit)
                    Text("minutes")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    BrandToggleChip(title: "No limit", isOn: $noTimeLimit)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
    }

    private func setupHint(_ message: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // `.link` is AppKit's. Plain plus the accent reads the same
                // and is the nearest thing iOS has.
                #if os(macOS)
                Button(action, action: perform)
                    .buttonStyle(.link)
                    .font(.caption)
                #else
                Button(action, action: perform)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .font(.caption)
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
                    Text("What the agent should do. Sent as the prompt, e.g. claude -p \"…\"")
                        .font(.caption)
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
            Text("Frequency")
                .font(Theme.sectionHeader)
                .foregroundStyle(.tertiary)
                .padding(.bottom, Theme.Space.xs)

            VStack(spacing: 0) {
                frequencyRow("Repeat") {
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
                    Divider()
                    frequencyRow("Every") {
                        Menu {
                            ForEach(intervalMenuMinutes, id: \.self) { minutes in
                                Button {
                                    intervalMinutes = String(minutes)
                                } label: {
                                    if (Int(intervalMinutes) ?? 0) == minutes {
                                        Label(intervalPresetLabel(minutes), systemImage: "checkmark")
                                    } else {
                                        Text(intervalPresetLabel(minutes))
                                    }
                                }
                            }
                        } label: {
                            frequencyMenuLabel(intervalPresetLabel(Int(intervalMinutes) ?? 60))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                    }
                }

                if scheduleKind == .weekly {
                    Divider()
                    frequencyRow("On") {
                        Menu {
                            ForEach(weekdays, id: \.0) { day in
                                Button {
                                    scheduleWeekday = day.0
                                } label: {
                                    if scheduleWeekday == day.0 {
                                        Label(day.1, systemImage: "checkmark")
                                    } else {
                                        Text(day.1)
                                    }
                                }
                            }
                        } label: {
                            frequencyMenuLabel(weekdays.first { $0.0 == scheduleWeekday }?.1 ?? "Day")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                    }
                }

                if scheduleKind == .custom {
                    Divider()
                    frequencyRow("On") {
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
                                        .font(.caption2.weight(.medium))
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
                    Divider()
                    frequencyRow("At") {
                        DatePicker("Time", selection: $scheduleTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }

                if scheduleKind == .once {
                    Divider()
                    Text("Runs only when you press Run now. Nothing is scheduled.")
                        .font(.caption)
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
                .font(.callout)
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
                .font(.callout)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }

    private func intervalPresetLabel(_ minutes: Int) -> String {
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    private func applySchedule(_ schedule: AutomationSchedule) {
        scheduleKind = schedule.kind
        intervalMinutes = String(max(1, schedule.everySeconds / 60))
        scheduleTime = Calendar.current.date(
            bySettingHour: schedule.hour,
            minute: schedule.minute,
            second: 0,
            of: Date()
        ) ?? Date()
        scheduleWeekday = schedule.weekday
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
        let every = max((UInt64(intervalMinutes) ?? 60) * 60, 60)
        switch scheduleKind {
        case .once:
            return AutomationSchedule(kind: .once)
        case .interval:
            return AutomationSchedule(kind: .interval, everySeconds: every)
        case .daily:
            return AutomationSchedule(kind: .daily, hour: hour, minute: minute)
        case .weekdays:
            return AutomationSchedule(
                kind: .weekdays, hour: hour, minute: minute,
                weekdays: AutomationSchedule.weekdaysMask
            )
        case .weekly:
            return AutomationSchedule(
                kind: .weekly, hour: hour, minute: minute, weekday: scheduleWeekday
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
        let minutes = UInt64(budgetMinutes) ?? 180
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
                lastRunID: existing.lastRunID
            ))
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
