// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The selected automation or run. The list stays an overview.
///
/// The live transcript used to sit inside the runs card. That buried the list
/// under a stream. It lives here, next to the job that produced it.
struct AutomationsInspector: View {
    @Bindable var model: AutomationsModel
    var folders: [WorkspaceFolder]
    var onReviewWorkspace: ((String, TaskResultWorkspaceSurface) -> Void)? = nil
    var onClose: () -> Void

    @State private var editing = false
    /// Live tail. On by default so a started run stays on the newest line.
    @AppStorage("automations.followLive") private var followLive = true

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                InspectorTitle(title: chromeTitle, symbol: "bolt.fill")
                Spacer(minLength: 0)
            }
            Group {
                if let run = model.selectedRun, model.selectedFocus == .run {
                    runBody(run)
                } else if let job = model.selectedJob {
                    jobBody(job)
                } else {
                    InspectorEmptyState(
                        mark: "mark_automation",
                        title: "Pick a job or a run",
                        subtitle: "Schedule and transcript open here."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .sheet(isPresented: $editing) {
            if let job = model.selectedJob {
                NewAutomationSheet(model: model, folders: folders, existing: job)
            }
        }
    }

    private var chromeTitle: String {
        switch model.selectedFocus {
        case .run: return "Run"
        case .job: return "Automation"
        case .none: return "Automations"
        }
    }

    private func jobBody(_ job: Automation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(job.name)
                    .font(Theme.font(15, weight: .semibold))
                Text(job.prompt)
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                labeled("Backend", model.backends.first { $0.id == job.backend }?.label ?? job.backend)
                if let modelName = job.model, !modelName.isEmpty {
                    labeled("Model", modelName)
                }
                labeled("Schedule", model.scheduleSummary(job.schedule))
                if let folder = folders.first(where: { $0.id == job.workspaceID }) {
                    labeled("Folder", folder.name)
                }
                if let clock = HostScheduleClock.clock(model.schedulerTimezone) {
                    labeled("Time zone", clock)
                }
                if let next = job.nextRun, job.enabled {
                    labeled("Next", HostScheduleClock.nextRun(next, timezone: model.schedulerTimezone))
                }
                if let last = model.lastRun(for: job) {
                    labeled("Last", last.startedAt.formatted(date: .abbreviated, time: .shortened))
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.s) { jobActions(job) }
                    VStack(alignment: .leading, spacing: Theme.Space.s) { jobActions(job) }
                }
                if model.hasUnconfirmedLaunch(job.id), model.lastRun(for: job)?.isRunning != true {
                    Text("This run is not confirmed yet. Check it before starting another.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func jobActions(_ job: Automation) -> some View {
        if let last = model.lastRun(for: job), last.isRunning {
            Button("Stop", .stop) { Task { await model.stop(last) } }
                .buttonStyle(AccentButtonStyle())
                .help("Kill this run now")
        } else if model.hasUnconfirmedLaunch(job.id) {
            Button("Check run", .refresh) { Task { await model.checkLaunch(job) } }
                .buttonStyle(SecondaryButtonStyle())
            Button("Retry run", .run) { Task { await model.run(job) } }
                .buttonStyle(AccentButtonStyle())
        } else {
            Button("Run now", .run) { Task { await model.run(job) } }
                .buttonStyle(AccentButtonStyle())
        }
        Button("Edit", .edit) { editing = true }
            .buttonStyle(SecondaryButtonStyle())
    }

    private func runBody(_ run: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text(run.name)
                        .font(Theme.font(15, weight: .semibold))
                    Spacer()
                    if run.isRunning {
                        Button("Stop", .stop) { Task { await model.stop(run) } }
                            .buttonStyle(SecondaryButtonStyle())
                            .help("Kill this run now")
                    }
                    if model.selectedJob != nil {
                        Button("Edit job", .edit) { editing = true }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    StatusPill(status: run.status, text: run.endedLabel)
                }
                Text(model.backends.first { $0.id == run.backend }?.label ?? run.backend)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                BrandToggleChip(title: "Follow", isOn: $followLive)
                    .help("Keep the transcript pinned to the newest line")
                if let onReviewWorkspace, !run.workspaceID.isEmpty {
                    TaskResultWorkspaceLinks(
                        route: TaskResultRoute(
                            runID: run.id, workspaceID: run.workspaceID, folders: folders, hostName: "This computer"
                        ),
                        onSelect: { surface in
                            onReviewWorkspace(run.workspaceID, surface)
                        },
                        showsContext: false
                    )
                }
            }
            .padding(Theme.Space.m)

            ScrollViewReader { proxy in
                ScrollView {
                    TranscriptView(
                        text: model.transcriptText,
                        empty: run.isRunning ? "Waiting for output…" : "(No readable output)"
                    )
                    .padding(Theme.Space.m)
                    Color.clear
                        .frame(height: 1)
                        .id("transcript-tail")
                }
                .background(Theme.background)
                .onChange(of: model.transcriptText) { _, _ in
                    guard followLive else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("transcript-tail", anchor: .bottom)
                    }
                }
                .onAppear {
                    if followLive {
                        proxy.scrollTo("transcript-tail", anchor: .bottom)
                    }
                }
            }
        }
        .onAppear { model.watch(run) }
        .onChange(of: run.id) { _, _ in
            model.watch(run)
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(Theme.callout)
        }
    }
}
