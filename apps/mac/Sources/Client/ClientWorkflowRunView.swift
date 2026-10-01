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
        session.runs.first { $0.id == runID }
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
                } else if session.loaded {
                    ClientSectionEmpty(text: L10n.text("apple.clientworkflowrunview.this_run_is_unavailable.5bef28b2"), message: L10n.text("apple.clientworkflowrunview.it_is_no_longer_in_this_folder_s_run_histo.0960f968"))
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .navigationTitle(run?.name ?? L10n.text("common.run"))
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
            ClientFactRow(label: L10n.text("apple.clientworkflowrunview.budget.1c6225ec"), value: ClientJobCopy.budget(run.budgetSeconds))
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    @ViewBuilder
    private func steps(_ run: WorkflowRunRecord) -> some View {
        if !run.steps.isEmpty {
            Text(L10n.text("apple.clientworkflowrunview.steps.1de3df70"))
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
            Text(L10n.text("apple.clientworkflowrunview.transcript.721164f0"))
                .font(ClientType.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            TranscriptView(
                text: session.transcriptText,
                empty: run.isLive ? L10n.text("apple.clientworkflowrunview.waiting_for_output.f05fefe2") : L10n.text("apple.clientworkflowrunview.no_readable_output.cd218ba3")
            )
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .padding(.top, Theme.Space.xs)
    }
}

#endif
