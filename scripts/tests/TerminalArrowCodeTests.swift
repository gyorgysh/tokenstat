// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientTerminalKeys.swift.
import Foundation

@main enum TerminalArrowCodeTests {
    static func main() {
        func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }
        precondition(text(TerminalArrowCode.encode(0x44)) == "\u{1B}[D")
        precondition(text(TerminalArrowCode.encode(0x43, applicationCursor: true)) == "\u{1B}OC")
        precondition(text(TerminalArrowCode.encode(0x44, shift: true)) == "\u{1B}[1;2D")
        precondition(text(TerminalArrowCode.encode(0x44, shift: true, applicationCursor: true)) == "\u{1B}[1;2D")
        precondition(text(TerminalArrowCode.encode(0x41, control: true)) == "\u{1B}[1;5A")
        precondition(text(TerminalArrowCode.encode(0x42, shift: true, control: true)) == "\u{1B}[1;6B")
        precondition(text(TerminalArrowCode.encode(0x43, shift: true, option: true)) == "\u{1B}[1;4C")
        precondition(text(TerminalArrowCode.encode(0x44, shift: true, option: true, control: true)) == "\u{1B}[1;8D")
        precondition(TerminalControlCode.fold(0x63) == 3)
        print("Terminal cursor keys: application mode and Shift/Option/Control modifier bytes passed")
    }
}
