// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct TeamChatShareEditor: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let repository: TeamRepository
    let checkout: TeamCheckout
    let transcript: (TeamChatHistory) -> AnyView
    @Environment(\.dismiss) private var dismiss
    @State private var chats: [TeamLocalChat] = []
    @State private var chatsNext: Int?
    @State private var local: [TeamLocalChatPublication] = []
    @State private var localNext: Int?
    @State private var selectedId: String?
    @State private var preview: TeamChatPreview?
    @State private var stopping: TeamLocalChatPublication?
    @State private var confirmed = false
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var requestId = UUID().uuidString
    @State private var managingSharedChats = false
    private var isCurrent: Bool { store.mutationContext == context && store.phase == .ready }
    private var target: [String: JSONValue] { ["organization":.string(repository.organizationId),"repository":.string(repository.id),"checkout":.string(checkout.id)] }

    var body: some View {
        if store.capabilities?.canReviewChatSelection == true && !managingSharedChats {
            TeamChatReviewEditor(store: store, context: context, repository: repository, checkout: checkout, transcript: transcript,
                manageSharedChats: { managingSharedChats = true })
        } else { singleChatEditor }
    }
    private var singleChatEditor: some View {
        ThemedSheet(title: L10n.text("common.teams.share_chat"), subtitle: repository.name, icon: .comment, scrolls: true, onClose: { if !saving { dismiss() } }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let error { TeamNotice(message: error, warning: true) }
                if !isCurrent { TeamNotice(message: L10n.text("common.teams.checkout_access_changed"), warning: true) }
                else if let stopping { stopReview(stopping) }
                else if let preview { historyReview(preview) }
                else { chooser }
                if loading { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("common.loading")) }
            }
        } actions: {
            Button(preview == nil && stopping == nil ? L10n.text("common.close") : L10n.text("common.back"), preview == nil && stopping == nil ? .dismiss : .back) {
                if preview == nil && stopping == nil { dismiss() }
                else { preview = nil; stopping = nil; confirmed = false; error = nil; Task { await load() } }
            }.buttonStyle(TeamButtonStyle()).disabled(saving).keyboardShortcut(.cancelAction)
            Spacer(minLength: Theme.Space.m)
            if saving { ProgressView().controlSize(.small) }
            if isCurrent {
                if stopping != nil {
                    Button(L10n.text("common.teams.stop_sharing"), .revoke, role: .destructive) { Task { await withdraw() } }.buttonStyle(TeamButtonStyle(primary: true)).disabled(!confirmed || saving || loading).accessibilityIdentifier("team.chat.stop")
                } else if preview != nil {
                    Button(L10n.text("common.teams.share_chat"), .connect) { Task { await publish() } }.buttonStyle(TeamButtonStyle(primary: true)).disabled(!confirmed || saving || loading).accessibilityIdentifier("team.chat.publish")
                } else {
                    Button(L10n.text("common.teams.review_sharing"), .preview) { Task { await review() } }.buttonStyle(TeamButtonStyle(primary: true)).disabled(selectedId == nil || saving || loading).accessibilityIdentifier("team.chat.review")
                }
            }
        }
        .task { await load() }
        .interactiveDismissDisabled(saving)
        .onChange(of: selectedId) { preview = nil; confirmed = false; requestId = UUID().uuidString }
    }
    private var chooser: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(L10n.text("common.teams.share_chat_intro")).font(Theme.body).foregroundStyle(.secondary)
            TeamPickerField(title: L10n.text("common.teams.chat"), selection: $selectedId) {
                Text(L10n.text("common.teams.choose_chat")).tag(Optional<String>.none)
                ForEach(chats.filter { !$0.shared }) { Text($0.title).tag(Optional($0.id)) }
            }.disabled(loading || saving).accessibilityIdentifier("team.chat.picker")
            if chatsNext != nil { Button(L10n.text("common.teams.load_more"), .more) { Task { await loadOptions(more: true) } }.buttonStyle(TeamButtonStyle()).disabled(loading || saving) }
            if chats.isEmpty && !loading { TeamNotice(message: L10n.text("common.teams.no_local_chats")) }
            if !local.isEmpty {
                Text(L10n.text("common.teams.your_shared_chats")).font(Theme.headline).accessibilityAddTraits(.isHeader)
                ForEach(local) { row in
                    Card(title: chats.first { $0.id == row.conversationId }?.title ?? L10n.text("common.teams.shared_chat")) {
                        Text(row.accountCleanupPending ? L10n.text("common.teams.cleanup_pending") : row.phase == "prepared" ? L10n.text("common.teams.publication_pending") : L10n.text("common.teams.chat_is_shared")).font(Theme.callout).foregroundStyle(.secondary)
                        Button(row.accountCleanupPending ? L10n.text("common.teams.retry_cleanup") : L10n.text("common.teams.stop_sharing"), .revoke) { stopping = row; confirmed = false; error = nil }.buttonStyle(TeamButtonStyle()).disabled(loading || saving)
                    }
                }
                if localNext != nil { Button(L10n.text("common.teams.load_more"), .more) { Task { await loadPublications(more: true) } }.buttonStyle(TeamButtonStyle()).disabled(loading || saving) }
            }
            if error != nil { Button(L10n.text("common.retry"), .refresh) { Task { await load() } }.buttonStyle(TeamButtonStyle()).disabled(loading || saving) }
        }
    }
    private func historyReview(_ preview: TeamChatPreview) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(preview.history.title).font(Theme.headline).accessibilityAddTraits(.isHeader)
            LabeledContent(L10n.text("common.teams.repository_name"), value: preview.repository.name)
            LabeledContent(L10n.text("common.teams.computer"), value: preview.deviceName)
            TeamNotice(message: L10n.text("common.teams.share_chat_audience", preview.repository.name))
            Text(L10n.text("common.teams.share_chat_contents")).font(Theme.body).foregroundStyle(.secondary)
            Toggle(L10n.text("common.teams.share_chat_confirm"), isOn: $confirmed).toggleStyle(.checkboxForTeam).accessibilityIdentifier("team.chat.confirm")
            ThemeRule()
            Text(L10n.text("common.teams.history_preview")).font(Theme.headline).accessibilityAddTraits(.isHeader)
            if preview.history.historyTrimmed { TeamNotice(message: L10n.text("common.teams.shared_history_trimmed")) }
            transcript(preview.history).environment(\.teamAvatarOwner, context.owner)
        }
    }
    private func stopReview(_ row: TeamLocalChatPublication) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(chats.first { $0.id == row.conversationId }?.title ?? L10n.text("common.teams.shared_chat")).font(Theme.headline)
            TeamNotice(message: L10n.text("common.teams.stop_chat_sharing_detail"), warning: true)
            Toggle(L10n.text("common.teams.stop_chat_sharing_confirm"), isOn: $confirmed).toggleStyle(.checkboxForTeam).accessibilityIdentifier("team.chat.stop.confirm")
        }
    }
    private func load() async {
        error = nil
        await loadOptions(more: false)
        if isCurrent { await loadPublications(more: false) }
    }
    private func loadOptions(more: Bool) async {
        guard isCurrent, !loading else { return }
        loading = true; defer { loading = false }
        do {
            var fields = target; fields["page"] = TeamStore.page(offset: more ? chatsNext ?? 0 : 0)
            let result: TeamLocalChats = try await store.read(.chatOptions, fields: fields, context: context)
            guard isCurrent else { return }
            chats = more ? chats + result.chats.filter { next in !chats.contains { $0.id == next.id } } : result.chats
            chatsNext = result.nextOffset
            if let selectedId, !chats.contains(where: { $0.id == selectedId && !$0.shared }) { self.selectedId = nil }
        } catch is CancellationError {} catch { if isCurrent { self.error = error.localizedDescription } }
    }
    private func loadPublications(more: Bool) async {
        guard isCurrent, !loading else { return }
        loading = true; defer { loading = false }
        do {
            var fields = target; fields["page"] = TeamStore.page(offset: more ? localNext ?? 0 : 0)
            let result: TeamLocalChatPublications = try await store.read(.chatList, fields: fields, context: context)
            guard isCurrent else { return }
            local = more ? local + result.publications.filter { next in !local.contains { $0.id == next.id } } : result.publications
            localNext = result.nextOffset
        } catch is CancellationError {} catch { if isCurrent { self.error = error.localizedDescription } }
    }
    private func review() async {
        guard isCurrent, !loading, !saving, let selectedId else { return }
        loading = true; error = nil; defer { loading = false }
        do {
            var fields = target; fields["conversation"] = .string(selectedId)
            let result: TeamChatPreview = try await store.read(.chatPreview, fields: fields, context: context)
            guard isCurrent, self.selectedId == selectedId, result.conversation == selectedId, result.checkoutId == checkout.id, result.repository.id == repository.id, result.repository.organizationId == repository.organizationId,
                  result.audience == "currentAndFutureRepositoryMembers", !result.allowsAgentRuns else { throw CancellationError() }
            preview = result; confirmed = false
        } catch is CancellationError {} catch { if isCurrent { self.error = error.localizedDescription } }
    }
    private func publish() async {
        guard isCurrent, confirmed, !saving, let preview else { return }
        saving = true; error = nil; defer { saving = false }
        do {
            var fields = target; fields["conversation"] = .string(preview.conversation); fields["preview"] = .string(preview.preview)
            fields["requestId"] = .string(requestId); fields["confirmHistory"] = .bool(true)
            let result: TeamChatPublished = try await store.perform(.chatPublish, fields: fields, context: context)
            guard isCurrent, result.publication.checkoutId == checkout.id else { throw CancellationError() }
            dismiss()
        } catch is CancellationError {} catch {
            guard isCurrent else { return }
            self.error = error.localizedDescription
            if let failure = error as? TeamRequestFailure, failure.code == "chat_history_changed" {
                self.preview = nil; confirmed = false; requestId = UUID().uuidString
            }
        }
    }
    private func withdraw() async {
        guard isCurrent, confirmed, !saving, let stopping else { return }
        saving = true; error = nil; defer { saving = false }
        do {
            var fields = target; fields["share"] = .string(stopping.id); fields["expectedRevision"] = .uint(stopping.revision)
            let _: TeamCheckoutWithdrawn = try await store.perform(.chatWithdraw, fields: fields, context: context)
            guard isCurrent else { throw CancellationError() }
            self.stopping = nil; confirmed = false
            await load()
        } catch is CancellationError {} catch { if isCurrent { self.error = error.localizedDescription } }
    }
}
