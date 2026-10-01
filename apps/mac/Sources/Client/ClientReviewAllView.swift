// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// Every changed file's diff on one screen, for the final read before a
/// commit.
///
/// Bounded twice: at most twenty files, sixty display rows each, with a Full diff
/// link per file for the rest. A generated file with oceans of output stays
/// a card with a link rather than a hang. File selection and the commit
/// draft live above this screen and are untouched by opening it.
struct ClientReviewAllView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let files: [FileChange]

    static let maxFiles = 20
    static let linesPerFile = 60

    @Environment(\.fileContent) private var content
    private struct Preview: Sendable {
        let rows: [DiffDocumentRow]
        let total: Int
    }
    @State private var diffs: [String: Preview] = [:]
    @State private var failures = 0
    @State private var loaded = false
    @State private var loadRevision = UUID()
    /// The width of the screen, measured.
    ///
    /// Inside a horizontally scrolling container `maxWidth: .infinity` means
    /// *unbounded* rather than "fill", so rows grow enormous and the content
    /// ends up somewhere off to the right. A row takes it as a minimum
    /// instead, which is also what makes the tint behind a short line span
    /// the screen rather than stop at the last character. Same measure as
    /// the per-file diff and the commit detail.
    @State private var paneWidth: CGFloat = 0

    private var shown: [FileChange] { Array(files.prefix(Self.maxFiles)) }
    private var leftoverFiles: Int { max(0, files.count - shown.count) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Space.xl)
                } else {
                    if failures > 0 {
                        Text((failures == 1 ? L10n.text("apple.clientreviewallview.0_file_1_did_not_load_open_2_individually.2acd4427.one", "\(failures)") : L10n.text("apple.clientreviewallview.0_file_1_did_not_load_open_2_individually.2acd4427.other", "\(failures)")))
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.controlGlyph)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(shown) { file in
                        fileCard(file)
                    }
                    if leftoverFiles > 0 {
                        Text((leftoverFiles == 1 ? L10n.text("apple.clientreviewallview.0_more_file_1_changed_open_2_from_changes.206bca3b.one", "\(leftoverFiles)") : L10n.text("apple.clientreviewallview.0_more_file_1_changed_open_2_from_changes.206bca3b.other", "\(leftoverFiles)")))
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.controlGlyph)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .background(
            GeometryReader { proxy in
                Color.clear
                    // Quantised: `minWidth` relays every row in the diff, and
                    // a rotation or a split-view drag would otherwise deliver
                    // a new width, and a full relayout, on every frame.
                    .onAppear { paneWidth = (proxy.size.width / 8).rounded(.down) * 8 }
                    .onChange(of: (proxy.size.width / 8).rounded(.down) * 8) { _, new in
                        paneWidth = new
                    }
            }
        )
        .navigationTitle(L10n.text("apple.clientreviewallview.review_all.d05163fa"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await ClientRefresh.pull("workspace-review-all-\(workspaceID)") { await load() }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func fileCard(_ file: FileChange) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                    .font(ClientType.label.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                Text(file.kind.label)
                    .font(ClientType.caption.weight(.medium))
                    .foregroundStyle(file.kind.tint)
            }
            if let preview = diffs[file.path] {
                if preview.rows.count == 1, case let .note(text) = preview.rows[0].content {
                    Text(text)
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                } else {
                    hunks(preview)
                }
            } else {
                Text(loaded ? L10n.text("apple.workingtreereviewview.could_not_load_changes.07be1deb")
                            : L10n.text("apple.clientreviewallview.still_loading.fa2e3194"))
                    .font(ClientType.caption)
                    .foregroundStyle(.tertiary)
            }
            NavigationLink {
                ClientDiffView(peer: peer, workspaceID: workspaceID, hostName: hostName, file: file)
            } label: {
                HStack {
                    Text(L10n.text("apple.clientreviewallview.full_diff.79eeb065"))
                        .font(ClientType.label.weight(.medium))
                        .foregroundStyle(Theme.accent)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(Theme.controlGlyph)
                }
                .padding(.vertical, Theme.Space.xs)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(file.path). \(file.kind.label)")
    }

    /// The width a row should fill, less the card's own horizontal padding.
    private var rowWidth: CGFloat {
        max(0, paneWidth - Theme.Space.m * 2)
    }

    /// One horizontal scroll around each file's diff, not one per row, so the
    /// gutter and the code cannot slide out of step with each other. The same
    /// container the per-file diff and the commit detail use: without it a
    /// long line, which never wraps, forces its row wider than the screen and
    /// the card overflows with nowhere to scroll.
    private func hunks(_ preview: Preview) -> some View {
        let cut = max(0, preview.total - preview.rows.count)
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(preview.rows) { row in
                        switch row.content {
                        case let .hunk(header):
                            Text(header)
                                .font(ClientType.code)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .padding(.horizontal, Theme.Space.s)
                                .padding(.vertical, 6)
                                .frame(minWidth: rowWidth, alignment: .leading)
                                .background(Theme.panel)
                        case let .line(line):
                            DiffLineRow(line: line, minWidth: rowWidth)
                        case let .note(text):
                            Text(text)
                                .font(ClientType.caption)
                                .foregroundStyle(.secondary)
                        case .file:
                            EmptyView()
                        }
                    }
                }
                .padding(.vertical, Theme.Space.xs)
            }
            if cut > 0 {
                Text(L10n.text("apple.clientreviewallview.showing_0_of_1_lines_here.f2764462", "\(preview.rows.count)", "\(preview.total)"))
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .padding(.top, Theme.Space.xs)
            }
        }
    }

    private func load() async {
        let request = UUID()
        loadRevision = request
        let owner = WorkSessionContext.shared.scope
        var fresh: [String: Preview] = [:]
        var missed = 0
        for file in shown {
            do {
                let diff = try await content.diff(peer: peer, workspace: workspaceID, path: file.path)
                guard !Task.isCancelled else { return }
                let limit = Self.linesPerFile
                let task = Task.detached(priority: .userInitiated) {
                    Preview(rows: DiffDocumentRow.make([diff], fileHeaders: false, rowLimit: limit),
                            total: DiffDocumentRow.count([diff], fileHeaders: false))
                }
                let preview = await withTaskCancellationHandler {
                    await task.value
                } onCancel: { task.cancel() }
                guard !Task.isCancelled, request == loadRevision,
                      owner == WorkSessionContext.shared.scope else { return }
                fresh[file.path] = preview
            } catch {
                guard !Task.isCancelled, request == loadRevision,
                      owner == WorkSessionContext.shared.scope else { return }
                missed += 1
            }
        }
        guard !Task.isCancelled, request == loadRevision,
              owner == WorkSessionContext.shared.scope else { return }
        diffs = fresh
        failures = missed
        loaded = true
    }
}
#endif
