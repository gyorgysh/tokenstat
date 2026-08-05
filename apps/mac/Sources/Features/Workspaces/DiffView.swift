// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// One file's changes, in the centre pane beside the terminals.
///
/// Unified rather than side by side, with both gutters shown. Side by side
/// wastes half the width on a pane that is already sharing the window with a
/// sidebar, a terminal and an inspector, and the two line numbers carry the
/// same information a split would.
struct DiffView: View {
    let diff: FileDiff

    /// Width of the pane, so a row can be at least that wide.
    ///
    /// Inside a horizontally scrolling container `maxWidth: .infinity` means
    /// *unbounded*, not "fill the pane", so rows grow to an enormous width and
    /// the content ends up somewhere off to the side. The pane has to be
    /// measured and used as a minimum instead.
    @State private var paneWidth: CGFloat = 0

    var body: some View {
        Group {
            if diff.binary {
                note("This is a binary file. There is nothing to show line by line.")
            } else if diff.hunks.isEmpty {
                note(diff.untracked
                     ? "This file is not tracked yet and is empty."
                     : "No changes against HEAD.")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    DiffBody(diff: diff, minWidth: paneWidth)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .background(
            GeometryReader { proxy in
                Color.clear
                    // Quantised, because `minWidth` relays every row in the
                    // diff and a drag otherwise delivers a new width, and so a
                    // full relayout, on every frame.
                    .onAppear { paneWidth = quantised(proxy.size.width, step: 8) }
                    .onChange(of: quantised(proxy.size.width, step: 8)) { _, new in
                        paneWidth = new
                    }
            }
        )
    }

    private func note(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// The hunks and lines of one diff, without any scrolling of its own.
///
/// Shared by the file viewer, which scrolls it, and by the commit view, which
/// stacks several of them inside one scroll view. A commit's files scrolling
/// independently of each other would be a strange way to read a change.
struct DiffBody: View {
    let diff: FileDiff
    /// At least this wide, so a tint spans the pane rather than stopping at the
    /// last character. Zero is fine: rows then size to their content.
    var minWidth: CGFloat = 0

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(diff.hunks) { hunk in
                Text(hunk.header)
                    .font(Theme.mono(11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, 4)
                    .frame(minWidth: minWidth, alignment: .leading)
                    .background(Theme.panel)
                ForEach(hunk.lines) { line in
                    DiffRow(line: line, minWidth: minWidth)
                }
            }
        }
    }
}

/// One line, with the line number each side would show.
///
/// A dash where a number does not exist, not a blank: on an added line there is
/// no old number, and leaving the column empty reads as a number that failed to
/// load rather than one that does not apply.
private struct DiffRow: View {
    let line: DiffLine
    /// At least the pane's width, so the tint behind a short line still spans
    /// the pane instead of stopping at the last character.
    let minWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(line.oldLine)
            gutter(line.newLine)
            Text(marker)
                .font(Theme.mono(11))
                .foregroundStyle(line.kind.tint)
                .frame(width: 14, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .font(Theme.mono(11))
                .foregroundStyle(line.kind == .context ? Color.primary : line.kind.tint)
                .textSelection(.enabled)
                // Never wrap: a wrapped line breaks the alignment with its
                // gutter, and long lines are what the horizontal scroll is for.
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, Theme.Space.m)
        }
        .frame(minWidth: minWidth, alignment: .leading)
        .background(background)
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    private func gutter(_ number: UInt32?) -> some View {
        Text(number.map(String.init) ?? "·")
            .font(Theme.numeric(10))
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, Theme.Space.xs)
    }

    private var background: Color {
        switch line.kind {
        case .added: return .green.opacity(0.12)
        case .removed: return .red.opacity(0.12)
        case .context: return .clear
        }
    }
}
