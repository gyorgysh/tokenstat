// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// One Team repository: where it is shared from and what can be done with it.
/// A repository is a project shared from one or more computers, so the row
/// names each computer and the person who shared it.
struct TeamRepositoryRow: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let repository: TeamRepository
    let organization: TeamOrganization
    let openChats: () -> Void
    let openCheckouts: () -> Void
    let manageAccess: () -> Void
    let rename: () -> Void
    @State private var checkouts: [TeamCheckout] = []
    @State private var more = false
    @State private var localIds: Set<String> = []
    @State private var loaded = false
    @State private var lanes: [String: [TeamLane]] = [:]
    @State private var landing: String?
    @State private var landMessage: String?

    private var canManage: Bool { organization.role.canManage || repository.role == .maintainer }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Image(systemName: "folder.badge.person.crop").font(Theme.font(18)).foregroundStyle(TeamColors.action)
                    .frame(width: 40, height: 40).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(repository.name).font(Theme.body.weight(.semibold)).lineLimit(2).accessibilityAddTraits(.isHeader)
                    TeamRoleBadge(text: repository.role?.label ?? L10n.text("common.teams.unassigned"))
                }
                Spacer(minLength: Theme.Space.m)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.s) { actions }
                    HStack(spacing: Theme.Space.s) { primaryAction; overflow(includingCheckouts: true) }
                }
            }
            .padding(Theme.cardPadding)
            if repository.role != nil {
                ThemeRule().padding(.leading, Theme.cardPadding)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(L10n.text("common.teams.computers_sharing").uppercased()).font(Theme.sectionHeader).foregroundStyle(.secondary)
                    if loaded && checkouts.isEmpty {
                        Text(L10n.text("common.teams.repository_not_shared")).font(Theme.callout).foregroundStyle(.secondary)
                    }
                    ForEach(checkouts) { checkout in
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: ActionIcon.device.symbol).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
                            Text(source(checkout)).font(Theme.callout).lineLimit(2)
                            if localIds.contains(checkout.id) { TeamRoleBadge(text: L10n.text("common.teams.this_computer")) }
                        }.accessibilityElement(children: .combine)
                    }
                    if more { Text(L10n.text("common.teams.more_computers")).font(Theme.caption).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, Theme.cardPadding).padding(.vertical, Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                let work = checkouts.flatMap { lanes[$0.id] ?? [] }
                if !work.isEmpty {
                    ThemeRule().padding(.leading, Theme.cardPadding)
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(L10n.text("common.teams.work_in_progress").uppercased()).font(Theme.sectionHeader).foregroundStyle(.secondary)
                        if more || lanes.count < checkouts.count { Text(L10n.text("common.teams.partial_lanes")).font(Theme.caption).foregroundStyle(.secondary) }
                        if let landMessage { TeamNotice(message: landMessage) }
                        ForEach(checkouts) { checkout in
                            ForEach(lanes[checkout.id] ?? [], id: \.branch) { lane in laneRow(lane, all: work, checkout: checkout) }
                        }
                    }
                    .padding(.horizontal, Theme.cardPadding).padding(.vertical, Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .teamCard()
        .task(id: repository.revision) { await load() }
    }

    @ViewBuilder private var primaryAction: some View {
        if repository.role != nil {
            Button(L10n.text("common.teams.section_chats"), .comment, action: openChats)
                .buttonStyle(TeamButtonStyle(primary: true)).disabled(!organization.isActive)
        }
    }

    @ViewBuilder private var actions: some View {
        primaryAction
        if repository.role != nil {
            Button(L10n.text("common.teams.checkouts"), .checkout, action: openCheckouts)
                .buttonStyle(TeamButtonStyle()).disabled(!organization.isActive)
        }
        overflow(includingCheckouts: false)
    }

    /// Changes to the project itself: rare, so they wait behind one menu
    /// instead of competing with Chats for attention on every card.
    @ViewBuilder private func overflow(includingCheckouts: Bool) -> some View {
        if canManage || (includingCheckouts && repository.role != nil) {
            TeamRowMenu(label: L10n.text("common.teams.more_actions")) {
                if includingCheckouts && repository.role != nil {
                    Button(L10n.text("common.teams.checkouts"), action: openCheckouts).disabled(!organization.isActive)
                }
                if canManage {
                    Button(L10n.text("common.teams.manage_access"), action: manageAccess)
                    Button(L10n.text("common.teams.rename_repository"), action: rename).disabled(!organization.isActive)
                }
            }
        }
    }

    private func laneRow(_ lane: TeamLane, all: [TeamLane], checkout: TeamCheckout) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                if lane.state == "running" {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                } else {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Text(lane.ask.isEmpty ? lane.branch : lane.ask).font(Theme.body).lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text(lane.state == "running"
                ? L10n.text("common.teams.lane_running", lane.askedBy.name, String(lane.files.count))
                : lane.state == "ready"
                ? L10n.text("common.teams.lane_ready", lane.askedBy.name, String(lane.files.count))
                : L10n.text("common.teams.lane_kept", lane.askedBy.name, String(lane.files.count)))
                .font(Theme.caption).foregroundStyle(.secondary)
            // Compared here across every computer's lanes, not only within one host.
            let files = Set(lane.files)
            let overlapping = all.filter { $0.branch != lane.branch && !files.isDisjoint(with: $0.files) }
                .map { $0.ask.isEmpty ? $0.branch : $0.ask }
            if !overlapping.isEmpty {
                Label(L10n.text("common.teams.lane_overlap", overlapping.joined(separator: ", ")), systemImage: "exclamationmark.triangle")
                    .font(Theme.caption).foregroundStyle(TeamColors.warning)
            }
            if lane.state != "running", let share = lane.share {
                HStack(spacing: Theme.Space.s) {
                    if lane.state == "ready" {
                        Button(L10n.text("common.teams.land"), .merge) { Task { await act("team.lanes.land", lane, share: share, checkout: checkout) } }
                            .buttonStyle(TeamButtonStyle(primary: true)).disabled(landing != nil)
                    }
                    Button(L10n.text("common.teams.discard"), .delete, role: .destructive) { Task { await act("team.lanes.discard", lane, share: share, checkout: checkout) } }
                        .buttonStyle(TeamButtonStyle()).disabled(landing != nil)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func act(_ method: String, _ lane: TeamLane, share: String, checkout: TeamCheckout) async {
        guard landing == nil else { return }
        landing = lane.branch; landMessage = nil
        defer { landing = nil }
        let target: JSONValue = .object(["organization": .string(repository.organizationId), "repository": .string(repository.id),
                                         "checkout": .string(checkout.id), "share": .string(share)])
        do {
            let result: TeamLandResult = try await store.read(.ask, fields: ["target": target, "method": .string(method),
                "params": .object(["branch": .string(lane.branch)])], context: context)
            landMessage = result.message ?? (result.discarded == true ? L10n.text("common.teams.lane_discarded") : nil)
        } catch is CancellationError {} catch { landMessage = error.localizedDescription }
        await load()
    }

    private func source(_ checkout: TeamCheckout) -> String {
        let computer = checkout.deviceName ?? L10n.text("common.teams.computer")
        guard let person = checkout.publisher?.name else { return computer }
        return L10n.text("common.teams.shared_from", computer, person)
    }

    private func load() async {
        guard repository.role != nil else { return }
        do {
            let result: TeamCheckouts = try await store.read("checkouts.list", fields: [
                "organization": .string(repository.organizationId), "repository": .string(repository.id),
                "page": TeamStore.page(offset: 0),
            ], context: context)
            checkouts = Array(result.checkouts.prefix(5)); more = result.checkouts.count > 5 || result.nextOffset != nil
            if store.capabilities?.canPublishCheckouts == true {
                let local: TeamLocalPublications = try await store.read(.checkoutList, fields: [
                    "organization": .string(repository.organizationId), "repository": .string(repository.id), "page": TeamStore.page(),
                ], context: context)
                localIds = Set(local.publications.filter { $0.phase == "active" }.map(\.id))
            }
        } catch {}
        loaded = true
        // Each computer answers for its own lanes. One that is offline just
        // shows nothing; it is not an error on this screen.
        for checkout in checkouts.prefix(3) {
            let target: JSONValue = .object(["organization": .string(repository.organizationId), "repository": .string(repository.id), "checkout": .string(checkout.id)])
            if let result: TeamLanes = try? await store.read(.connectionCall, fields: ["target": target, "method": .string("team.lanes"), "params": .object([:])], context: context) {
                lanes[checkout.id] = result.lanes
            }
        }
    }
}

struct TeamLane: Codable, Sendable, Hashable {
    struct Person: Codable, Sendable, Hashable { let id: String; let name: String }
    let branch: String; let ask: String; let askedBy: Person; let startedAtMs: Int64
    let state: String; let files: [String]; let overlaps: [String]; var share: String? = nil
}
struct TeamLandResult: Codable, Sendable { let landed: Bool?; let message: String?; let discarded: Bool? }
struct TeamLanes: Codable, Sendable { let lanes: [TeamLane] }
