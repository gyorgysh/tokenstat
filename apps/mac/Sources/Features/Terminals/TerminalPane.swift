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

    private var sessions: [TerminalSession] {
        terminals.sessions(in: folder.id)
    }

    /// Files open in this pane beside the terminals.
    private var openFiles: [String] {
        workspaces.openFiles[folder.id] ?? []
    }

    /// The file on screen, or nil when a terminal is.
    private var activeFile: String? {
        workspaces.activeFile[folder.id]
    }

    /// The commit on screen, if History opened one.
    private var openCommit: CommitDetail? {
        workspaces.openCommit[folder.id]
    }

    private var reviewingWorkingTree: Bool {
        workspaces.reviewingWorkingTree.contains(folder.id)
    }

    private var browserShown: Bool {
        workspaces.activeBrowserID[folder.id] != nil
    }

    private var activeBrowser: WorkspaceBrowserTab? {
        guard let id = workspaces.activeBrowserID[folder.id] else { return nil }
        return workspaces.browserTabs(in: folder.id).first { $0.id == id }
    }

    private var filesShown: Bool {
        workspaces.filesShown.contains(folder.id)
    }

    private var loadingCommit: String? {
        workspaces.loadingCommit[folder.id]
    }

    /// True when the pane is showing a terminal rather than a file or a commit.
    private var showsTerminal: Bool {
        activeFile == nil && !browserShown && !filesShown && openCommit == nil && loadingCommit == nil && !reviewingWorkingTree
    }

    /// Which harnesses this Mac can launch. Shared, and resolved off the main
    /// actor: see `LaunchCatalog` for the crash that reading it inline caused.
    private var launcher: LaunchCatalog { LaunchCatalog.shared }

    /// The machine that owns this folder, when it is remote.
    private var peer: String? {
        let parts = folder.id.split(separator: ":", maxSplits: 2).map(String.init)
        return parts.count == 3 && parts[0] == "remote" ? parts[1] : nil
    }

    /// What to offer in the launcher: this machine's harnesses for a local
    /// folder, the owning machine's for a remote one.
    private var launcherProfiles: [LaunchProfile] {
        peer == nil ? launcher.available : launcher.remoteAvailable
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

    /// The session the user can actually see, which is nothing at all while a
    /// file, a commit or the browser is over the top of it, or while another
    /// destination is in front of this whole surface.
    private var focusedSessionID: String? {
        isSurfaceActive && showsTerminal ? active?.id : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if folder.exists {
                strip
                Divider()
                surface
                if activeFile == nil, !browserShown, !filesShown, let active {
                    TerminalHost(session: active)
                }
            } else {
                missingFolder
            }
        }
        // Only the session actually on screen polls at keystroke speed. The
        // rest keep draining the host's buffer, just slower, which is the
        // difference between a few round trips a second and a few hundred when
        // several agents are running at once.
        .onChange(of: focusedSessionID, initial: true) {
            terminals.focus(focusedSessionID)
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
        .alert("Could not start session", isPresented: launchFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(terminals.errorMessage ?? "")
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
                    // down.
                    active: showsTerminal ? active : nil,
                    // Do not steal the keyboard while Home (or any other
                    // destination) is in front of a kept-mounted surface.
                    claimsFocus: isSurfaceActive && showsTerminal
                )
                .frame(width: size.width, height: size.height)

                // Starting state over the stack: pending host spawn, or the
                // process is up but has not painted yet. Agent CLIs spend
                // several seconds in that gap; an empty live terminal there
                // is what read as a 10s hang.
                if showsTerminal, let active, active.showsStartingState {
                    SessionStartingView(command: active.command)
                        .frame(width: size.width, height: size.height)
                }

                // The launcher wins over every other surface when toggled on:
                // that is its whole point, to put a new launch in front even
                // while sessions are running underneath. Any real navigation
                // (opening a file, browser, terminal) clears the flag.
                if workspaces.showingLauncher.contains(folder.id) {
                    LaunchSurface(
                        folder: folder,
                        terminals: terminals,
                        workspaces: workspaces,
                        grid: spawnGrid,
                        profiles: launcherProfiles
                    )
                        .frame(width: size.width, height: size.height)
                } else if reviewingWorkingTree {
                    WorkingTreeReviewView(folder: folder, model: workspaces)
                        .frame(width: size.width, height: size.height)
                } else if let commit = openCommit {
                    CommitView(detail: commit)
                        .frame(width: size.width, height: size.height)
                        .id(commit.id)
                } else if loadingCommit != nil {
                    reading("commit")
                        .frame(width: size.width, height: size.height)
                } else if let path = activeFile {
                    fileSurface(path)
                    .frame(width: size.width, height: size.height)
                } else if filesShown {
                    WorkspaceFilesView(model: workspaces, folder: folder, surface: .content)
                        .frame(width: size.width, height: size.height)
                } else if let browser = activeBrowser {
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
                        profiles: launcherProfiles
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
                value: workspaces.showingLauncher.contains(folder.id)
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

    private var closingUnsaved: Binding<Bool> {
        Binding(
            get: { workspaces.pendingClose != nil },
            set: { if !$0 { workspaces.pendingClose = nil } }
        )
    }

    private var launchFailed: Binding<Bool> {
        Binding(
            get: { terminals.errorMessage != nil },
            set: { if !$0 { terminals.errorMessage = nil } }
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
            ForEach(sessions) { session in
                SessionChip(
                    session: session,
                    isSelected: showsTerminal && session.id == active?.id
                ) {
                    // Selecting a terminal puts it back in front without
                    // closing whatever files are open.
                    workspaces.showTerminal(in: folder.id)
                    terminals.select(session)
                } onClose: {
                    Task { await terminals.close(session) }
                }
            }

            ForEach(openFiles, id: \.self) { path in
                FileChip(
                    path: path,
                    symbol: "doc.text",
                    label: String(path.split(separator: "/").last ?? ""),
                    isSelected: openCommit == nil && activeFile == path,
                    isDirty: workspaces.isEditorDirty(path, in: folder.id)
                ) {
                    Task { await workspaces.openFile(path, in: folder.id) }
                } onClose: {
                    // Asks first when the file has unsaved changes. A tab close
                    // is one click from a tab select.
                    workspaces.requestClose(path, in: folder.id)
                }
            }

            ForEach(workspaces.browserTabs(in: folder.id)) { browser in
                FileChip(
                    path: browser.url.isEmpty ? browser.title : browser.url,
                    symbol: "globe",
                    label: browser.title,
                    isSelected: browser.id == workspaces.activeBrowserID[folder.id]
                ) {
                    _ = workspaces.showBrowser(in: folder.id, id: browser.id)
                } onClose: {
                    workspaces.closeBrowser(browser, in: folder.id)
                }
            }

            if filesShown || !openFiles.isEmpty {
                FileChip(
                    path: folder.path,
                    symbol: "folder",
                    label: "Files",
                    isSelected: filesShown && activeFile == nil,
                    isDirty: false
                ) {
                    workspaces.showFiles(in: folder.id)
                } onClose: {
                    workspaces.closeFiles(in: folder.id)
                }
            }

            // A commit gets a tab too, so it is as closeable as anything else
            // and it is obvious the pane is showing history rather than work.
            if let commit = openCommit {
                FileChip(
                    path: commit.subject,
                    symbol: "arrow.triangle.branch",
                    label: commit.shortID,
                    isSelected: true
                ) {} onClose: {
                    workspaces.closeCommit(in: folder.id)
                }
            }

            // The working tree opens in the same pane as a commit and reads
            // the same way, so it gets the same tab rather than a "Back to
            // terminal" button of its own. Two surfaces that behave alike
            // should be closed alike.
            if reviewingWorkingTree {
                FileChip(
                    path: "Uncommitted changes in \(folder.name)",
                    symbol: "plusminus",
                    label: "Changes",
                    isSelected: true
                ) {} onClose: {
                    workspaces.closeWorkingTreeReview(in: folder.id)
                }
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

    private func start(_ profile: LaunchProfile) {
        // A new session is what the user now wants to look at, so get any open
        // file out of the way.
        workspaces.showTerminal(in: folder.id)
        let grid = spawnGrid
        let args = workspaces.bypassPermissions(for: folder.id)
            ? profile.args + profile.bypassArgs
            : profile.args
        Task {
            await terminals.start(
                workspace: folder,
                command: profile.command,
                args: args,
                rows: grid.rows,
                cols: grid.cols
            )
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

/// One session's tab: status dot, label, and a close button on the active one.
private struct SessionChip: View {
    let session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

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
        .background(isSelected ? Theme.panel : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Theme.border : .clear, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
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
            if session.exitCode != nil || session.droppedOutput {
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
    /// owning machine's for a remote one.
    let profiles: [LaunchProfile]

    /// The tile that was pressed, while the host is still working on it.
    ///
    /// A spawn is a socket round trip and, on the first one of the daemon's
    /// life, a login shell resolve behind it. Until it returns, `sessions` is
    /// still empty and this whole surface is still on screen, so without this
    /// the click produced nothing at all and people clicked again.
    @State private var launching: String?

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

                // In the default view, not buried under the grid: a setting
                // nobody can see is a setting that does not exist. The
                // dividers keep it from blending into the intro and the grid.
                VStack(spacing: Theme.Space.s) {
                    Divider()
                    bypassToggle
                    Divider()
                }
                .frame(maxWidth: 460, alignment: .leading)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: Theme.Space.m)],
                    spacing: Theme.Space.m
                ) {
                    utilityButton("Browser", symbol: "globe") {
                        _ = workspaces.showBrowser(in: folder.id)
                    }
                    utilityButton("Files", symbol: "folder") {
                        workspaces.showFiles(in: folder.id)
                    }
                    ForEach(profiles) { profile in
                        launchButton(profile)
                    }
                }
                .frame(maxWidth: 620)

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
            Button("Back to session") {
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

    private var bypassToggle: some View {
        Toggle(isOn: Binding(
            get: { workspaces.bypassPermissions(for: folder.id) },
            set: { workspaces.setBypassPermissions($0, for: folder.id) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bypass permission prompts")
                    .font(.callout.weight(.medium))
                Text("Agents run without asking for permission. Remembered for this workspace. Only agents with a bypass flag are affected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: 460, alignment: .leading)
    }

    private func launchButton(_ profile: LaunchProfile) -> some View {
        LaunchTile(
            profile: profile,
            isLaunching: launching == profile.id,
            othersBusy: launching != nil && launching != profile.id,
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
                    _ = await terminals.complete(
                        session,
                        args: args,
                        rows: grid.rows,
                        cols: grid.cols
                    )
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
                Button("Browse") {
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
