// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

struct DiffView: View {
    let diff: FileDiff

    var body: some View {
        Group {
            if diff.binary {
                note(L10n.text("apple.diffview.this_is_a_binary_file_there_is_nothing_to.6573d54c"))
            } else if diff.hunks.isEmpty {
                note(diff.untracked
                     ? L10n.text("apple.diffview.this_file_is_not_tracked_yet_and_is_empty.7354c94b")
                     : L10n.text("apple.diffview.no_changes_against_head.84a982f2"))
            } else {
                DiffDocumentView(diffs: [diff], fileHeaders: false) { EmptyView() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)

    }

    private func note(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct DiffBody: View {
    let diff: FileDiff
    var minWidth: CGFloat = 0
    /// Whether the lines build lazily.
    ///
    /// True for a viewer that scrolls this on its own, where laziness is the
    /// whole point. **False inside another lazy stack**, such as a transcript
    /// row, and the reason is not the building. SwiftUI keeps a phase
    /// attribute per lazy item and re-stamps every one of them through the
    /// attribute graph on a pass, and a live sample of a stopped application
    /// put every single sample of `AG::Graph::propagate_dirty` under
    /// `LazyLayoutViewCache.updateItemPhases`. A diff card nested a second
    /// lazy layout inside an item of the first, so one transcript row became
    /// a few hundred more items to stamp, and stamping them dirtied the row
    /// that held them. A card is capped at a couple of hundred lines and
    /// costs nothing to build in full.
    var lazy = true

    @State private var rows: [DiffDocumentRow] = []
    @State private var total = 0
    @State private var extraRows = 0
    @State private var displayedRevision: UUID?
    @State private var builtLimit = 0

    init(diff: FileDiff, minWidth: CGFloat = 0, lazy: Bool = true) {
        self.diff = diff
        self.minWidth = minWidth
        self.lazy = lazy
        let page = lazy ? 2_000 : 200
        if let first = DiffRowCache.first(for: diff, limit: page) {
            _rows = State(initialValue: first.rows)
            _total = State(initialValue: first.total)
            _displayedRevision = State(initialValue: diff.renderRevision)
            _builtLimit = State(initialValue: page)
        }
    }

    private var page: Int { lazy ? 2_000 : 200 }

    var body: some View {
        stack {
            ForEach(rows) { row in DiffDocumentRowView(row: row, width: minWidth) }
            if total > rows.count {
                Button(L10n.text("apple.clientdiffdocumentview.show_more_lines"), .reveal) { extraRows += page }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .padding(Theme.Space.s)
            }
        }
        .task(id: "\(diff.renderRevision)|\(lazy)|\(extraRows)") {
            let revision = diff.renderRevision
            let current = displayedRevision == revision
            let limit = page + (current ? extraRows : 0)
            if current, builtLimit >= limit { return }
            if !current, let first = DiffRowCache.first(for: diff, limit: limit) {
                show(first, revision: revision, limit: limit)
                return
            }
            let input = diff
            let knownTotal = current ? total : nil
            let task = Task.detached(priority: .userInitiated) {
                DiffRowCache.Entry(
                    rows: DiffDocumentRow.make([input], fileHeaders: false, rowLimit: limit,
                                               maxLineCharacters: DiffDocumentRow.wrappedLineCharacterLimit),
                    total: knownTotal ?? DiffDocumentRow.count([input], fileHeaders: false,
                                                               maxLineCharacters: DiffDocumentRow.wrappedLineCharacterLimit))
            }
            let built = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            DiffRowCache.store(built, for: input, limit: limit)
            show(built, revision: revision, limit: limit)
        }
    }

    private func show(_ entry: DiffRowCache.Entry, revision: UUID, limit: Int) {
        rows = entry.rows
        total = entry.total
        builtLimit = limit
        if displayedRevision != revision {
            displayedRevision = revision
            extraRows = 0
        }
    }

    @ViewBuilder
    private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 0, content: content)
        } else {
            VStack(alignment: .leading, spacing: 0, content: content)
        }
    }
}

struct DiffRow: View {
    let line: DiffLine
    let minWidth: CGFloat
    var continuation = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            (Text(Self.column(continuation ? nil : line.oldLine) + Self.column(continuation ? nil : line.newLine) + " ")
                .foregroundStyle(.tertiary)
                + Text(marker).foregroundStyle(line.kind.tint))
                .font(Theme.mono(10))
                .fixedSize()
                .padding(.trailing, Theme.Space.s)
            Text(line.text.isEmpty ? " " : line.text)
                .font(Theme.mono(11))
                .foregroundStyle(line.kind == .context ? Color.primary : line.kind.tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, Theme.Space.m)
        }
        .frame(minWidth: minWidth, alignment: .leading)
        .background(background)
    }

    private var marker: String {
        if continuation { return "↪" }
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    private static func column(_ number: UInt32?) -> String {
        let text = number.map(String.init) ?? "·"
        return String(repeating: " ", count: max(1, 7 - text.count)) + text
    }

    private var background: Color {
        switch line.kind {
        case .added: return .green.opacity(0.12)
        case .removed: return .red.opacity(0.12)
        case .context: return .clear
        }
    }
}

struct InlineDiffView: View {
    let diff: FileDiff
    let onReview: () -> Void
    @State private var rows: [DiffDocumentRow] = []
    @State private var total = 0
    @State private var displayedRevision: UUID?

    private static let limit = 60

    init(diff: FileDiff, onReview: @escaping () -> Void) {
        self.diff = diff
        self.onReview = onReview
        if let first = DiffRowCache.first(for: diff, limit: Self.limit) {
            _rows = State(initialValue: first.rows)
            _total = State(initialValue: first.total)
            _displayedRevision = State(initialValue: diff.renderRevision)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in DiffDocumentRowView(row: row, width: 0) }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxHeight: 260)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
            if total > rows.count {
                Button(L10n.text("apple.workspacesview.review_full_diff_0_more_lines.071f50d8", "\(total - rows.count)"), .preview, action: onReview)
                    .buttonStyle(SecondaryButtonStyle(small: true))
            }
        }
        .task(id: diff.renderRevision) {
            let revision = diff.renderRevision
            guard displayedRevision != revision else { return }
            let input = diff
            let limit = Self.limit
            let built: DiffRowCache.Entry
            if let first = DiffRowCache.first(for: input, limit: limit) {
                built = first
            } else {
                let task = Task.detached(priority: .userInitiated) {
                    DiffRowCache.Entry(
                        rows: DiffDocumentRow.make([input], fileHeaders: false, rowLimit: limit,
                                                   maxLineCharacters: DiffDocumentRow.wrappedLineCharacterLimit),
                        total: DiffDocumentRow.count([input], fileHeaders: false,
                                                     maxLineCharacters: DiffDocumentRow.wrappedLineCharacterLimit))
                }
                built = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
                guard !Task.isCancelled else { return }
                DiffRowCache.store(built, for: input, limit: limit)
            }
            rows = built.rows
            total = built.total
            displayedRevision = revision
        }
    }
}

enum DiffRowCache {
    struct Entry {
        let rows: [DiffDocumentRow]
        let total: Int
    }

    private final class Held {
        let entry: Entry
        init(_ entry: Entry) { self.entry = entry }
    }

    private static let cache: NSCache<NSString, Held> = {
        let cache = NSCache<NSString, Held>()
        cache.countLimit = 64
        return cache
    }()

    static func first(for diff: FileDiff, limit: Int) -> Entry? {
        if let held = cache.object(forKey: key(diff, limit)) { return held.entry }
        guard isSmall(diff) else { return nil }
        let entry = Entry(
            rows: DiffDocumentRow.make([diff], fileHeaders: false, rowLimit: limit,
                                       maxLineCharacters: DiffDocumentRow.wrappedLineCharacterLimit),
            total: DiffDocumentRow.count([diff], fileHeaders: false,
                                         maxLineCharacters: DiffDocumentRow.wrappedLineCharacterLimit))
        store(entry, for: diff, limit: limit)
        return entry
    }

    static func store(_ entry: Entry, for diff: FileDiff, limit: Int) {
        cache.setObject(Held(entry), forKey: key(diff, limit))
    }

    private static func key(_ diff: FileDiff, _ limit: Int) -> NSString {
        "\(diff.renderRevision)|\(limit)" as NSString
    }

    private static func isSmall(_ diff: FileDiff) -> Bool {
        var lines = 0
        var bytes = 0
        for hunk in diff.hunks {
            lines += hunk.lines.count
            guard lines <= 300 else { return false }
            for line in hunk.lines { bytes += line.text.utf8.count }
            guard bytes <= 32_768 else { return false }
        }
        return true
    }
}
