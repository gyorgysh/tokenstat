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
///
/// Scoping rules, which every call site follows:
///
/// - Mount a shortcut only in the surface its action belongs to. Editor
///   chords live in editor surfaces, job chords in the job surface they run,
///   inspector chords where the inspector lives. Nothing global invents a
///   second path to the same mutation.
/// - Terminal screens mount none of the workbench chords, so typed keys keep
///   reaching the program. Chat composition keeps `⌘Return` for sending; no
///   workbench chord claims bare Return anywhere (see
///   `ClientWorkbenchShortcutPolicy`).
/// - Every chord has a visible, touch-reachable control performing the same
///   action. A shortcut is never the only path.
struct ClientShortcuts: View {
    let commands: [ClientShortcut]

    var body: some View {
        ZStack {
            ForEach(commands) { command in
                Button(command.title) { command.action() }
                    .keyboardShortcut(command.key, modifiers: command.modifiers)
                    .disabled(!command.enabled)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One shortcut: what it is called, what it is bound to, what it does.
///
/// Disabled commands stay in the hierarchy but do not fire, so holding `⌘`
/// lists them greyed rather than running an action whose button is off.
struct ClientShortcut: Identifiable {
    let id: String
    let title: String
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command
    var enabled = true
    let action: () -> Void
}

extension ClientShortcut {
    /// A workbench chord from the shared policy, with the surface's own
    /// title. Keys live in `WorkbenchShortcut` so tests and views agree.
    static func workbench(
        _ shortcut: WorkbenchShortcut,
        id: String,
        title: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> ClientShortcut {
        ClientShortcut(
            id: id,
            title: title,
            key: KeyEquivalent(Character(shortcut.key)),
            modifiers: shortcut.swiftModifiers,
            enabled: enabled,
            action: action
        )
    }
}

extension WorkbenchShortcut {
    /// The SwiftUI modifiers for this chord.
    var swiftModifiers: EventModifiers {
        var out = EventModifiers()
        if modifiers.contains(.command) { out.insert(.command) }
        if modifiers.contains(.shift) { out.insert(.shift) }
        if modifiers.contains(.option) { out.insert(.option) }
        return out
    }
}

extension View {
    /// Attach a set of shortcuts to this view.
    func clientShortcuts(_ commands: [ClientShortcut]) -> some View {
        background(ClientShortcuts(commands: commands))
    }
}

#endif
