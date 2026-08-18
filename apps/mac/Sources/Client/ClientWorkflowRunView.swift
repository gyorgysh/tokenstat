// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// One workflow run on a phone: steps and the transcript of the selected step.
struct ClientWorkflowRunView: View {
    @Bindable var session: ClientWorkflowSession
    let runID: String

    private var run: WorkflowRunRecord? {
        session.runs.first { $0.id == runID } ?? session.selectedRun
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let errorMessage = session.errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await session.load() }
                    }
                }
                if let run {
                    header(run)
                    ClientWorkflowActions(session: session, showsPrompt: false, pinnedRunID: runID)
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface()
                    steps(run)
                    transcript(run)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .navigationTitle(run?.name ?? "Run")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await ClientRefresh.pull("workflow-run-\(runID)") { await session.load() }
        }
        .task {
            if let run = session.runs.first(where: { $0.id == runID }) {
                session.selectRun(run)
            }
            await session.appeared()
        }
        .onDisappear { session.disappeared() }
    }

    private func header(_ run: WorkflowRunRecord) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                StatusPill(status: run.status, text: run.endedLabel)
                Spacer()
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
            if !run.input.isEmpty {
                Text(run.input)
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ClientFactRow(label: "Budget", value: ClientJobCopy.budget(run.budgetSeconds))
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    @ViewBuilder
    private func steps(_ run: WorkflowRunRecord) -> some View {
        if !run.steps.isEmpty {
            Text("Steps")
                .font(ClientType.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            ForEach(run.steps) { step in
                Button {
                    session.selectNode(step.nodeID)
                } label: {
                    HStack(spacing: Theme.Space.s) {
                        Circle()
                            .fill(RunOutcome.tint(step.status))
                            .frame(width: 8, height: 8)
                        Text(step.title.isEmpty ? step.kind : step.title)
                            .font(ClientType.label.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        StatusPill(status: step.status, text: step.endedLabel)
                    }
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        session.selectedNodeID == step.nodeID ? Theme.rowSelected : Theme.panel,
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cardRadius)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func transcript(_ run: WorkflowRunRecord) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Transcript")
                .font(ClientType.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            TranscriptView(
                text: session.transcriptText,
                empty: run.isLive ? "Waiting for output…" : "No readable output."
            )
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .padding(.top, Theme.Space.xs)
    }
}

#endif
