// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftUI

/// Every session on one server, with tabs and an optional split.
///
/// The workspace terminals have had this since the beginning, in
/// `TerminalPane`. SSH got a full-screen cover holding one session, which is
/// why two shells on the same server meant closing the first.
///
/// The chrome is written here rather than shared with `TerminalPane`: that
/// view is a launcher, a file editor, a diff viewer and a browser as well as a
/// tab strip, and dragging all of it behind an SSH tab bar would be worse than
/// a second small view. What *is* shared is the part that matters, the AppKit
/// stack that owns the emulators, so the sizing and the no-SIGWINCH switching
/// learned there are not learned again here.
struct SSHTerminalPane: View {
    @Bindable var sessions: SSHSessionsModel
    let library: SSHLibraryModel
    /// The saved record this pane belongs to. Layout is remembered per host.
    let host: SSHHost
    /// Whether this pane may take the keyboard. False while it is mounted
    /// under another destination.
    var claimsFocus: Bool = true

    @Environment(\.detailChromeToggles) private var toggles

    @State private var closing: SSHLiveTerminal?
    /// A command whose placeholders are being filled before it is typed into
    /// the shell in front. This keeps snippets reachable when the inspector is
    /// closed, which is the common layout on a narrower window.
    @State private var asking: SSHSnippet?

    private var mine: [SSHLiveTerminal] { sessions.sessions(for: host.id) }
    private var layout: TerminalSplitLayout { sessions.layout(for: host.id) }
    private var snippets: [SSHSnippet] { library.snippets(for: host.id) }

    private var leading: SSHLiveTerminal? {
        guard layout.isSplit else { return active }
        return sessions.leadingSession(in: host.id) ?? active
    }

    private var trailing: SSHLiveTerminal? {
        layout.isSplit ? sessions.trailingSession(in: host.id) : nil
    }

    private var active: SSHLiveTerminal? {
        sessions.activeSession(for: host.id)
    }

    /// Snippets type into a live shell only. Ended tabs keep their scrollback
    /// and may stay selected, but writing to one is a silent no-op at the host.
    private var snippetTarget: SSHLiveTerminal? {
        guard let active, active.alive else { return nil }
        return active
    }

    var body: some View {
        VStack(spacing: 0) {
            strip
            ThemeRule()
            if mine.isEmpty {
                empty
            } else {
                TerminalStack(
                    sessions: mine,
                    leading: leading,
                    trailing: trailing,
                    focused: active,
                    splitAxis: layout.axis,
                    fraction: sessions.fraction(for: host.id),
                    claimsFocus: claimsFocus,
                    onActivate: { sessions.select($0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TerminalPalette.surface)
            }
        }
        .background(Theme.background)
        .task(id: host.id) { sessions.restoreSelection(for: host.id) }
        .confirmationDialog(
            "Close this session?",
            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Close", role: .destructive) {
                if let doomed = closing {
                    closing = nil
                    Task { await sessions.close(doomed) }
                }
            }
            Button("Cancel", role: .cancel) { closing = nil }
        } message: {
            Text("Whatever is running in it stops. Nothing else on the server changes.")
        }
        .sheet(item: $asking) { snippet in
            SSHSnippetRunSheet(snippet: snippet) { command in type(command) }
        }
    }

    // MARK: - Tabs

    private var strip: some View {
        HStack(spacing: Theme.Space.s) {
            // The window's own two marks, in the places every other screen
            // puts them. This strip is written here rather than built from
            // `DetailChromeBar`, because that view owns the order of its
            // slots and a row of session tabs wants to sit after the sidebar
            // mark rather than before it. What it must not do is skip them:
            // the SSH terminal was the one destination in the app with no way
            // to reopen the inspector except the keyboard, so a snippets pane
            // somebody closed was a pane they had to know a chord to get back.
            toggles?.leftSidebar
            ForEach(mine) { session in
                SSHSessionChip(
                    session: session,
                    isSelected: session.id == active?.id,
                    isOtherHalf: layout.isSplit
                        && session.id == trailing?.id
                        && session.id != active?.id
                ) {
                    // Option-click puts a tab in the other half, the same
                    // chord the workspace strip uses. One gesture, two panes,
                    // and nothing new to learn on this screen.
                    if NSEvent.modifierFlags.contains(.option) {
                        sessions.sendToOtherHalf(session, in: host.id)
                    } else {
                        sessions.select(session)
                    }
                } onClose: {
                    if session.alive {
                        closing = session
                    } else {
                        Task { await sessions.close(session) }
                    }
                } onSplit: {
                    sessions.sendToOtherHalf(session, in: host.id)
                }
            }

            Button("New session", .create) { library.connectRequest = host }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .help("Open another shell on \(host.label)")

            if !snippets.isEmpty {
                Menu {
                    ForEach(snippets) { snippet in
                        Button(snippet.title, .run) { use(snippet) }
                    }
                } label: {
                    ActionIcon.run.label("Snippets")
                        .font(Theme.font(12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Run a saved command in the session in front")
                .disabled(snippetTarget == nil)
            }

            Spacer()

            if !mine.isEmpty {
                Menu {
                    Button("Single", .layout) { sessions.setLayout(.single, for: host.id) }
                    Button("Side by side", .compare) { sessions.setLayout(.side, for: host.id) }
                    Button("Stacked", .compare) { sessions.setLayout(.stacked, for: host.id) }
                } label: {
                    ActionIcon.compare.label("Split")
                        .font(Theme.font(12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Show two sessions at once")
                .disabled(mine.count < 2)
            }

            // Last, nearest the edge it opens, exactly as the shared chrome
            // bar places it.
            if let right = toggles?.rightInspector {
                right
            }
        }
        .padding(.horizontal, Theme.Space.m)
        // The same optical baseline as every other destination's chrome row.
        .chromeBarMetrics()
        .background(Theme.tabStrip)
    }

    private var empty: some View {
        EmptyState(
            symbol: "terminal",
            title: "No session on \(host.label)",
            message: "Open one and it stays open here, with its own tab, until you close it."
        ) {
            Button("Connect", .connect) { library.connectRequest = host }
                .buttonStyle(AccentButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Run a saved command. Placeholder commands go through the same prompt as
    /// the phone and the inspector before they reach this path, so the filled
    /// line is on screen before anything is sent.
    private func use(_ snippet: SSHSnippet) {
        if SSHSnippet.placeholders(in: snippet.command).isEmpty {
            type(snippet.command)
        } else {
            asking = snippet
        }
    }

    private func type(_ command: String) {
        guard let snippetTarget else { return }
        sessions.select(snippetTarget)
        snippetTarget.sendBytes(SSHSnippet.bytesToRun(command))
    }
}

/// One session's tab.
private struct SSHSessionChip: View {
    let session: SSHLiveTerminal
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
                    Image(systemName: session.alive ? "terminal" : "terminal.fill")
                        .font(Theme.font(11))
                        .foregroundStyle(session.alive ? Theme.accent : Theme.stateIdle)
                        .frame(width: 16, height: 16)
                    Text(session.title)
                        .font(Theme.font(12, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // A session that ended keeps its tab and says so. Its last
                    // screenful is often the reason somebody is looking.
                    if !session.alive {
                        Text("ended")
                            .font(Theme.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isSelected || isHovering {
                TabCloseButton(help: "Close this session", action: onClose)
            } else {
                // Holds the width the button would take, so a tab does not
                // resize under the pointer and shove every tab after it along.
                Color.clear.frame(width: 20, height: 20)
            }
        }
        .padding(.leading, Theme.Space.s)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .background(
            isSelected ? Theme.panel : (isOtherHalf ? Theme.rowHighlight : .clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isSelected ? Theme.border : (isOtherHalf ? Theme.accent.opacity(0.4) : .clear),
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
}
#endif
