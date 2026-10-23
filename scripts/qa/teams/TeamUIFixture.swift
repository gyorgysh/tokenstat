// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Standalone preview of the production Team views. No production Bridge, host, login,
// keychain or clipboard writes. All Teams responses are fictional and avatars
// have no image URLs. Browser actions are intercepted inside the fixture.
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main struct TeamUIFixture: App {
    private let commentStorage = TeamCommentDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("team-ui-drafts-" + UUID().uuidString))
    private let askStorage = TeamAskRecoveryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("team-ui-asks-" + UUID().uuidString))
    init() { AppFonts.register() }
    var body: some Scene {
        #if os(macOS)
        WindowGroup("Teams UI fixture") {
            if ProcessInfo.processInfo.arguments.contains("--fixture-shared-source") { TeamSourceFixture() }
            else { TeamFixtureRoot().environment(\.teamCommentDraftStorage, commentStorage).environment(\.teamAskRecoveryStorage, askStorage) }
        }.defaultSize(width: 1150, height: 760)
        #else
        WindowGroup("Teams UI fixture") {
            if ProcessInfo.processInfo.arguments.contains("--fixture-shared-source") { TeamSourceFixture() }
            else { TeamMobileFixtureRoot().environment(\.teamCommentDraftStorage, commentStorage).environment(\.teamAskRecoveryStorage, askStorage) }
        }
        #endif
    }
}
#if os(macOS)
@MainActor struct TeamFixtureRoot: View {
    @State private var store = TeamStore(api: TeamFixtureData.api)
    @State private var sheet: TeamSheet?
    @State private var dark = true
    @State private var showingSource = false
    @State private var showingFolder = false
    private let owner = TeamAccountOwner(scope: .account(origin: "https://accounts.example.test", handle: "example-owner")!, generation: 1, session: "fixture", personId: TeamFixtureData.state == .member ? "fixture-member" : "fixture-owner")
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("tokenstat").font(Theme.title2.weight(.semibold)).padding(Theme.Space.l)
                Text("Example repositories").font(Theme.callout).foregroundStyle(.secondary).padding(Theme.Space.m)
                Label("Website", systemImage: "folder").font(Theme.body).padding(Theme.Space.m)
                Label("iOS app", systemImage: "folder").font(Theme.body).padding(Theme.Space.m)
                TeamSidebarLinks(store: store, isTeamSelected: true, open: { store.show($0) }, openProjects: { store.showProjects() })
                Spacer()
                ZStack {
                    HStack { Text("Example owner"); Spacer(); Image(systemName: "chevron.up.chevron.down") }.font(Theme.body).padding(Theme.Space.m)
                    NativeMenuTrigger(items: { TeamScopeMenuItems.make(store: store) { store.show(.overview) } }, accessibilityLabel: "Fixture account scope")
                }
                Text("Legend · \(store.selectedOrganization?.name ?? "Personal")").font(Theme.callout).foregroundStyle(.secondary).padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.m)
            }.frame(width: 250).background(Theme.sidebar)
            ThemeRule.vertical
            TeamManagementView(store: store, canCreateOrganization: true, onAccount: {}, transcript: TeamFixtureTranscript.render)
        }
        .tint(Theme.accent)
        .preferredColorScheme(dark ? .dark : .light)
        .environment(\.teamCopy, { _ in })
        .environment(\.openURL, OpenURLAction { _ in .handled })
        .toolbar {
            Toggle("Dark", isOn: $dark)
            Button("Shared source") { showingSource = true }
            Button("Share Website") { showingFolder = true }
            Menu("Fixture size") {
                Button("Wide (1150)") { NSApp.keyWindow?.setContentSize(NSSize(width: 1150, height: 760)) }
                Button("Narrow (950)") { NSApp.keyWindow?.setContentSize(NSSize(width: 950, height: 700)) }
                Button("Compact (780)") { NSApp.keyWindow?.setContentSize(NSSize(width: 780, height: 650)) }
            }
            Menu("Fixture forms") {
                if let context = store.mutationContext {
                    Button("Create organization") { sheet = .create(context) }
                    Button("Invite") { sheet = .invite(context) }
                    Button("Add repository") { sheet = .repository(context) }
                    Button("Access") { sheet = .access(context, TeamFixtureData.repository) }
                    Button("Checkouts") { sheet = .checkouts(context, TeamFixtureData.repository) }
                    Button("Member role") { sheet = .memberRole(context, TeamFixtureData.member) }
                    Button("Remove member") { sheet = .remove(context, TeamFixtureData.member) }
                    Button("Transfer ownership") { sheet = .transfer(context) }
                    Button("Delete") { sheet = .delete(context) }
                }
                Button("Authorize") { sheet = .authorize }
            }
        }
        .sheet(isPresented: $showingSource) { TeamSourceFixture().frame(width: 650, height: 600) }
        .sheet(isPresented: $showingFolder) {
            TeamFolderShareView(store: store, workspace: .init(id: "/example/Website", name: "Website", path: "/example/Website"),
                onManageTeams: { showingFolder = false; store.show(.overview); store.select(nil) },
                onOpen: { organization, repository, checkout in showingFolder = false; store.openProject(repository, in: organization, checkout: checkout) })
                .frame(width: 580, height: 720)
        }
        .sheet(item: $sheet) { route in
            TeamEditorSheet(store: store, route: route, canCreateOrganization: true, onAccount: {}).frame(width: 560, height: 600)
        }
        .task {
            await store.bind(to: owner)
            store.select(store.organizations.first)
            await store.refreshSelected()
        }
        .task(id: store.selectionKey) { await store.refreshSelected() }
    }
}
#endif
