// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

@MainActor struct TeamMobileFixtureRoot: View {
    @State private var store = TeamStore(api: TeamFixtureData.api)
    @State private var sheet: TeamSheet?
    @State private var dark = true
    var body: some View {
        NavigationStack {
            TeamManagementView(store: store, canCreateOrganization: true, onAccount: {})
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu("Fixture") {
                            Toggle("Dark", isOn: $dark)
                            Button("Personal") { store.select(nil) }
                            Button("Example Studio") { store.select(store.organizations.first) }
                            if let context = store.mutationContext {
                                Button("Create organization") { sheet = .create(context) }
                                Button("Invite") { sheet = .invite(context) }
                                Button("Repository access") { sheet = .access(context, TeamFixtureData.repository) }
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
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .task {
            let owner = TeamAccountOwner(scope: .account(origin: "https://accounts.example.test", handle: "example-owner")!, generation: 1, session: "fixture")
            await store.bind(to: owner)
            if TeamFixtureData.state != .invitation && TeamFixtureData.state != .expiredInvitation { store.select(store.organizations.first) }
            await store.refreshSelected()
        }
        .task(id: store.selectionKey) { await store.refreshSelected() }
    }
}
#endif
