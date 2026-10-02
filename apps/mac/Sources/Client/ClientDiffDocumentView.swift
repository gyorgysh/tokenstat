// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI
import UIKit

/// A phone diff has one lazy item per line and one shared horizontal offset.
/// Each explicit expansion adds a bounded page across the whole commit.
struct ClientDiffDocumentView<Header: View>: View {
    let diffs: [FileDiff]
    let revision: UUID
    var fileHeaders = true
    @ViewBuilder var header: () -> Header

    @ScaledMetric(relativeTo: .footnote) private var codeSize: CGFloat = 13
    @State private var rows: [DiffDocumentRow] = []
    @State private var rowLimit = 2_000
    @State private var totalRows = 0
    @State private var textWidth: CGFloat = 0
    @State private var preparing = true
    @State private var displayedRevision: UUID?
    @State private var metadataHeight: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let paneWidth = max(0, geometry.size.width - Theme.Space.m * 2)
            let documentWidth = max(paneWidth, textWidth + 88 * codeSize / 13)
            let headerLimit = max(1, geometry.size.height * 0.4)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                // Metadata never joins the code's horizontal coordinate space.
                // A long message can scroll in its own bounded header area.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) { header() }
                        .frame(width: paneWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            metadataHeight = $0
                        }
                }
                .frame(height: min(metadataHeight, headerLimit))
                .scrollBounceBehavior(.basedOnSize)

                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row, width: documentWidth)
                        }
                    }
                    .frame(width: documentWidth, alignment: .leading)
                    .padding(.bottom, Theme.Space.s)
                    .background(ClientDiffDirectionLock())
                }
                .defaultScrollAnchor(.topLeading)
                .frame(width: paneWidth)
                .overlay {
                    if preparing && rows.isEmpty { ProgressView() }
                }
                if totalRows > rowLimit {
                    Button(L10n.text("apple.clientdiffdocumentview.show_more_lines", "\(min(2_000, totalRows - rowLimit))", "\(totalRows - rowLimit)"), .reveal) {
                        rowLimit += 2_000
                    }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true))
                    .disabled(preparing)
                    .frame(width: paneWidth)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .task(id: Request(revision: revision, rowLimit: rowLimit, codeSize: codeSize, fileHeaders: fileHeaders)) {
            if displayedRevision != revision {
                rows = []
                rowLimit = 2_000
                displayedRevision = revision
            }
            preparing = true
            let input = diffs
            let headers = fileHeaders
            let limit = rowLimit
            let size = codeSize
            let task = Task.detached(priority: .userInitiated) {
                let rows = DiffDocumentRow.make(input, fileHeaders: headers, rowLimit: limit)
                let font = AppFonts.terminal(size: size)
                var width: CGFloat = 0
                for row in rows {
                    guard !Task.isCancelled else { return Prepared(rows: [], total: 0, width: 0) }
                    if case let .line(line) = row.content {
                        width = max(width, (line.text as NSString).size(withAttributes: [.font: font]).width)
                    }
                }
                let total = DiffDocumentRow.count(input, fileHeaders: headers)
                return Prepared(rows: rows, total: total, width: ceil(width))
            }
            let result = await withTaskCancellationHandler {
                await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            rows = result.rows
            totalRows = result.total
            textWidth = result.width
            preparing = false
        }
    }

    @ViewBuilder
    private func rowView(_ row: DiffDocumentRow, width: CGFloat) -> some View {
        switch row.content {
        case let .line(line):
            DiffLineRow(line: line, minWidth: width)
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
        let codeSize: CGFloat
        let fileHeaders: Bool
    }

    private struct Prepared: Sendable {
        let rows: [DiffDocumentRow]
        let total: Int
        let width: CGFloat
    }
}

/// UIScrollView chooses one axis for a diagonal drag instead of drifting on both.
private struct ClientDiffDirectionLock: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.configure() }

    final class Probe: UIView {
        override func didMoveToWindow() { super.didMoveToWindow(); configure() }
        override func didMoveToSuperview() { super.didMoveToSuperview(); configure() }
        override func layoutSubviews() { super.layoutSubviews(); configure() }

        func configure() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    scroll.isDirectionalLockEnabled = true
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
#endif
