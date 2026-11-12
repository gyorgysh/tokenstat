// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
#if os(macOS)

/// A value copy keeps the chosen turn independent of later transcript paging.
struct ChatTurnReview: Identifiable {
    let id = UUID()
    let changes: ChatTurnChanges
    let focus: String?
    let conversation: String

    var files: [ChatTurnChanges.File] {
        guard let focus, let index = changes.files.firstIndex(where: { $0.path == focus }) else { return changes.files }
        var files = changes.files
        files.insert(files.remove(at: index), at: 0)
        return files
    }
}

struct ChatChangesWorkbenchView: View {
    let folder: WorkspaceFolder
    @Bindable var model: WorkspacesModel
    @Bindable var automations: AutomationsModel
    let review: ChatTurnReview?
    let commitID: String?
    let isActive: Bool
    let showWorkingTree: () -> Void
    @State private var managing = false
    @State private var commitDetail: CommitDetail?
    @State private var commitError: String?
    @State private var loadedCommitID: String?
    @State private var commitLoadGeneration = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Label(commitID.map { String($0.prefix(8)) } ?? (review == nil ? L10n.text("apple.workingtreereviewview.working_tree.f90114ae")
                                    : L10n.text("apple.workbench.turn_changes")), systemImage: ActionIcon.compare.symbol)
                    .font(Theme.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
                if review != nil || commitID != nil {
                    Button(L10n.text("apple.workingtreereviewview.working_tree.f90114ae"), .compare) {
                        managing = false
                        showWorkingTree()
                    }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                } else {
                    Button(managing ? L10n.text("apple.chatchanges.review") : L10n.text("apple.workbench.manage_changes"),
                           managing ? .preview : .commit) { managing.toggle() }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            }
            .padding(Theme.Space.s)
            ThemeRule()
            if let commitID {
                if loadedCommitID == commitID, let detail = commitDetail {
                    CommitView(detail: detail).id(commitID)
                } else if loadedCommitID == commitID, let error = commitError {
                    ErrorBanner(message: error) {
                        Task { await loadCommit(commitID) }
                    }
                    Spacer()
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let review {
                RecordedTurnReviewView(review: review)
            } else if managing {
                WorkspaceChangesView(model: model, folder: folder, automations: automations,
                    onReview: { path in
                        model.focusWorkingTree(in: folder.id, path: path)
                        managing = false
                    })
            } else {
                WorkingTreeReviewView(folder: folder, model: model, isActive: isActive)
            }
        }
        .background(Theme.background)
        .task(id: commitID) {
            await loadCommit(commitID)
        }
    }

    /// The side review owns its snapshot. A document tab's concurrent read or
    /// close must not cancel it or empty the commit currently being reviewed.
    private func loadCommit(_ id: String?) async {
        let generation = UUID()
        commitLoadGeneration = generation
        loadedCommitID = nil
        commitDetail = nil
        commitError = nil
        guard let id else { return }
        do {
            let detail = try await Bridge.workspaceShow(id: folder.id, commit: id)
            guard !Task.isCancelled, commitLoadGeneration == generation else { return }
            commitDetail = detail
            loadedCommitID = id
        } catch {
            guard !Task.isCancelled, commitLoadGeneration == generation else { return }
            commitError = error.localizedDescription
            loadedCommitID = id
        }
    }
}

/// Recorded patches are independent of Git and remain readable after a commit.
struct RecordedTurnReviewView: View {
    let review: ChatTurnReview
    @State private var selectedPath: String?

    private var selectedFile: ChatTurnChanges.File? {
        let path = ChangePathMatch.reviewSelection(selectedPath, focus: review.focus, paths: review.changes.files.map(\.path))
        return review.changes.files.first { $0.path == path }
    }

    var body: some View {
        ReviewFileBrowser(
            files: review.changes.files.map { ReviewFileChoice(path: $0.path, added: $0.added, removed: $0.removed) },
            selection: Binding(get: { selectedFile?.path }, set: { selectedPath = $0 })
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if let file = selectedFile {
                    ReviewFileHeading(path: file.path)
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            Text(review.conversation).font(Theme.callout.weight(.medium))
                            Text(L10n.text("apple.workbench.recorded_edits"))
                                .font(Theme.caption).foregroundStyle(.secondary)
                            if file.patches.isEmpty {
                                missingPatch
                            } else {
                                ForEach(Array(file.patches.enumerated()), id: \.offset) { index, patch in
                                    if file.patches.count > 1 {
                                        Text(L10n.text("apple.workbench.edit_number", "\(index + 1)"))
                                            .font(Theme.caption).foregroundStyle(.secondary)
                                    }
                                    if patch.isEmpty { missingPatch }
                                    else { RecordedPatchView(patch: patch) }
                                }
                            }
                        }
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(file.path)
                }
            }
        }
        .onChange(of: review.id, initial: true) { _, _ in selectedPath = review.focus }
    }

    private var missingPatch: some View {
        Text(L10n.text("apple.workbench.patch_unavailable"))
            .font(Theme.caption).foregroundStyle(.secondary)
    }
}

#endif

/// A resize or a streaming chat update must not recolor every recorded patch.
struct RecordedPatchView: View {
    let patch: String
    @State private var rendered: AttributedString?

    var body: some View {
        Text(rendered ?? AttributedString(patch))
            .font(Theme.mono(12)).textSelection(.enabled)
            .task(id: patch) {
                let input = patch
                let task = Task.detached(priority: .userInitiated) {
                    diffColoredText(input, lineLimit: Int.max, clipLongLines: false).text
                }
                let colored = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
                if !Task.isCancelled { rendered = colored }
            }
    }
}
