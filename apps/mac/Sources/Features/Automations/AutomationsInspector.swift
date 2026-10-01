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
                        title: L10n.text("apple.automationsinspector.pick_a_job_or_a_run.60a81061"),
                        subtitle: L10n.text("apple.automationsinspector.schedule_and_transcript_open_here.9c32c0ed")
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
        case .run: return L10n.text("common.run")
        case .job: return L10n.text("apple.automationsinspector.automation.d909750b")
        case .none: return L10n.text("common.automations")
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

                labeled(L10n.text("apple.automationsinspector.backend.2fb4019a"), model.backends.first { $0.id == job.backend }?.label ?? job.backend)
                if let modelName = job.model, !modelName.isEmpty {
                    labeled(L10n.text("apple.automationsinspector.model.5e2c614c"), modelName)
                }
                labeled(L10n.text("apple.automationsinspector.schedule.f4830a1d"), model.scheduleSummary(job.schedule))
                if let folder = folders.first(where: { $0.id == job.workspaceID }) {
                    labeled(L10n.text("apple.automationsinspector.folder.74ccd433"), folder.name)
                }
                if let clock = HostScheduleClock.clock(model.schedulerTimezone) {
                    labeled(L10n.text("apple.automationsinspector.time_zone.b9fe1464"), clock)
                }
                if let next = job.nextRun, job.enabled {
                    labeled(L10n.text("common.next"), HostScheduleClock.nextRun(next, timezone: model.schedulerTimezone))
                }
                if let last = model.lastRun(for: job) {
                    labeled(L10n.text("apple.automationsinspector.last.eb970eb0"), last.startedAt.formatted(date: .abbreviated, time: .shortened))
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.s) { jobActions(job) }
                    VStack(alignment: .leading, spacing: Theme.Space.s) { jobActions(job) }
                }
                if model.hasUnconfirmedLaunch(job.id), model.lastRun(for: job)?.isRunning != true {
                    Text(L10n.text("apple.automationsinspector.this_run_is_not_confirmed_yet_check_it_bef.46c377ae"))
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
            Button(L10n.text("common.stop"), .stop) { Task { await model.stop(last) } }
                .buttonStyle(AccentButtonStyle())
                .help(L10n.text("apple.automationsinspector.kill_this_run_now.87db925a"))
        } else if model.hasUnconfirmedLaunch(job.id) {
            Button(L10n.text("apple.automationsinspector.check_run.cece2401"), .refresh) { Task { await model.checkLaunch(job) } }
                .buttonStyle(SecondaryButtonStyle())
            Button(L10n.text("apple.automationsinspector.retry_run.2f9c439b"), .run) { Task { await model.run(job) } }
                .buttonStyle(AccentButtonStyle())
        } else {
            Button(L10n.text("apple.automationsinspector.run_now.09913977"), .run) { Task { await model.run(job) } }
                .buttonStyle(AccentButtonStyle())
        }
        Button(L10n.text("common.edit"), .edit) { editing = true }
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
                        Button(L10n.text("common.stop"), .stop) { Task { await model.stop(run) } }
                            .buttonStyle(SecondaryButtonStyle())
                            .help(L10n.text("apple.automationsinspector.kill_this_run_now.87db925a"))
                    }
                    if model.selectedJob != nil {
                        Button(L10n.text("apple.automationsinspector.edit_job.4d9c1d76"), .edit) { editing = true }
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
                BrandToggleChip(title: L10n.text("apple.automationsinspector.follow.641d1ef6"), isOn: $followLive)
                    .help(L10n.text("apple.automationsinspector.keep_the_transcript_pinned_to_the_newest_l.91faa696"))
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
                        empty: run.isRunning ? L10n.text("apple.automationsinspector.waiting_for_output.f05fefe2") : L10n.text("apple.automationsinspector.no_readable_output.0ff4d5c1")
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
