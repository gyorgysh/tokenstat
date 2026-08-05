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
/// at a budget. It runs whether this window is open or not, which is the whole
/// point of it living in the daemon.
struct AutomationsView: View {
    @Bindable var model: AutomationsModel
    /// The registered folders, shared with the workspaces screen. Passed in so
    /// this screen never runs a second `workspace.list`.
    var folders: [WorkspaceFolder]
    var onNavigate: ((Destination) -> Void)? = nil

    @State private var creating = false
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let error = model.errorMessage {
                    Banner(text: error, severity: .warning)
                }
                intro
                TextField("Search automations", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .overlay(alignment: .leading) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 8)
                    }
                    .padding(.leading, 4)
                if filteredJobs.isEmpty {
                    nothingYet
                } else {
                    taskSection("Active", jobs: filteredJobs.filter(\.enabled))
                    taskSection("Paused", jobs: filteredJobs.filter { !$0.enabled })
                }
                if !model.runs.isEmpty {
                    recentRuns
                }
            }
            .padding(Theme.Space.m)
        }
        .navigationTitle("Automations")
        .background(Theme.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: {
                    Label("New automation", systemImage: "plus")
                }
                .help("Set up an agent to run on a schedule")
            }
        }
        .sheet(isPresented: $creating) {
            NewAutomationSheet(model: model, folders: folders, onNavigate: onNavigate)
        }
        .overlay(alignment: .bottomTrailing) {
            TransientToast(message: $model.noticeMessage, severity: .success)
                .padding(Theme.Space.l)
        }
        .task {
            await model.load()
            model.syncWatching()
        }
    }

    private var intro: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Automations")
                    .font(.system(size: 24, weight: .semibold))
                Text("Give an agent a job, a folder, and a time. It runs in the background and stops at your limit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { creating = true } label: {
                Label("Create", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

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
                                  folder: folders.first { $0.id == job.workspaceID })
                    if job.id != jobs.last?.id { Divider() }
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
        })
    }

    private var recentRuns: some View {
        Card(title: "Recent runs", subtitle: "The latest result from each scheduled job.") {
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
        Card(title: "Automations", subtitle: nil) {
            EmptyState(
                symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                title: "No automations yet",
                message: """
                An automation is an agent given a prompt, a folder and a time to \
                run. The daemon runs it whether this window is open or not, and \
                stops it at a budget you set.
                """
            ) {
                if folders.isEmpty {
                    Text("Add a folder on the Workspaces screen first. An agent runs somewhere.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Button {
                        creating = true
                    } label: {
                        Label("New automation", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - The automations

    private var automationsCard: some View {
        Card(
            title: "Automations",
            subtitle: "Owned by the daemon. They run whether this window is open or not.",
            accessory: AnyView(
                Button { creating = true } label: {
                    Label("New", systemImage: "plus")
                }
                .controlSize(.small)
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
                            folder: folders.first { $0.id == job.workspaceID }
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
            subtitle: model.selectedRun?.isRunning == true
                ? "The latest run, live as its transcript is written."
                : "Select a run to read its output."
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
                    if let selected = model.selectedRun {
                        liveTranscript(selected)
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
        .onTapGesture { model.watch(run) }
    }

    private func liveTranscript(_ run: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Output")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(model.transcriptText.isEmpty ? "Waiting for output…" : model.transcriptText)
                    .font(Theme.mono(11))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            .padding(Theme.Space.s)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            HStack(spacing: Theme.Space.s) {
                Label(run.status == "running" ? "Live output" : run.endedLabel,
                      systemImage: run.status == "running" ? "waveform" : "doc.text")
                    .font(.caption)
                    .foregroundStyle(Self.statusTint(run.status))
                if let exitCode = run.exitCode {
                    Text("Exit \(exitCode)")
                        .font(Theme.numeric(11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
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
    var folder: WorkspaceFolder?

    @State private var confirmingDelete = false
    @State private var showingHistory = false
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            header
            Text(job.prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            facts
        }
        .padding(.vertical, Theme.Space.s)
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
            Toggle("Enabled", isOn: Binding(
                get: { job.enabled },
                set: { _ in Task { await model.toggle(job) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
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
            if job.enabled, let next = job.nextRun {
                Text("Next \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let last = model.lastRun(for: job) {
                // The time is the useful half. The outcome is already a pill up
                // in the header, so repeating the word here would say it twice.
                Text("Last ran \(last.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Never run")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let folder {
                Label(folder.name, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Run now") { Task { await model.run(job) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("History") { showingHistory = true }
                .buttonStyle(.borderless)
                .controlSize(.small)
            Button("Edit") { editing = true }
                .buttonStyle(.borderless)
                .controlSize(.small)
            Button(role: .destructive) { confirmingDelete = true } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this automation")
        }
        .sheet(isPresented: $showingHistory) {
            AutomationHistorySheet(job: job, model: model)
        }
        .sheet(isPresented: $editing) {
            NewAutomationSheet(model: model, folders: folder.map { [$0] } ?? [], existing: job)
        }
    }
}

/// The outcome of a run, in the one shape it takes everywhere on this screen.
private struct StatusPill: View {
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.name).font(.title3.weight(.semibold))
                    Text("Run history").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
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
                                Button("View") { model.watch(run); dismiss() }
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

/// Setting up an automation, in a sheet.
///
/// A sheet rather than a card at the bottom of the screen: this is a form with
/// six decisions in it, and standing it permanently under the list meant an
/// empty screen was mostly an empty form. It also gives Cancel somewhere to be,
/// which a permanent form never had.
private struct NewAutomationSheet: View {
    @Bindable var model: AutomationsModel
    var folders: [WorkspaceFolder]
    var onNavigate: ((Destination) -> Void)?
    var existing: Automation? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var backendID = ""
    @State private var workspaceID = ""
    @State private var prompt = ""
    @State private var scheduleKind: ScheduleKind = .once
    @State private var intervalMinutes = "60"
    @State private var scheduleTime = Date()
    @State private var scheduleWeekday = 0
    @State private var budget = "900"
    @State private var working = false
    @State private var step = 0

    /// Monday first, and zero-based, matching `AutomationSchedule.weekday` and
    /// the daemon's `to_monday_zero_offset`. The picker used to be one-based
    /// with Sunday at zero, so choosing Monday scheduled a Tuesday.
    private let weekdays = [
        (0, "Monday"), (1, "Tuesday"), (2, "Wednesday"), (3, "Thursday"),
        (4, "Friday"), (5, "Saturday"), (6, "Sunday"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(existing == nil ? "New automation" : "Edit automation")
                    .font(.system(size: 15, weight: .semibold))
                Text("An agent run headless in a folder, like a person launching it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            stepHeader
            fields

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
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
                    Label(step < 2 ? "Continue" : (existing == nil ? "Create" : "Save"), systemImage: step < 2 ? "arrow.right" : "checkmark")
                }
                .buttonStyle(.borderedProminent)
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
                scheduleKind = existing.schedule.kind
                budget = String(existing.budgetSeconds)
            }
            if backendID.isEmpty, let first = model.backends.first {
                backendID = first.id
            }
            if workspaceID.isEmpty, let first = folders.first {
                workspaceID = first.id
            }
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
                    setupHint("Background helper is not running. Set it up from Machines before scheduling this task.", action: "Open Machines") {
                        dismiss()
                        onNavigate?(.machines)
                    }
                } else if model.backends.isEmpty {
                    setupHint("No supported agent CLI is installed yet. Install one, then reload this screen.", action: "Refresh agents") {
                        Task { await model.load() }
                    }
                } else if folders.isEmpty {
                    setupHint("Add a workspace before choosing where this task should run.", action: "Go to Workspaces") {
                        dismiss()
                        onNavigate?(.workspaces)
                    }
                }
                Picker("Agent", selection: $backendID) {
                    ForEach(model.backends) { backend in
                        Text(backend.label).tag(backend.id)
                    }
                }
                Picker("Workspace", selection: $workspaceID) {
                    Text("Choose a workspace").tag("")
                    ForEach(folders) { folder in
                        Text(folder.name).tag(folder.id)
                    }
                }
                Text("The agent runs on this machine, in the selected workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                scheduleControls
                HStack(spacing: 4) {
                    Text("Stop after")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Budget", text: $budget)
                        .frame(width: 70)
                    Text("seconds")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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
                Button(action, action: perform)
                    .buttonStyle(.link)
                    .font(.caption)
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

    @ViewBuilder
    private var scheduleControls: some View {
        Picker("Schedule", selection: $scheduleKind) {
            Text("Only when I run it").tag(ScheduleKind.once)
            Text("Every so often").tag(ScheduleKind.interval)
            Text("Daily").tag(ScheduleKind.daily)
            Text("Weekly").tag(ScheduleKind.weekly)
        }
        .pickerStyle(.segmented)

        switch scheduleKind {
        case .interval:
            HStack(spacing: 4) {
                Text("Every")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Interval", text: $intervalMinutes)
                    .frame(width: 70)
                Text("minutes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .daily:
            HStack(spacing: Theme.Space.s) {
                Text("At")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DatePicker("Time", selection: $scheduleTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
        case .weekly:
            HStack(spacing: Theme.Space.s) {
                Picker("Day", selection: $scheduleWeekday) {
                    ForEach(weekdays, id: \.0) { day in
                        Text(day.1).tag(day.0)
                    }
                }
                .frame(maxWidth: 160, alignment: .leading)
                Text("at")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DatePicker("Time", selection: $scheduleTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
        case .once:
            EmptyView()
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
            return canCreate
        }
    }

    private func save() async {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: scheduleTime)
        let every = (UInt64(intervalMinutes) ?? 60) * 60
        let spec = AutomationSchedule(
            kind: scheduleKind,
            everySeconds: scheduleKind == .interval ? max(every, 60) : 0,
            hour: scheduleKind == .daily || scheduleKind == .weekly ? (comps.hour ?? 9) : 0,
            minute: scheduleKind == .daily || scheduleKind == .weekly ? (comps.minute ?? 0) : 0,
            weekday: scheduleKind == .weekly ? scheduleWeekday : 0
        )
        if let existing {
            await model.update(Automation(
                id: existing.id,
                name: name.trimmingCharacters(in: .whitespaces),
                backend: backendID,
                workspaceID: workspaceID,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                schedule: spec,
                budgetSeconds: max(UInt64(budget) ?? 900, 60),
                enabled: existing.enabled,
                lastRunAtMs: existing.lastRunAtMs,
                nextRunAtMs: existing.nextRunAtMs,
                lastRunID: existing.lastRunID
            ))
        } else {
            await model.create(
                name: name.trimmingCharacters(in: .whitespaces),
                backend: backendID,
                workspaceID: workspaceID,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                schedule: spec,
                budget: UInt64(budget) ?? 900
            )
        }
    }
}
