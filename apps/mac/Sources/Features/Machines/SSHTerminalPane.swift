// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
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
    let host: SSHHost
    var claimsFocus: Bool = true

    @Environment(\.detailChromeToggles) private var toggles

    @State private var closing: SSHLiveTerminal?
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

    private var snippetTarget: SSHLiveTerminal? {
        guard let active, active.alive else { return nil }
        return active
    }

    var body: some View {
        VStack(spacing: 0) {
            strip
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
                .modifier(PaletteSnippetSheet(session: active))
            }
        }
        .desktopPaneBackground()
        .task(id: host.id) { sessions.restoreSelection(for: host.id) }
        .confirmationDialog(
            L10n.text("apple.sshterminalpane.close_this_session.2b66ce2d"),
            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.text("common.close"), role: .destructive) {
                if let doomed = closing {
                    closing = nil
                    Task { await sessions.close(doomed) }
                }
            }
            Button(L10n.text("common.cancel"), role: .cancel) { closing = nil }
        } message: {
            Text(L10n.text("apple.sshterminalpane.whatever_is_running_in_it_stops_nothing_el.f25aee6b"))
        }
        .sheet(item: $asking) { snippet in
            SSHSnippetRunSheet(snippet: snippet) { command in type(command) }
        }
    }


    private var strip: some View {
        HStack(spacing: Theme.Space.s) {
            toggles?.leftSidebar
            ForEach(mine) { session in
                SSHSessionChip(
                    session: session,
                    isSelected: session.id == active?.id,
                    isOtherHalf: layout.isSplit
                        && session.id == trailing?.id
                        && session.id != active?.id
                ) {
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

            Button(L10n.text("apple.sshterminalpane.new_terminal.fe544556"), .create) { library.connectRequest = host }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .help(L10n.text("apple.sshterminalpane.open_another_shell_on_0.ef2411b2", "\(host.label)"))

            if !snippets.isEmpty {
                Menu {
                    ForEach(snippets) { snippet in
                        Button(snippet.title, .run) { use(snippet) }
                    }
                } label: {
                    ActionIcon.run.label(L10n.text("apple.sshterminalpane.snippets.ff717209"))
                        .font(Theme.font(12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L10n.text("apple.sshterminalpane.run_a_saved_command_in_the_session_in_fron.241bc4fa"))
                .disabled(snippetTarget == nil)
            }

            Spacer()

            if !mine.isEmpty {
                Menu {
                    Button(L10n.text("apple.sshterminalpane.single.8888a029"), .layout) { sessions.setLayout(.single, for: host.id) }
                    Button(L10n.text("apple.sshterminalpane.side_by_side.a3d7b387"), .compare) { sessions.setLayout(.side, for: host.id) }
                    Button(L10n.text("apple.sshterminalpane.stacked.c2fed746"), .compare) { sessions.setLayout(.stacked, for: host.id) }
                    if layout.isSplit {
                        Divider()
                        TerminalSwapButton(layout: layout) { sessions.swapPanes(in: host.id) }
                            .disabled(trailing == nil || leading?.id == trailing?.id)
                    }
                } label: {
                    ActionIcon.compare.label(L10n.text("apple.sshterminalpane.split.32afaa78"))
                        .font(Theme.font(12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L10n.text("apple.sshterminalpane.show_two_sessions_at_once.0cfb6b4a"))
                .disabled(mine.count < 2)
            }

            if let right = toggles?.rightInspector {
                right
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .chromeBarMetrics()
        .modifier(DesktopTitlebarPlate(fallback: Theme.tabStrip))
    }

    private var empty: some View {
        EmptyState(
            symbol: "terminal",
            title: L10n.text("apple.sshterminalpane.no_session_on_0.90ff0939", "\(host.label)"),
            message: L10n.text("apple.sshterminalpane.open_one_and_it_stays_open_here_with_its_o.16edc392")
        ) {
            Button(L10n.text("common.connect"), .connect) { library.connectRequest = host }
                .buttonStyle(AccentButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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

struct PaletteSnippetSheet: ViewModifier {
    let session: SSHLiveTerminal?

    func body(content: Content) -> some View {
        content.paletteSnippetSheet(session)
    }
}

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
                    if !session.alive {
                        Text(L10n.text("apple.sshterminalpane.ended.e87ba7a0"))
                            .font(Theme.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isSelected || isHovering {
                TabCloseButton(help: L10n.text("apple.sshterminalpane.close_this_session.fa2af1b6"), action: onClose)
            } else {
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
                Button(L10n.text("apple.sshterminalpane.open_in_split.6b36cec3"), .compare) { onSplit() }
            }
            Button(L10n.text("common.close"), .delete) { onClose() }
        }
    }
}
#endif
