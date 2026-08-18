// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// One automation run on a phone: status and a live transcript.
struct ClientAutomationRunView: View {
    @Bindable var session: ClientAutomationSession
    let runID: String

    private var run: RunRecord? {
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
                    ClientAutomationActions(session: session, pinnedRunID: runID)
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface()
                    TranscriptView(
                        text: session.transcriptText,
                        empty: run.isRunning ? "Waiting for output…" : "No readable output."
                    )
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
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
            await ClientRefresh.pull("automation-run-\(runID)") { await session.load() }
        }
        .task {
            if let run = session.runs.first(where: { $0.id == runID }) {
                session.selectRun(run)
            }
            await session.appeared()
        }
        .onDisappear { session.disappeared() }
    }

    private func header(_ run: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                StatusPill(status: run.status, text: run.endedLabel)
                Spacer()
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
            ClientFactRow(label: "Backend", value: run.backend)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

#endif
