// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import SwiftUI

/// The project's existing host-owned sessions, beside a chat. Closing this
/// pane leaves the sessions running and available in the project sidebar.
struct ChatTerminalPane: View {
    let folder: WorkspaceFolder
    @Bindable var terminals: TerminalsModel
    @Bindable var workspaces: WorkspacesModel
    let onClose: () -> Void
    @State private var selectedID: String?
    @State private var paneSize: CGSize = .zero
    @State private var resolved = false
    @State private var launchError: String?

    private var sessions: [TerminalSession] { terminals.sessions(in: folder.id) }
    private var active: TerminalSession? {
        sessions.first { $0.id == selectedID } ?? terminals.active(in: folder.id)
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
                Menu {
                    ForEach(profiles) { profile in
                        Button { start(profile) } label: {
                            Label(profile.name, systemImage: profile.symbol ?? "terminal")
                        }
                    }
                } label: {
                    Image(systemName: "plus").frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(profiles.isEmpty || !folder.exists)
                .help(L10n.text("apple.chatterminalpane.new_terminal_in_0.aa5d373d", "\(folder.name)"))
                .accessibilityLabel(L10n.text("apple.chatterminalpane.new_terminal_beside_chat.2441e10a"))
                .padding(.trailing, Theme.Space.xs)
            }
            if !sessions.isEmpty {
                HStack(spacing: Theme.Space.s) {
                    Menu {
                        ForEach(sessions) { session in
                            Button { select(session) } label: {
                                Label(sessionName(session), systemImage: "terminal")
                            }
                        }
                    } label: {
                        Label(active.map(sessionName) ?? L10n.text("apple.chatterminalpane.sessions.6fa3cbf4"), systemImage: "terminal")
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel(L10n.text("apple.chatterminalpane.terminal_sessions_beside_chat.fd6daa2a"))
                    Spacer(minLength: 0)
                    Text(folder.name).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                ThemeRule()
            }
            GeometryReader { proxy in
                ZStack {
                    Theme.background
                    if let active {
                        TerminalStack(sessions: sessions, leading: active, focused: active,
                                      onActivate: { select($0) })
                        if active.showsStartingState {
                            ProgressView(L10n.text("apple.chatterminalpane.starting_terminal.1d72e0c6")).font(Theme.caption)
                        }
                    } else {
                        launcher
                    }
                }
                .onChange(of: proxy.size, initial: true) { _, size in paneSize = size }
            }
            if let active, active.showsHostLine { TerminalHost(session: active) }
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
        .onChange(of: active?.id, initial: true) { terminals.focus(active?.id) }
        .onDisappear { terminals.focus(nil) }
    }

    private var launcher: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(L10n.text("apple.chatterminalpane.open_beside_this_chat.aaf2b9ed")).font(Theme.callout.weight(.semibold))
                Text(L10n.text("apple.chatterminalpane.start_a_shell_or_an_installed_agent_in_0.1a6f0bcf", "\(folder.name)"))
                    .font(Theme.caption).foregroundStyle(.secondary)
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

    private func sessionName(_ session: TerminalSession) -> String {
        session.customName ?? session.title ?? (session.command as NSString).lastPathComponent
    }

    private func select(_ session: TerminalSession) {
        selectedID = session.id
        terminals.select(session)
        terminals.focus(session.id)
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
        select(session)
        let scope = WorkSessionContext.shared.scope
        Task {
            let started = await terminals.complete(session, args: args, rows: grid.rows, cols: grid.cols,
                                                   modelProvider: model?.provider, modelID: model?.model,
                                                   selectAfter: false)
            guard scope == WorkSessionContext.shared.scope else { return }
            if started == nil { launchError = terminals.errorMessage ?? L10n.text("apple.chatterminalpane.the_terminal_could_not_start_reconnect_thi.c7cbe80c") }
        }
    }
}
#endif
