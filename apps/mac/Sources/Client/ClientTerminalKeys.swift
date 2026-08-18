// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI
import UIKit

/// The keys a phone keyboard does not have, above a live terminal.
///
/// SwiftTerm ships its own accessory, and it is missing the one chord an agent
/// session actually needs: **Shift+Tab**, which is how every harness rotates
/// its mode. There is no Shift key on that bar and no back-tab anywhere, so on
/// a phone the mode could be read and never changed.
///
/// A back-tab is not a shifted tab byte, it is `ESC [ Z`. That is why a generic
/// Shift key alone would not have been enough: Shift here arms the *next* key
/// and each key decides what its shifted form is, which for Tab is CSI Z.
///
/// Bytes go to the same closure the terminal view writes on, so this adds no
/// transport and cannot get out of step with what typing does.
struct ClientTerminalKeys: View {
    /// Send raw bytes to the pty.
    let send: ([UInt8]) -> Void
    /// Put the keyboard away, so the screen is all output.
    let dismissKeyboard: () -> Void
    /// Whether a drag scrolls the buffer instead of reaching the program.
    @Binding var scrolls: Bool

    /// Armed for the next key only, like a real modifier tapped once. Sticky
    /// on purpose: a phone cannot hold one key while pressing another.
    @State private var shift = false
    @State private var control = false

    private enum Key {
        static let escape: [UInt8] = [0x1B]
        static let tab: [UInt8] = [0x09]
        /// CSI Z. Back-tab, and the reason this bar exists.
        static let backTab: [UInt8] = [0x1B, 0x5B, 0x5A]
        static let up: [UInt8] = [0x1B, 0x5B, 0x41]
        static let down: [UInt8] = [0x1B, 0x5B, 0x42]
        static let right: [UInt8] = [0x1B, 0x5B, 0x43]
        static let left: [UInt8] = [0x1B, 0x5B, 0x44]
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                // Reading is half of what a phone does with a terminal, and
                // the keyboard covers half the screen. This is the way out of
                // it; tapping the terminal brings the keyboard back.
                iconKey("keyboard.chevron.compact.down", label: "Hide keyboard") {
                    dismissKeyboard()
                }
                // An agent holds mouse reporting on, which turns a drag into
                // an event for the program rather than a scroll, so the view
                // is pinned to the bottom. This is the toggle SwiftTerm's own
                // bar carried and ours dropped.
                modifier("scroll", isOn: scrolls) { scrolls.toggle() }
                modifier("esc", isOn: false) { fire(Key.escape) }
                modifier("ctrl", isOn: control) { control.toggle() }
                modifier("shift", isOn: shift) { shift.toggle() }
                // One key, two meanings, and the label says which one is
                // armed. Shift+Tab as a separate button would have been a
                // chord nobody would look for under a keyboard.
                key(shift ? "⇧⇥" : "⇥") { fire(shift ? Key.backTab : Key.tab) }
                key("↑") { fire(Key.up) }
                key("↓") { fire(Key.down) }
                key("←") { fire(Key.left) }
                key("→") { fire(Key.right) }
                ForEach(["/", "-", "|", "~"], id: \.self) { text in
                    key(text) { fire(Array(text.utf8)) }
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }

    /// Send one key, applying and then clearing whatever was armed.
    ///
    /// Control folds a letter to its C0 code the way a keyboard does: `ctrl`
    /// then `c` is 0x03. Shift is consumed by the key that read it, so it is
    /// cleared here whether or not that key did anything with it.
    private func fire(_ bytes: [UInt8]) {
        var out = bytes
        if control, out.count == 1, let folded = Self.controlCode(out[0]) {
            out = [folded]
        }
        send(out)
        if shift { shift = false }
        if control { control = false }
    }

    /// The C0 code for a printable byte, or nil when there is none.
    static func controlCode(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x61...0x7A: return byte - 0x60  // a–z
        case 0x41...0x5A: return byte - 0x40  // A–Z
        case 0x5B...0x5F: return byte - 0x40  // [ \ ] ^ _
        case 0x20: return 0  // space is NUL
        default: return nil
        }
    }

    /// A key whose face is a symbol rather than what it types.
    private func iconKey(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(minWidth: 44, minHeight: 34)
                .background(Theme.panel, in: .rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .frame(minWidth: 38, minHeight: 34)
                .background(Theme.panel, in: .rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(Self.spoken(label))
    }

    private func modifier(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 46, minHeight: 34)
                .background(
                    isOn ? Theme.accent.opacity(0.28) : Theme.panel,
                    in: .rect(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Theme.accent : .primary)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// VoiceOver reads the glyphs as words. "Right arrow", not "greater than".
    static func spoken(_ label: String) -> String {
        switch label {
        case "⇥": return "Tab"
        case "⇧⇥": return "Shift Tab"
        case "↑": return "Up arrow"
        case "↓": return "Down arrow"
        case "←": return "Left arrow"
        case "→": return "Right arrow"
        case "/": return "Slash"
        case "-": return "Dash"
        case "|": return "Pipe"
        case "~": return "Tilde"
        default: return label
        }
    }
}

#endif
