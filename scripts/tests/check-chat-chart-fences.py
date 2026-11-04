#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production Apple Markdown parser without mounting the running app."""
import pathlib
import subprocess
import tempfile
root = pathlib.Path(__file__).resolve().parents[2]
source = (root / 'apps/mac/Sources/Design/MarkdownText.swift').read_text()
models = source[source.index('private struct MarkdownBlock:'):source.index('private struct MarkdownBlockView:')]
parser = source[source.index('private struct MarkdownParser {'):source.index('/// One clipboard for both apps.')]
checks = r'''
func code(_ markdown: String) -> [(String?, String)] {
    var parser = MarkdownParser(markdown)
    return parser.blocks().compactMap { block in
        if case let .code(language, text, _, _) = block.kind { return (language, text) }
        return nil
    }
}
let json = "{\"version\":1,\"type\":\"bar\",\"title\":\"Chart\",\"categories\":[\"A\"],\"series\":[{\"name\":\"Count\",\"data\":[1]}]}"
let pending = "```tokenstat-chart\n" + json
for index in 0..<pending.count {
    let text = String(pending.prefix(index))
    assert(code(text).allSatisfy { $0.0 != "tokenstat-chart" }, "Streaming content must not render a chart")
}
assert(code(pending).first?.0 == "tokenstat-chart-pending")
assert(code(pending + "\n```").first?.0 == "tokenstat-chart")
assert(code(pending + "\n```").first?.1 == json)
assert(code("~~~tokenstat-chart\n" + json + "\n~~~").first?.0 == "tokenstat-chart")
assert(code("````tokenstat-chart\n" + json + "\n```\n").first?.0 == "tokenstat-chart-pending")
assert(code("```json\n" + json + "\n```").first?.0 == "json")
assert(code(pending + "\n```\n\nAfter\n\n" + pending + "\n```").count == 2)
let many = code(Array(repeating: pending + "\n```", count: 200).joined(separator: "\n\n"))
assert(many.count == 200 && many.allSatisfy { $0.1 == json }, "The complete JSON remains readable for every chart")
assert(many.allSatisfy { $0.0 == "tokenstat-chart" }, "Every chart stays renderable, including fences after the fourth")
let unfinished = code(Array(repeating: pending + "\n```", count: 4).joined(separator: "\n\n") + "\n\n" + pending)
assert(unfinished.last?.0 == "tokenstat-chart-pending" && unfinished.last?.1 == json)

private func blocks(_ markdown: String) -> [MarkdownBlock] {
    var parser = MarkdownParser(markdown)
    return parser.blocks()
}
let paragraph = "A plain sentence with café 日本語 👩🏽‍💻.\nAnother sentence mentioning --- and # without starting a block."
private let prose = blocks(paragraph)
assert(prose.count == 1)
if case let .paragraph(text) = prose[0].kind { assert(text == paragraph) } else { fatalError("Prose changed shape") }
for rule in ["---", "* * *", "_\t_\t_", "-\u{a0}-\u{a0}-"] {
    let parsed = blocks(rule)
    assert(parsed.count == 1)
    if case .rule = parsed[0].kind {} else { fatalError("Rule was lost: \(rule)") }
}
for notRule in ["--", "-*-", "A---", "___ text", "日本語", "-\u{301}--"] {
    assert(!blocks(notRule).contains { if case .rule = $0.kind { true } else { false } })
}
private let tasks = blocks("- [x] Done\n- [ ] Pending\n- [X] Also done\n- [x]")
if case let .list(items) = tasks[0].kind {
    assert(items.map(\.checked) == [true, false, true, nil])
    assert(items.map(\.text) == ["Done", "Pending", "Also done", "[x]"])
} else { fatalError("Task list changed shape") }
private let table = blocks("Name | Notes\n--- | ---\none | `a|b`\ntwo | a\\|b")
if case let .table(header, rows, overflow) = table[0].kind {
    assert(header == ["Name", "Notes"] && rows == [["one", "`a|b`"], ["two", "a\\|b"]] && overflow == 0)
} else { fatalError("A table without outer pipes was lost") }
for text in ["Name\\|Notes\n--- | ---", "Name `|` Notes\n--- | ---", "Name\n---"] {
    assert(!blocks(text).contains { if case .table = $0.kind { true } else { false } })
}
print("Apple Markdown: prose, rules, task lists, escaped table cells and 200 complete/streaming chart fences passed")
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-chart-parser-') as directory:
    work = pathlib.Path(directory)
    (work / 'main.swift').write_text('import Foundation\n' + models + '\nenum MarkdownDigest { static func key(_ language: String?, _ text: String) -> String { text } }\n' + parser + checks)
    subprocess.run(['swiftc', '-swift-version', '5', str(work / 'main.swift'), str(root / 'apps/mac/Sources/Design/MarkdownSanitizer.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True)
