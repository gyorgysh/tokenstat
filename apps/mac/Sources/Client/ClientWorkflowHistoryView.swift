// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// Every retained run for one workflow. Compact layouts push this. Split
/// layouts present it as a sheet so the transcript stays on the page.
///
/// The host returns the retained list in one read. The client windows it:
/// live first, then newest, twenty at a time. Times use the host scheduler
/// zone. Transcripts stay bounded at the run view.
struct ClientWorkflowHistoryView: View {
    @Bindable var session: ClientWorkflowSession
    let graphID: String
    var onSelect: ((WorkflowRunRecord) -> Void)? = nil

    var body: some View {
        ScrollView {
            ClientWorkflowHistoryList(session: session, graphID: graphID, onSelect: onSelect)
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.s)
                .padding(.bottom, 96)
        }
        .background(Theme.background)
        .navigationTitle("Runs")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await ClientRefresh.pull("workflow-history-\(graphID)") { await session.load() }
        }
        .task { await session.appeared() }
        .onDisappear { session.disappeared() }
    }
}

struct ClientWorkflowHistorySheet: View {
    @Bindable var session: ClientWorkflowSession
    let graphID: String
    var onSelect: (WorkflowRunRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ThemedSheet(
            title: "Runs",
            subtitle: session.graphs.first(where: { $0.id == graphID })?.name ?? session.folderName,
            icon: .history,
            scrolls: true,
            onClose: { dismiss() }
        ) {
            ClientWorkflowHistoryList(session: session, graphID: graphID) { run in
                onSelect(run)
                dismiss()
            }
        }
    }
}

struct ClientWorkflowHistoryList: View {
    @Bindable var session: ClientWorkflowSession
    let graphID: String
    var onSelect: ((WorkflowRunRecord) -> Void)? = nil
    @State private var shown = AutomationRunHistory.pageSize

    var body: some View {
        let runs = session.runs.filter { $0.workflowID == graphID }
        let visible = AutomationRunHistory.page(
            runs, shown: shown,
            id: \.id, startedAtMs: \.startedAtMs, isLive: \.isLive
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
                    message: "When this workflow runs, the output lands here."
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
    private func runRow(_ run: WorkflowRunRecord) -> some View {
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
                ClientWorkflowRunView(session: session, runID: run.id)
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
#endif
