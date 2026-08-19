// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI
import UIKit

/// The client with navigation down the left, for an iPad that has a keyboard.
///
/// Not a second app. Every screen here is the screen the tab bar shows, in the
/// detail column instead of behind a tab. What the sidebar adds is the thing a
/// tab bar cannot hold: the account's machines, their folders, and the sessions
/// running in them, all visible at once the way the Mac's sidebar shows them.
///
/// `.sidebarAdaptable` would have been four lines and can only ever show the
/// four destinations, which is exactly the part that was already fine.
struct ClientSidebarRoot: View {
    @Binding var showAccount: Bool

    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation
    /// A pointer means a person aiming, not a thumb landing. Rows tighten and
    /// grow hover states. See `ClientLayout`.
    @Environment(PointerKeyboardModel.self) private var input

    /// One workspaces model for the whole layout: the tree in the sidebar and
    /// the screen in the detail column are the same connection, not two.
    @State private var workspaces = ClientWorkspacesModel()
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            NavigationStack {
                detail
            }
        }
        .navigationSplitViewStyle(.balanced)
        .clientShortcuts(shortcuts)
        .task { await workspaces.refresh(account: account.account) }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task { await workspaces.recoverAfterNetworkChange(account: account.account) }
        }
        .fullScreenCover(item: Binding(
            get: { workspaces.activeTerminal },
            set: { workspaces.activeTerminal = $0 }
        )) { session in
            ClientTerminalScreen(
                session: session,
                hostName: workspaces.hosts.first { $0.peerKey == workspaces.connectedKey }?.name ?? "",
                onClose: { workspaces.activeTerminal = nil },
                onClosedProcess: {
                    Task { await workspaces.refresh(account: account.account) }
                }
            )
        }
    }

    // MARK: - Sidebar

    private var selection: Binding<ClientSidebarItem?> {
        Binding(
            get: {
                if let folder = navigation.folderID, navigation.destination == .workspaces {
                    return .folder(folder)
                }
                return .destination(navigation.destination)
            },
            set: { item in
                guard let item else { return }
                switch item {
                case .destination(let tab):
                    navigation.destination = tab
                    navigation.folderID = nil
                case .folder(let id):
                    navigation.open(folderID: id)
                case .session(let id):
                    if let info = workspaces.sessions.first(where: { $0.id == id }) {
                        workspaces.openSession(info)
                    }
                }
            }
        )
    }

    private var sidebar: some View {
        List(selection: selection) {
            Section {
                ForEach(ClientTab.allCases) { tab in
                    Label(tab.label, systemImage: tab.symbol)
                        .tag(ClientSidebarItem.destination(tab))
                }
            }
            Section("Machines") {
                if workspaces.hosts.isEmpty {
                    Text("No host computers yet")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(workspaces.hosts) { host in
                    hostRow(host)
                    if workspaces.connectedKey == host.peerKey {
                        ForEach(workspaces.folders) { folder in
                            folderRow(folder)
                            ForEach(sessions(in: folder)) { session in
                                sessionRow(session)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // A thumb needs 44 points. A trackpad pointer does not, and the whole
        // point of this layout is seeing more of the account at once.
        .environment(\.defaultMinListRowHeight, input.hasPointer ? 32 : 44)
        .navigationTitle("tokenstat")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await workspaces.refresh(account: account.account) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AvatarButton { showAccount = true }
            }
        }
    }

    /// What `⌘` opens, and what holding it lists.
    ///
    /// The numbers follow the sidebar's own order rather than the tab bar's,
    /// because the sidebar is what is on screen. `⌘,` is Settings everywhere
    /// on this platform, and here the account is the settings.
    private var shortcuts: [ClientShortcut] {
        var commands: [ClientShortcut] = []
        for (index, tab) in ClientTab.allCases.enumerated() {
            guard let key = "1234".dropFirst(index).first else { continue }
            commands.append(
                ClientShortcut(id: tab.rawValue, title: tab.label, key: KeyEquivalent(key)) {
                    navigation.destination = tab
                    navigation.folderID = nil
                }
            )
        }
        commands.append(
            ClientShortcut(id: "refresh", title: "Refresh", key: "r") {
                Task { await workspaces.refresh(account: account.account) }
            }
        )
        commands.append(
            ClientShortcut(id: "sidebar", title: "Toggle Sidebar", key: "\\") {
                columns = columns == .detailOnly ? .all : .detailOnly
            }
        )
        commands.append(
            ClientShortcut(id: "account", title: "Account", key: ",") {
                showAccount = true
            }
        )
        return commands
    }

    /// A machine, with the dot that says whether it is awake.
    ///
    /// Asleep machines still list, greyed. The sidebar is a map of the account
    /// rather than of what happens to be running.
    private func hostRow(_ host: ClientHost) -> some View {
        Button {
            if workspaces.connectedKey == host.peerKey {
                workspaces.disconnect()
            } else {
                Task { await workspaces.connect(host) }
            }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Circle()
                    .fill(host.online == true ? Theme.accent : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
                Image(systemName: ClientDeviceIcon.symbol(name: host.name, isHost: true))
                    .foregroundStyle(.secondary)
                Text(host.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if workspaces.isConnecting == host.peerKey {
                    ProgressView().controlSize(.small)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(host.online == false)
        .hoverEffect(.highlight)
    }

    private func folderRow(_ folder: WorkspaceFolder) -> some View {
        Label(folder.name, systemImage: "folder.fill")
            .lineLimit(1)
            .padding(.leading, Theme.Space.m)
            .tag(ClientSidebarItem.folder(folder.id))
            .hoverEffect(.highlight)
    }

    private func sessionRow(_ session: PtySessionInfo) -> some View {
        Label {
            Text(sessionTitle(session)).lineLimit(1)
        } icon: {
            Image(systemName: session.alive ? "terminal.fill" : "terminal")
                .foregroundStyle(session.alive ? Theme.accent : .secondary)
        }
        .font(ClientType.caption)
        .padding(.leading, Theme.Space.l)
        .tag(ClientSidebarItem.session(session.id))
        .hoverEffect(.highlight)
    }

    private func sessionTitle(_ session: PtySessionInfo) -> String {
        if let harness = harnessID(forCommand: session.command) { return harnessName(harness) }
        return URL(fileURLWithPath: session.command).lastPathComponent
    }

    /// The sessions running in one folder, matched on the directory rather
    /// than on a label: two checkouts can share a basename.
    private func sessions(in folder: WorkspaceFolder) -> [PtySessionInfo] {
        workspaces.sessions.filter { $0.cwd == folder.path }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = navigation.folderID,
           navigation.destination == .workspaces,
           let folder = workspaces.folders.first(where: { $0.id == id }),
           let peer = workspaces.connectedKey
        {
            ClientWorkspaceDetailView(
                peer: peer,
                hostName: workspaces.hosts.first { $0.peerKey == peer }?.name ?? "",
                folder: folder
            )
        } else {
            switch navigation.destination {
            case .home: ClientHomeView()
            case .insights: ClientInsightsView()
            case .machines: ClientDevicesView()
            case .workspaces: ClientWorkspacesView(model: workspaces)
            }
        }
    }
}

/// What one row in the sidebar stands for.
enum ClientSidebarItem: Hashable {
    case destination(ClientTab)
    case folder(String)
    case session(String)
}

#endif
