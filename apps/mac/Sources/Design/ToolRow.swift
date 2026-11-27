// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct ToolRow: View {
    #if os(macOS)
    private static let diffFigure = Theme.mono(11, weight: .medium)
    #else
    private static let diffFigure = ClientType.diffFigure
    #endif

    var verb: String
    var arg: String
    var snippet: [String] = []
    var time: String? = nil
    var running: Bool = false
    var failed: Bool = false
    var animatesRunning: Bool = true
    var expandsOutput: Bool = false
    var compact: Bool = false
    var onToggleOutput: () -> Void = {}
    @State private var showSnippet = false
    @State private var snippetToggled = false

    private var usesCompactStyle: Bool { compact }

    private var snippetIsOutput: Bool {
        snippet.contains { $0.hasPrefix("|") }
    }

    private var hasDiff: Bool {
        ["Edit", "NotebookEdit", "Diff"].contains(verb) && diffAdded + diffRemoved > 0
    }

    private var diffAdded: Int {
        snippet.filter { Self.isDiffLine($0, added: true) }.count
    }

    private var diffRemoved: Int {
        snippet.filter { Self.isDiffLine($0, added: false) }.count
    }

    private static func isDiffLine(_ line: String, added: Bool) -> Bool {
        guard let first = line.first else { return false }
        let want: Character = added ? "+" : "-"
        guard first == want else { return false }
        return !(line.hasPrefix("+++ ") || line.hasPrefix("--- "))
    }

    private static let autoExpandLines = 10

    private func autoExpand() {
        guard !snippetToggled, !running else { return }
        if expandsOutput, !snippet.isEmpty {
            showSnippet = true
        } else if !usesCompactStyle, hasDiff, snippet.count <= Self.autoExpandLines {
            showSnippet = true
        } else if !expandsOutput {
            showSnippet = false
        }
    }

    private var preview: String? {
        guard !hasDiff else { return nil }
        for line in snippet {
            let text = Self.displaySnippet(line).trimmingCharacters(in: .whitespacesAndNewlines)
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
                    if running, animatesRunning {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: failed ? "xmark.circle" : symbol)
                            .font(Theme.font(12, weight: .medium))
                    }
                }
                .foregroundStyle(failed ? Theme.danger : tint)
                .frame(width: 16)

                Text(SeatStep.word(verb: verb, running: running))
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !arg.isEmpty {
                    Text(arg)
                        .font(Theme.mono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(usesCompactStyle ? 1 : 2)
                        .truncationMode(.middle)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .help(arg)
                } else {
                    Spacer(minLength: 0)
                }
                if hasDiff, !running {
                    DiffStat(added: diffAdded, removed: diffRemoved, font: Self.diffFigure)
                }
                if running, !SeatStep.speaks(verb: verb) {
                    Text(L10n.text("common.running"))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.accent)
                        .fixedSize()
                } else if failed {
                    Text(L10n.text("common.failed"))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.danger)
                        .fixedSize()
                }
                if !running, let time, !time.isEmpty {
                    Text(time)
                        .font(Theme.mono(10))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                if !snippet.isEmpty && !running {
                    outputToggle.fixedSize()
                }
            }
            if !usesCompactStyle, !showSnippet, !running, let preview {
                Text(preview)
                    .font(Theme.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            if showSnippet && !snippet.isEmpty && !running {
                Group {
                    if snippet.count > 12 || snippet.contains(where: { $0.count > 1000 }) {
                        ScrollView(.vertical) { snippetContent }
                            .frame(height: 260)
                    } else {
                        snippetContent
                    }
                }
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .onAppear {
            autoExpand()
        }
        .onChange(of: snippet.count) { _, _ in autoExpand() }
        .onChange(of: running) { _, _ in autoExpand() }
        .onChange(of: expandsOutput) { _, _ in autoExpand() }
        .onChange(of: compact) { _, _ in autoExpand() }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, usesCompactStyle ? 4 : Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(usesCompactStyle ? Color.clear : Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(usesCompactStyle ? Color.clear : border, lineWidth: 1)
        )
    }

    private var snippetContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(snippet.enumerated()), id: \.offset) { _, line in
                Text(Self.displaySnippet(line))
                    .font(Theme.mono(11))
                    .foregroundStyle(Self.snippetColor(line))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var outputToggle: some View {
        if usesCompactStyle {
            Button(action: toggleSnippet) {
                Image(systemName: showSnippet ? "chevron.up" : "chevron.down")
                    .font(Theme.font(11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    #if os(macOS)
                    .frame(width: 22, height: 22)
                    #else
                    .frame(width: 44, height: 44)
                    #endif
                    .contentShape(.rect)
            }
            .buttonStyle(ControlFeedbackStyle(pressScale: 0.9))
            .help(showSnippet ? hideLabel : showLabel)
            .accessibilityLabel(showSnippet ? hideLabel : showLabel)
        } else {
            Button(showSnippet ? hideLabel : showLabel, .preview, action: toggleSnippet)
                .buttonStyle(AccentButtonStyle(small: true))
        }
    }

    private func toggleSnippet() {
        onToggleOutput()
        snippetToggled = true
        showSnippet.toggle()
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
        if failed { return Color.secondary }
        if running { return Theme.accent }
        switch verb {
        case "Shell", "Bash": return Theme.warning
        default: return Theme.accent
        }
    }

    private var border: Color {
        if running { return Theme.accent.opacity(0.45) }
        return Theme.border
    }

    private var showLabel: String { hasDiff ? L10n.text("apple.toolrow.show_edit.8da806e1") : snippetIsOutput ? L10n.text("apple.toolrow.show_output.9dbbb249") : L10n.text("apple.toolrow.show_edit.8da806e1") }
    private var hideLabel: String { hasDiff ? L10n.text("apple.toolrow.hide_edit.e9dbd4f5") : snippetIsOutput ? L10n.text("apple.toolrow.hide_output.64876c47") : L10n.text("apple.toolrow.hide_edit.e9dbd4f5") }

    static func displaySnippet(_ line: String) -> String {
        if line.hasPrefix("| ") { return String(line.dropFirst(2)) }
        if line == "| …" { return "…" }
        return line
    }

    static func snippetColor(_ line: String) -> Color {
        if Self.isDiffLine(line, added: true) { return Theme.diffAdded }
        if Self.isDiffLine(line, added: false) { return Theme.diffRemoved }
        return .secondary
    }
}

struct DiffStat: View {
    var added: Int
    var removed: Int
    var font: Font

    var body: some View {
        HStack(spacing: 4) {
            if added > 0 || removed == 0 {
                Text("+\(added)")
                    .foregroundStyle(Theme.diffAdded)
            }
            if removed > 0 {
                Text("−\(removed)")
                    .foregroundStyle(Theme.diffRemoved)
            }
        }
        .font(font)
        .monospacedDigit()
        .fixedSize()
        .accessibilityLabel(L10n.text("apple.toolrow.0_added_1_removed.b84e338d", "\(added)", "\(removed)"))
    }
}
