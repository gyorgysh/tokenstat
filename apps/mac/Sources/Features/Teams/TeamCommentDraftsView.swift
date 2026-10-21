// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Local writing is available even after its original audience is withdrawn.
/// This surface has no network or send action.
struct TeamCommentDraftsView: View {
    let origin: String
    let person: String
    let storage: TeamCommentDraftStore
    let isCurrent: () -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.teamCopy) private var copy
    @State private var entries: [TeamCommentDraftStore.Entry] = []
    @State private var next: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var unreadable = false
    @State private var removing: TeamCommentDraftStore.Entry?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("common.teams.comment_drafts")).font(Theme.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: Theme.Space.s)
                Button(L10n.text("common.done")) { dismiss() }.buttonStyle(TeamButtonStyle())
            }.padding(Theme.Space.m)
            ThemeRule()
            if isCurrent() {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        Text(L10n.text("common.teams.comment_drafts_detail")).font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let error { TeamNotice(message: error, warning: true) }
                        if unreadable { TeamNotice(message: L10n.text("common.teams.comment_drafts_unreadable"), warning: true) }
                        if loaded, entries.isEmpty, next == nil, !unreadable {
                            Text(L10n.text("common.teams.no_comment_drafts")).font(Theme.body).foregroundStyle(.secondary).accessibilityIdentifier("team.drafts.empty")
                        }
                        ForEach(entries) { entry in row(entry) }
                        if loading { ProgressView().accessibilityLabel(L10n.text("common.loading")) }
                        Button(next == nil ? L10n.text("common.refresh") : L10n.text("common.teams.load_more"), .refresh) { Task { await load(more: next != nil) } }
                            .buttonStyle(TeamButtonStyle()).disabled(loading)
                    }.padding(Theme.Space.l).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Theme.background).tint(TeamColors.action)
        .task { await load(more: false) }
        .alert(L10n.text("common.teams.remove_local_draft"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L10n.text("common.cancel"), role: .cancel) { removing = nil }
            Button(L10n.text("common.teams.remove_draft"), role: .destructive) {
                guard let entry = removing else { return }
                removing = nil
                Task { await remove(entry) }
            }
        } message: { Text(L10n.text("common.teams.remove_local_draft_detail")) }
    }
    private func row(_ entry: TeamCommentDraftStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let location = entry.draft?.location ?? entry.unsaved?.location {
                if !location.chat.isEmpty { Text(location.chat).font(Theme.headline).fixedSize(horizontal: false, vertical: true) }
                Text([location.organization, location.repository, location.computer].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(entry.draft?.attempt == nil ? L10n.text("common.teams.saved_comment_draft") : L10n.text("common.teams.comment_unconfirmed"))
                .font(Theme.callout.weight(.semibold)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let draft = entry.draft {
                Text(draft.text).font(Theme.body).lineLimit(8).textSelection(.enabled)
                Button(L10n.text("common.teams.copy_draft"), .copy) { if isCurrent() { copy(draft.text) } }.buttonStyle(TeamButtonStyle())
            }
            if let writing = entry.unsaved, writing.text != entry.draft?.text {
                Text(L10n.text("common.teams.unsaved_comment_copy")).font(Theme.caption.weight(.semibold))
                Text(writing.text).font(Theme.body).lineLimit(8).textSelection(.enabled)
                Button(L10n.text("common.teams.copy_unsaved_text"), .copy) { if isCurrent() { copy(writing.text) } }.buttonStyle(TeamButtonStyle())
            }
            Button(L10n.text("common.teams.remove_draft"), .delete, role: .destructive) { removing = entry }
                .buttonStyle(TeamButtonStyle()).disabled(loading).accessibilityIdentifier("team.drafts.remove")
        }.padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
    private func load(more: Bool) async {
        guard isCurrent(), !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let page = try await storage.list(origin: origin, person: person, after: more ? next : nil)
            guard isCurrent() else { return }
            entries = more ? entries + page.entries.filter { row in !entries.contains { $0.id == row.id } } : page.entries
            next = page.next; unreadable = (more && unreadable) || page.unreadable; loaded = true
        } catch { if isCurrent() { self.error = L10n.text("common.teams.comment_drafts_unreadable") } }
    }
    private func remove(_ entry: TeamCommentDraftStore.Entry) async {
        guard isCurrent(), !loading else { return }
        loading = true; error = nil
        do {
            try await storage.discard(entry)
            guard isCurrent() else { loading = false; return }
            entries.removeAll { $0.id == entry.id }
        } catch { if isCurrent() { self.error = (error as? TeamCommentDraftFailure)?.localizedDescription ?? L10n.text("common.teams.comment_drafts_unreadable") } }
        loading = false
    }
}
