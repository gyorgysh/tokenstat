// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct TeamOwnershipEditor: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let organization: TeamOrganization?
    @State private var successor: String?
    @State private var confirmed = false
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var candidates: [TeamMember] { store.directory?.members.members.filter { $0.id != organization?.ownerId && $0.ownershipEligible == true } ?? [] }
    var body: some View {
        TeamEditorFrame(title: L10n.text("common.teams.transfer_ownership"), subtitle: organization?.name ?? "", submitTitle: L10n.text("common.teams.send_ownership_request"), submitIcon: .move,
            valid: confirmed && successor != nil && organization?.role == .owner, saving: saving || store.isMutating, error: error, submit: save) {
            Text(L10n.text("common.teams.transfer_detail")).font(Theme.body).foregroundStyle(.secondary)
            Picker(L10n.text("common.teams.next_owner"), selection: $successor) {
                Text(L10n.text("common.teams.choose_member")).tag(Optional<String>.none)
                ForEach(candidates) { member in Text(member.name).tag(Optional(member.id)) }
            }
            if candidates.isEmpty { Text(L10n.text("common.teams.no_eligible_owner")).font(Theme.callout).foregroundStyle(.secondary) }
            if store.directory?.members.nextOffset != nil {
                Button(L10n.text("common.teams.load_more"), .more) { Task { await store.loadMore(.members) } }.buttonStyle(TeamButtonStyle()).disabled(store.isLoadingDirectory)
            }
            TeamNotice(message: L10n.text("common.teams.transfer_confirmation_detail"), warning: true)
            Toggle(L10n.text("common.teams.transfer_confirm"), isOn: $confirmed).toggleStyle(.checkboxForTeam)
        }
    }
    private func save() {
        guard let org = context.organizationId, let organization, let successor else { return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                let _: JSONValue = try await store.perform("ownership.request", fields: ["organization":.string(org),"input":.object(["userId":.string(successor),"expectedRevision":.uint(organization.revision)])], context: context)
                dismiss(); await store.reloadAfterChange()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct TeamOwnershipDecisionEditor: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let request: TeamOwnershipRequest
    let cancelling: Bool
    @State private var confirmed = false
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var title: String { (cancelling ? L10n.text("common.teams.cancel_ownership_request") : L10n.text("common.teams.accept_ownership")) }
    var body: some View {
        TeamEditorFrame(title: title, subtitle: store.selectedOrganization?.name ?? "", submitTitle: title, submitIcon: cancelling ? .revoke : .approve,
            valid: confirmed && request.requestId != nil && (cancelling || request.current), saving: saving || store.isMutating, error: error, submit: save) {
            TeamNotice(message: (cancelling ? L10n.text("common.teams.cancel_ownership_detail") : L10n.text("common.teams.accept_ownership_confirmation")), warning: true)
            Toggle(L10n.text("common.teams.confirm_understood"), isOn: $confirmed).toggleStyle(.checkboxForTeam)
        }
    }
    private func save() {
        guard let org = context.organizationId, let requestId = request.requestId else { return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                let _: JSONValue = try await store.perform(cancelling ? "ownership.cancel" : "ownership.accept", fields: ["organization":.string(org),"input":.object(["requestId":.string(requestId),"expectedRevision":.uint(request.revision)])], context: context)
                dismiss(); await store.reloadAfterChange()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
