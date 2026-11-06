#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise overlapping warm requests with the production parser and caches."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "apps/mac/Sources/Design/MarkdownText.swift").read_text()
warm = source[source.index("extension MarkdownText {"):source.index("/// Whether this markdown")]
warm = warm.replace("extension MarkdownText {", "private enum MarkdownText {", 1)
assert warm.count("guard !sources.isEmpty else { return }") == 1
assert warm.count("Task.detached(priority: .utility) {") == 1
# Observe completion without changing the worker or its scheduling.
warm = warm.replace("guard !sources.isEmpty else { return }",
                    "guard !sources.isEmpty else { return }; completed.enter()")
warm = warm.replace("Task.detached(priority: .utility) {",
                    "Task.detached(priority: .utility) { defer { completed.leave() }")
cache = source[source.index("private final class ParsedTextCache<Value>"):source.index("private enum MarkdownCache {")]
assert cache.count("let parsed = parse()") == 1
cache = cache.replace("let parsed = parse()",
                      "Probe.shared.begin(self, source); defer { Probe.shared.end() }; let parsed = parse()")
models = source[source.index("private struct MarkdownBlock:"):source.index("private struct MarkdownBlockView:")]
parser = source[source.index("private struct MarkdownParser {"):source.index("/// One clipboard for both apps.")]
digest = source[source.index("private enum MarkdownDigest {"):source.index("private actor MarkdownHighlightLimiter {")]
inline = source[source.index("private enum MarkdownInline {"):source.index("private struct InlineMarkdown:")]
links = (root / "apps/mac/Sources/Design/MarkdownLinks.swift").read_text()
links = links[links.index("enum MarkdownLinks {"):links.index("struct MarkdownLinkAttribute:")]

support = r'''
import Foundation
import SwiftUI
private let completed = DispatchGroup()
private enum Theme { static let accent = Color.purple }
// This fixture uses web links, not application navigation.
private struct SimulatorAttachRequest { init?(url: URL) { return nil } }
private struct DesktopOpenRequest { init?(url: URL) { return nil } }
private enum MarkdownCache {
    static let blocks = ParsedTextCache<[MarkdownBlock]>(limit: 3000)
    static let inline = ParsedTextCache<AttributedString>(limit: 10000)
}
private final class Probe: @unchecked Sendable {
    static let shared = Probe()
    private let lock = NSLock()
    private var parses: [ObjectIdentifier: [String: Int]] = [:]
    private var active = 0
    private var peak = 0

    func begin(_ owner: AnyObject, _ source: String) {
        precondition(!Thread.isMainThread, "Warm-up must not parse on the main thread")
        lock.lock(); defer { lock.unlock() }
        parses[ObjectIdentifier(owner), default: [:]][source, default: 0] += 1
        active += 1
        peak = max(peak, active)
    }
    func end() { lock.lock(); defer { lock.unlock() }; active -= 1 }
    func verify() {
        lock.lock(); defer { lock.unlock() }
        precondition(active == 0 && peak == 1, "Warm requests must share one parsing worker")
        precondition(!parses.isEmpty && parses.values.allSatisfy { $0.values.allSatisfy { $0 == 1 } },
                     "Overlapping requests must reuse completed block and inline parses")
    }
}
'''
checks = r'''
@main private struct WarmupTests {
    static func main() {
        let bodies = (0..<8).map { number in
            """
            # Heading \(number)

            Paragraph \(number) **bold** and [web](https://example.com/\(number)) café 日本語 👩🏽‍💻.

            > Quote \(number)

            - First \(number)
            - [x] Done \(number)

            Name \(number) | Value \(number)
            --- | ---
            Left \(number) | Right \(number)

            ```swift
            let untouched = "<tag> & text"
            ```

            ---
            """
        }
        MarkdownText.warm([])
        MarkdownText.warm(["", " \n\t "])
        for index in 0..<12 {
            MarkdownText.warm(index.isMultiple(of: 2) ? bodies : Array(bodies.reversed()))
        }
        precondition(completed.wait(timeout: .now() + 90) == .success, "Warm-up did not finish")
        Probe.shared.verify()
        for body in bodies {
            guard let blocks = MarkdownCache.blocks.stored(for: body) else {
                preconditionFailure("A requested body was skipped")
            }
            var kinds = Set<String>()
            for block in blocks {
                let texts: [String]
                switch block.kind {
                case let .heading(_, text): kinds.insert("heading"); texts = [text]
                case let .paragraph(text): kinds.insert("paragraph"); texts = [text]
                case let .quote(text): kinds.insert("quote"); texts = [text]
                case let .list(items): kinds.insert("list"); texts = items.map(\.text)
                case let .table(header, rows, _): kinds.insert("table"); texts = header + rows.flatMap { $0 }
                case .code: kinds.insert("code"); texts = []
                case .rule: kinds.insert("rule"); texts = []
                }
                for text in texts {
                    precondition(MarkdownCache.inline.stored(for: text) != nil,
                                 "Every supported inline body must be warmed")
                }
            }
            precondition(kinds == ["heading", "paragraph", "quote", "list", "table", "code", "rule"])
        }
        precondition(MarkdownCache.blocks.stored(for: " \n\t ") == nil)
        print("Markdown warm-up: overlapping requests reuse off-main parses; all block kinds retained")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="tokenstat-markdown-warmup-") as directory:
    work = Path(directory)
    swift = work / "Warmup.swift"
    swift.write_text(support + cache + models + digest + parser + links + inline + warm + checks)
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(swift),
                    str(root / "apps/mac/Sources/Design/MarkdownSanitizer.swift"),
                    "-o", str(work / "test")], check=True)
    subprocess.run([str(work / "test")], check=True)
