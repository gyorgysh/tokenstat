// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Team navigation has its own reader. It never selects a private ChatModel,
/// changes WorkSessionContext, or loads another person's personal archive.
struct TeamSharedChatsView: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let repositories: [TeamRepository]
    let transcript: (TeamChatHistory) -> AnyView
    @State private var checkouts: [TeamCheckout] = []
    @State private var checkoutId: String?
    @State private var checkoutsNext: Int?
    @State private var shares: [TeamSharedChat] = []
    @State private var sharesNext: Int?
    @State private var sharesCursor: String?
    @State private var catalogAvailable = true
    @State private var selected: TeamSharedChat?
    @State private var loadingCheckouts = false
    @State private var loadingShares = false
    @State private var checkoutLoad = UUID()
    @State private var shareLoad = UUID()
    private var loading: Bool { loadingCheckouts || loadingShares }
    @State private var error: String?
    @State private var shareSheet = false
    @State private var localCheckoutIds: Set<String> = []
    @State private var newTitle = ""
    // Kept per title so a retry after a lost reply settles to the same chat.
    @State private var newRequest: (title: String, id: String)?
    @State private var starting = false
    private var isCurrent: Bool { store.mutationContext == context && store.phase == .ready }
    private var availableRepositories: [TeamRepository] { repositories.filter { $0.role != nil } }
    private var repository: TeamRepository? { availableRepositories.first { $0.id == store.selectedRepositoryId } }
    private var checkout: TeamCheckout? { checkouts.first { $0.id == checkoutId } }

    var body: some View {
        Group {
            if let selected, let repository, let checkout {
                TeamSharedChatReader(store: store, context: context, repository: repository, checkout: checkout, share: selected, transcript: transcript) { self.selected = nil }
                    .id(selected.id)
            } else {
                directory
            }
        }
        .preference(key: TeamChatReadingKey.self, value: selected != nil)
        .task(id: store.selectedRepositoryId) { await loadCheckouts() }
        .task(id: checkoutId) { await loadShares(more: false) }
        .sheet(isPresented: $shareSheet) {
            if let repository, let checkout {
                TeamChatShareEditor(store: store, context: context, repository: repository, checkout: checkout, transcript: transcript)
                    #if os(macOS)
                    .frame(width: 760, height: 700)
                    #else
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
                    #endif
            }
        }
        .onChange(of: shareSheet) { if !shareSheet { Task { await loadShares(more: false) } } }
    }
    private var directory: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                TeamSectionHeader(title: L10n.text("common.teams.chats"), subtitle: L10n.text("common.teams.shared_chats_detail")) {
                    Button(L10n.text("common.refresh"), .refresh) { Task { await loadShares(more: false) } }.buttonStyle(TeamButtonStyle()).disabled(loading || checkout == nil)
                }
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let error { TeamNotice(message: error, warning: true) }
                    if availableRepositories.isEmpty {
                        TeamNotice(message: L10n.text("common.teams.no_repositories_member"))
                    } else {
                        TeamPickerField(title: L10n.text("common.teams.repository_name"), selection: $store.selectedRepositoryId) {
                            Text(L10n.text("common.teams.choose_repository")).tag(Optional<String>.none)
                            ForEach(availableRepositories) { Text($0.name).tag(Optional($0.id)) }
                        }.accessibilityIdentifier("team.chats.repository")
                        if repository != nil {
                            TeamPickerField(title: L10n.text("common.teams.computer"), selection: $checkoutId) {
                                Text(L10n.text("common.teams.choose_computer")).tag(Optional<String>.none)
                                ForEach(checkouts) { row in Text(computerName(row)).tag(Optional(row.id)) }
                            }.accessibilityIdentifier("team.chats.checkout")
                            if checkoutsNext != nil {
                                Button(L10n.text("common.teams.load_more"), .more) { Task { await loadCheckouts(more: true) } }.buttonStyle(TeamButtonStyle()).disabled(loading)
                            }
                            if checkouts.isEmpty && !loading { TeamNotice(message: L10n.text("common.teams.no_checkouts")) }
                        }
                    }
                    if loading { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("common.loading")) }
                    if let checkout {
                        if let publisher = checkout.publisher {
                            TeamPersonLabel(id: publisher.id, name: publisher.name, handle: publisher.handle, avatar: publisher.avatar, owner: context.owner)
                        }
                        if shares.isEmpty && sharesNext == nil && sharesCursor == nil && !loading { TeamNotice(message: L10n.text("common.teams.no_shared_chats")) }
                        ForEach(shares) { share in
                            Button {
                                selected = share
                            } label: {
                                HStack(spacing: Theme.Space.m) {
                                    Image(systemName: ActionIcon.comment.symbol).foregroundStyle(TeamColors.action)
                                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                        Text(share.title.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("common.teams.shared_chat"))
                                            .font(Theme.body.weight(.medium)).lineLimit(2)
                                        if let date = TeamDate.parse(share.createdAt) {
                                            Text(date, format: .dateTime.month().day().hour().minute()).font(Theme.caption).foregroundStyle(.secondary)
                                        }
                                        Group {
                                            if share.title == nil { Text(L10n.text("common.teams.connect_to_read")) }
                                            else { Text(L10n.text("common.teams.open_shared_chat")) }
                                        }.font(Theme.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }.padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).accessibilityIdentifier("team.chats.open.\(share.id)")
                        }
                        if sharesNext != nil || sharesCursor != nil { Button(L10n.text("common.teams.load_more"), .more) { Task { await loadShares(more: true) } }.buttonStyle(TeamButtonStyle()).disabled(loading) }
                        if let role = repository?.role, role != .viewer {
                            newChat(checkout)
                        }
                        if store.capabilities?.canPublishChats == true, localCheckoutIds.contains(checkout.id) {
                            Button(L10n.text("common.teams.share_chat"), .connect) { shareSheet = true }.buttonStyle(TeamButtonStyle(primary: true)).accessibilityIdentifier("team.chats.share")
                        }
                    }
                }.padding(.horizontal, Theme.Space.l)
                .frame(maxWidth: 860, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, Theme.Space.l)
        }
        .onAppear {
            // One repository needs no choice. Picking it saves an empty step.
            if store.selectedRepositoryId == nil, availableRepositories.count == 1 {
                store.selectedRepositoryId = availableRepositories[0].id
            }
        }
    }
    /// A member starts an empty shared chat on that computer and asks its
    /// agent there, without waiting for the owner to share one.
    private func newChat(_ checkout: TeamCheckout) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("common.teams.new_chat_title")).font(Theme.callout.weight(.semibold))
            HStack(spacing: Theme.Space.s) {
                TextField(L10n.text("common.teams.new_chat_placeholder"), text: $newTitle).textFieldStyle(ThemedFieldStyle())
                    .accessibilityLabel(L10n.text("common.teams.new_chat_title"))
                    .onSubmit { Task { await startChat(checkout) } }
                Button(L10n.text("common.teams.new_chat"), .create) { Task { await startChat(checkout) } }
                    .buttonStyle(TeamButtonStyle(primary: true))
                    .disabled(starting || newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("team.chats.new")
            }
            Text(L10n.text("common.teams.new_chat_detail", computerName(checkout))).font(Theme.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
    private func startChat(_ checkout: TeamCheckout) async {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !starting, let repository else { return }
        let request: (title: String, id: String) = newRequest?.title == title ? newRequest! : (title, "new-" + UUID().uuidString.lowercased())
        newRequest = request; starting = true; error = nil
        defer { starting = false }
        do {
            let target: JSONValue = .object(["organization":.string(repository.organizationId),"repository":.string(repository.id),"checkout":.string(checkout.id)])
            let result: TeamNewChat = try await store.read(.ask, fields: ["target":target,"method":.string("team.chat.new"),
                "params":.object(["title":.string(title),"requestId":.string(request.id)])], context: context)
            newTitle = ""; newRequest = nil
            await loadShares(more: false)
            selected = shares.first { $0.id == result.share }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func computerName(_ row: TeamCheckout) -> String {
        [row.deviceName ?? L10n.text("common.teams.computer"), row.publisher?.name].compactMap { $0 }.joined(separator: " · ")
    }
    private func loadCheckouts(more: Bool = false) async {
        let load = UUID(); checkoutLoad = load
        if !more { checkouts = []; checkoutId = nil; shares = []; selected = nil; shareSheet = false; localCheckoutIds = []; error = nil }
        guard isCurrent, let repository else { loadingCheckouts = false; return }
        loadingCheckouts = true
        defer { if checkoutLoad == load { loadingCheckouts = false } }
        do {
            let result: TeamCheckouts = try await store.read("checkouts.list", fields: ["organization":.string(repository.organizationId),"repository":.string(repository.id),"page":TeamStore.page(offset: more ? checkoutsNext ?? 0 : 0)], context: context)
            guard isCurrent, checkoutLoad == load, self.repository?.id == repository.id else { return }
            checkouts = more ? checkouts + result.checkouts.filter { next in !checkouts.contains { $0.id == next.id } } : result.checkouts
            checkoutsNext = result.nextOffset
            if store.capabilities?.canPublishChats == true {
                let local: TeamLocalPublications = try await store.read(.checkoutList, fields: ["organization":.string(repository.organizationId),"repository":.string(repository.id),"page":TeamStore.page()], context: context)
                guard isCurrent, checkoutLoad == load, self.repository?.id == repository.id else { return }
                localCheckoutIds = Set(local.publications.filter { $0.phase == "active" }.map(\.id))
            }
            if checkoutId == nil { checkoutId = checkouts.first?.id }
        } catch is CancellationError {} catch { if isCurrent, checkoutLoad == load, self.repository?.id == repository.id { self.error = error.localizedDescription } }
    }
    private func loadShares(more: Bool) async {
        let load = UUID(); shareLoad = load
        if !more { shares = []; sharesNext = nil; sharesCursor = nil; catalogAvailable = true; selected = nil; error = nil }
        guard isCurrent, let repository, let checkoutId else { loadingShares = false; return }
        loadingShares = true
        defer { if shareLoad == load { loadingShares = false } }
        do {
            var catalog: TeamChatCatalog?
            if catalogAvailable {
                var params: [String: JSONValue] = ["limit":.int(100)]
                if more, let sharesCursor { params["cursor"] = .string(sharesCursor) }
                do {
                    catalog = try await store.read(.connectionCall, fields: [
                        "target":.object(["organization":.string(repository.organizationId),"repository":.string(repository.id),"checkout":.string(checkoutId)]),
                        "method":.string("team.chat.catalog"),"params":.object(params)], context: context)
                } catch let failure as TeamRequestFailure where ["team_method_required", "unknown_method"].contains(failure.code) {
                    guard isCurrent, shareLoad == load, self.checkoutId == checkoutId, self.repository?.id == repository.id else { return }
                    // Older hosts can still provide exact-share history. Their
                    // account directory contains opaque references only.
                    catalogAvailable = false
                }
            }
            let rows: [TeamSharedChat]
            let nextOffset: Int?
            let nextCursor: String?
            if let catalog { rows = catalog.shares; nextCursor = catalog.nextCursor; nextOffset = nil }
            else {
                let result: TeamSharedChats = try await store.read("chats.list", fields: ["organization":.string(repository.organizationId),"checkout":.string(checkoutId),"page":TeamStore.page(offset: more ? sharesNext ?? 0 : 0)], context: context)
                rows = result.shares; nextCursor = nil; nextOffset = result.nextOffset
            }
            guard isCurrent, shareLoad == load, self.checkoutId == checkoutId, self.repository?.id == repository.id, rows.allSatisfy({ $0.checkoutId == checkoutId }) else { return }
            shares = more ? shares + rows.filter { next in !shares.contains { $0.id == next.id } } : rows
            sharesNext = nextOffset; sharesCursor = nextCursor
        } catch is CancellationError {} catch { if isCurrent, shareLoad == load, self.checkoutId == checkoutId { self.error = error.localizedDescription } }
    }
}
