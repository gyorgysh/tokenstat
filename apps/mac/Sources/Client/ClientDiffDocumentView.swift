// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

/// Fixed metadata sits outside a vertical-only, width-bounded code pane.
/// Long source lines wrap and retain their source number; oversized lines are
/// split into bounded lazy items so a minified file cannot monopolize layout.
struct ClientDiffDocumentView<Header: View>: View {
    let diffs: [FileDiff]
    let revision: UUID
    var fileHeaders = true
    var bottomInset: CGFloat = 96
    @ViewBuilder var header: () -> Header

    @State private var rows: [DiffDocumentRow] = []
    @State private var rowLimit = 2_000
    @State private var totalRows = 0
    @State private var preparing = true
    @State private var displayedRevision: UUID?

    var body: some View {
        GeometryReader { geometry in
            let paneWidth = max(0, geometry.size.width - Theme.Space.m * 2)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: Theme.Space.s) { header() }
                    .frame(width: paneWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row, width: paneWidth)
                        }
                    }
                    .frame(width: paneWidth, alignment: .leading)
                    .padding(.bottom, Theme.Space.s)
                }
                .defaultScrollAnchor(.top)
                .id(revision)
                .frame(width: paneWidth)
                .overlay {
                    if preparing && rows.isEmpty { ProgressView() }
                }
                if totalRows > rowLimit {
                    Button(L10n.text("apple.clientdiffdocumentview.show_more_lines"), .reveal) {
                        rowLimit += 2_000
                    }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true))
                    .disabled(preparing)
                    .frame(width: paneWidth)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, bottomInset)
        }
        .task(id: Request(revision: revision, rowLimit: rowLimit, fileHeaders: fileHeaders)) {
            if displayedRevision != revision {
                rows = []
                rowLimit = 2_000
                totalRows = 0
                displayedRevision = revision
            }
            preparing = true
            let input = diffs
            let headers = fileHeaders
            let limit = rowLimit
            let task = Task.detached(priority: .userInitiated) {
                let rows = DiffDocumentRow.make(input, fileHeaders: headers, rowLimit: limit,
                                                maxLineCharacters: DiffDocumentRow.wrappedLineCharacterLimit)
                guard !Task.isCancelled else { return Prepared(rows: [], total: 0) }
                let total = DiffDocumentRow.count(input, fileHeaders: headers,
                                                 maxLineCharacters: DiffDocumentRow.wrappedLineCharacterLimit)
                return Prepared(rows: rows, total: total)
            }
            let result = await withTaskCancellationHandler {
                await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            rows = result.rows
            totalRows = result.total
            preparing = false
        }
    }

    @ViewBuilder
    private func rowView(_ row: DiffDocumentRow, width: CGFloat) -> some View {
        switch row.content {
        case let .line(line):
            DiffLineRow(line: line, minWidth: width, continuation: row.continuation)
        case let .file(path):
            Text(path)
                .font(ClientType.label.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(Theme.Space.s)
                .frame(width: width, alignment: .leading)
                .background(Theme.sidebar)
        case let .hunk(text):
            Text(text)
                .font(ClientType.code)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 6)
                .frame(width: width, alignment: .leading)
                .background(Theme.panel)
        case let .note(text):
            Text(text)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .padding(Theme.Space.m)
                .frame(width: width, alignment: .leading)
        }
    }

    private struct Request: Hashable {
        let revision: UUID
        let rowLimit: Int
        let fileHeaders: Bool
    }

    private struct Prepared: Sendable {
        let rows: [DiffDocumentRow]
        let total: Int
    }
}

#endif
