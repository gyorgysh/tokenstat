// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

@MainActor struct TeamMobileFixtureRoot: View {
    @State private var store = TeamStore(api: TeamFixtureData.api)
    @State private var sheet: TeamSheet?
    @State private var dark = true
    @Environment(\.teamCommentDraftStorage) private var commentStorage
    var body: some View {
        NavigationStack {
            TeamManagementView(store: store, canCreateOrganization: true, onAccount: {}, transcript: TeamFixtureTranscript.render)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu("Fixture") {
                            Toggle("Dark", isOn: $dark)
                            Button("Personal") { store.select(nil) }
                            Button("Example Studio") { store.select(store.organizations.first) }
                            Button("Team chats") { store.show(.chats) }
                            if TeamFixtureData.state == .commentUncertain {
                                Button("Remove repository access") { Task { await TeamFixtureComments.shared.removeAccess(); await store.refreshSelected() } }
                            }
                            if let context = store.mutationContext {
                                Button("Create organization") { sheet = .create(context) }
                                Button("Invite") { sheet = .invite(context) }
                                Button("Repository access") { sheet = .access(context, TeamFixtureData.repository) }
                                Button("Checkouts") { sheet = .checkouts(context, TeamFixtureData.repository) }
                                Button("Transfer ownership") { sheet = .transfer(context) }
                                Button("Delete organization") { sheet = .delete(context) }
                            }
                            Button("Authorize") { sheet = .authorize }
                        }
                    }
                }
        }
        .tint(Theme.accent)
        .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--fixture-large-text") ? .accessibility3 : .large)
        .preferredColorScheme(dark ? .dark : .light)
        .environment(\.teamCopy, { _ in })
        .environment(\.openURL, OpenURLAction { _ in .handled })
        .sheet(item: $sheet) { route in
            TeamEditorSheet(store: store, route: route, canCreateOrganization: true, onAccount: {})
                .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--fixture-large-text") ? .accessibility3 : .large)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .task {
            let owner = TeamAccountOwner(scope: .account(origin: "https://accounts.example.test", handle: "example-owner")!, generation: 1, session: "fixture", personId: TeamFixtureData.state == .member ? "fixture-member" : "fixture-owner")
            if TeamFixtureData.state == .draftOffline {
                let target = TeamCommentTarget(origin: owner.scope.origin, person: "fixture-owner", organization: "org_fixture", repository: "repo_fixture", checkout: "checkout_fixture", share: "share_fixture", host: String(repeating: "ab", count: 32))
                do {
                    let saved = try await commentStorage.save(target, text: "Saved before the fictional outage", expected: nil, location: TeamCommentLocation(organization: "Example Studio", repository: "Website", chat: "Quarterly totals", computer: "Example Mac"))
                    if let saved { _ = try await commentStorage.reserve(target, expected: saved) }
                } catch { assertionFailure("Could not prepare the disposable offline draft") }
            }
            await store.bind(to: owner)
            if TeamFixtureData.state != .invitation && TeamFixtureData.state != .expiredInvitation { store.select(store.organizations.first) }
            await store.refreshSelected()
        }
        .task(id: store.selectionKey) { await store.refreshSelected() }
    }
}
#endif
