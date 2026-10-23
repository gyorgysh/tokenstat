// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Pick several chats once; each is shared only after its own current review.
struct TeamChatReviewEditor: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let repository: TeamRepository
    let checkout: TeamCheckout
    let transcript: (TeamChatHistory) -> AnyView
    let manageSharedChats: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chats: [TeamLocalChat] = []
    @State private var next: Int?
    @State private var picked: Set<String> = []
    @State private var selection: TeamChatSelection?
    @State private var preview: TeamChatPreview?
    @State private var checkedSaved = false
    @State private var confirmed = false
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var requestId = UUID().uuidString
    @State private var confirmsDiscard = false
    @State private var skipping: String?
    private var current: Bool { store.mutationContext == context && store.phase == .ready }
    private var busy: Bool { loading || saving || store.isMutating }
    private var target: [String: JSONValue] { ["organization":.string(repository.organizationId),"repository":.string(repository.id),"checkout":.string(checkout.id)] }

    var body: some View {
        ThemedSheet(title: L10n.text("common.teams.share_chat"), subtitle: repository.name, icon: .comment, scrolls: true,
            onClose: { if !saving { dismiss() } }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let error { TeamNotice(message: error, warning: true) }
                if !current { TeamNotice(message: L10n.text("common.teams.checkout_access_changed"), warning: true) }
                else if let preview { history(preview) }
                else if let selection { saved(selection) }
                else { chooser }
                if loading { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("common.loading")) }
                if error != nil || !checkedSaved {
                    Button(L10n.text("common.retry"), .refresh) { Task { await load() } }.buttonStyle(TeamButtonStyle()).disabled(busy || !current)
                }
            }
        } actions: {
            Button(L10n.text(preview == nil ? "common.close" : "common.back"), preview == nil ? .dismiss : .back) {
                if preview == nil { dismiss() } else { preview = nil; confirmed = false }
            }.buttonStyle(TeamButtonStyle()).disabled(saving).keyboardShortcut(.cancelAction).accessibilityIdentifier("team.chat.selection.close")
            Spacer(minLength: Theme.Space.m)
            if saving { ProgressView().controlSize(.small) }
            if current {
                if preview != nil {
                    Button(L10n.text("common.teams.share_chat"), .connect) { Task { await publish() } }
                        .buttonStyle(TeamButtonStyle(primary: true)).disabled(!confirmed || busy).accessibilityIdentifier("team.chat.selection.publish")
                } else if selection == nil {
                    Button(L10n.text("common.teams.review_selected_chats"), .preview) { Task { await begin() } }
                        .buttonStyle(TeamButtonStyle(primary: true)).disabled(picked.isEmpty || picked.count > 100 || !checkedSaved || busy).accessibilityIdentifier("team.chat.selection.begin")
                }
            }
        }
        .task { await load() }
        .interactiveDismissDisabled(saving)
        .onChange(of: picked) { requestId = UUID().uuidString }
        .confirmationDialog(L10n.text("common.teams.stop_chat_review"), isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button(L10n.text("common.teams.stop_chat_review"), role: .destructive) { Task { await discard() } }
        } message: { Text(L10n.text("common.teams.stop_chat_review_detail")) }
        .confirmationDialog(L10n.text("common.teams.keep_chat_private"), isPresented: Binding(get: { skipping != nil }, set: { if !$0 { skipping = nil } }), titleVisibility: .visible) {
            if let conversation = skipping { Button(L10n.text("common.teams.keep_chat_private")) { Task { await skip(conversation) } } }
        } message: { Text(L10n.text("common.teams.stop_chat_review_detail")) }
    }
    private var chooser: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(L10n.text("common.teams.select_existing_chats")).font(Theme.body).foregroundStyle(.secondary)
            ForEach(chats.filter { !$0.shared }) { chat in
                Toggle(chat.title, isOn: Binding(get: { picked.contains(chat.id) }, set: { if $0 { picked.insert(chat.id) } else { picked.remove(chat.id) } }))
                    .toggleStyle(.checkboxForTeam).disabled(busy || (!picked.contains(chat.id) && picked.count >= 100))
                    .accessibilityIdentifier("team.chat.selection.option.\(chat.id)")
            }
            if next != nil { Button(L10n.text("common.teams.load_more"), .more) { Task { await loadOptions(more: true) } }.buttonStyle(TeamButtonStyle()).disabled(busy) }
            if chats.allSatisfy(\.shared) && !loading { TeamNotice(message: L10n.text("common.teams.no_local_chats")) }
            Button(L10n.text("common.teams.manage_shared_chats"), .settings, action: manageSharedChats).buttonStyle(TeamButtonStyle()).disabled(busy)
        }
    }
    private func saved(_ selection: TeamChatSelection) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            TeamNotice(message: selection.complete ? L10n.text("common.teams.chat_review_finished") : L10n.text("common.teams.saved_chat_selection"))
            ForEach(selection.items) { item in
                Card(title: item.title ?? L10n.text("common.teams.shared_chat")) {
                    if item.shared { Text(L10n.text("common.teams.chat_is_shared")).font(Theme.callout).foregroundStyle(.secondary) }
                    else if item.skipped { Text(L10n.text("common.teams.chat_kept_private")).font(Theme.callout).foregroundStyle(.secondary) }
                    else {
                        Button(L10n.text("common.teams.review_sharing"), .preview) { Task { await review(item.conversation) } }
                            .buttonStyle(TeamButtonStyle()).disabled(busy || !item.available).accessibilityIdentifier("team.chat.selection.review.\(item.conversation)")
                        Button(L10n.text("common.teams.keep_chat_private"), .dismiss) { skipping = item.conversation }.buttonStyle(TeamButtonStyle()).disabled(busy)
                    }
                }
            }
            if !selection.complete { Button(L10n.text("common.teams.stop_chat_review"), .dismiss) { confirmsDiscard = true }.buttonStyle(TeamButtonStyle()).disabled(busy) }
        }
    }
    private func history(_ preview: TeamChatPreview) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(preview.history.title).font(Theme.headline).accessibilityAddTraits(.isHeader)
            LabeledContent(L10n.text("common.teams.repository_name"), value: repository.name)
            LabeledContent(L10n.text("common.teams.computer"), value: preview.deviceName)
            TeamNotice(message: L10n.text("common.teams.share_chat_audience", repository.name))
            Text(L10n.text("common.teams.share_chat_contents")).font(Theme.body).foregroundStyle(.secondary)
            Toggle(L10n.text("common.teams.share_chat_confirm"), isOn: $confirmed).toggleStyle(.checkboxForTeam).accessibilityIdentifier("team.chat.selection.confirm")
            ThemeRule()
            Text(L10n.text("common.teams.history_preview")).font(Theme.headline).accessibilityAddTraits(.isHeader)
            if preview.history.historyTrimmed { TeamNotice(message: L10n.text("common.teams.shared_history_trimmed")) }
            transcript(preview.history).environment(\.teamAvatarOwner, context.owner)
        }
    }
    private func accept(_ value: TeamChatSelection?) throws {
        if let value {
            guard value.organizationId == repository.organizationId, value.repositoryId == repository.id, value.checkoutId == checkout.id,
                  !value.allowsAgentRuns, !value.discarded else { throw CancellationError() }
        }
        selection = value
    }
    private func restore() async throws {
        let result: TeamChatSelectionReply = try await store.read(.chatSharingRead, fields: target, context: context)
        guard current else { throw CancellationError() }
        try accept(result.selection); checkedSaved = true; preview = nil; confirmed = false
    }
    private func load() async {
        guard current, !busy else { return }
        loading = true; error = nil; checkedSaved = false
        do { try await restore() } catch is CancellationError {} catch { if current { self.error = error.localizedDescription } }
        loading = false
        if current && checkedSaved && selection == nil { await loadOptions(more: false) }
    }
    private func loadOptions(more: Bool) async {
        guard current, !busy else { return }
        loading = true; defer { loading = false }
        do {
            var fields = target; fields["page"] = TeamStore.page(offset: more ? next ?? 0 : 0)
            let result: TeamLocalChats = try await store.read(.chatOptions, fields: fields, context: context)
            guard current else { return }
            chats = more ? chats + result.chats.filter { next in !chats.contains { $0.id == next.id } } : result.chats; next = result.nextOffset
        } catch is CancellationError {} catch { if current { self.error = error.localizedDescription } }
    }
    private func begin() async {
        guard current, !busy, checkedSaved, !picked.isEmpty, picked.count <= 100 else { return }
        saving = true; error = nil
        do {
            var fields = target; fields["conversations"] = .array(picked.sorted().map(JSONValue.string)); fields["requestId"] = .string(requestId); fields["confirmSelection"] = .bool(true)
            let result: TeamChatSelectionReply = try await store.perform(.chatSharingBegin, fields: fields, context: context)
            guard current else { throw CancellationError() }; try accept(result.selection)
        } catch is CancellationError {} catch { await failed(error) }
        saving = false
    }
    private func review(_ conversation: String) async {
        guard current, !busy, let selection else { return }
        loading = true; error = nil; confirmed = false; defer { loading = false }
        do {
            let result: TeamChatSelectionReply = try await store.read(.chatSharingPreview, fields: ["selection":.string(selection.id),"conversation":.string(conversation)], context: context)
            guard current, result.selection?.id == selection.id, let review = result.preview, review.conversation == conversation, review.checkoutId == checkout.id,
                  review.repository.id == repository.id, review.repository.organizationId == repository.organizationId,
                  review.audience == "currentAndFutureRepositoryMembers", !review.allowsAgentRuns else { throw CancellationError() }
            try accept(result.selection); preview = review
        } catch is CancellationError {} catch { if current { self.error = error.localizedDescription; preview = nil } }
    }
    private func publish() async {
        guard current, !busy, confirmed, let selection, let preview else { return }
        saving = true; error = nil; confirmed = false
        do {
            let result: TeamChatSelectionReply = try await store.perform(.chatSharingPublish, fields: ["selection":.string(selection.id),"conversation":.string(preview.conversation),"preview":.string(preview.preview),"confirmHistory":.bool(true)], context: context)
            guard current, result.selection?.id == selection.id else { throw CancellationError() }; try accept(result.selection); self.preview = nil
        } catch is CancellationError {} catch { await failed(error) }
        saving = false
        if error == nil, let next = self.selection?.items.first(where: \.pending) { await review(next.conversation) }
    }
    private func skip(_ conversation: String) async {
        guard current, !busy, let selection else { return }; skipping = nil
        saving = true; error = nil; defer { saving = false }
        do {
            let result: TeamChatSelectionReply = try await store.perform(.chatSharingSkip, fields: ["selection":.string(selection.id),"conversation":.string(conversation),"confirmSkip":.bool(true)], context: context)
            guard current, result.selection?.id == selection.id else { throw CancellationError() }; try accept(result.selection)
        } catch is CancellationError {} catch { await failed(error) }
    }
    private func discard() async {
        guard current, !busy, let selection else { return }
        saving = true; error = nil
        do {
            let _: TeamChatSelectionReply = try await store.perform(.chatSharingDiscard, fields: ["selection":.string(selection.id),"confirmDiscard":.bool(true)], context: context)
            guard current else { throw CancellationError() }; self.selection = nil; preview = nil; picked = []; requestId = UUID().uuidString
        } catch is CancellationError {} catch { await failed(error) }
        saving = false
        if self.selection == nil { await loadOptions(more: false) }
    }
    private func failed(_ failure: Error) async {
        guard current else { return }; preview = nil; confirmed = false; checkedSaved = false
        do { try await restore() } catch { /* Keep selection locked until a successful read. */ }
        if current { error = failure.localizedDescription }
    }
}
