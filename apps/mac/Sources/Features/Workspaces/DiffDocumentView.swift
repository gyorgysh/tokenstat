// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// One scrolling surface for a file, commit or working-tree review. Avoid
/// nested lazy stacks: a large file must not be one enormous lazy item.
struct DiffDocumentView<Header: View>: View {
    let diffs: [FileDiff]
    var fileHeaders = true
    @ViewBuilder var header: () -> Header
    @State private var rows: [DiffDocumentRow] = []
    @State private var loaded = false

    var body: some View {
        GeometryReader { geometry in
            if loaded {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        header()
                            .frame(width: geometry.size.width, alignment: .leading)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                DiffDocumentRowView(row: row, width: geometry.size.width)
                            }
                        }
                    }
                    .frame(minWidth: geometry.size.width, alignment: .topLeading)
                }
                .defaultScrollAnchor(.topLeading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header()
                    ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                    Spacer(minLength: 0)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
        }
        .task(id: Request(diffs: diffs, fileHeaders: fileHeaders)) {
            // Mount the scroll view with its complete row set so its first
            // visible range is computed against the real document, rather
            // than a loading indicator that will be replaced asynchronously.
            loaded = false
            let input = diffs
            let headers = fileHeaders
            let task = Task.detached(priority: .userInitiated) {
                DiffDocumentRow.make(input, fileHeaders: headers)
            }
            let result = await withTaskCancellationHandler {
                await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            rows = result
            loaded = true
        }
    }

    private struct Request: Hashable {
        let diffs: [FileDiff]
        let fileHeaders: Bool
    }
}

private struct DiffDocumentRowView: View {
    let row: DiffDocumentRow
    let width: CGFloat

    var body: some View {
        switch row.content {
        case let .line(line):
            DiffRow(line: line, minWidth: width)
        case let .file(path):
            Label(path, systemImage: "doc.text")
                .font(Theme.mono(12))
                .lineLimit(1)
                .padding(.horizontal, Theme.Space.m)
                .frame(minWidth: width, minHeight: 32, alignment: .leading)
                .background(Theme.sidebar)
        case let .hunk(header):
            Text(header)
                .font(Theme.mono(11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.horizontal, Theme.Space.m)
                .frame(minWidth: width, minHeight: 26, alignment: .leading)
                .background(Theme.panel)
        case let .note(message):
            Text(message)
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .padding(Theme.Space.m)
                .frame(minWidth: width, alignment: .leading)
        }
    }
}
