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
    @State private var mode: TeamComposerMode = .comment
    @Environment(\.teamCommentDraftStorage) private var commentStorage
    @Environment(\.teamAskRecoveryStorage) private var askStorage
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.scenePhase) private var scenePhase
    private var isCurrent: Bool {
        store.mutationContext == context && store.phase == .ready && context.organizationId == repository.organizationId
            && checkout.organizationId == repository.organizationId && checkout.repositoryId == repository.id && share.checkoutId == checkout.id
    }

    private var canComment: Bool { summary?.allowsComments == true }
    private var canAsk: Bool { summary?.allowsAgentRuns == true }
    /// A comment waiting on delivery keeps the composer on comments until it
    /// lands. Otherwise the composer follows what this chat allows.
    private var activeMode: TeamComposerMode {
        if pendingComment || !canAsk { return .comment }
        if !canComment { return .ask }
        return mode
    }

    var body: some View {
        VStack(spacing: 0) {
            if !editingComment { header }
            if let error { TeamNotice(message: error, warning: true).frame(maxWidth: ReadingRoom.laneWidth).padding(.horizontal, Theme.Space.l).padding(.top, Theme.Space.m).frame(maxWidth: .infinity) }
            if let summary {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                            if hasMore {
                                Button(L10n.text("common.teams.load_earlier"), .history) { Task { await load(earlier: true) } }.buttonStyle(TeamButtonStyle()).disabled(loading)
                                    .frame(maxWidth: .infinity)
                            }
                            if summary.historyTrimmed { TeamNotice(message: L10n.text("common.teams.shared_history_trimmed")) }
                            if windowed { TeamNotice(message: L10n.text("common.teams.shared_history_window")) }
                            if let renderedHistory {
                                transcript(renderedHistory).environment(\.teamAvatarOwner, context.owner)
                                    .environment(\.teamAttachmentLoader, { id in try await attachment(id) })
                            }
                            if events.isEmpty && !loading {
                                EmptyState(symbol: "bubble.left.and.bubble.right", title: summary.title, message: L10n.text("common.teams.no_chat_messages"))
                            }
                            Color.clear.frame(height: 1).id("team-history-end")
                        }
                        .frame(maxWidth: ReadingRoom.laneWidth)
                        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.l)
                        .frame(maxWidth: .infinity)
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
            composer
        }
        .task { await load(earlier: false) }
        .task(id: share.id) {
            // Reading only: new comments and agent output appear while the
            // chat is open. Paused while someone is writing or paging back.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, isCurrent, !loading, !editingComment, !pendingComment, !loadedEarlier else { continue }
                await load(earlier: false)
            }
        }
        .onDisappear { loadId = UUID(); loading = false; reloadAfterRead = false }
    }
    /// The same dock the main chat uses: one well in the reading lane, on
    /// the page ground, under a hairline.
    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if canComment && canAsk && !pendingComment {
                SegmentedTabs(options: TeamComposerMode.allCases, selection: $mode, title: { $0.label }, comfortable: compactTouch)
                    .frame(maxWidth: 280)
                    .accessibilityLabel(L10n.text("common.teams.composer_mode"))
            }
            if summary != nil && !canComment && !canAsk && !pendingComment {
                Text(L10n.text("common.teams.shared_read_only")).font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let person = store.capabilities?.actorId, isCurrent {
                let target = TeamCommentTarget(origin: context.owner.scope.origin, person: person, organization: repository.organizationId, repository: repository.id, checkout: checkout.id, share: share.id, host: checkout.hostKey)
                let location = TeamCommentLocation(organization: store.selectedOrganization?.name ?? "", repository: repository.name, chat: summary?.title ?? share.title ?? L10n.text("common.teams.shared_chat"), computer: checkout.deviceName ?? "")
                TeamCommentComposer(store: store, context: context, target: target, allowsComments: canComment, storage: commentStorage, location: location, visible: activeMode == .comment, presentationChanged: { focused, pending in
                    #if os(iOS)
                    editingComment = focused
                    #endif
                    pendingComment = pending
                }) {
                    if loading { reloadAfterRead = true } else { Task { await load(earlier: false) } }
                }.id(target)
                TeamAskBar(store: store, context: context, target: target, computer: checkout.deviceName ?? L10n.text("common.teams.computer"),
                    allowsAgentRuns: canAsk, storage: askStorage, location: location, visible: activeMode == .ask) {
                        if loading { reloadAfterRead = true } else { Task { await load(earlier: false) } }
                    }.id(target)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(showsWell ? Theme.Space.m : 0)
        .background(showsWell ? Theme.panel : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(showsWell ? Theme.border : .clear, lineWidth: 1))
        .frame(maxWidth: ReadingRoom.laneWidth)
        .padding(.horizontal, Theme.Space.l)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.background)
        .overlay(alignment: .top) { ThemeRule() }
    }
    /// Nothing to write into until the chat has said what it allows, so no
    /// empty well while it loads. A comment waiting on delivery still shows.
    private var showsWell: Bool { summary != nil || pendingComment }
    private var compactTouch: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            ToolbarIconButton(systemImage: "chevron.left", help: L10n.text("common.teams.section_chats"), action: back)
                .accessibilityLabel(L10n.text("common.teams.section_chats"))
                .accessibilityIdentifier("team.chat.back")
            VStack(alignment: .leading, spacing: 2) {
                Text(summary?.title ?? share.title ?? L10n.text("common.teams.shared_chat")).font(Theme.headline).lineLimit(textSize.isAccessibilitySize ? 3 : 1).accessibilityAddTraits(.isHeader)
                Text([repository.name, checkout.deviceName ?? L10n.text("common.teams.computer"), checkout.publisher?.name].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.caption).foregroundStyle(.secondary).lineLimit(textSize.isAccessibilitySize ? 3 : 1)
            }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            if !textSize.isAccessibilitySize, !pendingComment, let asOf {
                Text(L10n.text("common.teams.history_checked", asOf.formatted(date: .omitted, time: .shortened)))
                    .font(Theme.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .help(asOf.formatted(date: .abbreviated, time: .standard))
            }
            ToolbarIconButton(systemImage: "arrow.clockwise", help: L10n.text("common.refresh"), isBusy: loading, isEnabled: !loading) { Task { await load(earlier: false) } }
                .accessibilityLabel(L10n.text("common.refresh"))
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
        .frame(minHeight: 52)
        .background(Theme.background)
        .overlay(alignment: .bottom) { ThemeRule() }
    }
    private func attachment(_ id: String) async throws -> TeamAttachmentFile {
        let reply: TeamAttachmentReply
        do {
            reply = try await store.read(.connectionCall, fields: fields("team.chat.attachment", params: ["attachment":.string(id)]), context: context)
        } catch let failure as TeamRequestFailure where ["team_method_required", "unknown_method"].contains(failure.code) {
            throw TeamRequestFailure(code: failure.code, message: L10n.text("common.teams.file_needs_update"))
        }
        guard reply.shareId == share.id, reply.attachment.id == id, let data = TeamAttachmentLimits.decode(reply.data, size: reply.attachment.size) else {
            throw TeamRequestFailure(code: "invalid_response", message: L10n.text("common.teams.file_unavailable"))
        }
        return TeamAttachmentFile(name: reply.attachment.name, mediaType: reply.attachment.mediaType, data: data)
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
            if !earlier, scenePhase == .active {
                let latest = page.events.compactMap { event -> Int64? in
                    guard case let .object(fields) = event, case let .int(at)? = fields["atMs"] else { return nil }
                    return at
                }.max()
                store.chatReadState.markRead(share, repository: repository, checkout: checkout, through: latest)
            }
        } catch is CancellationError {} catch {
            guard isCurrent, loadId == id else { return }
            self.error = error.localizedDescription
            if let error = error as? TeamRequestFailure, !["team_connection_unavailable","teams_unreachable","teams_busy","chat_window_full"].contains(error.code) {
                summary = nil; events = []; renderedHistory = nil; cursor = nil; hasMore = false; asOf = nil
            }
        }
    }
}
