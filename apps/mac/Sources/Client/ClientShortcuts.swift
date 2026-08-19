// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// The keyboard half of the sidebar layout.
///
/// An iPad with a keyboard attached is a machine somebody types on, and a
/// person who has just been given a Mac-shaped layout will try `⌘1` within a
/// minute. The commands are attached to real buttons rather than to a
/// `UIKeyCommand` table so they land in the system's own discoverability
/// overlay when `⌘` is held, with the words below as their titles.
///
/// The buttons are invisible and take no space. They are not `.hidden()`,
/// which would remove them from the hierarchy and take the shortcuts with
/// them, and they refuse hit testing so nothing can be pressed by accident.
struct ClientShortcuts: View {
    let commands: [ClientShortcut]

    var body: some View {
        ZStack {
            ForEach(commands) { command in
                Button(command.title) { command.action() }
                    .keyboardShortcut(command.key, modifiers: command.modifiers)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One shortcut: what it is called, what it is bound to, what it does.
struct ClientShortcut: Identifiable {
    let id: String
    let title: String
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command
    let action: () -> Void
}

extension View {
    /// Attach a set of shortcuts to this view.
    func clientShortcuts(_ commands: [ClientShortcut]) -> some View {
        background(ClientShortcuts(commands: commands))
    }
}

#endif
