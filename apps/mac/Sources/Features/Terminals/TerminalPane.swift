// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import Foundation
import SwiftUI

struct TerminalPane: View {
    let folder: WorkspaceFolder
    @Bindable var terminals: TerminalsModel
    @Bindable var workspaces: WorkspacesModel
    @Bindable var chat: ChatModel
    @Bindable var ssh: SSHLibraryModel
    @Bindable var sshSessions: SSHSessionsModel
    var onManageServers: () -> Void
    var onOpenSection: (WorkspaceSection) -> Void
    var isSurfaceActive: Bool = true
    @State private var focusOwner = UUID()
    @State private var closingSession: WorkspaceTerminal?
    @State private var connectingServer: SSHHost?
    @State private var browserWorkspaces: Set<String> = []
    @State private var browserURLs: [String: String] = [:]

    private var showsBrowser: Bool { browserWorkspaces.contains(folder.id) }

    private var sessions: [WorkspaceTerminal] {
        terminals.workspaceTerminals(in: folder.id)
    }

    private var front: WorkspaceSurface {
        workspaces.front(in: folder.id)
    }

    private var tabs: [WorkspaceSurface] {
        workspaces.tabs(in: folder.id)
    }

    private var showsTerminal: Bool { front == .sessions }

    private var launcher: LaunchCatalog { LaunchCatalog.shared }

    private var peer: String? {
        let parts = folder.id.split(separator: ":", maxSplits: 2).map(String.init)
        return parts.count == 3 && parts[0] == "remote" ? parts[1] : nil
    }

    private var launcherProfiles: [LaunchProfile] {
        let all: [LaunchProfile] = {
            guard let peer else { return launcher.available }
            let profiles = launcher.remoteAvailable(for: peer)
            if profiles.isEmpty { return [LaunchProfile.shellFallback] }
            return profiles
        }()
        let scope = peer ?? "local"
        let visibility = LauncherVisibility.shared
        return all.filter { !$0.hidden && !visibility.isHidden($0.id, scope: scope) }
    }

    private var launcherCatalog: [LaunchProfile] {
        guard let peer else { return launcher.catalog }
        let profiles = launcher.remoteCatalog(for: peer)
        if profiles.isEmpty { return [LaunchProfile.shellFallback] }
        return profiles
    }

    private var modelProfiles: [LaunchProfile] {
        launcherProfiles.filter { LaunchProfile.acceptsLocalModel($0.id) }
    }

    @State private var paneSize: CGSize = .zero

    private var spawnGrid: (rows: Int, cols: Int) {
        TerminalMetrics.grid(fitting: paneSize)
    }

    @State private var showingPort = false

    private var active: WorkspaceTerminal? {
        terminals.activeTerminal(in: folder.id)
    }

    private var focusedSessionIDs: Set<String> {
        guard isSurfaceActive, showsTerminal else { return [] }
        return Set(visibleSessions.compactMap { $0.local?.id })
    }

    private var splitLayout: TerminalSplitLayout {
        terminals.layout(for: folder.id)
    }

    private var splitFraction: Binding<Double> {
        Binding(
            get: { terminals.fraction(for: folder.id) },
            set: { terminals.setFraction($0, for: folder.id) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if folder.exists {
                strip
                ThemeRule()
                // Must expand. A GeometryReader with no flexible frame can keep a
                // zero size after a terminal↔launcher flip; the launch tiles then
                // paint at their ideal width over the sidebar until a resize.
                HSplitView {
                    surface
                        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                    if showsBrowser {
                        browserPane
                            .frame(minWidth: 280, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsTerminal {
                    hostLines
                }
            } else {
                missingFolder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: focusedSessionIDs, initial: true) {
            terminals.focus(owner: focusOwner, ids: focusedSessionIDs)
        }
        .onDisappear { terminals.focus(owner: focusOwner, ids: []) }
        .onChange(of: sessions.map(\.id)) { terminals.reconcilePane(in: folder.id) }
        .sheet(item: $connectingServer) { host in
            SSHConnectForm(host: host, model: ssh) { session in
                sshSessions.adopt(session, startup: session.hostID.map { ssh.startupSnippets(for: $0) } ?? [])
                if let adopted = sshSessions.sessions.first(where: { $0.id == session.id }) {
                    terminals.attach(adopted, in: folder.id)
                    workspaces.showTerminal(in: folder.id)
                }
            }
        }
        .task(id: peer) {
            await launcher.resolve()
            guard let peer else { return }
            var attempts = 0
            while !Task.isCancelled, attempts < 6 {
                await launcher.resolveRemote(peer: peer)
                if !launcher.remoteCatalog(for: peer).isEmpty { break }
                attempts += 1
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog(
            L10n.text("apple.terminalpane.save_changes_before_closing.6239f0dc"),
            isPresented: closingUnsaved,
            titleVisibility: .visible,
            presenting: workspaces.pendingClose
        ) { pending in
            Button(L10n.text("common.save")) { Task { await workspaces.saveAndClosePending() } }
            Button(L10n.text("apple.terminalpane.don_t_save.20961bde"), role: .destructive) { workspaces.discardAndClosePending() }
            Button(L10n.text("common.cancel"), role: .cancel) { workspaces.pendingClose = nil }
        } message: { pending in
            Text(L10n.text("apple.terminalpane.0_has_changes_that_are_not_written_to_disk.e072f51f", "\(pending.path)"))
        }
        .confirmationDialog(
            L10n.text("apple.terminalpane.stop_this_session.5efe50c8"),
            isPresented: Binding(
                get: { closingSession != nil },
                set: { if !$0 { closingSession = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("apple.terminalpane.stop_and_close.52b40c33"), role: .destructive) {
                if let session = closingSession {
                    closingSession = nil
                    Task { await terminals.close(session, in: folder.id) }
                }
            }
            Button(L10n.text("common.cancel"), role: .cancel) { closingSession = nil }
        } message: {
            Text(closingSession?.ssh == nil
                 ? L10n.text("apple.terminalpane.the_process_will_be_killed_a_stopped_sessi.bf3e9249")
                 : L10n.text("apple.sshterminalpane.whatever_is_running_in_it_stops_nothing_el.f25aee6b"))
        }
    }

    /// Every session in this folder, mounted at once, with the selected one in
    /// front.
    ///
    /// Not `if session == active`, which is the obvious way and the wrong one.
    /// Removing a terminal from the hierarchy and putting it back makes AppKit
    /// lay it out again, which resizes the pty, which raises SIGWINCH, which
    /// makes a full screen program repaint from scratch. That is the flicker
    /// and the pause on every tab switch. Keeping them all mounted at the same
    /// size means switching changes nothing about the terminal at all: no
    /// relayout, no resize, no repaint.
    private var surface: some View {
        // Two layers, not one GeometryReader ZStack:
        //
        // 1. Terminal stack is sized by a reader (AppKit needs explicit frames).
        // 2. Launch/Files/… covers are *siblings* of that reader and expand with
        //    the pane. Putting them inside the reader made a stuck 0-width
        //    measurement clip the launch tiles to gear icons on the left edge
        //    after terminal → Launch. The cover must not depend on that size.
        //
        // The stack view is also `isHidden` while a cover is up: SwiftUI opacity
        // does not hide NSViewRepresentable, so the black terminal otherwise
        // paints over the cover.
        ZStack {
            Theme.background

            GeometryReader { proxy in
                let size = proxy.size
                TerminalStack(
                    sessions: sessions,
                    leading: showsTerminal
                        ? (splitLayout.isSplit
                            ? terminals.leadingTerminal(in: folder.id)
                            : active)
                        : nil,
                    trailing: showsTerminal && splitLayout.isSplit
                        ? terminals.trailingTerminal(in: folder.id)
                        : nil,
                    focused: showsTerminal ? active : nil,
                    splitAxis: showsTerminal ? splitLayout.axis : nil,
                    fraction: CGFloat(terminals.fraction(for: folder.id)),
                    claimsFocus: isSurfaceActive && showsTerminal,
                    isSurfaceVisible: isSurfaceActive && showsTerminal,
                    onActivate: { terminals.select($0, in: folder.id) }
                )
                .frame(width: size.width, height: size.height)
                .modifier(PaletteSnippetSheet(session: active?.ssh))

                if showsTerminal, splitLayout.isSplit {
                    TerminalSplitHandle(
                        axis: splitLayout.axis ?? .horizontal,
                        fraction: splitFraction
                    )
                    .frame(width: size.width, height: size.height)
                    if terminals.trailingTerminal(in: folder.id) == nil {
                        trailingPlaceholder(in: size)
                    }
                }

                if showsTerminal, !splitLayout.isSplit, let active = active?.local, active.showsStartingState {
                    SessionStartingView(command: active.command)
                        .frame(width: size.width, height: size.height)
                }

                Color.clear
                    .frame(width: size.width, height: size.height)
                    .overlay(alignment: .bottomTrailing) {
                        if showsTerminal {
                            TerminalNotices(sessions: visibleSessions.compactMap(\.local))
                                .padding(Theme.Space.s)
                        }
                    }
                    .allowsHitTesting(false)

                Color.clear
                    .onAppear { paneSize = size }
                    .onChange(of: CGSize(width: quantised(size.width, step: 8),
                                         height: quantised(size.height, step: 8))) { _, new in
                        paneSize = new
                    }
            }
            .allowsHitTesting(showsTerminal)

            // Cover fills the pane on its own. Never sized from the terminal
            // GeometryReader (that is what left gear icons on a black void).
            coverFill
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var coverFill: some View {
        if front == .launcher {
            if isSurfaceActive {
                LaunchSurface(
                    folder: folder,
                    terminals: terminals,
                    workspaces: workspaces,
                    chat: chat,
                    ssh: ssh,
                    sshSessions: sshSessions,
                    onOpenServer: openServer,
                    onManageServers: onManageServers,
                    onOpenSection: onOpenSection,
                    grid: spawnGrid,
                    profiles: launcherCatalog,
                    modelPeer: peer
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if front == .changes {
            WorkingTreeReviewView(folder: folder, model: workspaces)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case let .commit(id) = front {
            Group {
                if let detail = workspaces.commit(id, in: folder.id) {
                    CommitView(detail: detail)
                        .task(id: detail) {
                            await WorkViewedChange.save(owner: WorkViewedChange.owner(folderID: folder.id), commit: detail)
                        }
                } else if let message = workspaces.commitError(id, in: folder.id) {
                    failedRead(message)
                } else {
                    reading("commit")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(id)
        } else if case let .file(path) = front {
            fileSurface(path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if front == .files {
            WorkspaceFilesView(model: workspaces, folder: folder, surface: .content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case let .browser(id) = front,
                  let browser = workspaces.browserTabs(in: folder.id).first(where: { $0.id == id }) {
            ProjectBrowserView(
                workspaceID: folder.id, initialURL: browser.url,
                waitsForService: browser.waitsForService,
                onURLChange: { workspaces.setBrowserURL($0, in: folder.id, tabID: browser.id) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sessions.isEmpty, isSurfaceActive {
            LaunchSurface(
                folder: folder,
                terminals: terminals,
                workspaces: workspaces,
                chat: chat,
                ssh: ssh,
                sshSessions: sshSessions,
                onOpenServer: openServer,
                onManageServers: onManageServers,
                onOpenSection: onOpenSection,
                grid: spawnGrid,
                profiles: launcherCatalog,
                modelPeer: peer
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func trailingPlaceholder(in size: CGSize) -> some View {
        let fraction = terminals.fraction(for: folder.id)
        return TerminalSplitPlaceholder()
            .frame(
                width: splitLayout == .stacked ? size.width : size.width * (1 - fraction),
                height: splitLayout == .stacked ? size.height * (1 - fraction) : size.height
            )
            .frame(width: size.width, height: size.height, alignment: splitLayout == .stacked ? .bottom : .trailing)
            .allowsHitTesting(false)
    }

    private var closingUnsaved: Binding<Bool> {
        Binding(
            get: { workspaces.pendingClose != nil },
            set: { if !$0 { workspaces.pendingClose = nil } }
        )
    }


    private var browserPane: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: { browserWorkspaces.remove(folder.id) }, closeLabel: L10n.text("apple.terminalpane.close_browser.dd33033e")) {
                InspectorTitle(title: L10n.text("common.browser"), symbol: "globe")
                Spacer(minLength: 0)
            }
            ProjectBrowserView(workspaceID: folder.id, initialURL: browserURLs[folder.id] ?? "", allowsExternalNavigation: true) {
                browserURLs[folder.id] = $0
            }
            .id(folder.id)
        }
        .environment(\.desktopChromeJoined, false)
    }

    @ViewBuilder
    private func fileSurface(_ path: String) -> some View {
        EditorView(model: workspaces, folder: folder, path: path)
            .id(path)
    }

    private func reading(_ what: String) -> some View {
        VStack {
            Spacer()
            Text(L10n.text("apple.terminalpane.reading_0.f5d364f3", "\(what)"))
                .font(Theme.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func failedRead(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(Theme.callout)
                .foregroundStyle(Theme.danger)
                .multilineTextAlignment(.center)
                .padding(Theme.Space.m)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var selectedStripID: String {
        if showsTerminal, let active { return "session:" + active.id }
        return isLaunchSelected ? "launcher" : front.id
    }

    private var strip: some View {
        HStack(spacing: Theme.Space.s) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        LaunchChip(isSelected: isLaunchSelected) {
                            workspaces.showLauncher(in: folder.id)
                        }
                        .id("launcher")

                        ForEach(sessions) { session in
                            SessionChip(
                                session: session,
                                isSelected: showsTerminal && session.id == active?.id,
                                isOtherHalf: showsTerminal
                                    && splitLayout.isSplit
                                    && (session.id == terminals.leadingTerminal(in: folder.id)?.id
                                        || session.id == terminals.trailingTerminal(in: folder.id)?.id)
                                    && session.id != active?.id
                            ) {
                                workspaces.showTerminal(in: folder.id)
                                if NSEvent.modifierFlags.contains(.option) {
                                    terminals.sendToOtherHalf(session, in: folder.id)
                                } else {
                                    terminals.select(session, in: folder.id)
                                }
                            } onClose: {
                                if session.alive {
                                    closingSession = session
                                } else {
                                    Task { await terminals.close(session, in: folder.id) }
                                }
                            } onSplit: {
                                workspaces.showTerminal(in: folder.id)
                                terminals.sendToOtherHalf(session, in: folder.id)
                            }
                            .id("session:" + session.id)
                        }

                        ForEach(tabs) { tab in
                            chip(for: tab)
                                .id(tab.id)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .onChange(of: selectedStripID, initial: true) { _, id in
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .frame(minWidth: 64)

            Menu {
                Button {
                    _ = workspaces.showBrowser(in: folder.id)
                } label: {
                    Label(L10n.text("common.browser"), systemImage: "globe")
                }
                Button {
                    workspaces.showFiles(in: folder.id)
                } label: {
                    Label(L10n.text("common.files"), systemImage: "folder")
                }
                ThemeRule()
                ForEach(launcherProfiles) { profile in
                    Button {
                        start(profile)
                    } label: {
                        HStack {
                            Text(profile.name)
                            if let harness = profile.harnessID {
                                Text(harnessName(harness))
                                    .font(Theme.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if !ssh.hosts.isEmpty {
                    ThemeRule()
                    Menu(L10n.text("apple.rootview.servers.68d7beb6")) {
                        ForEach(ssh.launcherHosts) { host in
                            Button { openServer(host) } label: {
                                Label(host.label, systemImage: "server.rack")
                            }
                        }
                    }
                }
                if peer != nil {
                    ThemeRule()
                    Button {
                        showingPort = true
                    } label: {
                        Label(L10n.text("apple.terminalpane.browse_local_port.490dc71d"), systemImage: "network")
                    }
                }
            } label: {
                Label(L10n.text("apple.terminalpane.new_terminal.fe544556"), systemImage: "plus")
                    .font(Theme.font(12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L10n.text("apple.terminalpane.launch_a_shell_or_an_agent_cli_in_this_fol.c2d4b278"))

            if let error = active?.local?.transportError ?? active?.ssh?.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.warning)
                    .help(L10n.text("apple.terminalpane.input_cannot_reach_this_session_0.021e871f", "\(error)"))
            }

            ToolbarIconButton(systemImage: "globe", help: L10n.text("apple.terminalpane.browser_open_a_web_preview_beside_sessions.ba1ba6cf"), isAccent: showsBrowser) {
                if showsBrowser { browserWorkspaces.remove(folder.id) }
                else { browserWorkspaces.insert(folder.id) }
            }
            .accessibilityLabel(L10n.text("apple.terminalpane.browser_beside_sessions.523dad6e"))

            if !sessions.isEmpty {
                Menu {
                    Button(L10n.text("apple.terminalpane.single.8888a029"), .layout) {
                        terminals.setLayout(.single, for: folder.id)
                    }
                    Button(L10n.text("apple.terminalpane.side_by_side.a3d7b387"), .compare) {
                        terminals.setLayout(.side, for: folder.id)
                    }
                    Button(L10n.text("apple.terminalpane.stacked.c2fed746"), .compare) {
                        terminals.setLayout(.stacked, for: folder.id)
                    }
                    if splitLayout.isSplit {
                        Divider()
                        TerminalSwapButton(layout: splitLayout) { terminals.swapPanes(in: folder.id) }
                            .disabled(terminals.trailingTerminal(in: folder.id) == nil)
                    }
                } label: {
                    ActionIcon.compare.label(L10n.text("apple.terminalpane.split.32afaa78"))
                        .font(Theme.font(12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L10n.text("apple.terminalpane.show_one_session_or_two_side_by_side_or_st.d8049d2d"))
                .accessibilityLabel(L10n.text("apple.terminalpane.split_terminals.d4e7a34f"))
            }

            if !modelProfiles.isEmpty {
                LocalModelControl(folder: folder, peer: peer, workspaces: workspaces)
            }
            AgentProfileLaunchControl(folder: folder, peer: peer)
            BypassPermissionsControl(folder: folder, workspaces: workspaces)
        }
        .padding(.horizontal, Theme.Space.m)
        // Fixed chrome height, same baseline as every other destination row.
        // A flexible strip under a GeometryReader was what left the New
        // session / Split / model menus at zero height until a resize.
        .chromeBarMetrics()
        .background(Theme.background)
        .popover(isPresented: $showingPort, arrowEdge: .bottom) {
            RemotePortForm(folder: folder, workspaces: workspaces) {
                showingPort = false
            }
        }
    }

    private var visibleSessions: [WorkspaceTerminal] {
        if splitLayout.isSplit {
            // Deduplicated: a leading pin whose session has gone falls back to
            // the workspace's active session, which can be the trailing one,
            // and the same id twice is not a list SwiftUI can identify.
            var seen = Set<String>()
            return [
                terminals.leadingTerminal(in: folder.id),
                terminals.trailingTerminal(in: folder.id),
            ].compactMap { $0 }.filter { seen.insert($0.id).inserted }
        }
        return [active].compactMap { $0 }
    }

    @ViewBuilder
    private var hostLines: some View {
        if splitLayout.isSplit {
            if let lead = terminals.leadingTerminal(in: folder.id)?.local, lead.showsHostLine {
                TerminalHost(session: lead)
            }
            if let trail = terminals.trailingTerminal(in: folder.id)?.local, trail.showsHostLine {
                TerminalHost(session: trail)
            }
        } else if let active = active?.local, active.showsHostLine {
            TerminalHost(session: active)
        }
    }

    private var isLaunchSelected: Bool {
        front == .launcher || (sessions.isEmpty && front == .sessions)
    }

    @ViewBuilder
    private func chip(for tab: WorkspaceSurface) -> some View {
        let selected = front == tab
        switch tab {
        case let .file(path):
            FileChip(
                path: path,
                symbol: "doc.text",
                label: String(path.split(separator: "/").last ?? ""),
                isSelected: selected,
                isDirty: workspaces.isEditorDirty(path, in: folder.id)
            ) {
                Task { await workspaces.openFile(path, in: folder.id) }
            } onClose: {
                workspaces.requestClose(path, in: folder.id)
            }
        case let .browser(id):
            if let browser = workspaces.browserTabs(in: folder.id).first(where: { $0.id == id }) {
                FileChip(
                    path: browser.url.isEmpty ? browser.title : browser.url,
                    symbol: "globe",
                    label: browser.title,
                    isSelected: selected
                ) {
                    _ = workspaces.showBrowser(in: folder.id, id: id)
                } onClose: {
                    workspaces.closeBrowser(browser, in: folder.id)
                }
            }
        case .files:
            FileChip(
                path: folder.path,
                symbol: "folder",
                label: L10n.text("common.files"),
                isSelected: selected
            ) {
                workspaces.showFiles(in: folder.id)
            } onClose: {
                workspaces.closeFiles(in: folder.id)
            }
        case let .commit(id):
            FileChip(
                path: workspaces.commit(id, in: folder.id)?.subject ?? id,
                symbol: "arrow.triangle.branch",
                label: workspaces.commit(id, in: folder.id)?.shortID ?? String(id.prefix(7)),
                isSelected: selected
            ) {
                Task { await workspaces.showCommit(id, in: folder.id) }
            } onClose: {
                workspaces.close(tab, in: folder.id)
            }
        case .changes:
            FileChip(
                path: "Uncommitted changes in \(folder.name)",
                symbol: "plusminus",
                label: L10n.text("apple.terminalpane.changes.bbd4b6a8"),
                isSelected: selected
            ) {
                workspaces.reviewWorkingTree(in: folder.id)
            } onClose: {
                workspaces.closeWorkingTreeReview(in: folder.id)
            }
        case .sessions, .launcher:
            EmptyView()
        }
    }

    private func openServer(_ host: SSHHost) {
        let live = sshSessions.sessions(for: host.id).filter(\.alive)
        if let session = live.first(where: { $0.id == sshSessions.selectedID }) ?? live.last {
            terminals.attach(session, in: folder.id)
            workspaces.showTerminal(in: folder.id)
        } else {
            connectingServer = host
        }
    }

    private func start(_ profile: LaunchProfile) {
        workspaces.showTerminal(in: folder.id)
        let grid = spawnGrid
        let args = workspaces.bypassPermissions(for: folder.id)
            ? profile.args + profile.bypassArgs
            : profile.args
        let selection = LaunchProfile.acceptsLocalModel(profile.id)
            ? LocalModelSelection.stored(for: folder.id, in: workspaces)
            : nil
        Task {
            let started = await terminals.start(
                workspace: folder,
                command: profile.command,
                args: args,
                rows: grid.rows,
                cols: grid.cols,
                modelProvider: selection?.provider,
                modelID: selection?.model,
                profileID: LaunchAgentProfile.stored(for: folder.id)
            )
            if started != nil, let url = profile.openUrl {
                await workspaces.openHarnessPage(url, in: folder)
            }
        }
    }


    private var missingFolder: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer()
            Label(L10n.text("apple.terminalpane.this_folder_is_missing_it_is_kept_in_case.fe3bde5c"),
                  systemImage: "exclamationmark.triangle")
                .font(Theme.callout)
                .foregroundStyle(Theme.warning)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TabCloseButton: View {
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(Theme.font(9, weight: .bold))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(isHovering ? Theme.controlSeat : .clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct LaunchChip: View {
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "square.grid.2x2")
                    .font(Theme.font(11, weight: .medium))
                    .frame(width: 16, height: 16)
                Text(L10n.text("apple.terminalpane.launch.ccf56ef5"))
                    .font(Theme.font(12, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 3)
            .background(isSelected ? Theme.panel : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Theme.border : .clear, lineWidth: 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(L10n.text("apple.terminalpane.back_to_the_launcher_pick_a_tool_to_start.9a5e79a7"))
        .accessibilityLabel(L10n.text("apple.terminalpane.launch.ccf56ef5"))
        .opacity(isHovering && !isSelected ? 0.85 : 1)
    }
}

private struct SessionChip: View {
    let session: WorkspaceTerminal
    let isSelected: Bool
    var isOtherHalf: Bool = false
    let onSelect: () -> Void
    let onClose: () -> Void
    var onSplit: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: Theme.Space.xs) {
                    if let harnessID = session.local?.harnessID {
                        HarnessMark(id: harnessID, size: 16)
                    } else {
                        Image(systemName: session.ssh == nil ? "terminal" : "server.rack")
                            .font(Theme.font(11))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 16, height: 16)
                    }
                    Text(label)
                        .font(Theme.font(12, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(session.local?.cwd ?? session.label)

            if isSelected || isHovering {
                TabCloseButton(help: L10n.text("apple.terminalpane.close_this_session.fa2af1b6"), action: onClose)
            } else {
                Color.clear.frame(width: 20, height: 20)
            }
        }
        .padding(.leading, Theme.Space.s)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .background(
            isSelected
                ? Theme.panel
                : (isOtherHalf ? Theme.rowHighlight : .clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Theme.border
                        : (isOtherHalf ? Theme.accent.opacity(0.4) : .clear),
                    lineWidth: 1
                )
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            if let onSplit {
                Button(L10n.text("apple.terminalpane.open_in_split.6b36cec3"), .compare) { onSplit() }
            }
            Button(L10n.text("common.close"), .delete) { onClose() }
        }
    }

    private var label: String {
        session.label
    }

}

private struct FileChip: View {
    let path: String
    let symbol: String
    let label: String
    let isSelected: Bool
    var isDirty: Bool = false
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: symbol)
                        .font(Theme.font(11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                    Text(label)
                        .font(Theme.font(12, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isDirty {
                        Circle()
                            .fill(Theme.warning)
                            .frame(width: 5, height: 5)
                    }
                }
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(path)

            if isSelected || isHovering {
                TabCloseButton(help: L10n.text("apple.terminalpane.close_this_file.6f1ca61c"), action: onClose)
            } else {
                Color.clear.frame(width: 20, height: 20)
            }
        }
        .padding(.leading, Theme.Space.s)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .background(isSelected ? Theme.panel : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Theme.border : .clear, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(L10n.text("common.close"), .delete) { onClose() }
        }
    }
}

private struct SessionStartingView: View {
    let command: String

    private var label: String {
        let base = URL(fileURLWithPath: command).lastPathComponent
        switch base {
        case "claude": return L10n.text("apple.terminalpane.claude_code.246ef8c1")
        case "codex": return L10n.text("apple.terminalpane.codex.616efbe9")
        case "grok": return L10n.text("apple.terminalpane.grok.dca61d32")
        case "opencode": return L10n.text("apple.terminalpane.opencode.3af0e55c")
        case "opencode2": return L10n.text("apple.terminalpane.opencode_2.5185d124")
        case "agent": return L10n.text("apple.terminalpane.cursor_agent.f2b703ad")
        case "agy": return L10n.text("apple.terminalpane.antigravity.4da276f5")
        case "zsh", "bash", "fish", "sh": return L10n.text("apple.terminalpane.shell.a7332854")
        default: return base
        }
    }

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            ProgressView()
                .controlSize(.regular)
            Text(L10n.text("apple.terminalpane.starting_0.099752ea", "\(label)"))
                .font(Theme.title3.weight(.medium))
            Text(L10n.text("apple.terminalpane.the_session_is_up_waiting_for_the_program.2a36333d"))
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

struct TerminalHost: View {
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            if let code = session.exitCode {
                statusLine(code)
            }
        }
    }

    private func statusLine(_ code: Int) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(Theme.font(11))
                .foregroundStyle(code == 0 ? .green : .red)
            Text(code == 0 ? L10n.text("apple.terminalpane.process_exited.077e5ee0") : L10n.text("apple.terminalpane.process_exited_with_code_0.619a6ae7", "\(code)"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.xs)
        .background(Theme.sidebar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}

private struct TerminalNotices: View {
    let sessions: [TerminalSession]

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            ForEach(sessions, id: \.id) { session in
                TerminalNotice(session: session)
            }
        }
    }
}

private struct TerminalNotice: View {
    let session: TerminalSession

    @State private var pauseHasHeld = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.clear.frame(width: 0, height: 0)
            if session.droppedOutput {
                pill {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.font(10))
                        .foregroundStyle(Theme.warning)
                    Text(L10n.text("apple.terminalpane.some_lines_are_missing_here.5f8ee2b3"))
                        .font(Theme.caption)
                        .foregroundStyle(.primary)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            } else if session.outputPaused, pauseHasHeld {
                pill {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("apple.terminalpane.output_paused_while_the_terminal_catches_u.c3cbbc1c"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.droppedOutput)
        .task(id: session.droppedOutput) {
            guard session.droppedOutput else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            session.droppedOutput = false
        }
        .task(id: session.outputPaused) {
            guard session.outputPaused else {
                pauseHasHeld = false
                return
            }
            try? await Task.sleep(for: .milliseconds(700))
            pauseHasHeld = !Task.isCancelled
        }
    }

    private func pill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Theme.Space.s) {
            content()
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.xs)
        .background(Theme.sidebar, in: Capsule())
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}

private struct LaunchSurface: View {
    let folder: WorkspaceFolder
    let terminals: TerminalsModel
    let workspaces: WorkspacesModel
    let chat: ChatModel
    let ssh: SSHLibraryModel
    let sshSessions: SSHSessionsModel
    let onOpenServer: (SSHHost) -> Void
    let onManageServers: () -> Void
    let onOpenSection: (WorkspaceSection) -> Void
    let grid: (rows: Int, cols: Int)
    let profiles: [LaunchProfile]
    let modelPeer: String?

    @State private var launching: String?
    @State private var installError: String?
    @State private var showingCatalog = false
    @State private var pendingInstall: LaunchProfile?
    @State private var pendingHide: LaunchProfile?
    @State private var openingChat = false
    @State private var pullCounts = PullCountStore.shared
    @State private var previewChats: [ChatConversation] = []
    @State private var previewGeneration: UInt64 = 0

    private var visibility: LauncherVisibility { LauncherVisibility.shared }
    private var visibilityScope: String { modelPeer ?? "local" }

    private var modelProfiles: [LaunchProfile] {
        profiles.filter { LaunchProfile.acceptsLocalModel($0.id) && $0.installed }
    }

    private var visibleProfiles: [LaunchProfile] {
        profiles.filter { $0.installed && !isOffGrid($0) }
    }

    private var extraProfiles: [LaunchProfile] {
        profiles.filter { !$0.installed || isOffGrid($0) }
    }

    private func isOffGrid(_ profile: LaunchProfile) -> Bool {
        profile.hidden || visibility.isHidden(profile.id, scope: visibilityScope)
    }

    private var selectedModel: (provider: String, model: String)? {
        LocalModelSelection.stored(for: folder.id, in: workspaces)
    }

    private var recentChat: ChatConversation? {
        previewChats.max { $0.updatedAtMs < $1.updatedAtMs }
    }

    private var conversationCount: Int {
        previewChats.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.m) {
                if !terminals.workspaceTerminals(in: folder.id).isEmpty {
                    runningSessionsBanner
                }

                Image(systemName: "square.grid.2x2")
                    .font(Theme.font(34, weight: .light))
                    .foregroundStyle(Theme.accent.opacity(0.65))
                    .padding(.top, Theme.Space.m)
                Text(L10n.text("apple.terminalpane.what_do_you_want_to_do_in_0.d6c232de", "\(folder.name)"))
                    .font(Theme.title3.weight(.medium))
                Text(L10n.text("apple.terminalpane.open_the_project_where_you_left_it_or_star.4f0ed092"))
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                launcherHeading(L10n.text("common.open"))

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: Theme.Space.m)],
                    spacing: Theme.Space.m
                ) {
                    chatButton
                    utilityButton(L10n.text("common.files"), symbol: WorkspaceSection.files.symbol) {
                        onOpenSection(.files)
                    }
                    utilityButton(L10n.text("common.browser"), symbol: WorkspaceSection.browser.symbol) {
                        onOpenSection(.browser)
                    }
                    utilityButton(L10n.text("apple.terminalpane.changes.bbd4b6a8"), symbol: WorkspaceSection.changes.symbol) {
                        onOpenSection(.changes)
                    }
                    utilityButton(
                        L10n.text("apple.terminalpane.pull_requests.d9e3f260"),
                        symbol: WorkspaceSection.pulls.symbol,
                        count: pullCounts.count(workspaceID: folder.id) ?? 0
                    ) {
                        onOpenSection(.pulls)
                    }
                    utilityButton(L10n.text("common.tasks"), symbol: WorkspaceSection.todo.symbol) {
                        onOpenSection(.todo)
                    }
                }
                .frame(maxWidth: 620)

                ServerLauncher(library: ssh, sessions: sshSessions, onOpen: onOpenServer, onManage: onManageServers)
                    .frame(maxWidth: 620).padding(.top, Theme.Space.s)

                launcherHeading(L10n.text("apple.terminalpane.run_an_agent.b7046310"))

                settingsHint

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: Theme.Space.m)],
                    spacing: Theme.Space.m
                ) {
                    ForEach(visibleProfiles) { profile in
                        tile(for: profile)
                    }
                    if !extraProfiles.isEmpty {
                        addTile
                    }
                    if showingCatalog {
                        ForEach(extraProfiles) { profile in
                            tile(for: profile)
                        }
                    }
                }
                .frame(maxWidth: 620)
                .animation(.easeOut(duration: 0.15), value: showingCatalog)

                if let installError {
                    Text(installError)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }
                if let error = terminals.errorMessage {
                    Text(error)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.danger)
                }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .task(id: folder.id) {
            previewGeneration &+= 1
            let generation = previewGeneration
            previewChats = []
            guard let list = try? await Bridge.chats(workspaceID: folder.id) else { return }
            guard !Task.isCancelled, generation == previewGeneration else { return }
            previewChats = list
        }
        .confirmationDialog(
            pendingInstall.map { L10n.text("apple.terminalpane.install_0_on_this_machine.05182120", "\($0.name)") } ?? L10n.text("apple.terminalpane.install_this_tool.c9c5635e"),
            isPresented: Binding(
                get: { pendingInstall != nil },
                set: { if !$0 { pendingInstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("apple.terminalpane.install.569ca49f")) {
                if let profile = pendingInstall {
                    runInstall(profile)
                }
                pendingInstall = nil
            }
            Button(L10n.text("apple.terminalpane.not_now.a0e63d7c"), role: .cancel) { pendingInstall = nil }
        } message: {
            Text(L10n.text("apple.terminalpane.this_runs_its_official_installer.0cbae9fd"))
        }
        .confirmationDialog(
            pendingHide.map { L10n.text("apple.terminalpane.remove_0_from_the_launcher.c6685e92", "\($0.name)") } ?? L10n.text("apple.terminalpane.remove_this_tool.fcc2e23e"),
            isPresented: Binding(
                get: { pendingHide != nil },
                set: { if !$0 { pendingHide = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("common.remove"), role: .destructive) {
                if let profile = pendingHide {
                    Task { await LaunchCatalog.shared.hide(profile.id, peer: modelPeer) }
                }
                pendingHide = nil
            }
            Button(L10n.text("apple.terminalpane.keep.183f00f4"), role: .cancel) { pendingHide = nil }
        } message: {
            Text(L10n.text("apple.terminalpane.the_tool_stays_on_this_machine_you_can_add.708f1c8d"))
        }
    }

    private func launcherHeading(_ title: String) -> some View {
        Text(title)
            .font(Theme.caption.weight(.semibold))
            .foregroundStyle(Theme.controlGlyph)
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.top, Theme.Space.xs)
    }

    private var chatButton: some View {
        Button {
            guard !openingChat else { return }
            openingChat = true
            Task {
                if chat.folderID != folder.id {
                    await chat.load(workspaceID: folder.id)
                }
                if chat.folderID == folder.id, chat.selected == nil {
                    if let recent = chat.mostRecent {
                        await chat.select(recent)
                    } else {
                        await chat.create()
                    }
                }
                if let list = try? await Bridge.chats(workspaceID: folder.id) {
                    previewChats = list
                }
                openingChat = false
                onOpenSection(.chat)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: Theme.Space.s) {
                    if openingChat {
                        ProgressView()
                            .controlSize(.small)
                            .frame(height: 34)
                    } else if let recentChat {
                        PersonaMark(
                            seed: chat.faceSeed(for: recentChat),
                            size: 34,
                            state: recentChat.running ? .working : .idle
                        )
                    } else {
                        Image(systemName: WorkspaceSection.chat.symbol)
                            .font(Theme.font(18))
                            .foregroundStyle(Theme.accent)
                            .frame(height: 34)
                    }
                    Text(openingChat ? L10n.text("apple.terminalpane.opening.c926c2c5") : L10n.text("apple.terminalpane.chat.460b3a7d"))
                        .font(Theme.font(13, weight: .medium))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.m)

                if conversationCount > 0 {
                    Text("\(conversationCount)")
                        .font(Theme.numeric(10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Theme.accentSoft, in: Capsule())
                        .padding(Theme.Space.s)
                }
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(openingChat)
        .help(conversationCount == 0
              ? L10n.text("apple.terminalpane.start_a_conversation_in_this_workspace.4add13f7")
              : L10n.text("apple.terminalpane.open_the_most_recent_of_0_conversations.6e60b8dd", "\(conversationCount)"))
        .accessibilityLabel(conversationCount == 0 ? L10n.text("apple.terminalpane.chat.460b3a7d") : L10n.text("apple.terminalpane.chat_0_conversations.bd13c4c3", "\(conversationCount)"))
    }

    private var settingsHint: some View {
        Label(
            modelProfiles.isEmpty
                ? L10n.text("apple.terminalpane.permission_bypass_is_in_the_bar_above.2c50d7ad")
                : L10n.text("apple.terminalpane.model_and_permission_bypass_are_in_the_bar.f3148a99"),
            systemImage: "arrow.up"
        )
        .font(Theme.caption)
        .foregroundStyle(.tertiary)
    }

    private var runningSessionsBanner: some View {
        HStack(spacing: Theme.Space.s) {
            Label(
                L10n.text("apple.terminalpane.sessions_are_still_running_launch_another.060224e8"),
                systemImage: "terminal.fill"
            )
            .foregroundStyle(.secondary)
            Spacer(minLength: Theme.Space.s)
            Button(L10n.text("apple.terminalpane.back_to_session.dea785db"), .back) {
                workspaces.showTerminal(in: folder.id)
            }
            .controlSize(.small)
        }
        .font(Theme.caption)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 6)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func tile(for profile: LaunchProfile) -> some View {
        if profile.installed, !isOffGrid(profile) {
            launchButton(profile)
        } else if profile.installed {
            showAgainButton(profile)
        } else if profile.installCommand != nil {
            installButton(profile)
        } else {
            unavailableTile(profile)
        }
    }

    private var addTile: some View {
        Button {
            showingCatalog.toggle()
        } label: {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "plus")
                    .font(Theme.font(18, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(height: 34)
                Text(showingCatalog ? L10n.text("apple.terminalpane.hide.ac20a57b") : L10n.text("apple.terminalpane.more.d47d7cb0"))
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.m)
            .background(Theme.panel.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(.rect)
        }
        .buttonStyle(CardButtonStyle())
        .help(showingCatalog
              ? L10n.text("apple.terminalpane.hide_tools_that_are_not_on_the_launcher.d2554f18")
              : L10n.text("apple.terminalpane.show_tools_you_can_install_or_add_back.95b8421f"))
        .accessibilityLabel(showingCatalog ? L10n.text("apple.terminalpane.hide_extra_tools.6063173b") : L10n.text("apple.terminalpane.show_more_tools.fd6e5f9f"))
    }

    private func installButton(_ profile: LaunchProfile) -> some View {
        LaunchInstallTile(
            profile: profile,
            isInstalling: LaunchCatalog.shared.isInstalling(profile.id, peer: modelPeer),
            onInstall: { pendingInstall = profile }
        )
    }

    private func showAgainButton(_ profile: LaunchProfile) -> some View {
        LaunchInstallTile(
            profile: profile,
            isInstalling: false,
            onInstall: { Task { await LaunchCatalog.shared.show(profile.id, peer: modelPeer) } }
        )
        .help(L10n.text("apple.terminalpane.0_is_installed_click_to_add_it_back_to_the.0d1c03c2", "\(profile.name)"))
    }

    private func runInstall(_ profile: LaunchProfile) {
        installError = nil
        Task {
            let message = await LaunchCatalog.shared.install(profile, peer: modelPeer)
            if let message {
                installError = L10n.text("apple.terminalpane.0_could_not_be_installed_1.aef9e3b1", "\(profile.name)", "\(message)")
            }
        }
    }

    private func unavailableTile(_ profile: LaunchProfile) -> some View {
        VStack(spacing: Theme.Space.s) {
            if let harness = profile.harnessID, harnessBrandAsset(harness) != nil {
                HarnessMark(id: harness, size: 34)
                    .opacity(0.35)
                    .saturation(0.2)
            } else {
                Image(systemName: profile.symbol ?? "terminal")
                    .font(Theme.font(18))
                    .foregroundStyle(.tertiary)
                    .frame(height: 34)
            }
            Text(profile.name)
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.panel.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .help(L10n.text("apple.terminalpane.no_bundled_installer_for_0_yet.6827f4d4", "\(profile.name)"))
    }

    private func launchButton(_ profile: LaunchProfile) -> some View {
        let selection = modelProfiles.contains(where: { $0.id == profile.id }) ? selectedModel : nil
        return LaunchTile(
            profile: profile,
            peer: modelPeer,
            isLaunching: launching == profile.id,
            othersBusy: launching != nil && launching != profile.id,
            onHide: profile.id == "shell" ? nil : { pendingHide = profile },
            onBegin: {
                guard launching == nil else { return }
                launching = profile.id
                let args = workspaces.bypassPermissions(for: folder.id)
                    ? profile.args + profile.bypassArgs
                    : profile.args
                let session = terminals.begin(
                    workspace: folder,
                    command: profile.command,
                    rows: grid.rows,
                    cols: grid.cols
                )
                workspaces.showTerminal(in: folder.id)
                Task {
                    let started = await terminals.complete(
                        session,
                        args: args,
                        rows: grid.rows,
                        cols: grid.cols,
                        modelProvider: selection?.provider,
                        modelID: selection?.model,
                        profileID: LaunchAgentProfile.stored(for: folder.id)
                    )
                    if started != nil, let url = profile.openUrl {
                        await workspaces.openHarnessPage(url, in: folder)
                    }
                    launching = nil
                }
            }
        )
    }

    private func utilityButton(
        _ label: String,
        symbol: String,
        count: Int = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: symbol)
                        .font(Theme.font(18))
                        .foregroundStyle(Theme.accent)
                        .frame(height: 34)
                    Text(label)
                        .font(Theme.font(13, weight: .medium))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.m)

                if count > 0 {
                    Text("\(count)")
                        .font(Theme.numeric(10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Theme.accentSoft, in: Capsule())
                        .padding(Theme.Space.s)
                }
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(CardButtonStyle())
        .accessibilityLabel(count > 0 ? "\(label), \(count)" : label)
    }
}

private struct LaunchTile: View {
    let profile: LaunchProfile
    let peer: String?
    let isLaunching: Bool
    let othersBusy: Bool
    var onHide: (() -> Void)? = nil
    let onBegin: () -> Void

    @State private var configuring = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onBegin) {
                VStack(spacing: Theme.Space.s) {
                    if isLaunching {
                        ProgressView()
                            .controlSize(.small)
                            .frame(height: 34)
                    } else if let harness = profile.harnessID, harnessBrandAsset(harness) != nil {
                        HarnessMark(id: harness, size: 34)
                    } else {
                        Image(systemName: profile.symbol ?? "terminal")
                            .font(Theme.font(18))
                            .foregroundStyle(Theme.accent)
                            .frame(height: 34)
                    }
                    Text(isLaunching ? L10n.text("apple.terminalpane.starting.bbe5fc3b") : profile.name)
                        .font(Theme.font(13, weight: .medium))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.m)
                .background(
                    isLaunching ? Theme.accent.opacity(0.12) : Theme.panel,
                    in: RoundedRectangle(cornerRadius: Theme.cardRadius)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(isLaunching ? Theme.accent : Theme.border, lineWidth: 1)
                )
                .contentShape(.rect)
            }
            .buttonStyle(CardButtonStyle())
            .disabled(othersBusy)
            .opacity(othersBusy ? 0.5 : 1)

            if !isLaunching {
                settingsBadge
                    .padding(8)
            }
        }
        .sheet(isPresented: $configuring) {
            HarnessConfigView(profile: profile, peer: peer) { configuring = false }
        }
        .contextMenu {
            if let onHide {
                Button(L10n.text("apple.terminalpane.remove_from_launcher.b107a73b"), .delete) { onHide() }
            }
        }
    }

    private var settingsBadge: some View {
        Button {
            configuring = true
        } label: {
            Image(systemName: ActionIcon.settings.symbol)
                .font(Theme.font(11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Theme.sidebar)
                        .shadow(color: Theme.shadow(0.35), radius: 3, x: 0, y: 1)
                )
                .overlay(
                    Circle().strokeBorder(Theme.border, lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(ControlFeedbackStyle(pressScale: 0.9))
        .help(L10n.text("apple.terminalpane.configure_0.76d41ce7", "\(profile.name)"))
        .accessibilityLabel(L10n.text("apple.terminalpane.configure_0.76d41ce7", "\(profile.name)"))
        .accessibilityValue(profile.command)
    }
}

private struct LaunchInstallTile: View {
    let profile: LaunchProfile
    let isInstalling: Bool
    let onInstall: () -> Void

    var body: some View {
        Button(action: onInstall) {
            VStack(spacing: Theme.Space.s) {
                if isInstalling {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 34)
                } else if let harness = profile.harnessID, harnessBrandAsset(harness) != nil {
                    HarnessMark(id: harness, size: 34)
                        .opacity(0.45)
                        .saturation(0.3)
                } else {
                    Image(systemName: profile.symbol ?? "arrow.down.circle")
                        .font(Theme.font(18))
                        .foregroundStyle(.tertiary)
                        .frame(height: 34)
                }
                Text(isInstalling ? L10n.text("apple.terminalpane.installing.530bcc35") : profile.name)
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(isInstalling ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.m)
            .background(
                isInstalling ? Theme.accent.opacity(0.08) : Theme.panel.opacity(0.4),
                in: RoundedRectangle(cornerRadius: Theme.cardRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(
                        isInstalling ? Theme.accent.opacity(0.6) : Theme.border.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .contentShape(.rect)
        }
        .buttonStyle(CardButtonStyle())
        .disabled(isInstalling)
        .help(L10n.text("apple.terminalpane.0_is_not_installed_click_to_run_its_offici.e78df0fc", "\(profile.name)"))
    }
}

private struct RemotePortForm: View {
    let folder: WorkspaceFolder
    @Bindable var workspaces: WorkspacesModel
    let done: () -> Void

    @State private var port = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.terminalpane.browse_a_local_port_on_0.e9fe39dc", "\(folder.machineLabel ?? L10n.text("apple.terminalpane.the_other_machine.1a59f693"))"))
                .font(Theme.callout.weight(.medium))
            Text(L10n.text("apple.terminalpane.view_a_service_running_on_that_device_s_ow.bc48a8b0"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            TextField(L10n.text("apple.terminalpane.port.72e9a59f"), text: $port)
                .textFieldStyle(.themed)
                .frame(width: 120)
            HStack {
                Spacer()
                Button(L10n.text("apple.terminalpane.browse.3227aa96"), .reveal) {
                    if let value = Int(port.trimmingCharacters(in: .whitespaces)),
                       value > 0, value <= 65_535 {
                        Task { await workspaces.openRemotePort(value, in: folder) }
                    }
                    done()
                }
                .buttonStyle(AccentButtonStyle(small: true))
            }
        }
        .padding(Theme.Space.m)
        .frame(width: 280)
    }
}

#endif
