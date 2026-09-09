// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// One file the agent changed, named after the file rather than after the tool.
///
/// A search-replace used to draw twice: a generic Edit tool row and a second
/// card with the same patch. This is the one card. The basename leads, a later
/// change of the same file in the same turn is numbered, and the full path
/// stays a caption so two edits of WORKLOG.md cannot be mistaken for twins.
struct ChatFileEditRow: View {
    let state: ChatEditState
    /// Whether this row carries the transcript's spinner. See
    /// `TranscriptFollow.spinningRow`: one animating platform view per
    /// transcript, whatever the timeline says is still running.
    var animatesRunning: Bool = true
    #if os(macOS)
    private static let nameFont = Theme.callout.weight(.semibold)
    private static let metaFont = Theme.mono(11)
    private static let diffFont = Theme.mono(11, weight: .medium)
    private static let bodyFont = Theme.mono(11)
    #else
    private static let nameFont = ClientType.label.weight(.semibold)
    private static let metaFont = ClientType.caption
    private static let diffFont = ClientType.diffFigure
    private static let bodyFont = Theme.mono(11)
    #endif

    @State private var expanded = false
    @State private var toggled = false
    @State private var shownText: AttributedString?
    @State private var shownCut = 0

    private static let lineCap = 200
    private static let autoExpandLines = 10

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Capsule()
                .fill(bar)
                .frame(width: 3)
                .padding(.vertical, 6)
                .padding(.leading, 8)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                header
                if let meta, !meta.isEmpty {
                    Text(meta)
                        .font(Self.metaFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if expanded, let shownText {
                    Text(shownText)
                        .font(Self.bodyFont)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.s)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    if shownCut > 0 {
                        Text("… \(shownCut) more lines")
                            .font(Self.bodyFont)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, Theme.Space.s)
            .padding(.horizontal, Theme.Space.s)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        }
        .onAppear { autoExpand() }
        .onChange(of: state.patch) { _, _ in
            if expanded { parse() } else { shownText = nil }
            autoExpand()
        }
        .onChange(of: state.running) { _, _ in autoExpand() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Group {
                if state.running, animatesRunning {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "doc.text")
                        .font(Theme.font(12, weight: .medium))
                }
            }
            .foregroundStyle(tint)
            .frame(width: 16)

            Text(state.fileName)
                .font(Self.nameFont)
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Spacer(minLength: 0)

            if state.added + state.removed > 0, !state.running {
                DiffStat(added: Int(state.added), removed: Int(state.removed), font: Self.diffFont)
            }
            if state.running {
                Text("Writing")
                    .font(Self.metaFont)
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
            } else if let time = state.duration, !time.isEmpty {
                Text(time)
                    .font(Self.metaFont)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            if !state.patch.isEmpty && !state.running {
                Button(expanded ? "Hide changes" : "Show changes", .preview) {
                    toggled = true
                    if expanded {
                        shownText = nil
                    } else {
                        parse()
                    }
                    expanded.toggle()
                }
                #if os(macOS)
                .buttonStyle(AccentButtonStyle(small: true))
                #else
                .clientGlassStyle()
                .controlSize(.small)
                #endif
                .fixedSize()
            }
        }
    }

    private var meta: String? {
        var parts: [String] = []
        if let label = state.changeLabel {
            parts.append(label)
        }
        if !state.location.isEmpty {
            parts.append(state.location)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibility: String {
        var parts = [state.fileName]
        if let label = state.changeLabel { parts.append(label) }
        if state.added + state.removed > 0 {
            parts.append("\(state.added) added, \(state.removed) removed")
        }
        if state.running { parts.append("writing") }
        if state.failed { parts.append("failed") }
        return parts.joined(separator: ", ")
    }

    private var tint: Color {
        if state.failed { return Theme.danger }
        if state.running { return Theme.accent }
        return Theme.accent
    }

    private var bar: Color {
        if state.failed { return Theme.danger }
        // Finished reads accent like its header: the bar marks the card, and
        // the added/removed meaning already lives in the patch lines and the
        // stat, which keep their diff colours.
        return Theme.accent
    }

    private var border: Color {
        if state.failed { return Theme.danger.opacity(0.45) }
        if state.running { return Theme.accent.opacity(0.45) }
        return Theme.border
    }

    private func parse() {
        let rendered = diffColoredText(state.patch, lineLimit: Self.lineCap)
        shownText = rendered.text
        shownCut = rendered.cut
    }

    private func autoExpand() {
        guard !toggled, !state.running, !state.patch.isEmpty else { return }
        let lines = state.patch.split(separator: "\n", omittingEmptySubsequences: false).count
        if lines > 0, lines <= Self.autoExpandLines {
            if shownText == nil { parse() }
            expanded = true
        }
    }
}
