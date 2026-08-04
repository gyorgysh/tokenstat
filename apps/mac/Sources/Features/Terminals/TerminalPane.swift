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

    private var sessions: [TerminalSession] {
        terminals.sessions(in: folder.id)
    }

    /// The session to display: the globally selected one when it belongs to
    /// this folder, otherwise the folder's first.
    private var active: TerminalSession? {
        if let selected = terminals.selected, sessions.contains(where: { $0.id == selected.id }) {
            return selected
        }
        return sessions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if folder.exists {
                strip
                Divider()
                if let active {
                    TerminalHost(session: active)
                } else {
                    LaunchSurface(folder: folder, terminals: terminals)
                }
            } else {
                missingFolder
            }
        }
        .onChange(of: folder.id) {
            // Coming back to a folder selects one of its own sessions, not
            // whatever is running in another workspace.
            if let first = sessions.first, terminals.selectedID != first.id {
                terminals.selectedID = first.id
            }
        }
        .alert("Could not start session", isPresented: launchFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(terminals.errorMessage ?? "")
        }
    }

    private var launchFailed: Binding<Bool> {
        Binding(
            get: { terminals.errorMessage != nil },
            set: { if !$0 { terminals.errorMessage = nil } }
        )
    }

    // MARK: - Session strip

    private var strip: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(sessions) { session in
                SessionChip(
                    session: session,
                    isSelected: session.id == active?.id
                ) {
                    terminals.selectedID = session.id
                } onClose: {
                    Task { await terminals.close(session) }
                }
            }

            Menu {
                ForEach(LaunchProfile.all.filter(\.available)) { profile in
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
                    .font(.system(size: 11))
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
        Task { await terminals.start(workspace: folder, command: profile.command, args: profile.args) }
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

/// One session's tab: status dot, label, and a close button on the active one.
private struct SessionChip: View {
    let session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: Theme.Space.xs) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(label)
                        .font(.system(size: 11, weight: isSelected ? .medium : .regular))
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

            if isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14, height: 14)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Close this session")
            }
        }
    }

    private var label: String {
        if let title = session.title, !title.isEmpty { return title }
        return session.command
    }

    private var statusColor: Color {
        if session.alive { return .green }
        if session.exitCode == 0 { return .gray }
        return .red
    }
}

/// The terminal itself, with a thin status line under it for the two facts a
/// terminal should never hide: that its process ended, and that output was
/// dropped because the reader fell behind.
struct TerminalHost: View {
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            TerminalViewRepresentable(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
            if session.exitCode != nil || session.droppedOutput {
                statusLine
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: Theme.Space.s) {
            if let code = session.exitCode {
                Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 10))
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
                ForEach(LaunchProfile.all.filter(\.available)) { profile in
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
            Task { await terminals.start(workspace: folder, command: profile.command, args: profile.args) }
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
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(profile.command)
                    .font(Theme.mono(10))
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
/// These are the same agent CLIs the archive counts, keyed by their source id
/// so the launch mark and the archive's mark are the same mark. Only commands
/// actually on the PATH are offered.
private struct LaunchProfile: Identifiable {
    let id: String
    let name: String
    let command: String
    let args: [String]
    /// Source id for the brand mark, or nil for a plain SF symbol.
    let harnessID: String?
    let symbol: String?

    var available: Bool {
        // The shell is an absolute path; everything else is looked up on PATH.
        command.hasPrefix("/") || commandAvailable(command)
    }

    static let all: [LaunchProfile] = [
        LaunchProfile(
            id: "shell",
            name: "Shell",
            command: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
            args: [],
            harnessID: nil,
            symbol: "terminal"
        ),
        LaunchProfile(id: "claude_code", name: "Claude Code", command: "claude", args: [], harnessID: "claude_code", symbol: nil),
        LaunchProfile(id: "codex", name: "Codex", command: "codex", args: [], harnessID: "codex", symbol: nil),
        LaunchProfile(id: "opencode", name: "OpenCode", command: "opencode", args: [], harnessID: "opencode", symbol: nil),
        LaunchProfile(id: "grok", name: "Grok Build", command: "grok", args: [], harnessID: "grok", symbol: nil),
        LaunchProfile(id: "copilot", name: "Copilot CLI", command: "copilot", args: [], harnessID: "copilot", symbol: nil),
    ]
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
