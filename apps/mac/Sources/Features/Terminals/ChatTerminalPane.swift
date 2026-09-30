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
            InspectorChromeBar(onClose: onClose, closeLabel: "Close terminal pane") {
                InspectorTitle(title: "Terminal", symbol: "terminal")
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
                .help("New terminal in \(folder.name)")
                .accessibilityLabel("New terminal beside chat")
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
                        Label(active.map(sessionName) ?? "Sessions", systemImage: "terminal")
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("Terminal sessions beside chat")
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
                            ProgressView("Starting terminal…").font(Theme.caption)
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
                Text("Open beside this chat").font(Theme.callout.weight(.semibold))
                Text("Start a shell or an installed agent in \(folder.name).")
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
                    Text(resolved ? "No terminal launchers are available on this computer. Enable installed tools in the project launcher." : "Checking installed tools…")
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
            Text(profile.id == "shell" ? "Shell (\((profile.command as NSString).lastPathComponent))" : profile.name)
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
            if started == nil { launchError = terminals.errorMessage ?? "The terminal could not start. Reconnect this computer and try again." }
        }
    }
}
#endif
