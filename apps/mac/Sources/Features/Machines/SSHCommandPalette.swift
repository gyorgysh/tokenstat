// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftTerm
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What the host is offering for the command being typed, drawn over the
/// terminal near the cursor.
///
/// Nothing in here reaches the shell by being shown. A row types its text
/// only when somebody chooses it, and choosing it never presses Return: the
/// line is left at the prompt for the person to read and run.
struct SSHSuggestionPanel: View {
    let session: SSHLiveTerminal

    /// Fixed rather than sized to its contents. A palette that grew and shrank
    /// with every keystroke would be movement beside the cursor while
    /// somebody is trying to read what they are typing.
    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(session.suggestions.enumerated()), id: \.element.id) { index, row in
                    SSHSuggestionRowView(
                        row: row,
                        focused: index == session.highlighted,
                        choose: { session.accept(row) }
                    )
                }
            }
            .padding(4)
            #if os(macOS)
            ThemeRule()
            Text(hint)
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 5)
            #endif
        }
        .frame(width: Self.width, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .shadow(color: SwiftUI.Color.black.opacity(0.22), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }

    /// The keys, and only the ones that are live right now. Before the palette
    /// has been stepped into, Return and Tab still belong to the shell, and
    /// saying otherwise would be teaching somebody the wrong thing.
    private var hint: String {
        session.highlighted == nil
            ? "↓ to choose"
            : "⇥ or ↩ inserts · esc dismisses"
    }
}

/// One offer: a name on the server, or a command somebody saved.
private struct SSHSuggestionRowView: View {
    let row: SSHSuggestion
    let focused: Bool
    let choose: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: symbol)
                    .font(Theme.font(11))
                    .foregroundStyle(focused ? Theme.accent : Theme.controlGlyph)
                    .frame(width: 14)
                Text(row.title)
                    .font(row.isSnippet ? Theme.font(12) : Theme.mono(12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if row.isSnippet {
                    Spacer(minLength: Theme.Space.s)
                    Text(row.detail)
                        .font(Theme.mono(10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityHint("Types it at the prompt without running it")
    }

    private var rowFill: SwiftUI.Color {
        if focused { return Theme.rowSelected }
        return hovering ? Theme.rowHighlight : .clear
    }

    private var symbol: String {
        switch row.kind {
        case "directory": return "folder"
        case "snippet": return "text.append"
        default: return "doc"
        }
    }

    private var label: String {
        switch row.kind {
        case "directory": return "Folder \(row.title)"
        case "snippet": return "Saved command \(row.title), \(row.detail)"
        default: return "File \(row.title)"
        }
    }
}

extension View {
    /// Ask for a chosen command's placeholders before it is typed.
    ///
    /// Written as a modifier so it can be attached to the terminal itself
    /// rather than to the screen around it: a view may present one sheet, and
    /// both of these screens already have one for the snippets menu.
    func paletteSnippetSheet(_ session: SSHLiveTerminal) -> some View {
        sheet(
            item: Binding(
                get: { session.snippetToFill },
                set: { session.snippetToFill = $0 }
            )
        ) { row in
            SSHSnippetRunSheet(
                snippet: SSHSnippet(
                    id: row.id,
                    title: row.title,
                    command: row.insert,
                    tags: [],
                    hostIDs: [],
                    variables: row.variables
                ),
                action: "Insert",
                icon: .apply
            ) { [replacing = session.pendingReplacement] command in
                session.insert(command, replacing: replacing)
            }
        }
    }
}

/// Where the panel sits.
///
/// Under the cursor's line when there is room below it, above that line when
/// there is not, and never outside the terminal. Anchored to the cursor
/// rather than to a corner, because a completion list that is not beside what
/// it completes is a list somebody has to look away to read.
enum SSHPalettePlacement {
    /// Clear of the edges, so the panel never sits on the terminal's border.
    static let margin: CGFloat = 8
    /// Between the line being typed and the panel.
    static let gap: CGFloat = 4

    /// The panel's top-left corner, in the terminal's own coordinates with the
    /// origin at its top-left.
    static func origin(
        panel: CGSize,
        cursor: CGPoint,
        lineHeight: CGFloat,
        in bounds: CGSize
    ) -> CGPoint {
        let maxX = max(margin, bounds.width - panel.width - margin)
        let x = min(max(cursor.x, margin), maxX)
        let below = cursor.y + lineHeight + gap
        let above = cursor.y - panel.height - gap
        let y: CGFloat
        if below + panel.height <= bounds.height - margin {
            y = below
        } else if above >= margin {
            y = above
        } else {
            // A window too short for either. Keeping it inside beats letting
            // it hang off the edge, and the line is one row from view.
            y = max(margin, bounds.height - panel.height - margin)
        }
        return CGPoint(x: x, y: y)
    }
}

#if !os(macOS)
/// The palette on a phone or an iPad, drawn over the terminal.
///
/// A SwiftUI overlay rather than a subview of the emulator, because there the
/// emulator is a scroll view: anything put inside it would slide away with
/// the buffer the moment somebody read back through their output.
struct SSHPaletteOverlay: View {
    let session: SSHLiveTerminal

    /// The panel's measured height. Its width is fixed, so this is the only
    /// part of the geometry that has to be found out rather than known.
    @State private var height: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            if !session.suggestions.isEmpty, let anchor = session.paletteAnchor {
                let panel = CGSize(width: SSHSuggestionPanel.width, height: height)
                let origin = SSHPalettePlacement.origin(
                    panel: panel,
                    cursor: anchor,
                    lineHeight: session.paletteLineHeight,
                    in: geometry.size
                )
                SSHSuggestionPanel(session: session)
                    .background(
                        GeometryReader { measured in
                            Color.clear
                                .onAppear { height = measured.size.height }
                                .onChange(of: measured.size.height) { height = $1 }
                        }
                    )
                    .offset(x: origin.x, y: origin.y)
                    // Hidden for the one frame before its height is known,
                    // rather than drawn in the wrong place and corrected.
                    .opacity(height > 0 ? 1 : 0)
            }
        }
        .allowsHitTesting(!session.suggestions.isEmpty)
    }
}
#endif

#if os(macOS)
/// Holds the palette inside the terminal it belongs to.
///
/// A subview of the emulator rather than a SwiftUI overlay on the screen,
/// because a Mac window can hold two sessions side by side and the panel has
/// to follow its own half through a split, a resize and a tab switch without
/// anybody computing where that half is.
@MainActor
final class SSHPaletteLayer {
    private var hosting: NSHostingView<SSHSuggestionPanel>?
    /// The key watch, held only while the panel is on screen.
    private var keys: Any?
    /// Answers true when the palette took the key.
    private let claimKey: (NSEvent) -> Bool

    init(claimKey: @escaping (NSEvent) -> Bool) {
        self.claimKey = claimKey
    }

    /// Draw or move the panel. `cursor` and the result are in the terminal's
    /// coordinates with the origin at its top-left.
    func show(_ panel: SSHSuggestionPanel, in view: NSView, cursor: CGPoint, lineHeight: CGFloat) {
        let hosted: NSHostingView<SSHSuggestionPanel>
        if let hosting {
            hosting.rootView = panel
            hosted = hosting
        } else {
            hosted = NSHostingView(rootView: panel)
            hosted.translatesAutoresizingMaskIntoConstraints = true
            hosting = hosted
        }
        if hosted.superview !== view { view.addSubview(hosted) }
        hosted.layoutSubtreeIfNeeded()
        let size = CGSize(
            width: SSHSuggestionPanel.width,
            height: hosted.fittingSize.height
        )
        let origin = SSHPalettePlacement.origin(
            panel: size,
            cursor: cursor,
            lineHeight: lineHeight,
            in: view.bounds.size
        )
        // AppKit measures from the bottom, the placement from the top.
        hosted.frame = NSRect(
            x: origin.x,
            y: view.bounds.height - origin.y - size.height,
            width: size.width,
            height: size.height
        )
        watchKeys(over: view)
    }

    func hide() {
        hosting?.removeFromSuperview()
        hosting = nil
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }

    /// See a key before the emulator does, while the panel is up.
    ///
    /// A local watch rather than a `keyDown` override, because SwiftTerm's
    /// `TerminalView` is not open for subclassing on this platform. It is
    /// installed only while there is something to offer, and it hands back
    /// every key the palette does not claim, so the terminal's own handling
    /// is unchanged in every other moment.
    private func watchKeys(over view: NSView) {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self, weak view] event in
            let taken = MainActor.assumeIsolated { self?.take(event, over: view) ?? false }
            return taken ? nil : event
        }
    }

    /// Whether this key was the palette's.
    ///
    /// Only for the terminal the panel is drawn on, and only while that
    /// terminal is the thing taking keystrokes. A window with two sessions
    /// side by side has two of these watches, and each answers for its own.
    private func take(_ event: NSEvent, over view: NSView?) -> Bool {
        guard let view, let window = view.window, event.window === window,
            let responder = window.firstResponder as? NSView,
            responder === view || responder.isDescendant(of: view)
        else { return false }
        return claimKey(event)
    }
}
#endif
