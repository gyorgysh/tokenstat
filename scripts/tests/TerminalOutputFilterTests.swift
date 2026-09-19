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
#if canImport(SwiftTerm) && os(macOS)
        _ = NSApplication.shared
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        var nativeFilter = TerminalOutputFilter()
        for byte in input { view.feed(byteArray: nativeFilter.filter([byte][...])[...]) }
        precondition(view.getTerminal().rows > 5)
#endif
        print("PASS: terminal resize crash sequence blocked across every chunk boundary; colors and queries preserved")
    }
}
