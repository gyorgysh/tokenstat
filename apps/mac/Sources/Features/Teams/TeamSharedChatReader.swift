// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct TeamSharedChatReader: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let repository: TeamRepository
    let checkout: TeamCheckout
    let share: TeamSharedChat
    let transcript: (TeamChatHistory) -> AnyView
    let back: () -> Void
    @State private var summary: TeamChatSummary?
    @State private var events: [JSONValue] = []
    @State private var renderedHistory: TeamChatHistory?
    @State private var cursor: String?
    @State private var hasMore = false
    @State private var asOf: Date?
    @State private var loading = false
    @State private var error: String?
    @State private var loadId = UUID()
    @State private var windowed = false
    @State private var reloadAfterRead = false
    @State private var editingComment = false
    @State private var pendingComment = false
    @State private var loadedEarlier = false
    @Environment(\.teamCommentDraftStorage) private var commentStorage
    @Environment(\.dynamicTypeSize) private var textSize
    private var isCurrent: Bool {
        store.mutationContext == context && store.phase == .ready && context.organizationId == repository.organizationId
            && checkout.organizationId == repository.organizationId && checkout.repositoryId == repository.id && share.checkoutId == checkout.id
    }

    var body: some View {
        VStack(spacing: 0) {
            if !editingComment {
                Group {
                if textSize.isAccessibilitySize {
                    HStack(alignment: .top, spacing: Theme.Space.s) { header; refresh }
                } else {
                ViewThatFits(in: .horizontal) {
                    HStack { header; Spacer(minLength: Theme.Space.m); refresh }
                    VStack(alignment: .leading, spacing: Theme.Space.s) { header; refresh }
                }
                }
                }.padding(Theme.Space.m).background(Theme.panel)
            }
            if let error { TeamNotice(message: error, warning: true).padding(Theme.Space.m) }
            if let summary {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                            if hasMore {
                                Button(L10n.text("common.teams.load_earlier"), .history) { Task { await load(earlier: true) } }.buttonStyle(TeamButtonStyle()).disabled(loading)
                            }
                            if summary.historyTrimmed { TeamNotice(message: L10n.text("common.teams.shared_history_trimmed")) }
                            if windowed { TeamNotice(message: L10n.text("common.teams.shared_history_window")) }
                            if let renderedHistory { transcript(renderedHistory).environment(\.teamAvatarOwner, context.owner) }
                            if events.isEmpty && !loading { Text(L10n.text("common.teams.no_chat_messages")).font(Theme.body).foregroundStyle(.secondary) }
                            Color.clear.frame(height: 1).id("team-history-end")
                        }.frame(maxWidth: 1000).frame(maxWidth: .infinity).padding(Theme.Space.l)
                    }
                    .onPreferenceChange(TeamTranscriptRenderedKey.self) { rendered in
                        guard rendered == renderedHistory?.renderId, !loadedEarlier else { return }
                        let selection = loadId
                        Task { @MainActor in
                            await Task.yield()
                            guard isCurrent, loadId == selection else { return }
                            proxy.scrollTo("team-history-end", anchor: .bottom)
                        }
                    }
                }
            } else if loading {
                TeamLoadingView()
            } else {
                EmptyState(symbol: "wifi.exclamationmark", title: L10n.text("common.teams.chat_unavailable"), message: L10n.text("common.teams.shared_host_needed"))
            }
            Spacer(minLength: 0)
            ThemeRule()
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if !editingComment, !pendingComment, let asOf {
                    Text(L10n.text("common.teams.history_checked", asOf.formatted(date: .abbreviated, time: .shortened))).font(Theme.caption).foregroundStyle(.secondary)
                }
                if summary?.allowsComments != true, !pendingComment {
                    Text(L10n.text("common.teams.shared_read_only")).font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let summary, let person = store.capabilities?.actorId, isCurrent {
                    let target = TeamCommentTarget(origin: context.owner.scope.origin, person: person, organization: repository.organizationId, repository: repository.id, checkout: checkout.id, share: share.id, host: checkout.hostKey)
                    TeamCommentComposer(store: store, context: context, target: target, allowsComments: summary.allowsComments == true, storage: commentStorage, presentationChanged: { focused, pending in
                        #if os(iOS)
                        editingComment = focused
                        #endif
                        pendingComment = pending
                    }) {
                        if loading { reloadAfterRead = true } else { Task { await load(earlier: false) } }
                    }.id(target)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.m).background(Theme.panel)
        }
        .task { await load(earlier: false) }
        .onDisappear { loadId = UUID(); loading = false; reloadAfterRead = false }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Button(L10n.text("common.teams.chats"), .back, action: back).buttonStyle(TeamButtonStyle()).accessibilityIdentifier("team.chat.back")
                .environment(\.compactActions, textSize.isAccessibilitySize)
                .frame(minWidth: 44, minHeight: 44)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(summary?.title ?? L10n.text("common.teams.shared_chat")).font(Theme.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                Text([repository.name, checkout.deviceName ?? L10n.text("common.teams.computer"), checkout.publisher?.name].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
        }
    }
    private var refresh: some View {
        HStack(spacing: Theme.Space.s) {
            if loading { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("common.loading")) }
            Button(L10n.text("common.refresh"), .refresh) { Task { await load(earlier: false) } }.buttonStyle(TeamButtonStyle()).disabled(loading)
                .environment(\.compactActions, textSize.isAccessibilitySize)
                .frame(minWidth: 44, minHeight: 44)
        }
    }
    private func fields(_ method: String, params: [String: JSONValue] = [:]) -> [String: JSONValue] {
        ["target":.object(["organization":.string(repository.organizationId),"repository":.string(repository.id),"checkout":.string(checkout.id),"share":.string(share.id)]),"method":.string(method),"params":.object(params)]
    }
    private func load(earlier: Bool) async {
        guard isCurrent, !loading, !earlier || hasMore else { return }
        let id = UUID(); loadId = id; loading = true; error = nil
        defer {
            if loadId == id {
                loading = false
                if reloadAfterRead, isCurrent {
                    reloadAfterRead = false
                    Task { await load(earlier: false) }
                }
            }
        }
        do {
            let details: TeamChatDetails
            if earlier, let summary { details = TeamChatDetails(chat: summary) }
            else { details = try await store.read(.connectionCall, fields: fields("team.chat.details"), context: context) }
            var params: [String:JSONValue] = ["direction":.string("older"),"limit":.int(100)]
            if earlier, let cursor { params["cursor"] = .string(cursor) }
            let page: TeamChatEvents = try await store.read(.connectionCall, fields: fields("team.chat.events",params:params), context: context)
            guard isCurrent, loadId == id, details.chat.id == share.id, details.chat.checkoutId == checkout.id, page.shareId == share.id else { throw CancellationError() }
            // Keep a bounded window. Refresh returns to the latest page; a
            // long archive cannot grow this view's memory without a limit.
            let combined = earlier ? page.events + events : page.events
            let bounded = try await Task.detached(priority: .userInitiated) {
                var size = 0, kept: [JSONValue] = []
                for event in combined.prefix(2000) {
                    size += try JSONEncoder().encode(event).count
                    if size > 8 * 1024 * 1024 { break }
                    kept.append(event)
                }
                return kept
            }.value
            guard isCurrent, loadId == id else { throw CancellationError() }
            if page.hasMore && (page.events.isEmpty || earlier && page.nextCursor == cursor) {
                throw TeamRequestFailure(code: "invalid_response", message: L10n.text("common.teams.history_cannot_display"))
            }
            windowed = earlier && (windowed || bounded.count < combined.count)
            summary = details.chat; events = bounded; cursor = page.nextCursor; hasMore = page.hasMore; loadedEarlier = earlier
            renderedHistory = TeamChatHistory(title: details.chat.title, backend: details.chat.backend, historyTrimmed: details.chat.historyTrimmed, events: bounded)
            asOf = Date(timeIntervalSince1970: Double(page.asOfMs) / 1000)
        } catch is CancellationError {} catch {
            guard isCurrent, loadId == id else { return }
            self.error = error.localizedDescription
            if let error = error as? TeamRequestFailure, !["team_connection_unavailable","teams_unreachable","teams_busy","chat_window_full"].contains(error.code) {
                summary = nil; events = []; renderedHistory = nil; cursor = nil; hasMore = false; asOf = nil
            }
        }
    }
}
