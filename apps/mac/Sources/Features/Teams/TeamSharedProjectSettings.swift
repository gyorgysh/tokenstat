// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct TeamSharedProjectSettings: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let repository: TeamRepository
    let checkout: TeamCheckout
    @Environment(\.dismiss) private var dismiss
    @State private var savedWorkspace: TeamLocalWorkspace?
    @State private var showsSavedSharing = false
    @State private var savedSharingError: String?
    var body: some View {
        ThemedSheet(title: L10n.text("common.teams.project_settings"), subtitle: repository.name, icon: .settings, scrolls: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text(L10n.text("common.teams.project_settings_detail")).font(Theme.body).foregroundStyle(.secondary)
                if savedWorkspace != nil {
                    Button(L10n.text("common.teams.project_setup_resume"), .connect) { showsSavedSharing = true }
                        .buttonStyle(TeamButtonStyle()).accessibilityIdentifier("team.project.recovery.open")
                }
                if let savedSharingError {
                    TeamNotice(message: savedSharingError, warning: true)
                    Button(L10n.text("common.retry"), .refresh) { Task { await loadSavedSharing() } }.buttonStyle(TeamButtonStyle())
                }
                TeamLaneSettings(store: store, context: context, checkoutId: checkout.id)
                ThemeRule()
                TeamAgentGrants(store: store, context: context, repository: repository, checkoutId: checkout.id)
            }
        } actions: {
            Spacer()
            Button(L10n.text("common.close"), .dismiss) { dismiss() }.buttonStyle(TeamButtonStyle()).keyboardShortcut(.cancelAction)
        }
        .task { await loadSavedSharing() }
        .sheet(isPresented: $showsSavedSharing) {
            if let savedWorkspace {
                TeamProjectShareEditor(store: store, context: context, organization: store.selectedOrganization,
                    repositories: store.directory?.repositories.repositories ?? [], initialWorkspace: savedWorkspace,
                    onShared: { _, _ in self.savedWorkspace = nil; showsSavedSharing = false })
            }
        }
    }
    private func loadSavedSharing() async {
        guard store.capabilities?.canResumeProjectSharing == true,
            let local = store.localProjects.first(where: { $0.id == checkout.id }) else { return }
        savedSharingError = nil
        do {
            let result: TeamProjectSetupResult = try await store.read(.projectSharingRead,
                fields: ["organization": .string(repository.organizationId), "workspace": .string(local.workspaceId)], context: context)
            if let setup = result.setup, setup.workspaceId == local.workspaceId,
                result.workspace?.id == local.workspaceId { savedWorkspace = result.workspace }
        } catch is CancellationError {} catch { savedSharingError = error.localizedDescription }
    }
}
