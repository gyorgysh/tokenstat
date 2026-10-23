// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Project membership normally authorizes a member's devices. Publishers can
/// explicitly select strict management to maintain individual device grants.
struct TeamAgentGrants: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let repository: TeamRepository
    let checkoutId: String
    @State private var grants: [TeamExecutionGrant] = []
    @State private var revision: UInt64 = 0
    @State private var members: [TeamRepositoryMember] = []
    @State private var memberId: String?
    @State private var devices: [TeamMemberDevice] = []
    @State private var deviceKey: String?
    @State private var acknowledged = false
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var loaded = false
    @State private var supportsMemberPolicy = false
    @State private var policy = "devices"
    @State private var selectedPolicy = "devices"

    private var eligible: [TeamRepositoryMember] {
        members.filter { $0.role == .contributor || $0.role == .maintainer }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let error { TeamNotice(message: error, warning: true) }
            if error != nil && !loading {
                Button(L10n.text("common.retry"), .refresh) { Task { await load() } }
                    .buttonStyle(TeamButtonStyle()).disabled(saving)
            }
            if loading { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("common.loading")) }
            if supportsMemberPolicy {
                TeamPickerField(title: L10n.text("common.teams.agent_access_policy"), selection: $selectedPolicy) {
                    Text(L10n.text("common.teams.agent_access_members")).tag("members")
                    Text(L10n.text("common.teams.agent_access_devices")).tag("devices")
                }.disabled(!loaded || loading || saving).accessibilityIdentifier("team.agent-access.policy")
                Text(L10n.text("common.teams.agent_access_account_detail"))
                    .font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if selectedPolicy != policy || saving {
                    Button(L10n.text("common.save"), .save) { Task { await setPolicy() } }
                        .buttonStyle(TeamButtonStyle(primary: true))
                        .disabled(!loaded || loading || saving || selectedPolicy == policy)
                        .accessibilityIdentifier("team.agent-access.save")
                }
            }
            if loaded && policy == "members" {
                Text(L10n.text("common.teams.agent_access_members_detail"))
                    .font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if loaded && policy == "devices" { deviceGrants }
        }
        .task { await load() }
        .onChange(of: memberId) { _, member in
            deviceKey = nil; devices = []
            if let member { Task { await loadDevices(member) } }
        }
    }

    private var deviceGrants: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(L10n.text("common.teams.agent_grants_detail")).font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if grants.isEmpty && !loading {
                Text(L10n.text("common.teams.agent_grants_none")).font(Theme.callout).foregroundStyle(.secondary)
            }
            ForEach(grants, id: \.self) { grant in
                HStack(spacing: Theme.Space.s) {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(name(grant.userId)).font(Theme.body.weight(.medium))
                        Text(shortKey(grant.deviceKey)).font(Theme.mono(11)).foregroundStyle(.secondary)
                        if grant.grantId == nil { Text(L10n.text("common.teams.agent_grant_renew")).font(Theme.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.text("common.teams.remove_agent_grant"), .revoke) { Task { await set(user: grant.userId, device: grant.deviceKey, machine: nil, allow: false) } }
                        .buttonStyle(TeamButtonStyle()).disabled(saving || loading)
                }
            }
            ThemeRule()
            Text(L10n.text("common.teams.add_agent_grant")).font(Theme.headline)
            TeamPickerField(title: L10n.text("common.teams.member"), selection: $memberId) {
                Text(L10n.text("common.teams.choose_member")).tag(Optional<String>.none)
                ForEach(eligible) { member in Text(member.handle.map { "\(member.name) (@\($0))" } ?? member.name).tag(Optional(member.id)) }
            }.disabled(saving || loading)
            if memberId != nil {
                TeamPickerField(title: L10n.text("common.teams.device"), selection: $deviceKey) {
                    Text(L10n.text("common.teams.choose_device")).tag(Optional<String>.none)
                    ForEach(devices, id: \.key) { device in Text(deviceLabel(device)).tag(Optional(device.key)) }
                }.disabled(saving || loading)
            }
            TeamNotice(message: L10n.text("common.teams.agent_grant_warning"), warning: true)
            Toggle(L10n.text("common.teams.agent_grant_confirm"), isOn: $acknowledged).toggleStyle(.checkboxForTeam)
            Button(L10n.text("common.teams.allow_agent_runs"), .allow) {
                guard let memberId, let device = devices.first(where: { $0.key == deviceKey }) else { return }
                Task { await set(user: memberId, device: device.key, machine: device.id, allow: true) }
            }
            .buttonStyle(TeamButtonStyle(primary: true))
            .disabled(memberId == nil || deviceKey == nil || !acknowledged || saving || loading)
        }
    }

    private func name(_ user: String) -> String {
        members.first { $0.id == user }?.name ?? user
    }
    private func shortKey(_ key: String) -> String { String(key.prefix(12)) }
    private func deviceLabel(_ device: TeamMemberDevice) -> String {
        let name = device.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "\(L10n.text("common.teams.device")) · \(shortKey(device.key))" : name
    }
    private var base: [String: JSONValue] {
        ["organization": .string(repository.organizationId), "checkout": .string(checkoutId)]
    }

    private func load() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let result: TeamExecutionGrants = try await store.read("execution.list", fields: base, context: context)
            let supportsPolicy = result.supportsMemberPolicy == true
            let currentPolicy = supportsPolicy ? result.policy ?? "" : "devices"
            guard currentPolicy == "members" || currentPolicy == "devices" else {
                throw TeamRequestFailure(code: "invalid_response", message: L10n.text("common.teams.agent_access_unavailable"))
            }
            grants = result.grants; revision = result.revision
            supportsMemberPolicy = supportsPolicy; policy = currentPolicy; selectedPolicy = currentPolicy; loaded = true
            if currentPolicy == "members" { members = []; error = nil; return }
            var page: TeamRepositoryMembers = try await store.read("repositories.members", fields: ["organization": .string(repository.organizationId), "repository": .string(repository.id), "page": TeamStore.page(offset: 0)], context: context)
            var all = page.members
            while let next = page.nextOffset, all.count < 500 {
                page = try await store.read("repositories.members", fields: ["organization": .string(repository.organizationId), "repository": .string(repository.id), "page": TeamStore.page(offset: next)], context: context)
                all += page.members
            }
            members = all; error = nil
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func loadDevices(_ member: String) async {
        do {
            var fields = base; fields["user"] = .string(member)
            let result: TeamMemberDevices = try await store.read("execution.devices", fields: fields, context: context)
            guard memberId == member else { return }
            devices = result.devices
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func setPolicy() async {
        guard loaded, supportsMemberPolicy, selectedPolicy != policy, !saving, !loading else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            var fields = base
            fields["input"] = .object(["policy": .string(selectedPolicy), "expectedRevision": .uint(revision), "acknowledgeHostAccess": .bool(true)])
            let _: JSONValue = try await store.perform("execution.policy", fields: fields, context: context)
            acknowledged = false; memberId = nil; deviceKey = nil; devices = []
            await load()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func set(user: String, device: String, machine: String?, allow: Bool) async {
        guard loaded, policy == "devices", !saving, !loading else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            var input: [String: JSONValue] = ["userId": .string(user), "deviceKey": .string(device), "allow": .bool(allow), "expectedRevision": .uint(revision)]
            if let machine { input["machineId"] = .string(machine) }
            if allow { input["acknowledgeHostAccess"] = .bool(true) }
            var fields = base; fields["input"] = .object(input)
            let _: JSONValue = try await store.perform("execution.set", fields: fields, context: context)
            acknowledged = false; memberId = nil
            await load()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct TeamExecutionGrant: Codable, Hashable, Sendable { let userId: String; let deviceKey: String; let createdAt: String; let grantId: String? }
struct TeamExecutionGrants: Codable, Sendable { let grants: [TeamExecutionGrant]; let revision: UInt64; var policy: String? = nil; var supportsMemberPolicy: Bool? = nil }
struct TeamMemberDevice: Codable, Hashable, Sendable { let id: String; let key: String; let kind: String; var name: String? = nil }
struct TeamMemberDevices: Codable, Sendable { let devices: [TeamMemberDevice] }
