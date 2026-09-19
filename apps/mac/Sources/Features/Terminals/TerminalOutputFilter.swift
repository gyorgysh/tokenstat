// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

/// Output on its way from a program to the emulator, with unsupported protocol commands removed.
///
/// **`CSI = 1 ; 1 u` is the kitty keyboard protocol, not a cursor restore.**
/// SwiftTerm 1.11.2 dispatches every CSI ending in `u` to `cmdRestoreCursor`
/// without looking at the private prefix that came before the parameters, so a
/// program announcing the kitty protocol has its cursor thrown to the last
/// saved position, which on a fresh screen is the top-left corner.
///
/// Antigravity 1.1.15 sends it after every redraw, and draws its composer with
/// relative cursor moves. One teleport and everything it prints afterwards
/// lands in the wrong place: keystrokes pile up in the corner over the banner
/// while the prompt stays empty. It is unusable, and it looks like the terminal
/// dropped the keys rather than misplaced them.
///
/// Dropping the announcement is right rather than merely convenient. We do not
/// implement the protocol, a program that sets it without asking gets the
/// terminal it was given, and the same programs read ordinary keys perfectly
/// well. Plain `CSI u`, which really is a cursor restore, stays intact.
/// Window resize requests are also removed to avoid SwiftTerm's overloaded
/// enum-case trap; the app controls the geometry of embedded terminal panes.
///
/// Stateful because a sequence can be cut in half by a read boundary: a
/// partial escape is held back and completed by the next chunk, which is what
/// the emulator's own parser does with the same stream.
struct TerminalOutputFilter {
    private enum State {
        case text
        /// An `ESC` arrived and we do not know what it starts yet.
        case escape
        /// Inside `ESC [`, collecting parameters until a final byte.
        case csi
    }

    private var state: State = .text
    /// Bytes held back since the `ESC`. Emitted whole unless the sequence turns
    /// out to be the one we drop.
    private var pending: [UInt8] = []

    /// A sequence longer than this is not one of ours and is very likely not a
    /// sequence at all. Emitted rather than held, so a program printing junk
    /// cannot make output disappear.
    private static let sequenceLimit = 64

    private static let escape: UInt8 = 0x1B
    private static let bracket = UInt8(ascii: "[")
    private static let finalU = UInt8(ascii: "u")

    mutating func filter(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count + pending.count)

        for byte in input {
            switch state {
            case .text:
                if byte == Self.escape {
                    state = .escape
                    pending = [byte]
                } else {
                    out.append(byte)
                }

            case .escape:
                if byte == Self.bracket {
                    pending.append(byte)
                    state = .csi
                } else if byte == Self.escape {
                    // `ESC ESC`: the first one was not the start of anything.
                    out.append(contentsOf: pending)
                    pending = [byte]
                } else {
                    out.append(contentsOf: pending)
                    out.append(byte)
                    pending = []
                    state = .text
                }

            case .csi:
                pending.append(byte)
                if byte < 0x20 {
                    // A control character inside a sequence is executed where
                    // it appears. Hand the lot over and let the emulator do
                    // exactly what it would have done.
                    out.append(contentsOf: pending)
                    pending = []
                    state = .text
                } else if (0x40...0x7E).contains(byte) {
                    if !isKittyKeyboard(pending) && !isWindowResize(pending) {
                        out.append(contentsOf: pending)
                    }
                    pending = []
                    state = .text
                } else if pending.count >= Self.sequenceLimit {
                    out.append(contentsOf: pending)
                    pending = []
                    state = .text
                }
            }
        }
        return out
    }

    /// SwiftTerm 1.11.2's macOS window-command switch handles only the
    /// single-argument overload of resizeTo. CSI 8;rows;cols t reaches the
    /// other enum case and traps. Embedded terminals follow their pane's
    /// geometry, so applications must not resize the containing window.
    /// Keep size queries (14/16/18 t) intact.
    private func isWindowResize(_ sequence: [UInt8]) -> Bool {
        guard sequence.last == UInt8(ascii: "t"), sequence.count >= 7 else { return false }
        let body = sequence.dropFirst(2).dropLast()
        guard body.allSatisfy({ (0x30...0x39).contains($0) || $0 == 0x3B }) else { return false }
        let parts = String(decoding: body, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        return parts.count == 3 && Int(parts[0]) == 8
    }

    /// `CSI` + a private prefix + parameters + `u`.
    ///
    /// The prefix is what tells the two apart: `=` sets the kitty flags, `>`
    /// pushes them and `<` pops them, while a bare `CSI u` with no prefix is
    /// DECRC and has to keep working.
    private func isKittyKeyboard(_ sequence: [UInt8]) -> Bool {
        guard sequence.count >= 4, sequence.last == Self.finalU else { return false }
        let prefix = sequence[2]
        return (0x3C...0x3F).contains(prefix)
    }
}
