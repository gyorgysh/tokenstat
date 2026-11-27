// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

struct ClientDiffView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let file: FileChange
    var showsNavigationTitle = true
    var showsEditAction = true

    @State private var diff: FileDiff?
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var editorContent: EditableFile?
    @State private var revision = UUID()
    @State private var loadRevision = UUID()
    @State private var editorRevision = UUID()
    @State private var openingEditor = false
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
        .modifier(ClientOptionalNavigationTitle(showsNavigationTitle ? name : nil))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsEditAction {
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.text("apple.clientdiffview.edit_file.9608dd14"), .edit) {
                        Task { await openEditor() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!loaded || diff == nil || diff?.binary == true || openingEditor)
                }
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
            await ClientRefresh.pull("workspace-diff-\(workspaceID)-\(file.path)") {
                await load()
            }
        }
        .task { await load() }
        .onDisappear {
            editorRevision = UUID()
            openingEditor = false
        }
    }

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
        guard loaded, diff != nil, diff?.binary != true, !openingEditor else { return }
        let request = UUID()
        editorRevision = request
        let owner = WorkSessionContext.shared.scope
        openingEditor = true
        defer { if request == editorRevision { openingEditor = false } }
        do {
            let text = try await files.read(peer: peer, workspace: workspaceID, path: file.path)
            guard !Task.isCancelled, request == editorRevision,
                  owner == WorkSessionContext.shared.scope else { return }
            errorMessage = nil
            editorContent = EditableFile(path: file.path, text: text)
        } catch {
            guard !Task.isCancelled, request == editorRevision,
                  owner == WorkSessionContext.shared.scope else { return }
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }
}

struct DiffLineRow: View {
    let line: DiffLine
    let minWidth: CGFloat
    var continuation = false
    @ScaledMetric(relativeTo: .footnote) private var gutterWidth: CGFloat = 34
    @ScaledMetric(relativeTo: .footnote) private var markerWidth: CGFloat = 12

    /// Both the gutter and the code scale with Dynamic Type, and they scale
    /// together because they share a font, so the columns stay aligned at
    /// every size.
    private var number: String {
        continuation ? "↳" : (line.newLine ?? line.oldLine).map(String.init) ?? "·"
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
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, Theme.Space.xs)
            Text(marker)
                .font(ClientType.code)
                .foregroundStyle(tint)
                .frame(width: markerWidth, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .font(ClientType.code)
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, Theme.Space.m)
        }
        .padding(.leading, Theme.Space.xs)
        .padding(.vertical, 1)
        .frame(width: max(1, minWidth), alignment: .leading)
        .background(wash)
    }
}

#endif
