// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with MuseToolPresentation.swift using swiftc -parse-as-library, then run.
import Foundation

@main
struct MuseToolPresentationTests {
    static func expect(_ verb: String, _ detail: String?, _ expectedVerb: String, _ expectedTarget: String,
                       target: String = "", backend: String? = "muse") {
        let result = MuseToolPresentation.completed(backend: backend, verb: verb, target: target, detail: detail)
        precondition(result == .init(verb: expectedVerb, target: expectedTarget), "\(verb): \(result)")
    }

    static func main() {
        let shell = #"{"command":"git status --short","description":"Check changes","output":" M file"}"#
        expect("Bash", shell, "Bash", "git status --short")
        expect("Bash Input", shell, "Bash", "git status --short")
        expect("bash_input", shell, "Bash", "git status --short")
        expect("Bash", "Check changes\n$ git status --short\n M file", "Bash", "git status --short")
        expect("Shell", "$ swift test\npassed", "Shell", "swift test")
        expect("Bash", "output\nmore output\n$ fake command", "Bash", "")
        expect("Bash", #"{"description":"Check changes","output":"$ fake command"}"#, "Bash", "")
        expect("Read", "Read text file `/tmp/a file.swift`.\ncontents", "Read", "/tmp/a file.swift")
        expect("Read", "output mentions /tmp/a file.swift", "Read", "")
        expect("Write", "wrote 23 bytes to /tmp/a file.swift\ncontents", "Write", "/tmp/a file.swift")
        expect("Write", "output\nwrote 23 bytes to /tmp/wrong.swift", "Write", "")
        expect("WebSearch", #"{"query":"Muse tool metadata","results":[{"title":"wrong query"}]}"#,
               "WebSearch", "Muse tool metadata")
        expect("WebSearch", "matches for something\nhttps://example.com", "WebSearch", "")
        expect("WebFetch", #"{"url":"https://example.com/source","links":["https://example.com/wrong"]}"#,
               "WebFetch", "https://example.com/source")
        expect("WebFetch", #"{"links":["https://example.com/wrong"]}"#, "WebFetch", "")
        let skill = #"<read-skill-result name="bundled:git" status="ok">"# + "\nskill contents"
        expect("Read Skill", skill, "Read", "bundled:git")
        expect("read_skill", skill, "Read", "bundled:git")
        expect("Read", skill, "Read", "bundled:git")
        expect("Read", #"<read-skill-result name="a&amp;b&quot;c" status="ok">"#, "Read", "a&b\"c")
        expect("Write Todos", "4 todos (revision 2)", "TodoWrite", "4 todos (revision 2)")
        expect("write_todos", "4 todos (revision 2)\nitems", "TodoWrite", "4 todos (revision 2)")
        expect("TodoWrite", "updated todos", "TodoWrite", "")
        expect("Custom Tool", shell, "Custom Tool", "")
        expect("", shell, "", "")
        expect("Bash", "{bad JSON", "Bash", "")

        // Explicit start metadata and every other provider remain authoritative.
        expect("Bash Input", shell, "Bash", "  explicit command  ", target: "  explicit command  ")
        expect("Read", skill, "Read", "/explicit/path", target: "/explicit/path")
        for backend in [nil, "codex", "grok", "claude", "Muse"] as [String?] {
            expect("Bash Input", shell, "Bash Input", "", backend: backend)
        }

        // Bound work on large logs while retaining their normalized header.
        let hugeOutput = String(repeating: "x", count: 5_000_000)
        expect("Bash", "Check changes\n$ git status\n" + hugeOutput, "Bash", "git status")
        expect("Bash", #"{"command":"git status","output":""# + hugeOutput + #""}"#, "Bash", "")
        expect("Read", "Read text file `/tmp/a`.\n" + hugeOutput, "Read", "/tmp/a")
        let unicode = #"{"command":"echo 🧪","output":"ok"}"#
        expect("Bash", unicode, "Bash", "echo 🧪")
        print("MuseToolPresentationTests passed")
    }
}
