// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TerminalOutputFilter.swift.
import Foundation
#if canImport(SwiftTerm) && os(macOS)
import AppKit
import SwiftTerm
#endif

@main struct TerminalOutputFilterTests {
    @MainActor static func main() {
        let input = Array("before\u{1b}[8;5;108tafter\u{1b}[31mred\u{1b}[0m\u{1b}[18t\u{1b}[16t\u{1b}[14;2t\u{1b}[=1;1u\u{1b}[u".utf8)
        let expected = Array("beforeafter\u{1b}[31mred\u{1b}[0m\u{1b}[18t\u{1b}[16t\u{1b}[14;2t\u{1b}[u".utf8)
        for split in 0...input.count {
            var filter = TerminalOutputFilter()
            let output = filter.filter(input[..<split]) + filter.filter(input[split...])
            precondition(output == expected, "Chunk boundary \(split) altered output")
        }
        var filter = TerminalOutputFilter()
        let output = input.flatMap { filter.filter([$0][...]) }
        precondition(output == expected)

        // Control bytes, UTF-8 and commands outside this filter's policy keep
        // their bytes across transport boundaries. Slices need not start at 0.
        let unchanged = [
            "plain log\r\nnext line\t🙂 e\u{301}",
            "\u{0}\u{7}\u{8}\u{D}\u{A}",
            "\u{1b}]0;window title\u{7}\u{1b}[?25ltext\u{1b}[?25h",
            "\u{1b}[u\u{1b}[1u\u{1b}[18t\u{1b}[8;5t\u{1b}[8;5;108;2t",
            "\u{1b}\u{1b}Z\u{1b}[12\nmore",
            "\u{1b}[" + String(repeating: "1", count: 80) + "mtext",
        ]
        for text in unchanged {
            let bytes = Array(text.utf8)
            for split in 0...bytes.count {
                var passThrough = TerminalOutputFilter()
                precondition(passThrough.filter(bytes[..<split]) + passThrough.filter(bytes[split...]) == bytes)
            }
            var bytewise = TerminalOutputFilter()
            precondition(bytes.flatMap { bytewise.filter([$0][...]) } == bytes)
            var sliced = TerminalOutputFilter()
            let padded = [UInt8(0x1B)] + bytes + [0x1B]
            precondition(sliced.filter(padded[1..<(padded.count - 1)]) == bytes)
        }
        var pending = TerminalOutputFilter()
        precondition(pending.filter(Array("prefix\u{1b}".utf8)[...]) == Array("prefix".utf8))
        precondition(pending.filter([][...]).isEmpty)
        precondition(pending.filter(Array("[8;".utf8)[...]).isEmpty)
        precondition(pending.filter(Array("5;108tafter".utf8)[...]) == Array("after".utf8))
        for command in ["\u{1b}[=1u", "\u{1b}[>1;1u", "\u{1b}[<u", "\u{1b}[?u"] {
            var keyboard = TerminalOutputFilter()
            precondition(Array(command.utf8).flatMap { keyboard.filter([$0][...]) }.isEmpty)
            precondition(keyboard.filter(Array("normal text".utf8)[...]) == Array("normal text".utf8))
        }
#if canImport(SwiftTerm) && os(macOS)
        _ = NSApplication.shared
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        var nativeFilter = TerminalOutputFilter()
        for byte in input { view.feed(byteArray: nativeFilter.filter([byte][...])[...]) }
        precondition(view.terminalDimensions.rows > 5)
#endif
        print("PASS: terminal filtering preserves plain/UTF-8/control bytes and split escapes; resize and keyboard negotiation remain blocked")
    }
}
