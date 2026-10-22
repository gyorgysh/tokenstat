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

    private var canManage: Bool { organization.role.canManage || repository.role == .maintainer }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Label(repository.name, systemImage: "folder").font(Theme.headline).lineLimit(2)
                Spacer(minLength: Theme.Space.m)
                TeamRoleBadge(text: repository.role?.label ?? L10n.text("common.teams.unassigned"))
            }
            if repository.role != nil {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    if loaded && checkouts.isEmpty {
                        Text(L10n.text("common.teams.repository_not_shared")).font(Theme.callout).foregroundStyle(.secondary)
                    }
                    ForEach(checkouts) { checkout in
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: ActionIcon.device.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                            Text(source(checkout)).font(Theme.callout).foregroundStyle(.secondary).lineLimit(2)
                            if localIds.contains(checkout.id) { TeamRoleBadge(text: L10n.text("common.teams.this_computer")) }
                        }
                    }
                    if more { Text(L10n.text("common.teams.more_computers")).font(Theme.caption).foregroundStyle(.secondary) }
                }
                let work = checkouts.flatMap { lanes[$0.id] ?? [] }
                if !work.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(L10n.text("common.teams.work_in_progress")).font(Theme.callout.weight(.semibold))
                        ForEach(work, id: \.branch) { lane in laneRow(lane, all: work) }
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) { actions }
                VStack(alignment: .leading, spacing: Theme.Space.s) { actions }
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .task(id: repository.revision) { await load() }
    }

    @ViewBuilder private var actions: some View {
        if repository.role != nil {
            Button(L10n.text("common.teams.chats"), .comment, action: openChats)
                .buttonStyle(TeamButtonStyle(primary: true)).disabled(!organization.isActive)
            Button(L10n.text("common.teams.checkouts"), .checkout, action: openCheckouts)
                .buttonStyle(TeamButtonStyle()).disabled(!organization.isActive)
        }
        if canManage {
            Button(L10n.text("common.teams.manage_access"), .permissions, action: manageAccess).buttonStyle(TeamButtonStyle())
            Button(L10n.text("common.teams.rename_repository"), .edit, action: rename)
                .buttonStyle(TeamButtonStyle()).disabled(!organization.isActive)
        }
    }

    private func laneRow(_ lane: TeamLane, all: [TeamLane]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                if lane.state == "running" {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                } else {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Text(lane.ask.isEmpty ? lane.branch : lane.ask).font(Theme.body).lineLimit(2)
            }
            Text(lane.state == "running"
                ? L10n.text("common.teams.lane_running", lane.askedBy.name, String(lane.files.count))
                : L10n.text("common.teams.lane_kept", lane.askedBy.name, String(lane.files.count)))
                .font(Theme.caption).foregroundStyle(.secondary)
            let overlapping = all.filter { lane.overlaps.contains($0.branch) }.map { $0.ask.isEmpty ? $0.branch : $0.ask }
            if !overlapping.isEmpty {
                Label(L10n.text("common.teams.lane_overlap", overlapping.joined(separator: ", ")), systemImage: "exclamationmark.triangle")
                    .font(Theme.caption).foregroundStyle(TeamColors.warning)
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.controlSeat, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    let state: String; let files: [String]; let overlaps: [String]
}
struct TeamLanes: Codable, Sendable { let lanes: [TeamLane] }
