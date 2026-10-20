// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct TeamEditorSheet: View {
    @Bindable var store: TeamStore
    let route: TeamSheet
    let canCreateOrganization: Bool
    let onAccount: () -> Void
    @State private var organization: TeamOrganization?
    @State private var repositories: [TeamRepository]
    init(store: TeamStore, route: TeamSheet, canCreateOrganization: Bool, onAccount: @escaping () -> Void) {
        self.store = store; self.route = route; self.canCreateOrganization = canCreateOrganization; self.onAccount = onAccount
        _organization = State(initialValue: store.selectedOrganization)
        _repositories = State(initialValue: store.directory?.repositories.repositories ?? [])
    }
    @ViewBuilder var body: some View {
        switch route {
        case .authorize: TeamAuthorizationEditor(store: store)
        case let .create(context): TeamOrganizationNameEditor(store: store, context: context, organization: nil, creating: true, canCreate: canCreateOrganization, onAccount: onAccount)
        case let .rename(context): TeamOrganizationNameEditor(store: store, context: context, organization: organization, creating: false, canCreate: true, onAccount: onAccount)
        case let .invite(context): TeamInviteEditor(store: store, context: context, organization: organization, repositories: repositories)
        case let .memberRole(context, member): TeamMemberRoleEditor(store: store, context: context, member: member)
        case let .remove(context, member): TeamRemovalEditor(store: store, context: context, organization: organization, member: member, deleting: false, leaving: false)
        case let .invitationAction(context, invitation, renewing): TeamInvitationActionEditor(store: store, context: context, invitation: invitation, renewing: renewing)
        case let .accept(context, invitation): TeamInvitationEditor(store: store, context: context, invitation: invitation, onAccount: onAccount)
        case let .repository(context): TeamRepositoryNameEditor(store: store, context: context)
        case let .renameRepository(context, repository): TeamRepositoryNameEditor(store: store, context: context, repository: repository)
        case let .access(context, repository): TeamRepositoryAccessEditor(store: store, context: context, repository: repository)
        case let .checkouts(context, repository): TeamCheckoutEditor(store: store, context: context, repository: repository)
        case let .ownershipDecision(context, request, cancelling): TeamOwnershipDecisionEditor(store: store, context: context, request: request, cancelling: cancelling)
        case let .transfer(context): TeamOwnershipEditor(store: store, context: context, organization: organization)
        case let .delete(context): TeamRemovalEditor(store: store, context: context, organization: organization, member: nil, deleting: true, leaving: false)
        case let .leave(context): TeamRemovalEditor(store: store, context: context, organization: organization, member: nil, deleting: false, leaving: true)
        }
    }
}
struct TeamEditorFrame<Content: View>: View {
    let title: String
    let subtitle: String
    var icon: ActionIcon = .team
    let submitTitle: String
    var submitIcon: ActionIcon = .save
    var valid = true
    var saving = false
    var destructive = false
    var error: String?
    let submit: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ThemedSheet(title: title, subtitle: subtitle, icon: icon, scrolls: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let error { TeamNotice(message: error, warning: true) }
                content()
            }
        } actions: {
            Button(L10n.text("common.cancel"), .dismiss) { dismiss() }.buttonStyle(TeamButtonStyle()).keyboardShortcut(.cancelAction).accessibilityIdentifier("team.editor.cancel")
            Spacer(minLength: Theme.Space.s)
            if saving { ProgressView().controlSize(.small) }
            Button(submitTitle, submitIcon, role: destructive ? .destructive : nil, action: submit)
                .buttonStyle(TeamButtonStyle(primary: true)).disabled(!valid || saving).keyboardShortcut(.defaultAction).accessibilityIdentifier("team.editor.submit")
        }
    }
}
struct TeamAuthorizationEditor: View {
    @Bindable var store: TeamStore
    @Environment(\.openURL) private var openURL
    @State private var confirmed = false
    @State private var saving = false
    @State private var error: String?
    @State private var preview: TeamAuthorizationPreview?
    var body: some View {
        TeamEditorFrame(title: L10n.text("common.teams.enable_title"), subtitle: L10n.text("common.teams.device_consent_detail"),
            submitTitle: L10n.text("common.teams.continue_browser"), submitIcon: .external, valid: confirmed && preview != nil, saving: saving || store.isMutating, error: error, submit: enable) {
            TeamNotice(message: L10n.text("common.teams.metadata_disclosure"))
            Text(L10n.text("common.teams.content_disclosure")).font(Theme.body).foregroundStyle(.secondary)
            if let preview {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(preview.deviceName).font(Theme.headline)
                    DisclosureGroup(L10n.text("common.teams.connection_key")) {
                        Text(L10n.text("common.teams.check_device_key")).font(Theme.callout).foregroundStyle(.secondary)
                        Text(preview.deviceKey).font(Theme.mono(12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle(L10n.text("common.teams.metadata_confirm"), isOn: $confirmed).toggleStyle(.checkboxForTeam).accessibilityIdentifier("team.authorization.confirm")
                }
            } else if error != nil {
                Button(L10n.text("common.retry"), .refresh) { Task { await loadPreview() } }.buttonStyle(TeamButtonStyle())
            } else { ProgressView().controlSize(.small) }
        }
        .task { await loadPreview() }
    }
    private func loadPreview() async {
        error = nil
        do { preview = try await store.authorizationPreview() }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func enable() {
        guard let preview else { return }
        saving = true; error = nil
        Task {
            do {
                let authorization = try await store.prepareAuthorization(expectedDeviceKey: preview.deviceKey)
                guard let url = URL(string: authorization.authorizationURL) else { throw TeamRequestFailure(code: "invalid_response", message: L10n.text("common.teams.invalid_link")) }
                openURL(url) { accepted in if !accepted { error = L10n.text("common.teams.browser_failed") } }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
struct TeamCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
        #else
        Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        #endif
    }
}
extension ToggleStyle where Self == TeamCheckboxStyle {
    static var checkboxForTeam: TeamCheckboxStyle { .init() }
}
struct TeamOrganizationNameEditor: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let organization: TeamOrganization?
    let creating: Bool
    let canCreate: Bool
    let onAccount: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var slug = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    private var valid: Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.utf16.count <= 80 && (creating ? (slug.range(of: "^[a-z][a-z0-9-]{1,46}[a-z0-9]$", options: .regularExpression) != nil && !slug.contains("--")) : organization != nil)
    }
    var body: some View {
        if !canCreate {
            ThemedSheet(title: L10n.text("common.teams.create_organization"), subtitle: L10n.text("common.teams.legend_creator"), icon: .team, onClose: { dismiss() }) {
                EmptyState(symbol: "crown", title: L10n.text("common.teams.legend_required"), message: L10n.text("common.teams.legend_creator"))
            } actions: {
                Button(L10n.text("common.cancel"), .dismiss) { dismiss() }.buttonStyle(TeamButtonStyle())
                Spacer()
                Button(L10n.text("common.teams.view_plan"), .plans) { dismiss(); onAccount() }.buttonStyle(TeamButtonStyle(primary: true))
            }
        } else {
            TeamEditorFrame(title: creating ? L10n.text("common.teams.create_organization") : L10n.text("common.teams.rename_organization"),
                subtitle: creating ? L10n.text("common.teams.create_detail") : organization?.name ?? "",
                submitTitle: creating ? L10n.text("common.teams.create_organization") : L10n.text("common.save"), submitIcon: creating ? .create : .save,
                valid: valid, saving: saving || store.isMutating, error: error, submit: save) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(L10n.text("common.teams.organization_name")).font(Theme.headline)
                    TextField(L10n.text("common.teams.organization_name"), text: $name).textFieldStyle(ThemedFieldStyle()).focused($nameFocused)
                }
                if creating {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(L10n.text("common.teams.organization_address")).font(Theme.headline)
                        TextField(L10n.text("common.teams.address_placeholder"), text: $slug).textFieldStyle(ThemedFieldStyle()).teamIdentifierInput()
                        Text(L10n.text("common.teams.address_detail")).font(Theme.callout).foregroundStyle(.secondary)
                    }
                    TeamNotice(message: L10n.text("common.teams.legend_creator"))
                }
            }
            .onAppear { if let organization { name = organization.name }; nameFocused = true }
            .onChange(of: name) { old, new in if creating && (slug.isEmpty || slug == Self.suggestedSlug(old)) { slug = Self.suggestedSlug(new) } }
        }
    }
    private func save() {
        saving = true; error = nil
        Task {
            do {
                let details: TeamOrganizationDetails
                if !creating {
                    guard let organization else { throw CancellationError() }
                    details = try await store.perform("organizations.rename", fields: ["organization":.string(organization.id),"input":.object(["name":.string(name),"expectedRevision":.uint(organization.revision)])], context: context)
                } else {
                    details = try await store.perform("organizations.create", fields: ["input":.object(["name":.string(name),"slug":.string(slug)])], context: context)
                }
                store.select(details.organization); dismiss(); await store.reloadAfterChange()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
            saving = false
        }
    }
    private static func suggestedSlug(_ name: String) -> String {
        let plain = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        return String(plain.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted)
            .filter { !$0.isEmpty }.joined(separator: "-").prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
extension View {
    @ViewBuilder func teamIdentifierInput() -> some View {
        #if os(macOS)
        self.autocorrectionDisabled()
        #else
        self.autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.asciiCapable)
        #endif
    }
}

struct TeamInvitationLink: View {
    let value: TeamInvitationCreated
    @Environment(\.teamCopy) private var copy
    @State private var copied = false
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(L10n.text("common.teams.invitation_ready")).font(Theme.headline)
                if let handle = value.invitation.recipient?.handle { Text("@\(handle)").font(Theme.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: Theme.Space.s)
            Button(copied ? L10n.text("common.teams.copied") : L10n.text("common.teams.copy_invitation_link"), .copy) { copy(value.invitationURL); copied = true }
                .buttonStyle(TeamButtonStyle())
        }
        .padding(Theme.Space.m).background(Theme.rowHighlight, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
enum TeamClipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

private struct TeamCopyKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = TeamClipboard.copy
}
extension EnvironmentValues {
    var teamCopy: (String) -> Void {
        get { self[TeamCopyKey.self] }
        set { self[TeamCopyKey.self] = newValue }
    }
}
