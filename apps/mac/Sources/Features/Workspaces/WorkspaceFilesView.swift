// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The Files tab: the workspace's folders and files, expanded as they are
/// opened.
///
/// One directory is read per expansion rather than the whole tree up front. A
/// monorepo has hundreds of thousands of files and reading them to draw a
/// dozen rows would stall the window for no benefit.
struct WorkspaceFilesView: View {
    /// Where the list is drawn, which decides what is behind it.
    ///
    /// The tree appears twice: in the inspector column, which sits on the same
    /// translucent material as the rest of the chrome, and in the middle pane
    /// as a session, which is content. Material in the middle made the file
    /// list read a shade lighter than the editor, the diff and the browser it
    /// shares that slot with, so the same folder changed colour depending on
    /// which pane you opened it in.
    enum Surface {
        case chrome
        case content
    }

    @Bindable var model: WorkspacesModel
    var folder: WorkspaceFolder?
    var surface: Surface = .chrome

    var body: some View {
        filesBody
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(backdrop)
            .task(id: folder?.id) {
                guard let folder, folder.exists else { return }
                if model.children(of: "", in: folder.id) == nil {
                    await model.loadTree("", in: folder.id)
                }
            }
    }

    private var backdrop: AnyShapeStyle {
        switch surface {
        case .chrome: return AnyShapeStyle(Theme.background)
        case .content: return AnyShapeStyle(Theme.background)
        }
    }

    @ViewBuilder
    private var filesBody: some View {
        if let folder {
            if !folder.exists {
                InspectorEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Folder missing",
                    subtitle: "The folder no longer exists on disk.",
                    tint: Theme.warning
                )
            } else if let roots = model.children(of: "", in: folder.id) {
                if roots.isEmpty {
                    InspectorEmptyState(
                        systemImage: "tray",
                        title: "Empty folder",
                        subtitle: "There are no files or directories here yet."
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows(roots, in: folder)) { row in
                                TreeRow(
                                    entry: row.entry,
                                    depth: row.depth,
                                    isExpanded: model.isExpanded(row.entry.path, in: folder.id),
                                    isOpen: model.isFront(.file(row.entry.path), in: folder.id)
                                ) {
                                    Task {
                                        if row.entry.isDir {
                                            await model.toggleDirectory(row.entry.path, in: folder.id)
                                        } else {
                                            await model.openFile(row.entry.path, in: folder.id)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Space.s)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            InspectorEmptyState(
                systemImage: "sidebar.right",
                title: "No workspace selected",
                subtitle: "Pick a workspace from the list on the left."
            )
        }
    }

    /// One visible row: an entry and how deep it sits.
    private struct Row: Identifiable {
        let entry: TreeEntry
        let depth: Int
        var id: String { entry.path }
    }

    /// Flatten the open parts of the tree into the rows actually on screen.
    ///
    /// A flat array rather than nested views: a view that renders its children
    /// by calling itself cannot have its return type inferred, and a flat list
    /// is what `LazyVStack` needs to skip the rows nobody has scrolled to.
    private func rows(_ roots: [TreeEntry], in folder: WorkspaceFolder) -> [Row] {
        var out: [Row] = []
        func walk(_ entries: [TreeEntry], depth: Int) {
            for entry in entries {
                out.append(Row(entry: entry, depth: depth))
                guard entry.isDir, model.isExpanded(entry.path, in: folder.id) else { continue }
                // Absent means the read is still in flight. Nothing is appended,
                // so the row simply has no children yet.
                if let children = model.children(of: entry.path, in: folder.id) {
                    walk(children, depth: depth + 1)
                }
            }
        }
        walk(roots, depth: 0)
        return out
    }
}

private struct TreeRow: View {
    let entry: TreeEntry
    let depth: Int
    let isExpanded: Bool
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(entry.isDir ? Theme.accent : Color.secondary)
                    .frame(width: 14)
                Text(entry.name)
                    .font(.system(size: 13, weight: isOpen ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            // Ignored entries are dimmed, not hidden: `target/` and a generated
            // project file are things people go looking for.
            .opacity(entry.ignored ? 0.45 : 1)
            .padding(.leading, CGFloat(depth) * 12 + Theme.Space.m)
            .padding(.trailing, Theme.Space.m)
            .padding(.vertical, 3)
            .background(background)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(entry.ignored ? "\(entry.path) (git ignores this)" : entry.path)
    }

    private var symbol: String {
        if entry.isDir { return isExpanded ? "folder.fill" : "folder" }
        return "doc"
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(isOpen ? Theme.rowHighlight : (isHovering ? Theme.rowHighlight.opacity(0.5) : .clear))
            .padding(.horizontal, Theme.Space.xs)
    }
}
