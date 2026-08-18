// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import Foundation
import SwiftUI

/// The centre pane below the workspace header: the session strip on top, the
/// selected session's terminal below, or the launch surface while the folder
/// has no session.
struct TerminalPane: View {
    let folder: WorkspaceFolder
    @Bindable var terminals: TerminalsModel
    @Bindable var workspaces: WorkspacesModel
    /// False while the workspace surface is kept mounted but another
    /// destination (Home, Insights, …) is in front. The stack stays in the
    /// hierarchy so paint is not lost; focus and keystroke-speed polling only
    /// apply when this is true.
    var isSurfaceActive: Bool = true
    @State private var closingSession: TerminalSession?

    private var sessions: [TerminalSession] {
        terminals.sessions(in: folder.id)
    }

    /// What this pane is showing. One value, so no two surfaces can both
    /// think they are in front.
    private var front: WorkspaceSurface {
        workspaces.front(in: folder.id)
    }

    /// The strip beside the sessions, in the order the tabs were opened.
    private var tabs: [WorkspaceSurface] {
        workspaces.tabs(in: folder.id)
    }

    /// True when the pane is showing a terminal rather than a document.
    private var showsTerminal: Bool { front == .sessions }

    /// Which harnesses this Mac can launch. Shared, and resolved off the main
    /// actor: see `LaunchCatalog` for the crash that reading it inline caused.
    private var launcher: LaunchCatalog { LaunchCatalog.shared }

    /// The machine that owns this folder, when it is remote.
    private var peer: String? {
        let parts = folder.id.split(separator: ":", maxSplits: 2).map(String.init)
        return parts.count == 3 && parts[0] == "remote" ? parts[1] : nil
    }

    /// What to offer in the launcher: this machine's harnesses for a local
    /// folder, the owning machine's for a remote one. Installed only; the
    /// launch surface additionally shows what could be installed.
    private var launcherProfiles: [LaunchProfile] {
        let all = peer == nil ? launcher.available : launcher.remoteAvailable
        let scope = peer ?? "local"
        let visibility = LauncherVisibility.shared
        return all.filter { !$0.hidden && !visibility.isHidden($0.id, scope: scope) }
    }

    /// Every supported harness on the owning machine, installed or not, for
    /// the launch surface to draw installed tiles vividly and the rest muted.
    private var launcherCatalog: [LaunchProfile] {
        peer == nil ? launcher.catalog : launcher.remoteCatalog
    }

    /// The harnesses a local model selection means anything to. With none of
    /// them installed the model control has nothing to act on, so it is not
    /// drawn at all.
    private var modelProfiles: [LaunchProfile] {
        launcherProfiles.filter { LaunchProfile.acceptsLocalModel($0.id) }
    }

    /// Size of the terminal area, measured rather than assumed.
    @State private var paneSize: CGSize = .zero

    /// The grid a new session should start at.
    ///
    /// Spawning at 24x80 and letting the first layout correct it means the
    /// shell prints its prompt at one size and immediately redraws at another,
    /// and an agent CLI repaints its whole interface. That is the flash when a
    /// session opens. Measuring first costs nothing and removes it.
    private var spawnGrid: (rows: Int, cols: Int) {
        TerminalMetrics.grid(fitting: paneSize)
    }

    /// The Open port popover in the strip menu, for a remote folder.
    @State private var showingPort = false

    /// The session to display: the globally selected one when it belongs to
    /// this folder, otherwise the folder's first.
    private var active: TerminalSession? {
        terminals.active(in: folder.id)
    }

    /// Sessions the user can actually see. A split names two. Nothing while a
    /// file, a commit or the browser is over the top, or while another
    /// destination is in front of this whole surface.
    private var focusedSessionIDs: Set<String> {
        guard isSurfaceActive, showsTerminal else { return [] }
        var ids = Set<String>()
        if let active { ids.insert(active.id) }
        if terminals.layout(for: folder.id).isSplit,
           let other = terminals.trailingSession(in: folder.id)
            ?? terminals.leadingSession(in: folder.id),
           other.id != active?.id
        {
            ids.insert(other.id)
        }
        return ids
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
                Divider()
                surface
                if showsTerminal {
                    hostLines
                }
            } else {
                missingFolder
            }
        }
        // Only the session actually on screen polls at keystroke speed. The
        // rest keep draining the host's buffer, just slower, which is the
        // difference between a few round trips a second and a few hundred when
        // several agents are running at once.
        .onChange(of: focusedSessionIDs, initial: true) {
            terminals.focus(focusedSessionIDs)
        }
        .onDisappear { terminals.focus(nil) }
        // Asking the login shell for the real PATH (once per launch, off the
        // main actor), and a remote folder's owner what it can launch. Both
        // fill in when they answer.
        .task {
            await launcher.resolve()
            if let peer {
                await launcher.resolveRemote(peer: peer)
            }
        }
        // Three buttons and not two, because "Cancel" and "Don't Save" are
        // different answers and a two-button dialog forces one of them to mean
        // both.
        .confirmationDialog(
            "Save changes before closing?",
            isPresented: closingUnsaved,
            titleVisibility: .visible,
            presenting: workspaces.pendingClose
        ) { pending in
            Button("Save") { Task { await workspaces.saveAndClosePending() } }
            Button("Don't Save", role: .destructive) { workspaces.discardAndClosePending() }
            Button("Cancel", role: .cancel) { workspaces.pendingClose = nil }
        } message: { pending in
            Text("\(pending.path) has changes that are not written to disk.")
        }
        .confirmationDialog(
            "Stop this session?",
            isPresented: Binding(
                get: { closingSession != nil },
                set: { if !$0 { closingSession = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop and close", role: .destructive) {
                if let session = closingSession {
                    closingSession = nil
                    Task { await terminals.close(session) }
                }
            }
            Button("Cancel", role: .cancel) { closingSession = nil }
        } message: {
            Text("The process will be killed. A stopped session can still close in one click.")
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
        // The size comes from the reader, and every child is given exactly it.
        // Letting a stack work the size out from its children does not survive
        // a second child being added: a terminal view has no useful intrinsic
        // width, so the stack settles on something tiny and the terminal
        // renders one character per line.
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                TerminalStack(
                    sessions: sessions,
                    // Nothing is shown while a file or a commit is open, so the
                    // terminals stay mounted underneath rather than being torn
                    // down. Positions stay put when focus moves.
                    leading: showsTerminal
                        ? (splitLayout.isSplit
                            ? terminals.leadingSession(in: folder.id)
                            : active)
                        : nil,
                    trailing: showsTerminal && splitLayout.isSplit
                        ? terminals.trailingSession(in: folder.id)
                        : nil,
                    focused: showsTerminal ? active : nil,
                    splitAxis: showsTerminal ? splitLayout.axis : nil,
                    fraction: CGFloat(terminals.fraction(for: folder.id)),
                    claimsFocus: isSurfaceActive && showsTerminal,
                    onActivate: { terminals.select($0) }
                )
                .frame(width: size.width, height: size.height)

                if showsTerminal, splitLayout.isSplit {
                    TerminalSplitHandle(
                        axis: splitLayout.axis ?? .horizontal,
                        fraction: splitFraction
                    )
                    .frame(width: size.width, height: size.height)
                    if terminals.trailingSession(in: folder.id) == nil {
                        trailingPlaceholder(in: size)
                    }
                }

                // Starting state over the stack: pending host spawn, or the
                // process is up but has not painted yet. Agent CLIs spend
                // several seconds in that gap; an empty live terminal there
                // is what read as a 10s hang.
                if showsTerminal, !splitLayout.isSplit, let active, active.showsStartingState {
                    SessionStartingView(command: active.command)
                        .frame(width: size.width, height: size.height)
                }

                // The launcher wins over every other surface when toggled on:
                // that is its whole point, to put a new launch in front even
                // while sessions are running underneath. Any real navigation
                // (opening a file, browser, terminal) clears the flag.
                if front == .launcher {
                    LaunchSurface(
                        folder: folder,
                        terminals: terminals,
                        workspaces: workspaces,
                        grid: spawnGrid,
                        profiles: launcherCatalog,
                        modelPeer: peer
                    )
                        .frame(width: size.width, height: size.height)
                } else if front == .changes {
                    WorkingTreeReviewView(folder: folder, model: workspaces)
                        .frame(width: size.width, height: size.height)
                } else if case let .commit(id) = front {
                    Group {
                        if let detail = workspaces.commit(id, in: folder.id) {
                            CommitView(detail: detail)
                        } else {
                            reading("commit")
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .id(id)
                } else if case let .file(path) = front {
                    fileSurface(path)
                    .frame(width: size.width, height: size.height)
                } else if front == .files {
                    WorkspaceFilesView(model: workspaces, folder: folder, surface: .content)
                        .frame(width: size.width, height: size.height)
                } else if case let .browser(id) = front,
                          let browser = workspaces.browserTabs(in: folder.id).first(where: { $0.id == id }) {
                    BrowserView(
                        url: browser.url,
                        onURLChange: { workspaces.setBrowserURL($0, in: folder.id, tabID: browser.id) }
                    )
                    .frame(width: size.width, height: size.height)
                } else if sessions.isEmpty {
                    LaunchSurface(
                        folder: folder,
                        terminals: terminals,
                        workspaces: workspaces,
                        grid: spawnGrid,
                        profiles: launcherCatalog,
                        modelPeer: peer
                    )
                        .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            // Only the explicit launcher toggle animates. Animating
            // `sessions.isEmpty` made every spawn fade the whole pane in and
            // out (and re-layout the terminal under it), which read as the
            // tty blinking before it settled.
            .animation(
                .easeOut(duration: 0.15),
                value: front == .launcher
            )
            // Also the size a new session is spawned at, so it never opens at
            // 24x80 and jumps.
            // Quantised to the cell grid's order of magnitude. This only feeds
            // the spawn size, so sub-pixel precision buys nothing, and writing
            // it every frame of a drag rebuilds this whole pane for a value no
            // terminal can use.
            .onAppear { paneSize = size }
            .onChange(of: CGSize(width: quantised(size.width, step: 8),
                                 height: quantised(size.height, step: 8))) { _, new in
                paneSize = new
            }
        }
    }

    /// Empty right / bottom half, positioned over the unused split frame.
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

    // MARK: - Session strip

    @ViewBuilder
    private func fileSurface(_ path: String) -> some View {
        EditorView(model: workspaces, folder: folder, path: path)
            .id(path)
    }

    private func reading(_ what: String) -> some View {
        VStack {
            Spacer()
            Text("Reading \(what)…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var strip: some View {
        HStack(spacing: Theme.Space.s) {
            LaunchChip(isSelected: isLaunchSelected) {
                workspaces.showLauncher(in: folder.id)
            }

            ForEach(sessions) { session in
                SessionChip(
                    session: session,
                    isSelected: showsTerminal && session.id == active?.id,
                    isOtherHalf: showsTerminal
                        && splitLayout.isSplit
                        && (session.id == terminals.leadingSession(in: folder.id)?.id
                            || session.id == terminals.trailingSession(in: folder.id)?.id)
                        && session.id != active?.id
                ) {
                    workspaces.showTerminal(in: folder.id)
                    if NSEvent.modifierFlags.contains(.option) {
                        terminals.sendToOtherHalf(session)
                    } else {
                        terminals.select(session)
                    }
                } onClose: {
                    if session.alive {
                        closingSession = session
                    } else {
                        Task { await terminals.close(session) }
                    }
                } onSplit: {
                    workspaces.showTerminal(in: folder.id)
                    terminals.sendToOtherHalf(session)
                }
            }

            // Every open surface is a chip, drawn from one list in the order
            // it was opened. A commit and the working tree are as closeable as
            // a file, and none of them can claim to be selected while another
            // is the one on screen.
            ForEach(tabs) { tab in
                chip(for: tab)
            }

            Menu {
                Button {
                    _ = workspaces.showBrowser(in: folder.id)
                } label: {
                    Label("Browser", systemImage: "globe")
                }
                Button {
                    workspaces.showFiles(in: folder.id)
                } label: {
                    Label("Files", systemImage: "folder")
                }
                Divider()
                ForEach(launcherProfiles) { profile in
                    Button {
                        start(profile)
                    } label: {
                        HStack {
                            Text(profile.name)
                            if let harness = profile.harnessID {
                                Text(harnessName(harness))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if peer != nil {
                    Divider()
                    Button {
                        showingPort = true
                    } label: {
                        Label("Browse local port…", systemImage: "network")
                    }
                }
            } label: {
                Label("New session", systemImage: "plus")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Launch a shell or an agent CLI in this folder")

            if let error = active?.transportError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .help("Input cannot reach this session: \(error)")
            }

            Spacer()

            if !sessions.isEmpty {
                Menu {
                    Button("Single", .layout) {
                        terminals.setLayout(.single, for: folder.id)
                    }
                    Button("Side by side", .compare) {
                        terminals.setLayout(.side, for: folder.id)
                    }
                    Button("Stacked", .compare) {
                        terminals.setLayout(.stacked, for: folder.id)
                    }
                } label: {
                    ActionIcon.compare.label("Split")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Show one session, or two side by side or stacked")
                .accessibilityLabel("Split terminals")
            }

            // What the next launch will do, on the row that launches it. Both
            // apply to every way of starting a session, including this strip's
            // own menu, so they sit beside it rather than on a surface that
            // disappears once anything is running.
            if !modelProfiles.isEmpty {
                LocalModelControl(folder: folder, peer: peer, workspaces: workspaces)
            }
            BypassPermissionsControl(folder: folder, workspaces: workspaces)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 4)
        .background(Theme.background)
        .popover(isPresented: $showingPort, arrowEdge: .bottom) {
            RemotePortForm(folder: folder, workspaces: workspaces) {
                showingPort = false
            }
        }
    }

    @ViewBuilder
    private var hostLines: some View {
        if splitLayout.isSplit {
            if let lead = terminals.leadingSession(in: folder.id), lead.showsHostLine {
                TerminalHost(session: lead)
            }
            if let trail = terminals.trailingSession(in: folder.id), trail.showsHostLine {
                TerminalHost(session: trail)
            }
        } else if let active, active.showsHostLine {
            TerminalHost(session: active)
        }
    }

    /// The Launch tab is the workspace home: selected while the grid is up,
    /// including the empty-folder case where the grid shows without the flag.
    private var isLaunchSelected: Bool {
        front == .launcher || (sessions.isEmpty && front == .sessions)
    }

    /// One chip, drawn from the surface it stands for.
    ///
    /// The strip used to build each kind of chip at its own call site with its
    /// own selection rule, and the commit and the working tree both hardcoded
    /// `isSelected: true`, so two tabs could look selected at once. Selection
    /// is one comparison against one value now.
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
                // Asks first when the file has unsaved changes. A tab close
                // is one click from a tab select.
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
                label: "Files",
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
            // The working tree opens in the same pane as a commit and reads
            // the same way, so it gets the same tab rather than a "Back to
            // terminal" button of its own. Two surfaces that behave alike
            // should be closed alike.
            FileChip(
                path: "Uncommitted changes in \(folder.name)",
                symbol: "plusminus",
                label: "Changes",
                isSelected: selected
            ) {
                workspaces.reviewWorkingTree(in: folder.id)
            } onClose: {
                workspaces.closeWorkingTreeReview(in: folder.id)
            }
        case .sessions, .launcher:
            // Not tabs. `WorkspaceSurface.isTab` keeps them out of the strip.
            EmptyView()
        }
    }

    private func start(_ profile: LaunchProfile) {
        // A new session is what the user now wants to look at, so get any open
        // file out of the way.
        workspaces.showTerminal(in: folder.id)
        let grid = spawnGrid
        let args = workspaces.bypassPermissions(for: folder.id)
            ? profile.args + profile.bypassArgs
            : profile.args
        // The strip's own menu honours the model selection too. It used to
        // ignore it, so the same harness started on a different model
        // depending on which button opened it.
        let selection = LaunchProfile.acceptsLocalModel(profile.id)
            ? LocalModelSelection.stored(for: folder.id, in: workspaces)
            : nil
        Task {
            await terminals.start(
                workspace: folder,
                command: profile.command,
                args: args,
                rows: grid.rows,
                cols: grid.cols,
                modelProvider: selection?.provider,
                modelID: selection?.model
            )
            if let url = profile.openUrl {
                await workspaces.openHarnessPage(url, in: folder)
            }
        }
    }

    // MARK: - Missing folder

    private var missingFolder: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer()
            Label("This folder is missing. It is kept in case it comes back.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Theme.warning)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The close control on a tab.
///
/// Shown whenever the tab is selected or the pointer is over it, not only when
/// selected: closing a background tab should not mean selecting it first.
///
/// It lives *inside* the tab's own chrome, which is what every tab in every
/// browser does and what this did not. It used to be a 44pt square sibling of
/// the tab, so the tab's rounded panel ended and then an unattached x floated
/// after it, reading as its own control rather than as part of the tab. The
/// target is 20pt now, still comfortably clickable, with its own hover circle
/// so the affordance does not depend on the glyph alone.
private struct TabCloseButton: View {
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
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

/// Always-on tab that brings the launch grid back. Not closeable: it is the
/// workspace home, not a session you can throw away.
private struct LaunchChip: View {
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16, height: 16)
                Text("Launch")
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
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
        .help("Back to the launcher. Pick a tool to start in this folder.")
        .accessibilityLabel("Launch")
        .opacity(isHovering && !isSelected ? 0.85 : 1)
    }
}

/// One session's tab: status dot, label, and a close button on the active one.
private struct SessionChip: View {
    let session: TerminalSession
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
                    if let harnessID = session.harnessID {
                        HarnessMark(id: harnessID, size: 16)
                    } else {
                        Image(systemName: "terminal")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 16, height: 16)
                    }
                    Text(label)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(session.cwd)

            if isSelected || isHovering {
                TabCloseButton(help: "Close this session", action: onClose)
            } else {
                // Holds the width the button would take, so a tab does not
                // change size when the pointer crosses it and shove every tab
                // after it sideways.
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
                Button("Open in split", .compare) { onSplit() }
            }
            Button("Close", .delete) { onClose() }
        }
    }

    private var label: String {
        if let title = session.title, !title.isEmpty { return title }
        return session.command
    }

}

/// An open file's tab, next to the session tabs.
///
/// A different icon from a session on purpose: these live in the same strip,
/// and a terminal and a file are not the same kind of thing to close.
private struct FileChip: View {
    /// The full thing, for the tooltip: a path, or a commit's subject.
    let path: String
    let symbol: String
    let label: String
    let isSelected: Bool
    /// Marks a file with unsaved changes, the way every editor does. Without
    /// it, an unsaved file is only visible on the tab you are already looking
    /// at, which is the one tab that does not need telling.
    var isDirty: Bool = false
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                    Text(label)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
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
                TabCloseButton(help: "Close this file", action: onClose)
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
            Button("Close", .delete) { onClose() }
        }
    }
}

/// Full-pane starting state while a session has no process output yet.
///
/// Replaces the empty live terminal that used to sit there with a blinking
/// caret for the whole of an agent boot (measured 3–6s for Claude Code under
/// hostd). The host call itself is tens of milliseconds; this covers the
/// process's own startup, not the bridge.
private struct SessionStartingView: View {
    let command: String

    private var label: String {
        let base = URL(fileURLWithPath: command).lastPathComponent
        switch base {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "grok": return "Grok"
        case "opencode": return "OpenCode"
        case "opencode2": return "OpenCode 2"
        case "agent": return "Cursor Agent"
        case "agy": return "Antigravity"
        case "zsh", "bash", "fish", "sh": return "Shell"
        default: return base
        }
    }

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            ProgressView()
                .controlSize(.regular)
            Text("Starting \(label)")
                .font(.title3.weight(.medium))
            Text("The session is up. Waiting for the program to draw.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

/// A thin line under the terminal for the two facts a terminal should never
/// hide: that its process ended, and that output was dropped because the reader
/// fell behind.
///
/// Separate from the terminal view, which is owned by `TerminalStack` in AppKit
/// so that switching sessions never relayouts it. Starting state lives in the
/// pane above, not here: a second "Starting…" strip under an empty terminal is
/// what made the wait feel like a stuck UI.
struct TerminalHost: View {
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            if session.exitCode != nil || session.droppedOutput || session.outputPaused {
                statusLine
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: Theme.Space.s) {
            if let code = session.exitCode {
                Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(code == 0 ? .green : .red)
                Text(code == 0 ? "Process exited" : "Process exited with code \(code)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if session.droppedOutput {
                Text("Some output was lost: the reader fell behind.")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
            if session.outputPaused {
                Text("Output paused while the terminal catches up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

/// Shown while a folder has no session. The launches are the same agent CLIs
/// the archive counts, so a session and its bill line up.
private struct LaunchSurface: View {
    let folder: WorkspaceFolder
    let terminals: TerminalsModel
    let workspaces: WorkspacesModel
    /// The grid to spawn at, measured by the pane. Passed in rather than
    /// guessed, so the first session opens at the size it will keep.
    let grid: (rows: Int, cols: Int)
    /// What can be launched: this machine's harnesses for a local folder, the
    /// owning machine's for a remote one. The whole supported catalog, so the
    /// grid can show what is installed to start and what could be installed.
    let profiles: [LaunchProfile]
    /// The machine to probe for local model servers. A remote folder's model
    /// picker must use the remote host, not the Mac displaying this surface.
    let modelPeer: String?

    /// The tile that was pressed, while the host is still working on it.
    ///
    /// A spawn is a socket round trip and, on the first one of the daemon's
    /// life, a login shell resolve behind it. Until it returns, `sessions` is
    /// still empty and this whole surface is still on screen, so without this
    /// the click produced nothing at all and people clicked again.
    @State private var launching: String?
    /// What an install said when it failed, shown under the grid so the
    /// installer's own message is what the user reads.
    @State private var installError: String?
    /// The + tile opens the rest of the catalog: not installed, and installed
    /// tiles the user hid. Closed by default so the grid is what they launch.
    @State private var showingCatalog = false
    @State private var pendingInstall: LaunchProfile?
    @State private var pendingHide: LaunchProfile?

    private var visibility: LauncherVisibility { LauncherVisibility.shared }
    private var visibilityScope: String { modelPeer ?? "local" }

    private var modelProfiles: [LaunchProfile] {
        profiles.filter { LaunchProfile.acceptsLocalModel($0.id) && $0.installed }
    }

    /// Installed and still on the grid. Hidden ones live under +.
    ///
    /// Host `hidden` and this device's defaults both count: a hide from the
    /// phone lands as catalog.hidden, a hide on an older host is local only.
    private var visibleProfiles: [LaunchProfile] {
        profiles.filter { $0.installed && !isOffGrid($0) }
    }

    /// Not installed, or installed and hidden. Same catalog order.
    private var extraProfiles: [LaunchProfile] {
        profiles.filter { !$0.installed || isOffGrid($0) }
    }

    private func isOffGrid(_ profile: LaunchProfile) -> Bool {
        profile.hidden || visibility.isHidden(profile.id, scope: visibilityScope)
    }

    /// The workspace's stored selection. The list itself lives in the chrome
    /// row's control, which owns loading it and is on screen whether or not
    /// this surface is.
    private var selectedModel: (provider: String, model: String)? {
        LocalModelSelection.stored(for: folder.id, in: workspaces)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.m) {
                if !terminals.sessions(in: folder.id).isEmpty {
                    runningSessionsBanner
                }

                Image(systemName: "terminal")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.accent.opacity(0.65))
                    .padding(.top, Theme.Space.m)
                Text("Run something in \(folder.name)")
                    .font(.title3.weight(.medium))
                Text("A session runs as its own process, owned by the host, so it keeps going whether or not the window is here to watch it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                // Both settings live in the strip above, where they stay
                // reachable once a session is running. This line is what is
                // left of them here: enough to find them, without a column of
                // controls between the intro and the tiles.
                settingsHint

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: Theme.Space.m)],
                    spacing: Theme.Space.m
                ) {
                    utilityButton("Browser", symbol: ActionIcon.browser.symbol) {
                        _ = workspaces.showBrowser(in: folder.id)
                    }
                    utilityButton("Files", symbol: ActionIcon.reveal.symbol) {
                        workspaces.showFiles(in: folder.id)
                    }
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
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }
                if let error = terminals.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .confirmationDialog(
            pendingInstall.map { "Install \($0.name) on this machine?" } ?? "Install this tool?",
            isPresented: Binding(
                get: { pendingInstall != nil },
                set: { if !$0 { pendingInstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Install") {
                if let profile = pendingInstall {
                    runInstall(profile)
                }
                pendingInstall = nil
            }
            Button("Not now", role: .cancel) { pendingInstall = nil }
        } message: {
            Text("This runs its official installer.")
        }
        .confirmationDialog(
            pendingHide.map { "Remove \($0.name) from the launcher?" } ?? "Remove this tool?",
            isPresented: Binding(
                get: { pendingHide != nil },
                set: { if !$0 { pendingHide = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let profile = pendingHide {
                    Task { await LaunchCatalog.shared.hide(profile.id, peer: modelPeer) }
                }
                pendingHide = nil
            }
            Button("Keep", role: .cancel) { pendingHide = nil }
        } message: {
            Text("The tool stays on this machine. You can add it again from +.")
        }
    }

    /// Where the launch settings went, in one line.
    private var settingsHint: some View {
        Label(
            modelProfiles.isEmpty
                ? "Permission bypass is in the bar above."
                : "Model and permission bypass are in the bar above.",
            systemImage: "arrow.up"
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    /// A slim line instead of a full card, so the launcher content below stays
    /// within the default view.
    private var runningSessionsBanner: some View {
        HStack(spacing: Theme.Space.s) {
            Label(
                "Sessions are still running. Launch another tool or go back.",
                systemImage: "terminal.fill"
            )
            .foregroundStyle(.secondary)
            Spacer(minLength: Theme.Space.s)
            Button("Back to session", .back) {
                workspaces.showTerminal(in: folder.id)
            }
            .controlSize(.small)
        }
        .font(.caption)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 6)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    /// One grid tile: a launch for something installed, an install for
    /// something that has a bundled installer, a muted card for the rest.
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

    /// Same dimmed dashed panel as an uninstalled tile. Opens the rest of
    /// the catalog, or closes it.
    private var addTile: some View {
        Button {
            showingCatalog.toggle()
        } label: {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(height: 34)
                Text(showingCatalog ? "Hide" : "More")
                    .font(.system(size: 13, weight: .medium))
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
        .buttonStyle(.plain)
        .help(showingCatalog
              ? "Hide tools that are not on the launcher."
              : "Show tools you can install or add back.")
        .accessibilityLabel(showingCatalog ? "Hide extra tools" : "Show more tools")
    }

    /// A muted tile that runs the tool's official installer, then flips to a
    /// launch tile once the catalog re-resolves.
    private func installButton(_ profile: LaunchProfile) -> some View {
        LaunchInstallTile(
            profile: profile,
            isInstalling: LaunchCatalog.shared.installing.contains(profile.id),
            onInstall: { pendingInstall = profile }
        )
    }

    /// An installed tool the user hid. Putting it back does not run the installer.
    private func showAgainButton(_ profile: LaunchProfile) -> some View {
        LaunchInstallTile(
            profile: profile,
            isInstalling: false,
            onInstall: { Task { await LaunchCatalog.shared.show(profile.id, peer: modelPeer) } }
        )
        .help("\(profile.name) is installed. Click to add it back to the launcher.")
    }

    private func runInstall(_ profile: LaunchProfile) {
        installError = nil
        Task {
            let message = await LaunchCatalog.shared.install(profile, peer: modelPeer)
            if let message {
                installError = "\(profile.name) could not be installed: \(message)"
            }
        }
    }

    /// A profile with no bundled installer yet: shown because it is a
    /// supported harness, but with nothing to offer but its name.
    private func unavailableTile(_ profile: LaunchProfile) -> some View {
        VStack(spacing: Theme.Space.s) {
            if let harness = profile.harnessID {
                HarnessMark(id: harness, size: 34)
                    .opacity(0.35)
                    .saturation(0.2)
            } else {
                Image(systemName: profile.symbol ?? "terminal")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
                    .frame(height: 34)
            }
            Text(profile.name)
                .font(.system(size: 13, weight: .medium))
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
        .help("No bundled installer for \(profile.name) yet.")
    }

    private func launchButton(_ profile: LaunchProfile) -> some View {
        let selection = modelProfiles.contains(where: { $0.id == profile.id }) ? selectedModel : nil
        return LaunchTile(
            profile: profile,
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
                    // The selection's own arguments are added by the host,
                    // beside the environment half of the same contract. A
                    // front end that mapped one and not the other could point
                    // a session at a local server and still ask it for a
                    // cloud model.
                    _ = await terminals.complete(
                        session,
                        args: args,
                        rows: grid.rows,
                        cols: grid.cols,
                        modelProvider: selection?.provider,
                        modelID: selection?.model
                    )
                    if let url = profile.openUrl {
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
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                    .frame(height: 34)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.m)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// One agent tile: mark, name, and a always-visible path (i) in the corner.
///
/// The (i) used to appear only on tile hover and was drawn too faint to see;
/// hovering the invisible hit target also produced a busy cursor. It is now
/// a real control on every tile: hover shows a Theme bubble with the path.
private struct LaunchTile: View {
    let profile: LaunchProfile
    let isLaunching: Bool
    let othersBusy: Bool
    var onHide: (() -> Void)? = nil
    let onBegin: () -> Void

    /// Hover reveals the path bubble; a click pins it open so a long path can
    /// be read without keeping the pointer on a 22pt target.
    @State private var hovered = false
    @State private var pinned = false

    private var showPath: Bool { hovered || pinned }

    var body: some View {
        // Badge outside the launch Button so a click on (i) never starts a
        // session, and so hover is not stolen by the button's hit testing.
        ZStack(alignment: .topTrailing) {
            Button(action: onBegin) {
                VStack(spacing: Theme.Space.s) {
                    if isLaunching {
                        ProgressView()
                            .controlSize(.small)
                            .frame(height: 34)
                    } else if let harness = profile.harnessID {
                        HarnessMark(id: harness, size: 34)
                    } else {
                        Image(systemName: profile.symbol ?? "terminal")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.accent)
                            .frame(height: 34)
                    }
                    Text(isLaunching ? "Starting…" : profile.name)
                        .font(.system(size: 13, weight: .medium))
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
            .buttonStyle(.plain)
            .disabled(othersBusy)
            .opacity(othersBusy ? 0.5 : 1)

            if !isLaunching {
                pathBadge
                    .padding(8)
            }
        }
        // Bubble sits above neighbouring tiles while open.
        .zIndex(showPath ? 20 : 0)
        .contextMenu {
            if let onHide {
                Button("Remove from launcher", .delete) { onHide() }
            }
        }
    }

    private var pathBadge: some View {
        // A real button, so the mark is clickable (pin the bubble), keyboard
        // reachable, and exposed to VoiceOver as a control rather than a
        // decorative image. It sits outside the launch Button, so a click on
        // (i) never starts a session.
        Button {
            withAnimation(.easeOut(duration: 0.12)) { pinned.toggle() }
        } label: {
            // Filled accent ring so the mark is always readable on a dark tile.
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.accent, Theme.panel)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Theme.sidebar)
                        .shadow(color: Theme.shadow(0.35), radius: 3, x: 0, y: 1)
                )
                .overlay(alignment: .topTrailing) {
                    if showPath {
                        pathBubble
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovered = inside }
        }
        .animation(.easeOut(duration: 0.12), value: showPath)
        .accessibilityLabel("Command path")
        .accessibilityValue(profile.command)
    }

    /// The readable path bubble.
    ///
    /// The width is fixed on purpose: an overlay proposes the badge's own 22pt
    /// size to its content, so a flexible `maxWidth` frame collapsed the text
    /// into a 2pt-wide sliver (measured live at 2x56pt). A fixed 300pt width
    /// keeps the whole command legible.
    private var pathBubble: some View {
        Text(profile.command)
            .font(Theme.mono(11))
            .foregroundStyle(.primary)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: 300, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .shadow(color: Theme.shadow(0.28), radius: 12, x: 0, y: 4)
            .offset(x: 4, y: -8)
            .alignmentGuide(.top) { $0[.bottom] }
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

/// One muted agent tile for a harness that is not installed.
///
/// The quiet treatment is the point: installed harnesses are vivid tiles you
/// start a session from, and these are the same grid a row down, so they use
/// the heatmap's trick of drawing the less important thing with less colour.
/// The click runs the tool's official installer through the host, and the
/// tile becomes a launch tile when the catalog re-resolves.
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
                } else if let harness = profile.harnessID {
                    HarnessMark(id: harness, size: 34)
                        .opacity(0.45)
                        .saturation(0.3)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                        .frame(height: 34)
                }
                Text(isInstalling ? "Installing…" : profile.name)
                    .font(.system(size: 13, weight: .medium))
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
        .buttonStyle(.plain)
        .disabled(isInstalling)
        .help("\(profile.name) is not installed. Click to run its official installer.")
    }
}

/// Opens a service on the other machine's localhost in a browser tab.
///
/// The daemon binds a loopback port on this machine and bridges it over the
/// authenticated stream, so the tab is an ordinary local URL and the remote
/// machine never exposes anything to its own network.
private struct RemotePortForm: View {
    let folder: WorkspaceFolder
    @Bindable var workspaces: WorkspacesModel
    let done: () -> Void

    @State private var port = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Browse a local port on \(folder.machineLabel ?? "the other machine")")
                .font(.callout.weight(.medium))
            Text("View a service running on that device's own localhost, like a webserver, a dev server or a dashboard, right here in the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Port", text: $port)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            HStack {
                Spacer()
                Button("Browse", .reveal) {
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
