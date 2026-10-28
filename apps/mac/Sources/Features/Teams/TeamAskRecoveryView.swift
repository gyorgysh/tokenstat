// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Account-local recovery remains available after directory access is lost.
/// Reading this list never sends, cancels or discards an agent request.
struct TeamAskRecoveryView: View {
    let store: TeamStore
    let owner: TeamAccountOwner
    let person: String
    let storage: TeamAskRecoveryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.teamCopy) private var copy
    @State private var entries: [TeamAskRecoveryStore.Entry] = []
    @State private var next: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var unreadable = false
    @State private var failed = false
    private var current: Bool { store.owner == owner && store.localDraftPersonId == person }

    var body: some View {
        ThemedSheet(title: L10n.text("common.teams.saved_asks"), subtitle: L10n.text("common.teams.saved_asks_detail"),
                    icon: .restore, scrolls: true, fills: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if current {
                    if failed || unreadable { TeamNotice(message: L10n.text("common.teams.saved_asks_unreadable"), warning: true) }
                    if loaded, entries.isEmpty, next == nil, !unreadable { Text(L10n.text("common.teams.no_saved_asks")).font(Theme.body) }
                    ForEach(entries) { entry in
                        TeamSavedAskRow(store: store, owner: owner, storage: storage, entry: entry, copy: { if current { copy(entry.snapshot.record.text) } })
                            .id(entry.snapshot.saved.revision)
                    }
                    if loading { ProgressView().accessibilityLabel(L10n.text("common.loading")) }
                    Button(L10n.text("common.refresh"), .refresh) { Task { await load(more: false) } }.buttonStyle(TeamButtonStyle()).disabled(loading)
                    if next != nil { Button(L10n.text("common.teams.load_more"), .more) { Task { await load(more: true) } }.buttonStyle(TeamButtonStyle()).disabled(loading) }
                }
            }
        } actions: {
            Button(L10n.text("common.done"), .done) { dismiss() }.buttonStyle(TeamButtonStyle()).keyboardShortcut(.cancelAction)
        }
        .task { await load(more: false) }
    }
    private func load(more: Bool) async {
        guard current, !loading else { return }
        loading = true; failed = false
        defer { loading = false }
        do {
            let page = try await storage.list(origin: owner.scope.origin, person: person, after: more ? next : nil)
            guard current else { return }
            entries = more ? entries + page.entries.filter { row in !entries.contains { $0.id == row.id } } : page.entries
            next = page.next; unreadable = (more && unreadable) || page.unreadable; loaded = true
        } catch { if current { failed = true } }
    }
}

private struct TeamSavedAskRow: View {
    let store: TeamStore
    let owner: TeamAccountOwner
    let storage: TeamAskRecoveryStore
    let entry: TeamAskRecoveryStore.Entry
    let copy: () -> Void
    @State private var opened = false
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let location = entry.snapshot.saved.location {
                Text(location.chat).font(Theme.headline).fixedSize(horizontal: false, vertical: true)
                Text([location.organization, location.repository, location.computer].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(entry.snapshot.record.text).font(Theme.body).textSelection(.enabled)
            Button(L10n.text("common.teams.copy_ask"), .copy, action: copy).buttonStyle(TeamButtonStyle())
            if opened {
                TeamSavedAskControls(store: store, owner: owner, storage: storage, entry: entry)
            } else {
                Button(L10n.text("common.teams.recover_ask"), .restore) { opened = true }.buttonStyle(TeamButtonStyle())
            }
        }.padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct TeamSavedAskControls: View {
    @State private var model: TeamAskModel
    let computer: String
    init(store: TeamStore, owner: TeamAccountOwner, storage: TeamAskRecoveryStore, entry: TeamAskRecoveryStore.Entry) {
        computer = entry.snapshot.saved.location?.computer ?? entry.target.host
        _model = State(initialValue: TeamAskModel(target: entry.target, storage: storage,
            current: { store.owner == owner && store.localDraftPersonId == entry.target.person && owner.scope.origin == entry.target.origin },
            call: { method, input in
                do { return try await store.recoverAsk(origin: entry.target.origin, person: entry.target.person, target: entry.target.fields, owner: owner, method: method, input: input) }
                catch let failure as TeamRequestFailure where method == "team.chat.ask" && ["team_run_review_changed", "invalid_ask", "team_agent_request_denied", "team_agent_runs_off"].contains(failure.code) {
                    throw TeamAskNotAccepted(message: failure.localizedDescription)
                }
                catch let failure as TeamRequestFailure where method == "team.chat.ask" && failure.code == "team_agent_approval_pending" {
                    throw TeamAskAwaitingApproval()
                }
            }))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TeamAskBar(model: model, computer: computer, refresh: {})
            if model.loaded, !model.pending, model.fence == nil, model.error == nil {
                Text(L10n.text("common.teams.ask_resolved")).font(Theme.callout).foregroundStyle(.secondary)
            }
        }
    }
}
