// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

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

struct ClientShortcut: Identifiable {
    let id: String
    let title: String
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command
    var enabled = true
    let action: () -> Void
}

extension ClientShortcut {
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
    func clientShortcuts(_ commands: [ClientShortcut]) -> some View {
        background(ClientShortcuts(commands: commands))
    }
}

#endif
