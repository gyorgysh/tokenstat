// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// A project's chats stay visible across publishing computers. Choosing a
/// computer is only necessary when starting work or narrowing this list.
struct TeamProjectChatGroup: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let repository: TeamRepository
    let checkout: TeamCheckout
    let refresh: UUID
    let open: (TeamSharedChat) -> Void
    let start: (() -> Void)?
    @State private var shares: [TeamSharedChat] = []
    @State private var cursor: String?
    @State private var offset: Int?
    @State private var usesCatalog = true
    @State private var loading = false
    @State private var loaded = false
    @State private var hasLoadedMore = false
    @State private var error: String?
    @State private var request = UUID()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Card(title: checkout.deviceName ?? L10n.text("common.teams.computer"), subtitle: checkout.publisher?.name, mark: "mark_device",
            accessory: start.map { start in AnyView(Button(L10n.text("common.teams.new_chat"), .create, action: start).buttonStyle(TeamSmallButtonStyle())) }) {
            if let error {
                TeamNotice(message: error, warning: true)
                Button(L10n.text("common.retry"), .refresh) { Task { await load(more: false) } }.buttonStyle(TeamSmallButtonStyle())
            }
            TeamRows(items: shares) { share in
                Button { open(share) } label: {
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: ActionIcon.comment.symbol).foregroundStyle(TeamColors.action).frame(width: 20)
                        Text(share.title.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("common.teams.shared_chat"))
                            .font(Theme.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                        Spacer(minLength: Theme.Space.s)
                        TeamChatActivityBadge(store: store, share: share, repository: repository, checkout: checkout)
                    }
                }.buttonStyle(TeamListRowButtonStyle()).accessibilityIdentifier("team.chats.open.\(share.id)")
            }
            if loaded && shares.isEmpty && error == nil {
                Text(L10n.text("common.teams.no_shared_chats")).font(Theme.callout).foregroundStyle(.secondary)
            }
            if loading && shares.isEmpty { ProgressView().controlSize(.small) }
            if cursor != nil || offset != nil {
                Button(L10n.text("common.teams.load_more"), .more) { Task { await load(more: true) } }.buttonStyle(TeamSmallButtonStyle()).disabled(loading)
            }
        }
            .task(id: refresh) { await load(more: false) }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    // Preserve a person's expanded pages, including sparse
                    // catalogs whose visible row count is less than a page.
                    guard scenePhase == .active, !loading, !hasLoadedMore else { continue }
                    await load(more: false, background: true)
                }
            }
    }

    private func load(more: Bool, background: Bool = false) async {
        if more && loading { return }
        let id = UUID(); request = id; loading = true
        if !more && !background { usesCatalog = true; cursor = nil; offset = nil; hasLoadedMore = false }
        defer { if request == id { loading = false } }
        do {
            var catalog: TeamChatCatalog?
            if usesCatalog {
                var params: [String: JSONValue] = ["limit": .int(100)]
                if more, let cursor { params["cursor"] = .string(cursor) }
                do {
                    catalog = try await store.read(.connectionCall, fields: ["target": .object([
                        "organization": .string(repository.organizationId), "repository": .string(repository.id), "checkout": .string(checkout.id)]),
                        "method": .string("team.chat.catalog"), "params": .object(params)], context: context)
                } catch let failure as TeamRequestFailure where ["team_method_required", "unknown_method"].contains(failure.code) {
                    guard request == id else { return }
                    usesCatalog = false
                }
            }
            let rows: [TeamSharedChat], nextCursor: String?, nextOffset: Int?
            if let catalog { rows = catalog.shares; nextCursor = catalog.nextCursor; nextOffset = nil }
            else {
                let page: TeamSharedChats = try await store.read("chats.list", fields: ["organization": .string(repository.organizationId),
                    "checkout": .string(checkout.id), "page": TeamStore.page(offset: more ? offset ?? 0 : 0)], context: context)
                rows = page.shares; nextOffset = page.nextOffset; nextCursor = nil
            }
            guard request == id, store.mutationContext == context, rows.allSatisfy({ $0.checkoutId == checkout.id }) else { return }
            store.chatReadState.refresh()
            if more { hasLoadedMore = true }
            shares = more ? shares + rows.filter { next in !shares.contains { $0.id == next.id } } : rows
            if let pending = store.pendingShareId, let share = shares.first(where: { $0.id == pending }) {
                store.pendingShareId = nil
                open(share)
            }
            cursor = nextCursor; offset = nextOffset; loaded = true; error = nil
        } catch is CancellationError {} catch {
            if request == id, store.mutationContext == context { self.error = error.localizedDescription }
        }
    }
}
