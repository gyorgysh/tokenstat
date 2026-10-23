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
assert(many.filter { $0.0 == "tokenstat-chart" }.count == 4, "A reply must bound its native browsers")
assert(many.dropFirst(4).allSatisfy { $0.0 == "json" }, "Excess charts use ordinary JSON code blocks")
let unfinished = code(Array(repeating: pending + "\n```", count: 4).joined(separator: "\n\n") + "\n\n" + pending)
assert(unfinished.last?.0 == "json" && unfinished.last?.1 == json)
print("Production Apple chart fences preserve streaming and complete data, with at most four interactive charts per reply")
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-chart-parser-') as directory:
    work = pathlib.Path(directory)
    (work / 'main.swift').write_text('import Foundation\n' + models + '\nenum MarkdownDigest { static func key(_ language: String?, _ text: String) -> String { text } }\n' + parser + checks)
    subprocess.run(['swiftc', '-swift-version', '5', str(work / 'main.swift'), str(root / 'apps/mac/Sources/Design/MarkdownSanitizer.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True)
