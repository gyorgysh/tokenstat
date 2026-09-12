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
                    title: "Could not load changes",
                    subtitle: error,
                    tint: Theme.danger
                )
            } else if loading, diffs.isEmpty {
                ProgressView("Reading working tree")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diffs.isEmpty {
                InspectorEmptyState(
                    systemImage: "checkmark.seal",
                    title: "No changes to review",
                    subtitle: "The working tree is clean."
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
            error = "Could not refresh \(failures) file(s). Available changes are still shown. Try again."
        }
        loading = false
        let owner = WorkViewedChange.owner(folderID: folderID)
        for diff in diffs {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            await WorkViewedChange.save(owner: owner, diff: diff)
        }
    }
}
