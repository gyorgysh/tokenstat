// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

/// A roomy, commit-style review of the current working tree.
struct WorkingTreeReviewView: View {
    let folder: WorkspaceFolder
    @Bindable var model: WorkspacesModel

    @State private var diffs: [FileDiff] = []
    @State private var loading = true
    @State private var error: String?

    private var files: [FileChange] { folder.git?.files ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error {
                InspectorEmptyState(
                    systemImage: "exclamationmark.circle",
                    title: "Could not load changes",
                    subtitle: error,
                    tint: Theme.danger
                )
            } else if loading {
                ProgressView("Reading working tree")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diffs.isEmpty {
                InspectorEmptyState(
                    systemImage: "checkmark.seal",
                    title: "No changes to review",
                    subtitle: "The working tree is clean."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diffs, id: \.path) { diff in
                            fileHeader(diff)
                            DiffBody(diff: diff)
                        }
                    }
                }
            }
        }
        .background(Theme.background)
        .task(id: folder.id) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Uncommitted changes")
                        .font(Theme.font(15, weight: .semibold))
                    Text(folder.name)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // No "Back to terminal" button. This surface has a tab in the
                // strip above, like a commit does, and that tab's close is how
                // it goes away. A second way out, in a place a commit does not
                // have one, made two alike surfaces read as different things.
            }
            if let git = folder.git {
                HStack(spacing: Theme.Space.s) {
                    Text("+\(git.added)").foregroundStyle(Theme.success)
                    Text("−\(git.removed)").foregroundStyle(Theme.danger)
                    Text("· \(files.count) file\(files.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Working tree")
                        .foregroundStyle(.tertiary)
                }
                .font(Theme.caption)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
    }

    private func fileHeader(_ diff: FileDiff) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "doc.text")
                .font(Theme.font(11))
                .foregroundStyle(.tertiary)
            Text(diff.path)
                .font(Theme.mono(12))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            for file in files {
                await model.loadDiff(file.path, in: folder.id)
            }
            diffs = files.compactMap { model.diff(for: $0.path, in: folder.id) }
        }
        loading = false
    }
}
