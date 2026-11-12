// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

/// Browse every changed file, loading the full diff only for the current file.
/// Selection here is independent of the files selected for a commit.
struct ClientReviewAllView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let files: [FileChange]
    @State private var selectedPath: String?

    private var selectedFile: FileChange? {
        files.first(where: { $0.path == selectedPath }) ?? files.first
    }

    var body: some View {
        ReviewFileBrowser(
            files: files.map { ReviewFileChoice(path: $0.path, added: $0.added, removed: $0.removed) },
            selection: Binding(get: { selectedFile?.path }, set: { selectedPath = $0 })
        ) {
            if let file = selectedFile {
                ClientDiffView(peer: peer, workspaceID: workspaceID, hostName: hostName, file: file,
                               showsNavigationTitle: false, showsEditAction: false)
                    .id(file.path)
            } else {
                InspectorEmptyState(systemImage: "checkmark.seal",
                    title: L10n.text("apple.workingtreereviewview.no_changes_to_review.e964b314"),
                    subtitle: L10n.text("apple.workingtreereviewview.the_working_tree_is_clean.84230b1f"))
            }
        }
        .background(Theme.background)
        .navigationTitle(L10n.text("apple.clientreviewallview.review_all.d05163fa"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A turn is a recorded snapshot; it remains available after later Git edits.
struct ClientRecordedTurnReview: Identifiable {
    let id = UUID()
    let changes: ChatTurnChanges
    let focus: String?
}

struct ClientRecordedTurnReviewView: View {
    let review: ClientRecordedTurnReview
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
            if let file = selectedFile {
                VStack(spacing: 0) {
                    ReviewFileHeading(path: file.path)
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            Text(L10n.text("apple.workbench.recorded_edits"))
                                .font(ClientType.caption).foregroundStyle(.secondary)
                            if file.patches.isEmpty {
                                Text(L10n.text("apple.workbench.patch_unavailable"))
                                    .font(ClientType.caption).foregroundStyle(.secondary)
                            }
                            ForEach(Array(file.patches.enumerated()), id: \.offset) { index, patch in
                                if file.patches.count > 1 {
                                    Text(L10n.text("apple.workbench.edit_number", "\(index + 1)"))
                                        .font(ClientType.caption).foregroundStyle(.secondary)
                                }
                                if patch.isEmpty {
                                    Text(L10n.text("apple.workbench.patch_unavailable"))
                                        .font(ClientType.caption).foregroundStyle(.secondary)
                                } else { RecordedPatchView(patch: patch) }
                            }
                        }
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.id(file.path)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(L10n.text("apple.workbench.turn_changes"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
