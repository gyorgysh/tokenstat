// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// A run transcript as a timeline: tool rows, then prose, then a short edit
/// preview. The host already flattened NDJSON into paragraphs. This view
/// only splits that text.
struct TranscriptView: View {
    var text: String
    /// Shown when `text` is empty (waiting, or nothing readable).
    var empty: String

    var body: some View {
        let blocks = Self.parse(text.isEmpty ? empty : text)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let body):
                    Text(body)
                        .font(Theme.mono(11))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .tool(let verb, let arg, let snippet, let time):
                    ToolRow(verb: verb, arg: arg, snippet: snippet, time: time)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block {
        case text(String)
        case tool(verb: String, arg: String, snippet: [String], time: String?)
    }

    /// Verbs the host writes as the first token of a tool paragraph.
    private static let verbs: Set<String> = [
        "Read", "Write", "Edit", "Shell", "Grep", "Glob", "Find", "Search",
        "Bash", "Task", "Subagent", "NotebookEdit", "WebFetch", "WebSearch",
        "TodoWrite",
    ]

    static func parse(_ raw: String) -> [Block] {
        if raw.isEmpty { return [] }
        var out: [Block] = []
        for para in raw.components(separatedBy: "\n\n") {
            let trimmed = para.trimmingCharacters(in: .newlines)
            if trimmed.isEmpty { continue }
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let first = lines.first, let tool = toolLine(first) else {
                out.append(.text(trimmed))
                continue
            }
            var snippet: [String] = []
            var rest: [String] = []
            var inSnippet = true
            for line in lines.dropFirst() {
                if inSnippet && isSnippetLine(line) {
                    snippet.append(line)
                } else {
                    inSnippet = false
                    rest.append(line)
                }
            }
            out.append(.tool(verb: tool.verb, arg: tool.arg, snippet: snippet, time: tool.time))
            if !rest.isEmpty {
                out.append(.text(rest.joined(separator: "\n")))
            }
        }
        return out
    }

    private static func toolLine(_ line: String) -> (time: String?, verb: String, arg: String)? {
        var rest = line
        var time: String?
        if let split = clockPrefix(rest) {
            time = split.time
            rest = split.rest
        }
        let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        let verb = String(first)
        guard verbs.contains(verb) else { return nil }
        let arg = parts.count > 1 ? String(parts[1]) : ""
        // A sentence that happens to start with "Read" stays prose.
        if arg.contains(". ") || arg.contains("? ") { return nil }
        return (time, verb, arg)
    }

    /// `17:29:15 Bash ls` from the host. Optional. Prose never starts this way.
    private static func clockPrefix(_ line: String) -> (time: String, rest: String)? {
        let chars = Array(line)
        guard chars.count >= 8 else { return nil }
        let digits: (Character) -> Bool = { $0.isNumber }
        guard digits(chars[0]), digits(chars[1]), chars[2] == ":",
              digits(chars[3]), digits(chars[4]), chars[5] == ":",
              digits(chars[6]), digits(chars[7])
        else { return nil }
        let time = String(chars[0...7])
        var idx = 8
        if idx < chars.count && chars[idx] == " " { idx += 1 }
        return (time, String(chars[idx...]))
    }

    private static func isSnippetLine(_ line: String) -> Bool {
        line.hasPrefix("+ ") || line.hasPrefix("- ")
            || line.hasPrefix("+ …") || line.hasPrefix("- …")
            || line.hasPrefix("| ") || line.hasPrefix("| …")
    }
}

private struct ToolRow: View {
    var verb: String
    var arg: String
    var snippet: [String]
    var time: String?
    @State private var showSnippet = false

    private var snippetIsOutput: Bool {
        snippet.contains { $0.hasPrefix("|") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: symbol)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(verb)
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(tint)
                if !arg.isEmpty {
                    Text(arg)
                        .font(Theme.mono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if let time, !time.isEmpty {
                    Text(time)
                        .font(Theme.mono(10))
                        .foregroundStyle(.tertiary)
                }
                if !snippet.isEmpty {
                    Button(showSnippet ? hideLabel : showLabel, .preview) {
                        showSnippet.toggle()
                    }
                    .buttonStyle(AccentButtonStyle(small: true))
                }
            }
            if showSnippet && !snippet.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(snippet.enumerated()), id: \.offset) { _, line in
                        Text(displaySnippet(line))
                            .font(Theme.mono(11))
                            .foregroundStyle(snippetColor(line))
                    }
                }
                .textSelection(.enabled)
                .padding(Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private var symbol: String {
        switch verb {
        case "Read": return "book"
        case "Write": return "pencil"
        case "Edit", "NotebookEdit": return "square.and.pencil"
        case "Shell", "Bash": return "terminal"
        case "Grep", "Search": return "magnifyingglass"
        case "Glob", "Find": return "folder"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Subagent": return "person.2"
        case "TodoWrite": return "checklist"
        default: return "wrench"
        }
    }

    private var tint: Color {
        switch verb {
        case "Shell", "Bash": return Theme.warning
        default: return Theme.accent
        }
    }

    private var showLabel: String { snippetIsOutput ? "Show output" : "Show edit" }
    private var hideLabel: String { snippetIsOutput ? "Hide output" : "Hide edit" }

    private func displaySnippet(_ line: String) -> String {
        if line.hasPrefix("| ") { return String(line.dropFirst(2)) }
        if line == "| …" { return "…" }
        return line
    }

    private func snippetColor(_ line: String) -> Color {
        if line.hasPrefix("+") { return Theme.diffAdded }
        if line.hasPrefix("-") { return Theme.diffRemoved }
        return .secondary
    }
}
