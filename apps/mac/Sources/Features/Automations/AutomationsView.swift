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

    @State private var creating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let error = model.errorMessage {
                    Banner(text: error, severity: .warning)
                }
                if model.jobs.isEmpty && model.runs.isEmpty {
                    nothingYet
                } else {
                    automationsCard
                    runsCard
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
                .disabled(model.backends.isEmpty || folders.isEmpty)
            }
        }
        .sheet(isPresented: $creating) {
            NewAutomationSheet(model: model, folders: folders)
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
        .padding(Theme.Space.s)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
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
            Button(role: .destructive) { confirmingDelete = true } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this automation")
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
                Text("New automation")
                    .font(.system(size: 15, weight: .semibold))
                Text("An agent run headless in a folder, like a person launching it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            fields

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    working = true
                    Task {
                        await create()
                        working = false
                        if model.errorMessage == nil { dismiss() }
                    }
                } label: {
                    Label("Create", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate || working)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 520)
        .background(Theme.panel)
        .onAppear {
            if backendID.isEmpty, let first = model.backends.first {
                backendID = first.id
            }
            if workspaceID.isEmpty, let first = folders.first {
                workspaceID = first.id
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TextField("Name", text: $name, prompt: Text("e.g. Nightly docs check"))
            HStack(spacing: Theme.Space.s) {
                Picker("Backend", selection: $backendID) {
                    ForEach(model.backends) { backend in
                        Text(backend.label).tag(backend.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker("Folder", selection: $workspaceID) {
                    Text("Choose a folder").tag("")
                    ForEach(folders) { folder in
                        Text(folder.name).tag(folder.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            promptEditor
            scheduleControls
            HStack(spacing: 4) {
                Text("Stop it after")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Budget", text: $budget)
                    .frame(width: 70)
                Text("seconds")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
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

    private func create() async {
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
