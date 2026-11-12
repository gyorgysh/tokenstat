// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

/// A roomy, commit-style review of the current working tree.
struct WorkingTreeReviewView: View {
    let folder: WorkspaceFolder
    @Bindable var model: WorkspacesModel
    var isActive = true

    @State private var diffs: [FileDiff] = []
    @State private var loading = true
    @State private var error: String?
    @State private var loadGeneration = 0

    private var files: [FileChange] { folder.git?.files ?? [] }

    private var focus: WorkspacesModel.ChangeFocus? {
        model.workingTreeReviewFocus.flatMap { $0.folderID == folder.id ? $0 : nil }
    }

    @State private var selectedPath: String?

    private var selectedFile: FileChange? {
        let path = ChangePathMatch.reviewSelection(selectedPath, focus: focus?.path, paths: files.map(\.path))
        return files.first { $0.path == path }
    }

    /// Identity of the work to review: the folder and the change set. A save,
    /// an agent edit, or a commit changes it and reloads the diffs.
    private struct ReviewKey: Equatable {
        let folderID: String
        let file: FileChange?
        let revision: UInt64
    }

    private var reviewKey: ReviewKey {
        ReviewKey(folderID: folder.id, file: selectedFile, revision: model.diffRefreshRevisions[folder.id] ?? 0)
    }

    private var selectedDiff: FileDiff? {
        guard let path = selectedFile?.path else { return nil }
        return diffs.first { $0.path == path }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if files.isEmpty {
                InspectorEmptyState(
                    systemImage: "checkmark.seal",
                    title: L10n.text("apple.workingtreereviewview.no_changes_to_review.e964b314"),
                    subtitle: L10n.text("apple.workingtreereviewview.the_working_tree_is_clean.84230b1f")
                )
            } else {
                ReviewFileBrowser(
                    files: files.map { ReviewFileChoice(path: $0.path, added: $0.added, removed: $0.removed) },
                    selection: Binding(get: { selectedFile?.path }, set: { path in
                        if selectedFile?.path != path { loading = true; error = nil }
                        selectedPath = path
                    })
                ) {
                    VStack(spacing: 0) {
                        if let error {
                            ErrorBanner(message: error) { Task { await load() } }
                        }
                        if let file = selectedFile {
                            ReviewFileHeading(path: file.path)
                            if let diff = selectedDiff {
                                DiffDocumentView(diffs: [diff], fileHeaders: false) { EmptyView() }
                                    .id("\(file.path):\(focus?.generation ?? 0)")
                            } else if loading {
                                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                InspectorEmptyState(systemImage: "exclamationmark.circle",
                                    title: L10n.text("apple.workingtreereviewview.could_not_load_changes.07be1deb"),
                                    subtitle: file.path, tint: Theme.danger)
                            }
                        }
                    }
                }
                .onChange(of: focus?.generation, initial: true) { _, _ in
                    if let focus, let path = ChangePathMatch.path(focus.path, in: files.map(\.path)) {
                        if selectedFile?.path != path { loading = true; error = nil }
                        selectedPath = path
                    }
                }
                .onChange(of: files.map(\.path)) { _, paths in
                    if let selectedPath, !paths.contains(selectedPath) {
                        loading = true
                        error = nil
                        self.selectedPath = ChangePathMatch.reviewSelection(nil, focus: focus?.path, paths: paths)
                    }
                }
            }
        }
        .background(Theme.background)
        .task(id: isActive ? reviewKey : nil) {
            if isActive { await load() }
        }
        .task(id: isActive ? selectedDiff?.renderRevision : nil) {
            guard isActive, let diff = selectedDiff else { return }
            await WorkViewedChange.save(owner: WorkViewedChange.owner(folderID: folder.id), diff: diff)
        }
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
                    if git.hasLineChanges {
                        Text("+\(git.added)").foregroundStyle(Theme.success)
                        Text("−\(git.removed)").foregroundStyle(Theme.danger)
                    }
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
        guard let path = selectedFile?.path else {
            diffs = []
            loading = false
            return
        }
        let folderID = folder.id
        model.retainDiffPreview(path, in: folderID)
        defer { model.releaseDiffPreview(path, in: folderID) }
        let loaded = await model.loadDiff(path, in: folderID)
        guard !Task.isCancelled, generation == loadGeneration else { return }
        let refreshed = model.diff(for: path, in: folderID).map { [$0] } ?? []
        // Keep the row identity when a refresh found the same content.
        if diffs != refreshed { diffs = refreshed }
        if !loaded {
            error = L10n.text("apple.workingtreereviewview.could_not_refresh_0_file_s_available_chang.89fdefb0", "1")
        }
        loading = false
    }
}

/// The same file navigator for current Git changes and recorded turn edits.
struct ReviewFileChoice: Identifiable {
    let path: String
    let added: UInt64?
    let removed: UInt64?
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

struct ReviewFileHeading: View {
    let path: String
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "doc.text").foregroundStyle(Theme.accent)
            Text(path).font(Theme.mono(11)).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled).help(path)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
    }
}

struct ReviewFileBrowser<Detail: View>: View {
    let files: [ReviewFileChoice]
    @Binding var selection: String?
    @ViewBuilder var detail: () -> Detail
    /// The list's width is the person's to set, and is kept between launches.
    @AppStorage("reviewFileListWidth") private var listWidth: Double = 220
    @State private var dragStart: Double?
    @State private var cursorPushed = false

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 560 {
                HStack(spacing: 0) {
                    fileList.frame(width: clamped(listWidth, in: geometry.size.width))
                    divider(in: geometry.size.width)
                    detail().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    Menu {
                        ForEach(files) { file in
                            Button(file.path) { selection = file.path }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "doc.on.doc")
                            Text(files.first(where: { $0.path == selection })?.name ?? L10n.text("common.files"))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text("\(files.count)").foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down").font(Theme.caption)
                        }
                        .padding(Theme.Space.s).contentShape(.rect)
                    }
                    .menuStyle(.borderlessButton)
                    ThemeRule()
                    detail().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func clamped(_ width: Double, in total: CGFloat) -> CGFloat {
        CGFloat(min(max(width, 160), max(160, min(420, Double(total) * 0.5))))
    }

    /// A one point rule with a wider grab area, so the list can be resized.
    private func divider(in total: CGFloat) -> some View {
        Rectangle().fill(Theme.border).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 9).contentShape(.rect)
                    #if os(macOS)
                    .onHover { inside in
                        if inside, !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
                        if !inside { popCursor() }
                    }
                    // A layout change or a closed tab never reports the
                    // pointer leaving, so the cursor would stay a resize arrow.
                    .onDisappear { popCursor() }
                    #endif
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStart ?? listWidth
                            dragStart = start
                            listWidth = Double(clamped(start + value.translation.width, in: total))
                        }
                        .onEnded { _ in dragStart = nil })
            }
    }

    private func popCursor() {
        #if os(macOS)
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        #endif
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("common.files")).font(Theme.caption.weight(.semibold))
                Spacer()
                Text("\(files.count)").font(Theme.caption).foregroundStyle(.secondary)
            }
            .padding(Theme.Space.s)
            ThemeRule()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(files) { file in
                        HStack(alignment: .center, spacing: 0) {
                            Button { selection = file.path } label: {
                                HStack(alignment: .top, spacing: Theme.Space.s) {
                                    Image(systemName: "doc.text").foregroundStyle(Theme.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name.isEmpty ? file.path : file.name)
                                            .font(Theme.font(12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                        if !file.directory.isEmpty && file.directory != "." {
                                            Text(file.directory).font(Theme.caption2).foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.middle)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if let added = file.added, let removed = file.removed, added > 0 || removed > 0 {
                                        DiffStat(added: Int(clamping: added), removed: Int(clamping: removed), font: Theme.numeric(10))
                                    }
                                }
                                .padding(Theme.Space.s)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help(file.path)
                            .accessibilityAddTraits(selection == file.path ? [.isSelected] : [])
                        }
                        .background(selection == file.path ? Theme.accentSoft : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                }.padding(Theme.Space.xs)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }
}
