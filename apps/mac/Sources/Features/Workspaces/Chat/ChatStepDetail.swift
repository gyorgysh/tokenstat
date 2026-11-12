// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// What one step produced, below its open Compact line.
///
/// The line above already says what the step was, so this draws no card, no
/// second header and no show button: the full command or path, then the
/// output or the diff, in the transcript's own quiet type. Shared by the Mac
/// and the phone.
struct ChatStepDetail: View {
    enum Step: Equatable {
        case tool(ChatToolState)
        case edit(ChatEditState)
    }

    let step: Step

    private static let font = Theme.mono(11)
    private static let lineCap = 200

    @State private var diff: AttributedString?
    @State private var diffCut = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let subject, !subject.isEmpty {
                Text(subject)
                    .foregroundStyle(.tertiary)
                    .lineLimit(6)
                    .truncationMode(.middle)
            }
            switch step {
            case let .tool(state):
                if state.snippet.isEmpty {
                    note(state.running ? L10n.text("common.running") : L10n.text("apple.chatstepdetail.no_output"))
                } else {
                    if state.snippet.count > 12 || state.snippet.contains(where: { $0.count > 1000 }) {
                        ScrollView(.vertical) { toolLines(state.snippet) }
                            .frame(height: 260)
                    } else {
                        toolLines(state.snippet)
                    }
                }
            case let .edit(state):
                if let diff {
                    Text(diff)
                    if diffCut > 0 {
                        note(L10n.text("apple.chatfileeditrow.0_more_lines.c352841d", "\(diffCut)"))
                    }
                } else if state.patch.isEmpty {
                    note(state.running ? L10n.text("common.running") : L10n.text("apple.chatstepdetail.no_diff"))
                }
            }
        }
        .font(Self.font)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
        .padding(.horizontal, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: render)
        .onChange(of: patch) { _, _ in render() }
    }

    private func toolLines(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(ToolRow.displaySnippet(line))
                    .foregroundStyle(ToolRow.snippetColor(line))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The whole command or path. The line above shortens both.
    private var subject: String? {
        switch step {
        case let .tool(state): state.target
        case let .edit(state): state.path
        }
    }

    private var patch: String {
        if case let .edit(state) = step { return state.patch }
        return ""
    }

    private func note(_ text: String) -> some View {
        Text(text).foregroundStyle(.tertiary)
    }

    /// Colouring a patch walks every line, so it runs when the patch
    /// changes rather than on every pass of the transcript.
    private func render() {
        guard !patch.isEmpty else {
            diff = nil
            diffCut = 0
            return
        }
        let rendered = diffColoredText(patch, lineLimit: Self.lineCap)
        diff = rendered.text
        diffCut = rendered.cut
    }
}
