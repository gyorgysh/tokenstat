// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Publishing is a local-owner action. The directory can list other people's
/// computers without borrowing their credentials or a personal connection.
struct TeamCheckoutEditor: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let repository: TeamRepository
    private enum Stage { case directory, choose, review, stop, agents }
    @State private var stage: Stage = .directory
    @State private var checkouts: [TeamCheckout] = []
    @State private var checkoutsNext: Int?
    @State private var publications: [TeamLocalPublication] = []
    @State private var publicationsNext: Int?
    @State private var workspaces: [TeamLocalWorkspace] = []
    @State private var workspacesNext: Int?
    @State private var workspaceId: String?
    @State private var deviceName = ""
    @State private var preview: TeamCheckoutPreview?
    @State private var stopping: TeamLocalPublication?
    @State private var agentsFor: TeamLocalPublication?
    @State private var confirmed = false
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var notice: String?
    @State private var requestId = UUID().uuidString
    @State private var checkingCheckout: String?
    @State private var availableCheckouts: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    private var isCurrent: Bool { store.mutationContext == context && store.phase == .ready }
    private var canPublish: Bool {
        store.capabilities?.canPublishCheckouts == true && (repository.role == .contributor || repository.role == .maintainer)
    }
    private var visiblePublications: [TeamLocalPublication] {
        publications.filter { $0.organizationId == repository.organizationId && $0.repositoryId == repository.id && ($0.phase != "withdrawn" || $0.accountCleanupPending) }
    }
    private var otherCheckouts: [TeamCheckout] {
        let localIds = Set(visiblePublications.map(\.id))
        return checkouts.filter { !localIds.contains($0.id) }
    }
    var body: some View {
        ThemedSheet(title: L10n.text("common.teams.checkouts"), subtitle: repository.name, icon: .checkout, scrolls: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if isCurrent {
                    if let error { TeamNotice(message: error, warning: true) }
                    if let notice { TeamNotice(message: notice) }
                    if loading { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("common.loading")) }
                    switch stage {
                    case .directory: directory
                    case .choose: chooser
                    case .review: review
                    case .stop: stopReview
                    case .agents:
                        if let agentsFor {
                            Text(workspaceName(agentsFor)).font(Theme.headline)
                            TeamLaneSettings(store: store, context: context, checkoutId: agentsFor.id)
                            ThemeRule()
                            TeamAgentGrants(store: store, context: context, repository: repository, checkoutId: agentsFor.id)
                        }
                    }
                    if error != nil && !loading && stage == .directory {
                        Button(L10n.text("common.retry"), .refresh) { Task { await load() } }.buttonStyle(TeamButtonStyle())
                    }
                } else {
                    TeamNotice(message: L10n.text("common.teams.checkout_access_changed"), warning: true)
                }
            }
        } actions: {
            Button(stage == .directory || !isCurrent ? L10n.text("common.close") : L10n.text("common.back"), stage == .directory || !isCurrent ? .dismiss : .back) {
                if stage == .directory || !isCurrent { dismiss() }
                else { stage = .directory; preview = nil; stopping = nil; agentsFor = nil; confirmed = false; error = nil }
            }.buttonStyle(TeamButtonStyle()).disabled(saving).keyboardShortcut(.cancelAction)
            Spacer(minLength: Theme.Space.s)
            if saving { ProgressView().controlSize(.small) }
            if isCurrent { actions }
        }
        .task { await load() }
        .interactiveDismissDisabled(saving)
    }
    @ViewBuilder private var directory: some View {
        Text(L10n.text("common.teams.checkout_separate_detail")).font(Theme.body).foregroundStyle(.secondary)
        if !visiblePublications.isEmpty {
            Text(L10n.text("common.teams.this_computer")).font(Theme.headline).accessibilityAddTraits(.isHeader)
            ForEach(visiblePublications) { publication in
                Card(title: workspaceName(publication)) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(publication.accountCleanupPending ? L10n.text("common.teams.cleanup_pending") : publication.phase == "active" ? L10n.text("common.teams.checkout_shared") : L10n.text("common.teams.publication_pending"))
                            .font(Theme.callout).foregroundStyle(.secondary)
                        HStack(spacing: Theme.Space.s) {
                            if publication.phase == "active" && !publication.accountCleanupPending {
                                Button(L10n.text("common.teams.agent_runs"), .run) {
                                    agentsFor = publication; error = nil; notice = nil; stage = .agents
                                }.buttonStyle(TeamButtonStyle()).disabled(saving || loading)
                            }
                            Button(publication.accountCleanupPending ? L10n.text("common.teams.retry_cleanup") : L10n.text("common.teams.stop_sharing"), .revoke) {
                                stopping = publication; confirmed = false; error = nil; notice = nil; stage = .stop
                            }.buttonStyle(TeamButtonStyle()).disabled(saving || loading)
                        }
                    }
                }
            }
        }
        if publicationsNext != nil {
            Button(L10n.text("common.teams.more_local_checkouts"), .more) { Task { await loadLocal(more: true) } }.buttonStyle(TeamButtonStyle()).disabled(loading || saving)
        }
        if !otherCheckouts.isEmpty {
            Text(L10n.text("common.teams.published_computers")).font(Theme.headline).accessibilityAddTraits(.isHeader)
        }
        if checkouts.isEmpty && visiblePublications.isEmpty && !loading {
            Text(L10n.text("common.teams.no_checkouts")).font(Theme.body).foregroundStyle(.secondary)
        }
        ForEach(otherCheckouts) { checkout in
            Card(title: checkout.deviceName ?? L10n.text("common.teams.computer"), leading: AnyView(Image(systemName: ActionIcon.device.symbol).foregroundStyle(Theme.accent))) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if let publisher = checkout.publisher {
                        TeamPersonLabel(id: publisher.id, name: publisher.name, handle: publisher.handle, avatar: publisher.avatar, owner: context.owner)
                    }
                    if store.capabilities?.canConnectCheckouts == true {
                        if availableCheckouts.contains(checkout.id) {
                            Label(L10n.text("common.teams.checkout_available"), systemImage: ActionIcon.approve.symbol)
                                .font(Theme.callout).foregroundStyle(.secondary)
                        }
                        Button(L10n.text("common.teams.check_availability"), .refresh) {
                            Task { await checkAvailability(checkout) }
                        }.buttonStyle(TeamButtonStyle()).disabled(checkingCheckout != nil || saving || loading)
                        if checkingCheckout == checkout.id {
                            ProgressView().controlSize(.small).accessibilityLabel(L10n.text("common.loading"))
                        }
                    }
                    DisclosureGroup(L10n.text("common.teams.connection_details")) {
                        Text(checkout.id).font(Theme.mono(11)).textSelection(.enabled)
                        Text(checkout.hostKey).font(Theme.mono(11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }.font(Theme.callout).foregroundStyle(.secondary)
                }
            }
        }
        if checkoutsNext != nil {
            Button(L10n.text("common.teams.load_more"), .more) { Task { await loadCloud(more: true) } }.buttonStyle(TeamButtonStyle()).disabled(loading || saving)
        }
        if !canPublish { Text(L10n.text("common.teams.publish_on_computer")).font(Theme.callout).foregroundStyle(.secondary) }
    }
    private var chooser: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(L10n.text("common.teams.choose_checkout_detail")).font(Theme.body).foregroundStyle(.secondary)
            TeamPickerField(title: L10n.text("common.teams.local_checkout"), selection: $workspaceId) {
                Text(L10n.text("common.teams.choose_checkout")).tag(Optional<String>.none)
                ForEach(workspaces) { workspace in Text(workspace.name).tag(Optional(workspace.id)) }
            }.disabled(loading || saving).accessibilityIdentifier("team.checkout.picker")
            if let workspace = workspaces.first(where: { $0.id == workspaceId }) {
                Text(workspace.path).font(Theme.mono(12)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if workspacesNext != nil {
                Button(L10n.text("common.teams.load_more"), .more) { Task { await loadOptions(more: true) } }.buttonStyle(TeamButtonStyle()).disabled(loading || saving)
            }
            if !loading && workspaces.isEmpty { TeamNotice(message: L10n.text("common.teams.no_local_checkouts")) }
        }
    }
    @ViewBuilder private var review: some View {
        if let preview {
            reviewField(L10n.text("common.teams.repository_name"), value: preview.repository.name)
            reviewField(L10n.text("common.teams.local_checkout"), value: preview.workspaceName)
            reviewField(L10n.text("common.teams.computer"), value: deviceName)
            TeamNotice(message: L10n.text("common.teams.checkout_share_detail"))
            Text(L10n.text("common.teams.checkout_share_exclusions")).font(Theme.body).foregroundStyle(.secondary)
            Toggle(L10n.text("common.teams.checkout_share_confirm", preview.repository.name), isOn: $confirmed).toggleStyle(.checkboxForTeam).accessibilityIdentifier("team.checkout.confirm")
        }
    }
    @ViewBuilder private func reviewField(_ title: String, value: String) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title).font(Theme.headline)
                Text(value).font(Theme.body).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        } else { LabeledContent(title, value: value) }
    }
    @ViewBuilder private var stopReview: some View {
        if let stopping {
            Text(workspaceName(stopping)).font(Theme.headline)
            TeamNotice(message: L10n.text("common.teams.stop_sharing_detail"), warning: true)
            Text(L10n.text("common.teams.stop_sharing_files")).font(Theme.body).foregroundStyle(.secondary)
            Toggle(L10n.text("common.teams.stop_sharing_confirm"), isOn: $confirmed).toggleStyle(.checkboxForTeam).accessibilityIdentifier("team.checkout.stop.confirm")
        }
    }
    @ViewBuilder private var actions: some View {
        switch stage {
        case .directory:
            if canPublish {
                Button(L10n.text("common.teams.share_checkout"), .connect) {
                    stage = .choose; error = nil; notice = nil; Task { await loadOptions(more: false) }
                }.buttonStyle(TeamButtonStyle(primary: true)).disabled(loading || saving)
            }
        case .choose:
            Button(L10n.text("common.teams.review_sharing"), .preview) { Task { await prepare() } }
                .buttonStyle(TeamButtonStyle(primary: true)).disabled(workspaceId == nil || loading || saving).keyboardShortcut(.defaultAction).accessibilityIdentifier("team.checkout.review")
        case .review:
            Button(L10n.text("common.teams.share_checkout"), .connect) { Task { await publish() } }
                .buttonStyle(TeamButtonStyle(primary: true)).disabled(!confirmed || loading || saving).keyboardShortcut(.defaultAction).accessibilityIdentifier("team.checkout.publish")
        case .agents:
            EmptyView()
        case .stop:
            Button(L10n.text("common.teams.stop_sharing"), .revoke, role: .destructive) { Task { await withdraw() } }
                .buttonStyle(TeamButtonStyle(primary: true)).disabled(!confirmed || loading || saving).keyboardShortcut(.defaultAction).accessibilityIdentifier("team.checkout.stop")
        }
    }
    private func workspaceName(_ publication: TeamLocalPublication) -> String {
        workspaces.first { $0.id == publication.workspaceId }?.name ?? URL(fileURLWithPath: publication.workspaceId).lastPathComponent
    }
    private func load() async {
        await loadCloud(more: false)
        if isCurrent && store.capabilities?.canPublishCheckouts == true { await loadLocal(more: false) }
    }
    private func loadCloud(more: Bool) async {
        guard !loading, isCurrent else { return }
        loading = true; defer { loading = false }
        do {
            let result: TeamCheckouts = try await store.read("checkouts.list", fields: ["organization":.string(repository.organizationId),"repository":.string(repository.id),"page":TeamStore.page(offset: more ? checkoutsNext ?? 0 : 0)], context: context)
            guard isCurrent else { return }
            if more { let ids = Set(checkouts.map(\.id)); checkouts += result.checkouts.filter { !ids.contains($0.id) } } else { checkouts = result.checkouts }
            checkoutsNext = result.nextOffset; error = nil
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func loadLocal(more: Bool) async {
        guard !loading, isCurrent else { return }
        loading = true; defer { loading = false }
        do {
            let result: TeamLocalPublications = try await store.read(.checkoutList, fields: ["organization":.string(repository.organizationId),"repository":.string(repository.id),"page":TeamStore.page(offset: more ? publicationsNext ?? 0 : 0)], context: context)
            guard isCurrent else { return }
            if more { let ids = Set(publications.map(\.id)); publications += result.publications.filter { !ids.contains($0.id) } } else { publications = result.publications }
            publicationsNext = result.nextOffset
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func loadOptions(more: Bool) async {
        guard !loading, isCurrent else { return }
        loading = true; defer { loading = false }
        do {
            let result: TeamCheckoutOptions = try await store.read(.checkoutOptions, fields: ["page":TeamStore.page(offset: more ? workspacesNext ?? 0 : 0)], context: context)
            guard isCurrent, stage == .choose else { return }
            if more { let ids = Set(workspaces.map(\.id)); workspaces += result.workspaces.filter { !ids.contains($0.id) } } else { workspaces = result.workspaces }
            workspacesNext = result.nextOffset; deviceName = result.deviceName; error = nil
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func prepare() async {
        guard let workspaceId, !loading, !saving else { return }
        saving = true; error = nil; defer { saving = false }
        do {
            let result: TeamCheckoutPreview = try await store.read(.checkoutPreview, fields: target(workspaceId), context: context)
            guard isCurrent, result.workspaceId == workspaceId, result.repository.id == repository.id, result.repository.organizationId == repository.organizationId, !result.sharesExistingChats, !result.allowsAgentRuns else { throw CancellationError() }
            preview = result; confirmed = false; requestId = UUID().uuidString; stage = .review
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func publish() async {
        guard let preview, confirmed, !saving else { return }
        saving = true; error = nil
        do {
            var fields = target(preview.workspaceId)
            fields["preview"] = .string(preview.preview); fields["requestId"] = .string(requestId); fields["confirmSharing"] = .bool(true)
            let _: TeamCheckoutPublished = try await store.perform(.checkoutPublish, fields: fields, context: context)
            await store.refreshLocalProjects()
            guard isCurrent else { throw CancellationError() }
            stage = .directory; self.preview = nil; confirmed = false; notice = L10n.text("common.teams.checkout_shared")
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
        saving = false
        if stage == .directory { await load() }
    }
    private func withdraw() async {
        guard let stopping, confirmed, !saving else { return }
        saving = true; error = nil
        do {
            let result: TeamCheckoutWithdrawn = try await store.perform(.checkoutWithdraw, fields: ["checkout":.string(stopping.id),"expectedRevision":.uint(stopping.revision)], context: context)
            await store.refreshLocalProjects()
            guard isCurrent, result.withdrawn else { throw CancellationError() }
            stage = .directory; self.stopping = nil; confirmed = false
            notice = result.accountCleanupPending == true ? L10n.text("common.teams.cleanup_pending") : L10n.text("common.teams.sharing_stopped")
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
        saving = false
        if stage == .directory { await load() }
    }
    private func target(_ workspace: String) -> [String: JSONValue] {
        ["organization":.string(repository.organizationId),"repository":.string(repository.id),"workspace":.string(workspace)]
    }
    private func checkAvailability(_ checkout: TeamCheckout) async {
        guard isCurrent, checkingCheckout == nil, !saving, !loading else { return }
        checkingCheckout = checkout.id; availableCheckouts.remove(checkout.id); error = nil
        defer { checkingCheckout = nil }
        do {
            let result: TeamCheckoutAvailability = try await store.read(.connectionCall, fields: [
                "target": .object(["organization": .string(repository.organizationId), "repository": .string(repository.id), "checkout": .string(checkout.id)]),
                "method": .string("team.checkout.info"),
            ], context: context)
            guard isCurrent, result.checkoutId == checkout.id, result.organizationId == repository.organizationId,
                result.repositoryId == repository.id, result.state == "available" else { throw CancellationError() }
            availableCheckouts.insert(checkout.id)
        } catch is CancellationError {} catch { if isCurrent { self.error = error.localizedDescription } }
    }
}
