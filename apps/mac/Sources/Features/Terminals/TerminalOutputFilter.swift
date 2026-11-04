// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Distribution of builds is reserved. See LICENSE for terms.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

/// Keeps embedded-pane geometry and the app's legacy input encoding policy.
///
/// SwiftTerm now supports Kitty keyboard negotiation, but our mobile key bar
/// and app event monitors still send legacy key sequences. Suppress negotiation
/// until all those input sources use the same encoder. A bare CSI u remains a
/// cursor restore. Window resize requests are ignored because pane layout owns
/// geometry; size queries and other terminal output pass through unchanged.
/// Escape sequences may span transport reads, so filtering is stateful.
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

    /// Embedded applications may query size but cannot resize the app window.
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
