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
    @State private var loadGeneration = 0

    private var files: [FileChange] { folder.git?.files ?? [] }

    /// Identity of the work to review: the folder and the change set. A save,
    /// an agent edit, or a commit changes it and reloads the diffs.
    private struct ReviewKey: Equatable {
        let folderID: String
        let files: [FileChange]
    }

    private var reviewKey: ReviewKey {
        ReviewKey(folderID: folder.id, files: files)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error, diffs.isEmpty {
                ErrorBanner(message: error) { Task { await load() } }
                InspectorEmptyState(
                    systemImage: "exclamationmark.circle",
                    title: L10n.text("apple.workingtreereviewview.could_not_load_changes.07be1deb"),
                    subtitle: error,
                    tint: Theme.danger
                )
            } else if loading, diffs.isEmpty {
                ProgressView(L10n.text("apple.workingtreereviewview.reading_working_tree.7e8e886f"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diffs.isEmpty {
                InspectorEmptyState(
                    systemImage: "checkmark.seal",
                    title: L10n.text("apple.workingtreereviewview.no_changes_to_review.e964b314"),
                    subtitle: L10n.text("apple.workingtreereviewview.the_working_tree_is_clean.84230b1f")
                )
            } else {
                DiffDocumentView(diffs: diffs) {
                    if let error {
                        ErrorBanner(message: error) { Task { await load() } }
                    }
                }
            }
        }
        .background(Theme.background)
        .task(id: reviewKey) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("apple.workingtreereviewview.uncommitted_changes.a388bd2d"))
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
                    Text((files.count == 1 ? L10n.text("apple.workingtreereviewview.0_file_1.ac963029.one", "\(files.count)") : L10n.text("apple.workingtreereviewview.0_file_1.ac963029.other", "\(files.count)")))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(L10n.text("apple.workingtreereviewview.working_tree.f90114ae"))
                        .foregroundStyle(.tertiary)
                }
                .font(Theme.caption)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        loading = true
        error = nil
        let paths = files.map(\.path)
        let folderID = folder.id
        let failures = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            var next = 0
            var failures = 0
            // Bound parallel work: a large review should neither pay one RTT
            // per file nor flood the bridge with hundreds of requests.
            for _ in 0..<min(4, paths.count) {
                let path = paths[next]
                next += 1
                group.addTask { await model.loadDiff(path, in: folderID) }
            }
            for await loaded in group {
                if !loaded { failures += 1 }
                if !Task.isCancelled, next < paths.count {
                    let path = paths[next]
                    next += 1
                    group.addTask { await model.loadDiff(path, in: folderID) }
                }
            }
            return failures
        }
        guard !Task.isCancelled, generation == loadGeneration else { return }
        diffs = paths.compactMap { model.diff(for: $0, in: folderID) }
        if failures > 0 {
            error = L10n.text("apple.workingtreereviewview.could_not_refresh_0_file_s_available_chang.89fdefb0", "\(failures)")
        }
        loading = false
        let owner = WorkViewedChange.owner(folderID: folderID)
        for diff in diffs {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            await WorkViewedChange.save(owner: owner, diff: diff)
        }
    }
}
