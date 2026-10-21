// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct TeamRepositoryNameEditor: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let repository: TeamRepository
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(store: TeamStore, context: TeamMutationContext, repository: TeamRepository) {
        self.store = store; self.context = context; self.repository = repository
        _name = State(initialValue: repository.name)
    }
    var body: some View {
        TeamEditorFrame(title: L10n.text("common.teams.rename_repository"), subtitle: L10n.text("common.teams.repository_rename_detail"), icon: .edit,
            submitTitle: L10n.text("common.save"), submitIcon: .save, valid: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf16.count <= 80 && name.trimmingCharacters(in: .whitespacesAndNewlines) != repository.name, saving: saving || store.isMutating, error: error, submit: save) {
            TextField(L10n.text("common.teams.repository_name"), text: $name).textFieldStyle(ThemedFieldStyle())
            Text(L10n.text("common.teams.checkout_separate_detail")).font(Theme.body).foregroundStyle(.secondary)
        }
    }
    private func save() {
        guard let org = context.organizationId else { return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                let _: JSONValue = try await store.perform("repositories.rename", fields: ["organization":.string(org),"repository":.string(repository.id),"input":.object(["name":.string(name),"expectedRevision":.uint(repository.revision)])], context: context)
                dismiss(); await store.reloadAfterChange()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct TeamRepositoryAccessEditor: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let repository: TeamRepository
    @State private var members: [TeamRepositoryMember] = []
    @State private var nextOffset: Int?
    @State private var selectedId: String?
    @State private var role: TeamRepositoryRole?
    @State private var query = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    private var selected: TeamRepositoryMember? { members.first { $0.id == selectedId } }
    private var filtered: [TeamRepositoryMember] {
        members.filter { query.isEmpty || $0.name.localizedStandardContains(query) || ($0.handle?.localizedStandardContains(query) ?? false) }
    }
    var body: some View {
        TeamEditorFrame(title: L10n.text("common.teams.repository_access"), subtitle: repository.name, icon: .permissions,
            submitTitle: L10n.text("common.save"), valid: selected != nil && selected?.role != role && !loading, saving: saving || store.isMutating, error: error, submit: save) {
            TextField(L10n.text("common.teams.find_member"), text: $query).textFieldStyle(ThemedFieldStyle())
            if loading && members.isEmpty { ProgressView().controlSize(.small) }
            else {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    TeamPickerField(title: L10n.text("common.teams.member"), selection: $selectedId) {
                        Text(L10n.text("common.teams.choose_member")).tag(Optional<String>.none)
                        ForEach(filtered) { member in
                            Text(member.handle.map { "\(member.name) (@\($0))" } ?? member.name).tag(Optional(member.id))
                        }
                    }.disabled(saving)
                    if nextOffset != nil {
                        Button(L10n.text("common.teams.load_more"), .more) { Task { await load(more: true) } }.buttonStyle(TeamButtonStyle()).disabled(loading || saving)
                    }
                }
                if let member = selected {
                    TeamPersonLabel(id: member.id, name: member.name, handle: member.handle, avatar: member.avatar, owner: context.owner)
                    TeamPickerField(title: L10n.text("common.teams.access_level"), selection: $role) {
                        Text(L10n.text("common.teams.no_access")).tag(Optional<TeamRepositoryRole>.none)
                        ForEach(TeamRepositoryRole.allCases) { value in Text(value.label).tag(Optional(value)) }
                    }.disabled(saving)
                    Text(role?.detail ?? L10n.text("common.teams.no_access_detail")).font(Theme.body).foregroundStyle(.secondary)
                    if !member.eligible { TeamNotice(message: L10n.text("common.teams.member_plan_recovery"), warning: true) }
                    if (role == nil || role == .viewer) && (member.role == .contributor || member.role == .maintainer) {
                        TeamNotice(message: L10n.text("common.teams.access_reduction_detail"), warning: true)
                    }
                } else if filtered.isEmpty && !loading {
                    Text(L10n.text("common.teams.no_matching_members")).font(Theme.body).foregroundStyle(.secondary)
                    if error != nil { Button(L10n.text("common.retry"), .refresh) { Task { await load(more: false) } }.buttonStyle(TeamButtonStyle()) }
                }
            }
            TeamNotice(message: L10n.text("common.teams.execution_separate"))
        }
        .task { await load(more: false) }
        .onChange(of: selectedId) { role = selected?.role }
    }
    private func load(more: Bool) async {
        guard let org = context.organizationId else { return }
        loading = true
        defer { loading = false }
        do {
            let result: TeamRepositoryMembers = try await store.read("repositories.members", fields: ["organization":.string(org),"repository":.string(repository.id),"page":TeamStore.page(offset: more ? nextOffset ?? 0 : 0)], context: context)
            if more { let existing = Set(members.map(\.id)); members += result.members.filter { !existing.contains($0.id) } } else { members = result.members }
            nextOffset = result.nextOffset
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func save() {
        guard let org = context.organizationId, let member = selected else { return }
        let requested = role
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                let reply: TeamAccessReply = try await store.perform("repositories.access", fields: ["organization":.string(org),"repository":.string(repository.id),"user":.string(member.id),"input":.object(["role":requested.map { .string($0.rawValue) } ?? .null,"expectedRevision":.uint(member.revision)])], context: context)
                if let index = members.firstIndex(where: { $0.id == member.id }) {
                    members[index] = TeamRepositoryMember(id: member.id, name: member.name, handle: member.handle, avatar: member.avatar, role: reply.role, revision: reply.revision, eligible: member.eligible)
                }
                await store.reloadAfterChange()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
private struct TeamAccessReply: Decodable, Sendable { let role: TeamRepositoryRole?; let revision: UInt64 }
