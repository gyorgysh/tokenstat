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
    /// A run to open on arrival, requested from Tasks. Cleared once opened.
    @Binding var pendingRunID: String?

    @State private var creating = false
    @State private var template: AutomationTemplate?
    /// The run whose transcript sheet is open.
    @State private var viewingRun: RunRecord?
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            DetailChromeBar {
                ToolbarIconButton(
                    systemImage: "plus",
                    help: "Set up an agent to run on a schedule"
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
                    templatesRow
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
        .sheet(item: $viewingRun) { run in
            TranscriptSheet(model: model, run: run)
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
                    viewingRun = run
                    model.watch(run)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            pendingRunID = nil
        }
        // The model outlives this view, and the transcript tail must not.
        .onDisappear { model.disappeared() }
    }

    /// Waiting on the first read of the daemon's job list.
    private var isWarming: Bool {
        !model.hasLoaded && model.errorMessage == nil
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
            .buttonStyle(AccentButtonStyle())
        }
    }

    /// Three suggested setups, so a blank Automations screen shows what the
    /// screen is for instead of only an empty card.
    private var templatesRow: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
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
            schedule: AutomationSchedule(kind: .weekly, everySeconds: 0, hour: 9, minute: 0, weekday: 0),
            budgetSeconds: 900
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
                                  folder: folders.first { $0.id == job.workspaceID },
                                  onViewRun: { viewingRun = $0 })
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
                    .buttonStyle(AccentButtonStyle())
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
                            folder: folders.first { $0.id == job.workspaceID },
                            onViewRun: { viewingRun = $0 }
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
        .onTapGesture {
            viewingRun = run
        }
    }

    private func liveTranscript(_ run: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Output")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(
                    model.transcriptText.isEmpty
                        ? "Waiting for output…"
                        : (run.backend == "claude"
                            ? model.readableTranscript
                            : model.transcriptText)
                )
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

/// The full transcript of one run, rendered as something a person reads.
///
/// The raw transcript is the CLI's own stream — for Claude that is a JSON
/// line stream whose system hooks drown out the actual answer. This sheet
/// extracts the assistant messages and the final result, and passes plain
/// text through untouched for shell runs. Readable parsing exists for
/// Claude's stream-json today; every other backend stays raw until its
/// output shape is handled the same way.
private struct TranscriptSheet: View {
    @Bindable var model: AutomationsModel
    var run: RunRecord

    @Environment(\.dismiss) private var dismiss
    /// Raw shows the CLI's exact stream; off (the default) shows the parsed,
    /// human-readable version.
    @State private var showRaw = false

    /// Only Claude's stream-json has a readable form yet.
    private var canSummarize: Bool { run.backend == "claude" }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.name)
                        .font(.system(size: 15, weight: .semibold))
                    Text(headerLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if canSummarize {
                    Button {
                        showRaw.toggle()
                    } label: {
                        Label(showRaw ? "Readable" : "Raw", systemImage: showRaw ? "text.alignleft" : "terminal")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(showRaw ? "Show the readable summary" : "Show the raw machine output")
                }
                StatusPill(status: run.status, text: run.endedLabel)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.controlGlyph)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.controlSeat))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            ScrollView {
                Text(
                    showRaw || !canSummarize
                        ? model.transcriptText
                        : model.readableTranscript
                )
                    .font(Theme.mono(11))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.Space.s)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
        }
        .padding(Theme.Space.l)
        .frame(width: 680)
        .frame(minHeight: 420, maxHeight: 560)
        .background(Theme.panel)
        .task { model.watch(run) }
    }

    private var headerLine: String {
        var line = run.startedAt.formatted(date: .abbreviated, time: .shortened)
        if let code = run.exitCode {
            line += " · exit \(code)"
        }
        return line
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
    /// Opens the transcript sheet for a run, owned by the screen.
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
            Toggle("Enabled", isOn: Binding(
                get: { job.enabled },
                set: { _ in Task { await model.toggle(job) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Enabled")
            .accessibilityValue(job.enabled ? "On" : "Off")
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
            Button("Run now") { Task { await model.run(job) } }
                .buttonStyle(AccentButtonStyle(small: true))
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
            .accessibilityLabel("Delete \(job.name)")
        }
        .sheet(isPresented: $showingHistory) {
            AutomationHistorySheet(job: job, model: model, onView: onViewRun)
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
                Button("Done") { dismiss() }
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
                                Button("View") {
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
private struct AutomationTemplate: Identifiable {
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
private struct NewAutomationSheet: View {
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

            stepHeader
            fields

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
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
                    Label(step < 2 ? "Continue" : (existing == nil ? "Create" : "Save"), systemImage: step < 2 ? "arrow.right" : "checkmark")
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
                scheduleKind = existing.schedule.kind
                budget = String(existing.budgetSeconds)
            }
            if let template {
                name = template.name
                prompt = template.prompt
                scheduleKind = template.schedule.kind
                intervalMinutes = String(max(1, template.schedule.everySeconds / 60))
                scheduleTime = Calendar.current.date(
                    bySettingHour: template.schedule.hour,
                    minute: template.schedule.minute,
                    second: 0,
                    of: Date()
                ) ?? Date()
                scheduleWeekday = template.schedule.weekday
                budget = String(template.budgetSeconds)
                if model.backends.contains(where: { $0.id == template.backendID }) {
                    backendID = template.backendID
                }
            }
            if backendID.isEmpty, let first = model.backends.first {
                backendID = first.id
            }
            if workspaceID.isEmpty, let first = folders.first {
                workspaceID = first.id
            }
        }
        .onChange(of: backendID) { _, _ in
            // A model that meant something to one backend means nothing to
            // the next; go back to defaults when the agent changes.
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
                AppMenuPicker(
                    title: "Agent",
                    options: model.backends.map { (value: $0.id, label: $0.label) },
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
                    HStack(spacing: Theme.Space.s) {
                        if !backend.models.isEmpty {
                            AppMenuPicker(
                                title: "Model",
                                options: [(value: "", label: "Default")]
                                    + backend.models.map { (value: $0, label: $0) },
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
                Text("The agent runs on this machine, in the selected workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                scheduleControls
                HStack(spacing: 4) {
                    Text("Time limit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("900", text: $budget)
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
        SegmentedCapsulePicker(
            options: [
                (ScheduleKind.once, "Once", "cursorarrow.click"),
                (ScheduleKind.interval, "Interval", "repeat"),
                (ScheduleKind.daily, "Daily", "sun.max"),
                (ScheduleKind.weekly, "Weekly", "calendar"),
            ],
            selection: $scheduleKind
        )

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
                AppMenuPicker(
                    title: "Day",
                    options: weekdays.map { (value: $0.0, label: $0.1) },
                    selection: $scheduleWeekday
                )
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
                model: modelChoice.isEmpty ? nil : modelChoice,
                effort: effortChoice.isEmpty ? nil : effortChoice,
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
                model: modelChoice.isEmpty ? nil : modelChoice,
                effort: effortChoice.isEmpty ? nil : effortChoice,
                workspaceID: workspaceID,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                schedule: spec,
                budget: UInt64(budget) ?? 900
            )
        }
    }
}
