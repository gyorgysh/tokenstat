// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// One file's changes, read from the machine that owns the folder.
///
/// This reads the current working copy. Changes owns file selection and the
/// commit composer shows the immutable content reviewed for that submission.
///
/// Not `DiffView`, which compiles here but is built for a Mac pane: its two
/// 44pt gutters and marker spend 102 points of chrome before a character of
/// code, which is a quarter of a phone's width. One gutter instead, and the
/// `+` or `−` carries which side of the change the line is on.
struct ClientDiffView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let file: FileChange

    @State private var diff: FileDiff?
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var editorContent: EditableFile?
    @State private var revision = UUID()
    @State private var loadRevision = UUID()
    @Environment(\.fileContent) private var files

    private struct EditableFile: Identifiable {
        var path: String
        var text: String
        var id: String { path }
    }
    private var name: String {
        file.path.split(separator: "/").last.map(String.init) ?? file.path
    }

    var body: some View {
        ClientDiffDocumentView(diffs: diff.map { [$0] } ?? [], revision: revision, fileHeaders: false) {
            if let errorMessage {
                ClientErrorCard(message: errorMessage) { Task { await load() } }
            }
            header
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .background(Theme.background)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L10n.text("apple.clientdiffview.edit_file.9608dd14"), .edit) {
                    Task { await openEditor() }
                }
                .labelStyle(.iconOnly)
                .disabled(diff?.binary == true)
            }
        }
        .sheet(item: $editorContent, onDismiss: {
            Task { await load() }
        }) { content in
            ClientFileEditor(peer: peer, workspace: workspaceID, path: content.path, content: content.text)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clientFileDidChange)) { note in
            guard let change = note.object as? ClientFileChangeNotice,
                  change.peer == peer, change.workspace == workspaceID, change.path == file.path else { return }
            Task { await load() }
        }
        .refreshable {
            // Its own key. `ClientRefresh` throttles by key, so a diff sharing
            // one with the file list it was pushed from would swallow a pull.
            await ClientRefresh.pull("workspace-diff-\(workspaceID)-\(file.path)") {
                await load()
            }
        }
        .task { await load() }
    }

    /// What file, where, and how much of it moved. The path is here rather
    /// than in the title, which only has room for the name.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.path)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
            HStack(spacing: Theme.Space.s) {
                Text(file.kind.label)
                    .font(ClientType.caption.weight(.medium))
                    .foregroundStyle(file.kind.tint)
                if let added = file.added, added > 0 {
                    Text("+\(added)")
                        .font(ClientType.rowFigure)
                        .foregroundStyle(Theme.diffAdded)
                }
                if let removed = file.removed, removed > 0 {
                    Text("−\(removed)")
                        .font(ClientType.rowFigure)
                        .foregroundStyle(Theme.diffRemoved)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func load() async {
        let request = UUID()
        loadRevision = request
        let owner = WorkViewedChange.owner(folderID: workspaceID, peer: peer)
        do {
            let fresh = try await files.diff(
                peer: peer,
                workspace: workspaceID,
                path: file.path
            )
            guard !Task.isCancelled, request == loadRevision,
                  owner?.scope == WorkSessionContext.shared.scope else { return }
            diff = fresh
            revision = UUID()
            errorMessage = nil
            loaded = true
            await WorkViewedChange.save(owner: owner, diff: fresh)
        } catch {
            guard !Task.isCancelled, request == loadRevision,
                  owner?.scope == WorkSessionContext.shared.scope else { return }
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        loaded = true
    }

    private func openEditor() async {
        guard diff?.binary != true else { return }
        do {
            let text = try await files.read(peer: peer, workspace: workspaceID, path: file.path)
            errorMessage = nil
            editorContent = EditableFile(path: file.path, text: text)
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }
}

/// One line of a diff, sized for a phone.
///
/// One number column, not two. A line is on one side or the other, the `+` or
/// `−` says which, and a second column of dashes would spend width saying what
/// the marker already said. The number is the line's position on whichever
/// side it belongs to.
struct DiffLineRow: View {
    let line: DiffLine
    /// At least this wide, so the tint behind a short line spans the screen
    /// rather than stopping at the last character. Zero sizes to content.
    let minWidth: CGFloat
    @ScaledMetric(relativeTo: .footnote) private var gutterWidth: CGFloat = 34
    @ScaledMetric(relativeTo: .footnote) private var markerWidth: CGFloat = 12

    /// Both the gutter and the code scale with Dynamic Type, and they scale
    /// together because they share a font, so the columns stay aligned at
    /// every size.
    private var number: String {
        (line.newLine ?? line.oldLine).map(String.init) ?? "·"
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    private var tint: Color {
        switch line.kind {
        case .added: return Theme.diffAdded
        case .removed: return Theme.diffRemoved
        case .context: return .primary
        }
    }

    private var wash: Color {
        switch line.kind {
        case .added: return Theme.diffAdded.opacity(0.12)
        case .removed: return Theme.diffRemoved.opacity(0.12)
        case .context: return .clear
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number)
                .font(ClientType.code)
                .foregroundStyle(.tertiary)
                .frame(minWidth: gutterWidth, alignment: .trailing)
                .padding(.trailing, Theme.Space.xs)
            Text(marker)
                .font(ClientType.code)
                .foregroundStyle(tint)
                .frame(width: markerWidth, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .font(ClientType.code)
                .foregroundStyle(tint)
                .textSelection(.enabled)
                // Never wrap: a wrapped line loses its place against the
                // gutter, and long lines are what the horizontal scroll is for.
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, Theme.Space.m)
        }
        .padding(.leading, Theme.Space.xs)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(wash)
    }
}

#endif
