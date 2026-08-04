// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import SwiftUI

/// The centre pane below the workspace header: the session strip on top, the
/// selected session's terminal below, or the launch surface while the folder
/// has no session.
struct TerminalPane: View {
    let folder: WorkspaceFolder
    @Bindable var terminals: TerminalsModel
    @Bindable var workspaces: WorkspacesModel

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

    private var loadingCommit: String? {
        workspaces.loadingCommit[folder.id]
    }

    /// True when the pane is showing a terminal rather than a file or a commit.
    private var showsTerminal: Bool {
        activeFile == nil && openCommit == nil && loadingCommit == nil
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

    /// The session to display: the globally selected one when it belongs to
    /// this folder, otherwise the folder's first.
    private var active: TerminalSession? {
        terminals.active(in: folder.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if folder.exists {
                strip
                Divider()
                surface
                if activeFile == nil, let active {
                    TerminalHost(session: active)
                }
            } else {
                missingFolder
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
                    activeID: showsTerminal ? active?.id : nil
                )
                .frame(width: size.width, height: size.height)

                if let commit = openCommit {
                    CommitView(detail: commit)
                        .frame(width: size.width, height: size.height)
                        .id(commit.id)
                } else if loadingCommit != nil {
                    reading("commit")
                        .frame(width: size.width, height: size.height)
                } else if let path = activeFile {
                    fileSurface(path)
                        .frame(width: size.width, height: size.height)
                } else if sessions.isEmpty {
                    LaunchSurface(folder: folder, terminals: terminals, grid: spawnGrid)
                        .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            // Also the size a new session is spawned at, so it never opens at
            // 24x80 and jumps.
            .onAppear { paneSize = size }
            .onChange(of: size) { _, new in paneSize = new }
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

            Menu {
                ForEach(LaunchProfile.available) { profile in
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
            } label: {
                Label("New session", systemImage: "plus")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Launch a shell or an agent CLI in this folder")

            Spacer()
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 4)
        .background(Theme.background)
    }

    private func start(_ profile: LaunchProfile) {
        // A new session is what the user now wants to look at, so get any open
        // file out of the way.
        workspaces.showTerminal(in: folder.id)
        let grid = spawnGrid
        Task {
            await terminals.start(
                workspace: folder,
                command: profile.command,
                args: profile.args,
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
                .foregroundStyle(.orange)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The close control on a tab.
///
/// Shown whenever the tab is selected or the pointer is over it, not only when
/// selected: closing a background tab should not mean selecting it first. Sized
/// as a real target with its own hover background, because an 8pt glyph with no
/// affordance is something people miss and then click the tab instead.
private struct TabCloseButton: View {
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isHovering ? Color.primary : .secondary)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(isHovering ? Theme.rowHighlight : .clear)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
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
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 3)
                .background(isSelected ? Theme.panel : .clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Theme.border : .clear, lineWidth: 1)
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(session.cwd)

            if isSelected || isHovering {
                TabCloseButton(help: "Close this session", action: onClose)
            }
        }
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
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 3)
                .background(isSelected ? Theme.panel : .clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Theme.border : .clear, lineWidth: 1)
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(path)

            if isSelected || isHovering {
                TabCloseButton(help: "Close this file", action: onClose)
            }
        }
        .onHover { isHovering = $0 }
    }
}

/// A thin line under the terminal for the two facts a terminal should never
/// hide: that its process ended, and that output was dropped because the reader
/// fell behind.
///
/// Separate from the terminal view, which is owned by `TerminalStack` in AppKit
/// so that switching sessions never relayouts it.
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
                    .foregroundStyle(.orange)
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
    /// The grid to spawn at, measured by the pane. Passed in rather than
    /// guessed, so the first session opens at the size it will keep.
    let grid: (rows: Int, cols: Int)

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.65))
            Text("Run something in \(folder.name)")
                .font(.title3.weight(.medium))
            Text("A session runs as its own process, owned by the host, so it keeps going whether or not the window is here to watch it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: Theme.Space.m)],
                spacing: Theme.Space.m
            ) {
                ForEach(LaunchProfile.available) { profile in
                    launchButton(profile)
                }
            }
            .frame(maxWidth: 620)

            if let error = terminals.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
        .background(Theme.background)
    }

    private func launchButton(_ profile: LaunchProfile) -> some View {
        Button {
            Task {
                await terminals.start(
                    workspace: folder,
                    command: profile.command,
                    args: profile.args,
                    rows: grid.rows,
                    cols: grid.cols
                )
            }
        } label: {
            VStack(spacing: Theme.Space.s) {
                if let harness = profile.harnessID {
                    HarnessMark(id: harness, size: 34)
                } else {
                    Image(systemName: profile.symbol ?? "terminal")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accent)
                }
                Text(profile.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(profile.command)
                    .font(Theme.mono(11))
                    .foregroundStyle(.tertiary)
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

/// What can be launched in a workspace.
///
/// These are the supported harness commands, keyed by the source id so the
/// launch mark and the archive's mark are the same mark. Only commands actually
/// on the PATH are offered.
private struct LaunchProfile: Identifiable {
    let id: String
    let name: String
    let command: String
    let args: [String]
    /// Source id for the brand mark, or nil for a plain SF symbol.
    let harnessID: String?
    let symbol: String?

    /// The profiles whose command is actually installed.
    ///
    /// Resolved once. Working out what is on the PATH means a stat per
    /// directory per command, and this list is read by the session strip, which
    /// redraws on every keystroke in every terminal. Doing it per redraw put a
    /// filesystem walk on the main thread sixty times a second.
    static let available: [LaunchProfile] = all.filter {
        // The shell is an absolute path; everything else is looked up on PATH.
        $0.command.hasPrefix("/") || commandAvailable($0.command)
    }

    static let all: [LaunchProfile] = [
        LaunchProfile(
            id: "shell",
            name: "Shell",
            command: shellCommand,
            args: shellArguments,
            harnessID: nil,
            symbol: "terminal"
        ),
        LaunchProfile(id: "claude_code", name: "Claude Code", command: "claude", args: [], harnessID: "claude_code", symbol: nil),
        LaunchProfile(id: "codex", name: "Codex", command: "codex", args: [], harnessID: "codex", symbol: nil),
        LaunchProfile(id: "opencode", name: "OpenCode", command: "opencode", args: [], harnessID: "opencode", symbol: nil),
        LaunchProfile(id: "grok", name: "Grok Build", command: "grok", args: [], harnessID: "grok", symbol: nil),
        LaunchProfile(id: "copilot", name: "Copilot CLI", command: "copilot", args: [], harnessID: "copilot", symbol: nil),
        LaunchProfile(id: "cline", name: "Cline", command: "cline", args: [], harnessID: "cline", symbol: nil),
        LaunchProfile(id: "openclaw", name: "OpenClaw", command: "openclaw", args: [], harnessID: "openclaw", symbol: nil),
        LaunchProfile(id: "zed", name: "Zed", command: "zed", args: [], harnessID: "zed", symbol: nil),
        LaunchProfile(id: "antigravity", name: "Antigravity", command: "agy", args: [], harnessID: "antigravity", symbol: nil),
        LaunchProfile(id: "cursor_agent", name: "Cursor Agent", command: "agent", args: [], harnessID: "cursor", symbol: nil),
        LaunchProfile(id: "cursor", name: "Cursor CLI", command: "cursor", args: [], harnessID: "cursor", symbol: nil),
    ]

    private static var shellCommand: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private static var shellArguments: [String] {
        URL(fileURLWithPath: shellCommand).lastPathComponent == "zsh" ? ["-f"] : []
    }
}

/// Whether an executable is reachable on the PATH.
private func commandAvailable(_ name: String) -> Bool {
    guard let path = ProcessInfo.processInfo.environment["PATH"] else { return false }
    for dir in path.split(separator: ":") where !dir.isEmpty {
        if FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") {
            return true
        }
    }
    return false
}
#endif
