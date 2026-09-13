// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// Every retained run for one job. Compact layouts push this. Split layouts
/// present it as a sheet so the transcript stays on the page.
struct ClientAutomationHistoryView: View {
    @Bindable var session: ClientAutomationSession
    let jobID: String
    var onSelect: ((RunRecord) -> Void)? = nil

    var body: some View {
        ScrollView {
            ClientAutomationHistoryList(session: session, jobID: jobID, onSelect: onSelect)
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.s)
                .padding(.bottom, 96)
        }
        .background(Theme.background)
        .navigationTitle("Runs")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await ClientRefresh.pull("automation-history-\(jobID)") { await session.load() }
        }
        .task { await session.appeared() }
        .onDisappear { session.disappeared() }
    }
}

struct ClientAutomationHistorySheet: View {
    @Bindable var session: ClientAutomationSession
    let jobID: String
    var onSelect: (RunRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ThemedSheet(
            title: "Runs",
            subtitle: session.jobs.first(where: { $0.id == jobID })?.name ?? session.folderName,
            icon: .history,
            scrolls: true,
            onClose: { dismiss() }
        ) {
            ClientAutomationHistoryList(session: session, jobID: jobID) { run in
                onSelect(run)
                dismiss()
            }
        }
    }
}

struct ClientAutomationHistoryList: View {
    @Bindable var session: ClientAutomationSession
    let jobID: String
    var onSelect: ((RunRecord) -> Void)? = nil
    @State private var shown = AutomationRunHistory.pageSize

    var body: some View {
        let runs = session.runs.filter { $0.jobId == jobID }
        let visible = AutomationRunHistory.page(
            runs, shown: shown,
            id: \.id, startedAtMs: \.startedAtMs, isLive: \.isRunning
        )
        let leftover = AutomationRunHistory.remaining(total: runs.count, shown: shown)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !session.loaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Space.xl)
            } else if runs.isEmpty {
                ClientSectionEmpty(
                    text: "Nothing has run yet",
                    message: "When this job runs, the output lands here."
                )
            } else {
                Text(HostScheduleClock.timesCaption(
                    hostName: session.hostName,
                    timezone: session.schedulerTimezone
                ))
                .font(ClientType.caption)
                .foregroundStyle(Theme.controlGlyph)
                .fixedSize(horizontal: false, vertical: true)
                if leftover > 0 {
                    Text("Showing the \(visible.count) newest of \(runs.count).")
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.controlGlyph)
                }
                ForEach(visible) { run in
                    runRow(run)
                }
                if leftover > 0 {
                    Button("Earlier runs", .history) {
                        shown += AutomationRunHistory.pageSize
                    }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func runRow(_ run: RunRecord) -> some View {
        let selected = session.selectedRunID == run.id
        if let onSelect {
            Button {
                session.selectRun(run)
                onSelect(run)
            } label: {
                ClientPastRunRow(
                    title: run.name,
                    status: run.status,
                    label: run.endedLabel,
                    started: run.startedAt,
                    timezone: session.schedulerTimezone,
                    isSelected: selected
                )
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                ClientAutomationRunView(session: session, runID: run.id)
            } label: {
                ClientPastRunRow(
                    title: run.name,
                    status: run.status,
                    label: run.endedLabel,
                    started: run.startedAt,
                    timezone: session.schedulerTimezone,
                    isSelected: selected,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
        }
    }
}

struct HistorySheetPresentation: ViewModifier {
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.presentationDragIndicator(.visible)
        } else {
            content
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}
#endif
