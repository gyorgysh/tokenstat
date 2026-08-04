// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

/// The agent automations screen.
///
/// Ordered by what somebody came here to do: watch the run that is happening,
/// see the jobs, then add one. A job is a backend, a prompt, a workspace and a
/// schedule, exactly like launching `claude -p "…"` in a terminal but owned by
/// the daemon and stopped at a budget.
struct AutomationsView: View {
    @Bindable var model: AutomationsModel
    /// The registered folders, shared with the workspaces screen. Passed in so
    /// this screen never runs a second `workspace.list`.
    var folders: [WorkspaceFolder]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let error = model.errorMessage {
                    Banner(text: error, severity: .warning)
                }
                if let notice = model.noticeMessage {
                    Banner(text: notice, severity: .success)
                }

                runsCard
                if !model.jobs.isEmpty {
                    jobsCard
                }
                newAutomationCard
            }
            .padding(Theme.Space.m)
        }
        .navigationTitle("Automations")
        .task {
            await model.load()
            model.syncWatching()
        }
    }

    // MARK: - Runs

    private var runsCard: some View {
        Card(
            title: "Runs",
            subtitle: model.liveRun?.isRunning == true
                ? "The latest run, live as its transcript is written."
                : "Recent runs. Transcripts are kept on this machine."
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if model.runs.isEmpty {
                    Text("Nothing has run yet. Start one below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.runs.prefix(6))) { run in
                        runRow(run)
                    }
                    if let live = model.liveRun, live.isRunning {
                        liveTranscript(live)
                    }
                }
            }
        }
    }

    private func runRow(_ run: RunRecord) -> some View {
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(statusTint(run.status))
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
            Text(run.endedLabel)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusTint(run.status).opacity(0.15), in: Capsule())
                .foregroundStyle(statusTint(run.status))
        }
        .padding(.vertical, 2)
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
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "running": return Theme.accent
        case "ok": return Theme.success
        case "stopped": return Theme.warning
        case "error": return Theme.danger
        default: return .secondary
        }
    }

    // MARK: - Jobs

    private var jobsCard: some View {
        Card(title: "Automations", subtitle: "Owned by the daemon. They run whether this window is open or not.") {
            VStack(spacing: Theme.Space.s) {
                ForEach(model.jobs) { job in
                    jobRow(job)
                }
            }
        }
    }

    private func jobRow(_ job: Automation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text(job.name)
                    .font(.callout.weight(.medium))
                Text(model.backends.first { $0.id == job.backend }?.label ?? job.backend)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(Theme.accent)
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { job.enabled },
                    set: { _ in Task { await model.toggle(job) } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            Text(job.prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Theme.Space.m) {
                Label(model.scheduleSummary(job.schedule), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let next = job.nextRun {
                    Text("Next \(next.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Run now") { Task { await model.run(job) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(role: .destructive) { Task { await model.remove(job) } } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this automation")
            }
        }
        .padding(Theme.Space.s)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - New automation

    private var newAutomationCard: some View {
        NewAutomationForm(model: model, folders: folders)
    }
}

// MARK: - The form

private struct NewAutomationForm: View {
    @Bindable var model: AutomationsModel
    var folders: [WorkspaceFolder]

    @State private var name = ""
    @State private var backendID = ""
    @State private var workspaceID = ""
    @State private var prompt = ""
    @State private var scheduleKind: ScheduleKind = .once
    @State private var intervalMinutes = "60"
    @State private var scheduleTime = Date()
    @State private var scheduleWeekday = 1
    @State private var budget = "900"
    @State private var working = false

    private let weekdays = [
        (1, "Monday"), (2, "Tuesday"), (3, "Wednesday"), (4, "Thursday"),
        (5, "Friday"), (6, "Saturday"), (0, "Sunday"),
    ]

    var body: some View {
        Card(title: "New automation", subtitle: "An agent run headless in the workspace, like a person launching it.") {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField("Name", text: $name, prompt: Text("e.g. Nightly docs check"))
                HStack(spacing: Theme.Space.s) {
                    Picker("Backend", selection: $backendID) {
                        ForEach(model.backends) { backend in
                            Text(backend.label).tag(backend.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("Workspace", selection: $workspaceID) {
                        Text("Choose a folder").tag("")
                        ForEach(folders) { folder in
                            Text(folder.name).tag(folder.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                TextEditor(text: $prompt)
                    .font(Theme.mono(12))
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
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

                scheduleControls

                HStack(spacing: Theme.Space.s) {
                    HStack(spacing: 4) {
                        TextField("Budget", text: $budget)
                            .frame(width: 70)
                        Text("sec")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button {
                        working = true
                        Task {
                            await create()
                            working = false
                        }
                    } label: {
                        Label("Create", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
                }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
        }
        .onAppear {
            if backendID.isEmpty, let first = model.backends.first {
                backendID = first.id
            }
        }
    }

    @ViewBuilder
    private var scheduleControls: some View {
        Picker("Schedule", selection: $scheduleKind) {
            Text("Once, when I run it").tag(ScheduleKind.once)
            Text("Every so often").tag(ScheduleKind.interval)
            Text("Daily").tag(ScheduleKind.daily)
            Text("Weekly").tag(ScheduleKind.weekly)
        }
        .pickerStyle(.segmented)

        switch scheduleKind {
        case .interval:
            HStack(spacing: 4) {
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
        if model.errorMessage == nil {
            name = ""
            prompt = ""
            workspaceID = ""
        }
    }
}
