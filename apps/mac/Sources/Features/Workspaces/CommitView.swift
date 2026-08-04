// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// One commit in the centre pane: what it says, then every file it changed.
///
/// The message is the part people came for and it goes at the top, in full.
/// A history that only shows subjects is a history you have to leave the app to
/// read.
struct CommitView: View {
    let detail: CommitDetail

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                if detail.diffs.isEmpty {
                    empty
                } else {
                    ForEach(detail.diffs, id: \.path) { diff in
                        fileHeader(diff)
                        DiffBody(diff: diff)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(detail.subject)
                .font(.system(size: 15, weight: .semibold))
                .textSelection(.enabled)

            if !detail.body.isEmpty {
                Text(detail.body)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Space.s) {
                Text(detail.author)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(detail.date, format: .dateTime.year().month().day().hour().minute())
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Text(detail.shortID)
                    .font(Theme.mono(12))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                if detail.isMerge {
                    Text("merge")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: Theme.Space.xs)
                Text("+\(detail.added)")
                    .font(Theme.numeric(12, weight: .medium))
                    .foregroundStyle(.green)
                Text("−\(detail.removed)")
                    .font(Theme.numeric(12, weight: .medium))
                    .foregroundStyle(.red)
                Text("· \(detail.files.count) file\(detail.files.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
    }

    private var empty: some View {
        Text(detail.isMerge
             ? "A merge, so there is nothing of its own to show. Its changes belong to the commits it brought in."
             : "This commit changed no files.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(Theme.Space.m)
    }

    private func fileHeader(_ diff: FileDiff) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(diff.path)
                .font(Theme.mono(12))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
