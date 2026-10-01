// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import SwiftUI

/// Project shells and saved SSH servers beside a chat. Closing the pane
/// leaves its host-owned sessions running and available in the sidebar.
struct ChatTerminalPane: View {
    let folder: WorkspaceFolder
    @Bindable var terminals: TerminalsModel
    @Bindable var workspaces: WorkspacesModel
    @Bindable var ssh: SSHLibraryModel
    @Bindable var sshSessions: SSHSessionsModel
    let onManageServers: () -> Void
    let onClose: () -> Void
    @State private var showingLauncher = false
    @State private var connectingServer: SSHHost?
    @State private var paneSize: CGSize = .zero
    @State private var resolved = false
    @State private var launchError: String?

    private var sessions: [WorkspaceTerminal] { terminals.workspaceTerminals(in: folder.id) }
    private var active: WorkspaceTerminal? {
        showingLauncher ? nil : terminals.activeTerminal(in: folder.id)
    }
    private var activeTitle: String {
        active?.label ?? L10n.text("apple.chatterminalpane.sessions.6fa3cbf4")
    }
    private var layout: TerminalSplitLayout { terminals.layout(for: folder.id) }
    private var leading: WorkspaceTerminal? { showingLauncher ? nil : terminals.leadingTerminal(in: folder.id) }
    private var trailing: WorkspaceTerminal? { showingLauncher ? nil : terminals.trailingTerminal(in: folder.id) }
    private var focusedIDs: Set<String> {
        Set([leading, trailing].compactMap { $0?.local?.id })
    }
    private var peer: String? { Bridge.chatRoute(workspaceID: folder.id).peer }
    private var profiles: [LaunchProfile] {
        let catalog = LaunchCatalog.shared
        let all = peer.map { catalog.remoteAvailable(for: $0) } ?? catalog.available
        return all.filter {
            !$0.hidden && $0.openUrl == nil && !LauncherVisibility.shared.isHidden($0.id, scope: peer ?? "local")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose, closeLabel: L10n.text("apple.chatterminalpane.close_terminal_pane.8cf7ffa3")) {
                InspectorTitle(title: L10n.text("apple.chatterminalpane.terminal.e0926fda"), symbol: "terminal")
                Spacer(minLength: 0)
                Button { showingLauncher.toggle() } label: {
                    Image(systemName: "square.grid.2x2").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).foregroundStyle(showingLauncher ? Theme.accent : Theme.controlGlyph)
                .help(L10n.text("apple.serverlauncher.terminal_launcher"))
                .accessibilityLabel(L10n.text("apple.serverlauncher.terminal_launcher"))
                Menu {
                    ForEach(profiles) { profile in
                        Button { start(profile) } label: {
                            Label(profile.name, systemImage: profile.symbol ?? "terminal")
                        }
                        .disabled(!folder.exists)
                    }
                    if !ssh.hosts.isEmpty {
                        Divider()
                        Menu(L10n.text("apple.rootview.servers.68d7beb6")) {
                            ForEach(ssh.launcherHosts) { host in
                                Button { openServer(host) } label: {
                                    Label(host.label, systemImage: "server.rack")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus").frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(profiles.isEmpty && ssh.hosts.isEmpty)
                .help(L10n.text("apple.chatterminalpane.new_terminal_in_0.aa5d373d", "\(folder.name)"))
                .accessibilityLabel(L10n.text("apple.chatterminalpane.new_terminal_beside_chat.2441e10a"))
                .padding(.trailing, Theme.Space.xs)
            }
            if !sessions.isEmpty {
                HStack(spacing: Theme.Space.s) {
                    Menu {
                        ForEach(sessions) { session in
                            Button { select(session) } label: {
                                Label(session.label, systemImage: session.ssh == nil ? "terminal" : "server.rack")
                            }
                        }
                    } label: {
                        Label(activeTitle, systemImage: active?.ssh == nil ? "terminal" : "server.rack")
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel(L10n.text("apple.chatterminalpane.terminal_sessions_beside_chat.fd6daa2a"))
                    Spacer(minLength: 0)
                    Menu {
                        Button(L10n.text("apple.terminalpane.single.8888a029")) { terminals.setLayout(.single, for: folder.id) }
                        Button(L10n.text("apple.terminalpane.side_by_side.a3d7b387")) { terminals.setLayout(.side, for: folder.id) }
                        Button(L10n.text("apple.terminalpane.stacked.c2fed746")) { terminals.setLayout(.stacked, for: folder.id) }
                        if layout.isSplit {
                            Divider()
                            TerminalSwapButton(layout: layout) { terminals.swapPanes(in: folder.id) }
                                .disabled(trailing == nil)
                        }
                    } label: {
                        Image(systemName: ActionIcon.compare.symbol)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel(L10n.text("apple.terminalpane.split_terminals.d4e7a34f"))
                    Text(folder.name)
                        .font(Theme.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                ThemeRule()
            }
            GeometryReader { proxy in
                ZStack {
                    Theme.background
                    TerminalStack(sessions: sessions, leading: leading, trailing: trailing, focused: active,
                                  splitAxis: layout.axis, fraction: CGFloat(terminals.fraction(for: folder.id)),
                                  isSurfaceVisible: active != nil, onActivate: { select($0) })
                        .allowsHitTesting(active != nil)
                        .modifier(PaletteSnippetSheet(session: active?.ssh))
                    if active != nil, layout.isSplit {
                        TerminalSplitHandle(axis: layout.axis ?? .horizontal, fraction: Binding(
                            get: { terminals.fraction(for: folder.id) },
                            set: { terminals.setFraction($0, for: folder.id) }
                        ))
                        if trailing == nil { trailingPlaceholder(in: proxy.size) }
                    }
                    if active?.local?.showsStartingState == true {
                        ProgressView(L10n.text("apple.chatterminalpane.starting_terminal.1d72e0c6")).font(Theme.caption)
                    }
                    if active == nil {
                        launcher
                    }
                }
                .onChange(of: proxy.size, initial: true) { _, size in paneSize = size }
            }
            if let active = active?.local, active.showsHostLine { TerminalHost(session: active) }
            if let serverError = active?.ssh?.error {
                Text(serverError).font(Theme.caption).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true).padding(Theme.Space.m)
            }
            if let launchError {
                Text(launchError).font(Theme.caption).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true).padding(Theme.Space.m)
            }
        }
        .background(Theme.background)
        .task(id: folder.id) {
            if let peer { await LaunchCatalog.shared.resolveRemote(peer: peer) }
            else { await LaunchCatalog.shared.resolve() }
            guard !Task.isCancelled else { return }
            resolved = true
        }
        .onChange(of: focusedIDs, initial: true) { terminals.focus(focusedIDs) }
        .onChange(of: sessions.map(\.id)) { terminals.reconcilePane(in: folder.id) }
        .onDisappear { terminals.focus(nil) }
        .sheet(item: $connectingServer) { host in
            SSHConnectForm(host: host, model: ssh) { session in
                sshSessions.adopt(session, startup: session.hostID.map { ssh.startupSnippets(for: $0) } ?? [])
                if let adopted = sshSessions.sessions.first(where: { $0.id == session.id }) {
                    selectServerSession(adopted)
                }
            }
        }
    }

    private var launcher: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(L10n.text("apple.chatterminalpane.open_beside_this_chat.aaf2b9ed")).font(Theme.callout.weight(.semibold))
                Text(L10n.text("apple.chatterminalpane.start_a_shell_or_an_installed_agent_in_0.1a6f0bcf", "\(folder.name)"))
                    .font(Theme.caption).foregroundStyle(.secondary)
                ServerLauncher(library: ssh, sessions: sshSessions, onOpen: openServer, onManage: onManageServers)
                    .padding(.top, Theme.Space.s)
                Label(L10n.text("common.terminals"), systemImage: "terminal")
                    .font(Theme.callout.weight(.semibold)).padding(.top, Theme.Space.s)
                ForEach(profiles) { profile in
                    Button { start(profile) } label: {
                        HStack {
                            profileLabel(profile)
                            Spacer()
                            Image(systemName: "plus").foregroundStyle(.secondary)
                        }
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    }
                    .buttonStyle(.plain).disabled(!folder.exists)
                }
                if profiles.isEmpty {
                    Text(resolved ? L10n.text("apple.chatterminalpane.no_terminal_launchers_are_available_on_thi.6e800543") : L10n.text("apple.chatterminalpane.checking_installed_tools.5a7a24c9"))
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Space.l)
        }
    }

    private func profileLabel(_ profile: LaunchProfile) -> some View {
        HStack(spacing: Theme.Space.s) {
            if let harness = profile.harnessID {
                HarnessMark(id: harness, size: 18)
            } else {
                Image(systemName: profile.symbol ?? "terminal").frame(width: 18)
            }
            Text(profile.id == "shell" ? L10n.text("apple.chatterminalpane.shell_0.166d3d3c", "\((profile.command as NSString).lastPathComponent)") : profile.name)
                .font(Theme.callout)
        }
    }

    private func select(_ session: WorkspaceTerminal) {
        showingLauncher = false
        terminals.select(session, in: folder.id)
        terminals.focus(focusedIDs)
    }

    private func selectServerSession(_ session: SSHLiveTerminal) {
        launchError = nil
        showingLauncher = false
        terminals.attach(session, in: folder.id)
        terminals.focus(focusedIDs)
    }

    private func openServer(_ host: SSHHost) {
        let mine = sshSessions.sessions(for: host.id).filter(\.alive)
        if let session = mine.first(where: { $0.id == sshSessions.selectedID }) ?? mine.last {
            selectServerSession(session)
        } else {
            connectingServer = host
        }
    }

    private func start(_ profile: LaunchProfile) {
        guard folder.exists else { return }
        launchError = nil
        let grid = TerminalMetrics.grid(fitting: paneSize)
        let args = workspaces.bypassPermissions(for: folder.id) ? profile.args + profile.bypassArgs : profile.args
        let model = LaunchProfile.acceptsLocalModel(profile.id)
            ? LocalModelSelection.stored(for: folder.id, in: workspaces) : nil
        let session = terminals.begin(workspace: folder, command: profile.command,
                                      rows: grid.rows, cols: grid.cols, selectAfter: false)
        select(WorkspaceTerminal(session))
        let scope = WorkSessionContext.shared.scope
        Task {
            let started = await terminals.complete(session, args: args, rows: grid.rows, cols: grid.cols,
                                                   modelProvider: model?.provider, modelID: model?.model,
                                                   selectAfter: false)
            guard scope == WorkSessionContext.shared.scope else { return }
            if started == nil { launchError = terminals.errorMessage ?? L10n.text("apple.chatterminalpane.the_terminal_could_not_start_reconnect_thi.c7cbe80c") }
        }
    }

    private func trailingPlaceholder(in size: CGSize) -> some View {
        let fraction = CGFloat(terminals.fraction(for: folder.id))
        return TerminalSplitPlaceholder()
            .frame(width: layout == .stacked ? size.width : size.width * (1 - fraction),
                   height: layout == .stacked ? size.height * (1 - fraction) : size.height)
            .frame(width: size.width, height: size.height, alignment: layout == .stacked ? .bottom : .trailing)
            .allowsHitTesting(false)
    }
}
#endif
