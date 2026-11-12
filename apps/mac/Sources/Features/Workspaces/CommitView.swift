// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// One commit in the centre pane: a compact summary, then its files in the
/// same browser the working tree and a turn's edits use.
///
/// A commit is read as one change, so it opens on every file at once. The list
/// beside it (or the picker in a narrow pane) narrows that to one file, with
/// each file's own line counts so the shape of the change shows before any
/// diff is read. The message stays on screen in one line and opens in place,
/// because a history that only shows subjects is a history you have to leave
/// the app to read.
struct CommitView: View {
    let detail: CommitDetail

    /// Nil is "All files".
    @State private var selectedPath: String?
    @State private var showsMessage = false

    /// The host lists files with their counts. An older host that sent diffs
    /// without a file list still gets a list, without counts.
    private var files: [ReviewFileChoice] {
        if !detail.files.isEmpty {
            return detail.files.map { ReviewFileChoice(path: $0.path, added: $0.added, removed: $0.removed) }
        }
        return detail.diffs.map { ReviewFileChoice(path: $0.path, added: nil, removed: nil) }
    }

    private var selectedDiff: FileDiff? {
        guard let selectedPath else { return nil }
        return detail.diffs.first { $0.path == selectedPath }
    }

    private var hasMore: Bool { !detail.body.isEmpty || !detail.tagList.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            ThemeRule()
            if detail.diffs.isEmpty {
                empty
                Spacer(minLength: 0)
            } else {
                ReviewFileBrowser(
                    files: files,
                    selection: Binding(get: { selectedPath }, set: { selectedPath = $0 }),
                    allFiles: ReviewAllFiles(added: detail.added, removed: detail.removed)
                ) {
                    diffPane
                }
            }
        }
        .background(Theme.background)
        .onChange(of: detail.id) { _, _ in
            selectedPath = nil
            showsMessage = false
        }
    }

    @ViewBuilder
    private var diffPane: some View {
        if let selectedPath {
            VStack(spacing: 0) {
                ReviewFileHeading(path: selectedPath)
                if let diff = selectedDiff {
                    DiffDocumentView(diffs: [diff], fileHeaders: false) { EmptyView() }
                } else {
                    InspectorEmptyState(
                        systemImage: "doc.text",
                        title: L10n.text("apple.commitview.no_diff_for_this_file"),
                        subtitle: selectedPath
                    )
                }
            }
            .id(selectedPath)
        } else {
            DiffDocumentView(diffs: detail.diffs) { EmptyView() }
                .id(detail.id)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(detail.subject)
                    .font(Theme.font(14, weight: .semibold))
                    .lineLimit(showsMessage ? nil : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: showsMessage)
                    .textSelection(.enabled)
                    .help(detail.subject)
                Spacer(minLength: Theme.Space.xs)
                if hasMore {
                    Button(showsMessage ? L10n.text("apple.commitview.hide_message")
                                        : L10n.text("apple.commitview.show_message"),
                           showsMessage ? .collapse : .more) {
                        showsMessage.toggle()
                    }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                }
            }

            if showsMessage {
                if !detail.body.isEmpty {
                    // Long messages scroll inside a bounded area, so the diff
                    // below keeps most of the pane.
                    ScrollView {
                        Text(detail.body)
                            .font(Theme.font(13))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                }
                CommitTagPills(tags: detail.tagList)
            }

            HStack(spacing: Theme.Space.s) {
                Text(detail.author)
                    .font(Theme.font(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(detail.date, format: .dateTime.year().month().day().hour().minute())
                    .font(Theme.font(12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Text(detail.shortID)
                    .font(Theme.mono(12))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                if detail.isMerge {
                    Text(L10n.text("apple.commitview.merge.283128ac"))
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: Theme.Space.xs)
                Text("+\(detail.added)")
                    .font(Theme.numeric(12, weight: .medium))
                    .foregroundStyle(Theme.success)
                Text("−\(detail.removed)")
                    .font(Theme.numeric(12, weight: .medium))
                    .foregroundStyle(Theme.danger)
                Text((files.count == 1 ? L10n.text("apple.commitview.0_file_1.ac963029.one", "\(files.count)") : L10n.text("apple.commitview.0_file_1.ac963029.other", "\(files.count)")))
                    .font(Theme.font(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
    }

    private var empty: some View {
        Text(detail.isMerge
             ? L10n.text("apple.commitview.a_merge_so_there_is_nothing_of_its_own_to.6435e3f6")
             : L10n.text("apple.commitview.this_commit_changed_no_files.9786b223"))
            .font(Theme.callout)
            .foregroundStyle(.secondary)
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
