// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// A tool call on a transcript: verb, target, optional snippet, and how it ended.
///
/// Shared by automations and chat so a Read in either place is the same row.
/// Chat adds running and failure; automations leave those at their defaults
/// and keep the inspector looking as it did.
struct ToolRow: View {
    var verb: String
    var arg: String
    var snippet: [String] = []
    var time: String? = nil
    var running: Bool = false
    var failed: Bool = false
    @State private var showSnippet = false

    private var snippetIsOutput: Bool {
        snippet.contains { $0.hasPrefix("|") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Group {
                    if running {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: symbol)
                            .font(Theme.font(12, weight: .medium))
                    }
                }
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
                if running {
                    Text("Running")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.accent)
                } else if let time, !time.isEmpty {
                    Text(time)
                        .font(Theme.mono(10))
                        .foregroundStyle(.tertiary)
                }
                if !snippet.isEmpty && !running {
                    Button(showSnippet ? hideLabel : showLabel, .preview) {
                        showSnippet.toggle()
                    }
                    .buttonStyle(AccentButtonStyle(small: true))
                }
            }
            if showSnippet && !snippet.isEmpty && !running {
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
                .strokeBorder(border, lineWidth: 1)
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
        if failed { return Theme.danger }
        if running { return Theme.accent }
        switch verb {
        case "Shell", "Bash": return Theme.warning
        default: return Theme.accent
        }
    }

    private var border: Color {
        if failed { return Theme.danger.opacity(0.45) }
        if running { return Theme.accent.opacity(0.45) }
        return Theme.border
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
