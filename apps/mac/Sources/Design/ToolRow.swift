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
    /// Set once the person toggles the snippet by hand. Auto-expand must
    /// not overrule it: lazy rows re-run `onAppear` scrolling back, and a
    /// diff that streams in after appear must still open on its own.
    @State private var snippetToggled = false

    private var snippetIsOutput: Bool {
        snippet.contains { $0.hasPrefix("|") }
    }

    /// Red/green lines the host attached to an edit's end event.
    private var hasDiff: Bool {
        ["Edit", "NotebookEdit", "Diff"].contains(verb) && diffAdded + diffRemoved > 0
    }

    private var diffAdded: Int {
        snippet.filter { Self.isDiffLine($0, added: true) }.count
    }

    private var diffRemoved: Int {
        snippet.filter { Self.isDiffLine($0, added: false) }.count
    }

    /// A unified or old/new body line. File headers ("+++ b/…") stay out.
    private static func isDiffLine(_ line: String, added: Bool) -> Bool {
        guard let first = line.first else { return false }
        let want: Character = added ? "+" : "-"
        guard first == want else { return false }
        return !(line.hasPrefix("+++ ") || line.hasPrefix("--- "))
    }

    /// Few-line edits open on their own; anything bigger stays a stat with
    /// the full diff one tap away.
    private static let autoExpandLines = 10

    /// Open a small diff on arrival. Never overrules a hand toggle, and runs
    /// on changes as well as appear: the diff only arrives in the end event,
    /// after appear, and lazy rows re-appear on every scroll back.
    private func autoExpand() {
        // A two-line change reads better open. A hundred-line one stays
        // shut behind its stat until asked.
        if !snippetToggled, hasDiff, !running, snippet.count <= Self.autoExpandLines {
            showSnippet = true
        }
    }

    /// One line shown while collapsed so a row is never just "Tool".
    /// The header already shows the target (command/path); this is the
    /// first output line beneath it. Diffs skip this: their +/− stat lives
    /// in the header instead.
    private var preview: String? {
        guard !hasDiff else { return nil }
        for line in snippet {
            let text = displaySnippet(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != "…" { return String(text.prefix(160)) }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            // Centre, not `.firstTextBaseline`. A stack with an explicit
            // alignment cannot resolve it from sizes: it asks every child for
            // a baseline guide, and a child that is itself a stack has to
            // place all of *its* children to answer, which recurses through
            // the whole nest. In a transcript row that runs on every measuring
            // pass the lazy stack makes, and a live sample of a stopped
            // application had `ViewLayoutEngine.explicitAlignment` as its
            // hottest frame by a distance. Centring is read off the size.
            HStack(alignment: .center, spacing: Theme.Space.s) {
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
                if hasDiff, !running {
                    Text("+\(diffAdded)")
                        .font(Theme.mono(11, weight: .medium))
                        .foregroundStyle(Theme.diffAdded)
                    Text("−\(diffRemoved)")
                        .font(Theme.mono(11, weight: .medium))
                        .foregroundStyle(Theme.diffRemoved)
                }
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
                        snippetToggled = true
                        showSnippet.toggle()
                    }
                    .buttonStyle(AccentButtonStyle(small: true))
                }
            }
            // Collapsed but with something to show: a shell command's first
            // output line, an edit's +/- line. Without this a target-less
            // row is just "Tool" + a button and reads as empty space.
            if !showSnippet, !running, let preview {
                Text(preview)
                    .font(Theme.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
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
        .onAppear {
            autoExpand()
        }
        .onChange(of: snippet.count) { _, _ in autoExpand() }
        .onChange(of: running) { _, _ in autoExpand() }
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
        case "Diff": return "arrow.left.arrow.right"
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

    private var showLabel: String { hasDiff ? "Show edit" : snippetIsOutput ? "Show output" : "Show edit" }
    private var hideLabel: String { hasDiff ? "Hide edit" : snippetIsOutput ? "Hide output" : "Hide edit" }

    private func displaySnippet(_ line: String) -> String {
        if line.hasPrefix("| ") { return String(line.dropFirst(2)) }
        if line == "| …" { return "…" }
        return line
    }

    private func snippetColor(_ line: String) -> Color {
        if Self.isDiffLine(line, added: true) { return Theme.diffAdded }
        if Self.isDiffLine(line, added: false) { return Theme.diffRemoved }
        return .secondary
    }
}
