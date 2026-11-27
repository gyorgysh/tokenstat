// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

struct TerminalOutputFilter {
    private enum State {
        case text
        case escape
        case csi
    }

    private var state: State = .text
    private var pending: [UInt8] = []

    private static let sequenceLimit = 64

    private static let escape: UInt8 = 0x1B
    private static let bracket = UInt8(ascii: "[")
    private static let finalU = UInt8(ascii: "u")

    mutating func filter(_ input: ArraySlice<UInt8>) -> [UInt8] {
        if case .text = state, !input.contains(Self.escape) { return Array(input) }
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

    private func isWindowResize(_ sequence: [UInt8]) -> Bool {
        guard sequence.last == UInt8(ascii: "t"), sequence.count >= 7 else { return false }
        let body = sequence.dropFirst(2).dropLast()
        guard body.allSatisfy({ (0x30...0x39).contains($0) || $0 == 0x3B }) else { return false }
        let parts = String(decoding: body, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        return parts.count == 3 && Int(parts[0]) == 8
    }

    private func isKittyKeyboard(_ sequence: [UInt8]) -> Bool {
        guard sequence.count >= 4, sequence.last == Self.finalU else { return false }
        let prefix = sequence[2]
        return (0x3C...0x3F).contains(prefix)
    }
}
