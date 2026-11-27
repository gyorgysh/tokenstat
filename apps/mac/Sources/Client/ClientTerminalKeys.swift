// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

/// Fold a printable byte under Ctrl the way a keyboard does.
///
/// Lives outside the phone key bar because the same fold is applied on the
/// shared typing path (`SSHLiveTerminal.send`), which compiles for macOS too.
enum TerminalControlCode {
    static func fold(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x61...0x7A: return byte - 0x60
        case 0x41...0x5A: return byte - 0x40
        case 0x5B...0x5F: return byte - 0x40
        case 0x20: return 0
        default: return nil
        }
    }
}

enum TerminalArrowCode {
    static func encode(_ direction: UInt8, shift: Bool = false, option: Bool = false,
                       control: Bool = false, applicationCursor: Bool = false) -> [UInt8] {
        precondition((0x41...0x44).contains(direction))
        let modifier: UInt8 = 1 + (shift ? 1 : 0) + (option ? 2 : 0) + (control ? 4 : 0)
        if modifier == 1 { return [0x1B, applicationCursor ? 0x4F : 0x5B, direction] }
        return [0x1B, 0x5B, 0x31, 0x3B, 0x30 + modifier, direction]
    }
}

#if !os(macOS)
import SwiftUI
import UIKit

struct ClientTerminalKeys: View {
    let send: ([UInt8]) -> Void
    let toggleKeyboard: () -> Void
    @Binding var scrolls: Bool
    var control: Binding<Bool>? = nil
    var readingOutput = false
    var followOutput: (() -> Void)? = nil
    var leading: AnyView?

    @State private var shift = false
    @State private var localControl = false
    @State private var keyboardUp = true

    private var controlArmed: Binding<Bool> { control ?? $localControl }

    @Environment(PointerKeyboardModel.self) private var input: PointerKeyboardModel?

    /// iPadOS will not show the on-screen keyboard while a hardware one is
    /// attached. Not a setting, and not something an app can override: the
    /// system suppresses its own keyboard and leaves this bar, which is
    /// exactly what somebody sees when they press the key and nothing happens.
    ///
    /// So the key is not drawn. Nothing is covering the terminal for it to
    /// dismiss, and a control whose only outcome is nothing is worse than no
    /// control. Typing still reaches the terminal and every other key on this
    /// bar still works, because none of them are the software keyboard.
    private var canToggleKeyboard: Bool { input?.hasKeyboard != true }

    private enum Key {
        static let escape: [UInt8] = [0x1B]
        static let tab: [UInt8] = [0x09]
        static let backTab: [UInt8] = [0x1B, 0x5B, 0x5A]
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if let leading {
                    leading
                    ThemeRule.vertical.frame(height: 20)
                }
                if canToggleKeyboard {
                    iconKey(
                        keyboardUp ? "keyboard.chevron.compact.down" : "keyboard",
                        label: keyboardUp ? L10n.text("apple.clientterminalkeys.hide_keyboard.f6b0718e") : L10n.text("apple.clientterminalkeys.show_keyboard.585f7659")
                    ) {
                        toggleKeyboard()
                    }
                }
                modifier("scroll", isOn: scrolls) { scrolls.toggle() }
                if readingOutput, let followOutput {
                    iconKey("arrow.down", label: L10n.text("apple.transcriptfollow.jump_to_latest.86752458"), action: followOutput)
                }
                modifier("esc", isOn: false) { fire(Key.escape) }
                modifier("ctrl", isOn: controlArmed.wrappedValue) { controlArmed.wrappedValue.toggle() }
                modifier("shift", isOn: shift) { shift.toggle() }
                key(shift ? "⇧⇥" : "⇥") { fire(shift ? Key.backTab : Key.tab) }
                key("↑") { arrow(0x41) }
                key("↓") { arrow(0x42) }
                key("←") { arrow(0x44) }
                key("→") { arrow(0x43) }
                ForEach(["/", "-", "|", "~"], id: \.self) { text in
                    key(text) { fire(Array(text.utf8)) }
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 6)
        }
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.hidden)
        .background {
            Rectangle()
                .fill(TerminalPalette.surface)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        ) { _ in
            keyboardUp = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { _ in
            keyboardUp = false
        }
    }

    private func fire(_ bytes: [UInt8]) {
        var out = bytes
        if controlArmed.wrappedValue, out.count == 1, let folded = Self.controlCode(out[0]) {
            out = [folded]
        }
        send(out)
        if shift { shift = false }
        if controlArmed.wrappedValue { controlArmed.wrappedValue = false }
    }

    private func arrow(_ direction: UInt8) {
        fire(TerminalArrowCode.encode(direction, shift: shift, control: controlArmed.wrappedValue))
    }

    static func controlCode(_ byte: UInt8) -> UInt8? {
        TerminalControlCode.fold(byte)
    }

    private func iconKey(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.font(15, weight: .medium))
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
                .font(Theme.monoText(15, weight: .medium))
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
                .font(Theme.font(13, weight: .semibold))
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
        case "⇥": return L10n.text("apple.clientterminalkeys.tab.90ddf196")
        case "⇧⇥": return L10n.text("apple.clientterminalkeys.shift_tab.f3fa2578")
        case "↑": return L10n.text("apple.clientterminalkeys.up_arrow.9d2e0b44")
        case "↓": return L10n.text("apple.clientterminalkeys.down_arrow.2d612154")
        case "←": return L10n.text("apple.clientterminalkeys.left_arrow.fe87c896")
        case "→": return L10n.text("apple.clientterminalkeys.right_arrow.0611d428")
        case "/": return L10n.text("apple.clientterminalkeys.slash.9c92721e")
        case "-": return L10n.text("apple.clientterminalkeys.dash.8c3ea2ea")
        case "|": return L10n.text("apple.clientterminalkeys.pipe.3725dbfe")
        case "~": return L10n.text("apple.clientterminalkeys.tilde.66042131")
        default: return label
        }
    }
}

#endif
