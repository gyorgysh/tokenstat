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
                    if let live = session.liveRun, live.id != run.id {
                        Text(L10n.text("apple.clientautomationrunview.a_run_is_going_this_is_an_earlier_one.c004db24"))
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.controlGlyph)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Theme.Space.m)
                    }
                    ClientAutomationActions(session: session, pinnedRunID: runID)
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface()
                    TranscriptView(
                        text: session.transcriptText,
                        empty: run.isRunning ? L10n.text("apple.clientautomationrunview.waiting_for_output.f05fefe2") : L10n.text("apple.clientautomationrunview.no_readable_output.cd218ba3")
                    )
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                } else if session.loaded {
                    ClientSectionEmpty(text: L10n.text("apple.clientautomationrunview.this_run_is_unavailable.5bef28b2"), message: L10n.text("apple.clientautomationrunview.it_is_no_longer_in_this_folder_s_run_histo.0960f968"))
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
                Text(
                    HostScheduleClock.wallClock(run.startedAt, timezone: session.schedulerTimezone)
                        ?? run.startedAt.formatted(date: .abbreviated, time: .shortened)
                )
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
            ClientFactRow(label: L10n.text("apple.clientautomationrunview.backend.2fb4019a"), value: run.backend)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

#endif
