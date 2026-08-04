// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

#if os(macOS)
import AppKit
#endif

/// The tabs of the workspace inspector.
enum InspectorTab: String, CaseIterable, Identifiable, Sendable {
    case changes = "Changes"
    case files = "Files"
    case history = "History"

    var id: String { rawValue }
}

/// The folders the user chose to work in.
///
/// Nothing here reads the usage archive. Workspaces are a separate idea: a
/// folder you want a terminal open in, not a project an agent happened to touch.
@Observable
@MainActor
final class WorkspacesModel {
    var folders: [WorkspaceFolder] = []
    var selectedID: String?
    var isLoading = false
    var errorMessage: String?

    /// Which inspector tab is open.
    ///
    /// Here rather than in the view, because the view is rebuilt every time the
    /// file watcher refreshes the folder list, which during a build is several
    /// times a second. As view state the tab was reset on the next build and
    /// the picker looked like it did nothing at all.
    var inspectorTab: InspectorTab = .changes

    /// Label for an inspector tab, with the count that is the reason to look at
    /// it.
    ///
    /// On the model rather than in the view because the tabs are drawn in the
    /// window toolbar, above the inspector column, while the panel they switch
    /// lives here. Two places needing the same label is what puts a count on one
    /// of them and not the other.
    func inspectorTabTitle(_ tab: InspectorTab) -> String {
        switch tab {
        case .changes:
            let count = selected?.changeCount ?? 0
            return count > 0 ? "Changes (\(count))" : "Changes"
        case .files:
            return "Files"
        case .history:
            return "History"
        }
    }

    /// Recent commits per workspace, keyed by workspace id.
    ///
    /// Loaded when the History tab first asks for one, not with the folder
    /// list. A `git log` is a subprocess, the folder list runs on a file-change
    /// timer, and most of the time nobody is looking at the history.
    private(set) var history: [String: [Commit]] = [:]
    var historyError: String?

    /// Children of each expanded directory, keyed by `workspaceID:relativePath`.
    ///
    /// One directory per entry rather than a whole recursive walk: a monorepo
    /// has hundreds of thousands of files and a tree is only ever open a few
    /// levels deep.
    private(set) var tree: [String: [TreeEntry]] = [:]
    var expandedDirectories: Set<String> = []

    /// Paths the user ticked for the next commit.
    ///
    /// Held per workspace, so switching folders and back does not silently
    /// unstage a selection someone had already made.
    var stagedSelection: [String: Set<String>] = [:]
    var commitMessage: [String: String] = [:]
    /// Result of the last write, for the banner. Cleared on the next attempt.
    var gitOutcome: GitOutcome?
    var isCommitting = false

    /// Files open in the centre pane, per workspace, in the order opened.
    ///
    /// The centre pane holds terminals and files side by side, so opening a
    /// diff does not close the session you were watching. A terminal is where
    /// the work happens and must not be something you lose by looking at a file.
    private(set) var openFiles: [String: [String]] = [:]
    /// The open file being shown, or nil when the pane is showing a terminal.
    private(set) var activeFile: [String: String] = [:]
    private(set) var diffs: [String: FileDiff] = [:]
    /// One document per open file, keyed the same way as the diffs.
    ///
    /// This replaced a pair of dictionaries holding the text and the dirty
    /// paths. Once a file also carries syntax spans, a saved copy, changed-line
    /// marks and an in-flight highlight, keeping them as parallel dictionaries
    /// means five things keyed alike that fall out of step one at a time.
    private(set) var documents: [String: EditorDocument] = [:]
    var editorError: String?

    private static func treeKey(_ workspaceID: String, _ path: String) -> String {
        "\(workspaceID):\(path)"
    }

    // MARK: - The centre pane

    /// The commit open in the centre pane, per workspace.
    ///
    /// A commit takes the pane the same way a file does, but is not in
    /// `openFiles`: there is only ever one, and it is opened by clicking a row
    /// in History rather than accumulated as tabs.
    private(set) var openCommit: [String: CommitDetail] = [:]
    private(set) var loadingCommit: [String: String] = [:]

    /// Read a commit and show it. Replaces whatever the pane was showing.
    func showCommit(_ id: String, in workspaceID: String) async {
        loadingCommit[workspaceID] = id
        activeFile[workspaceID] = nil
        do {
            let detail = try await Bridge.workspaceShow(id: workspaceID, commit: id)
            // The user may have clicked another commit while this was in flight.
            guard loadingCommit[workspaceID] == id else { return }
            openCommit[workspaceID] = detail
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        if loadingCommit[workspaceID] == id { loadingCommit[workspaceID] = nil }
    }

    func closeCommit(in workspaceID: String) {
        openCommit[workspaceID] = nil
        loadingCommit[workspaceID] = nil
    }

    /// Show a file in the centre pane, opening it if it is not already there.
    func openFile(_ path: String, in workspaceID: String) async {
        // A file and a commit are both "what the pane is showing", so opening
        // one puts the other away.
        closeCommit(in: workspaceID)
        var files = openFiles[workspaceID] ?? []
        if !files.contains(path) {
            files.append(path)
            openFiles[workspaceID] = files
        }
        activeFile[workspaceID] = path
        await loadText(path, in: workspaceID)
    }

    /// A close that would lose unsaved work, waiting on the user's answer.
    ///
    /// The alternative was for `closeFile` to discard the buffer, which it did.
    /// Closing a tab is one click away from clicking the tab, and no editor
    /// gets to throw away typing on a mis-click.
    struct PendingClose: Identifiable {
        let workspaceID: String
        let path: String
        var id: String { "\(workspaceID):\(path)" }
    }

    var pendingClose: PendingClose?

    /// Close a file, asking first when it has unsaved changes.
    func requestClose(_ path: String, in workspaceID: String) {
        if isEditorDirty(path, in: workspaceID) {
            pendingClose = PendingClose(workspaceID: workspaceID, path: path)
            return
        }
        closeFile(path, in: workspaceID)
    }

    /// Save the pending file and then close it.
    func saveAndClosePending() async {
        guard let pending = pendingClose else { return }
        pendingClose = nil
        await saveText(pending.path, in: pending.workspaceID)
        // A failed write leaves the document dirty and the error on screen, and
        // closing then would lose exactly what the user asked to keep.
        guard !isEditorDirty(pending.path, in: pending.workspaceID) else { return }
        closeFile(pending.path, in: pending.workspaceID)
    }

    func discardAndClosePending() {
        guard let pending = pendingClose else { return }
        pendingClose = nil
        closeFile(pending.path, in: pending.workspaceID)
    }

    func closeFile(_ path: String, in workspaceID: String) {
        var files = openFiles[workspaceID] ?? []
        files.removeAll { $0 == path }
        openFiles[workspaceID] = files
        if activeFile[workspaceID] == path {
            // Back to the terminal rather than to another file: the terminal is
            // what this pane is mainly for.
            activeFile[workspaceID] = nil
        }
        let key = Self.treeKey(workspaceID, path)
        diffs[key] = nil
        documents[key] = nil
    }

    /// Put the terminal back in front without closing any open file.
    func showTerminal(in workspaceID: String) {
        activeFile[workspaceID] = nil
        closeCommit(in: workspaceID)
    }

    /// True when the pane is showing a terminal rather than a file or a commit.
    func isShowingTerminal(in workspaceID: String) -> Bool {
        activeFile[workspaceID] == nil
            && openCommit[workspaceID] == nil
            && loadingCommit[workspaceID] == nil
    }

    func diff(for path: String, in workspaceID: String) -> FileDiff? {
        diffs[Self.treeKey(workspaceID, path)]
    }

    func document(for path: String, in workspaceID: String) -> EditorDocument? {
        documents[Self.treeKey(workspaceID, path)]
    }

    func isEditorDirty(_ path: String, in workspaceID: String) -> Bool {
        document(for: path, in: workspaceID)?.isDirty ?? false
    }

    /// True when any open file has unsaved changes. Used to warn before an
    /// action that would lose them.
    var hasUnsavedWork: Bool {
        documents.values.contains(where: \.isDirty)
    }

    /// Read a file and open a document for it.
    ///
    /// An already open document is left alone unless it is clean. Re-reading a
    /// file someone has unsaved edits in, because they clicked its tab again,
    /// would throw their work away without asking.
    func loadText(_ path: String, in workspaceID: String) async {
        let key = Self.treeKey(workspaceID, path)
        if let existing = documents[key], existing.isDirty { return }
        do {
            let file = try await Bridge.workspaceRead(id: workspaceID, path: path)
            if let existing = documents[key] {
                existing.adopt(saved: file.content)
            } else {
                let document = EditorDocument(
                    workspaceID: workspaceID, path: path, content: file.content
                )
                documents[key] = document
                document.scheduleHighlight()
            }
            documents[key]?.applyDiff(diffs[key])
            editorError = nil
        } catch {
            editorError = error.localizedDescription
        }
    }

    /// Save only from the editor's own command. File writes never run from a
    /// watcher or a refresh path.
    func saveText(_ path: String, in workspaceID: String) async {
        let key = Self.treeKey(workspaceID, path)
        guard let document = documents[key], document.isDirty else { return }
        do {
            let outcome = try await Bridge.workspaceWrite(
                id: workspaceID, path: path, content: document.text
            )
            guard outcome.ok else {
                editorError = outcome.message
                return
            }
            document.markSaved()
            editorError = nil
            await loadDiff(path, in: workspaceID)
        } catch {
            editorError = error.localizedDescription
        }
    }

    func loadDiff(_ path: String, in workspaceID: String) async {
        let key = Self.treeKey(workspaceID, path)
        do {
            let diff = try await Bridge.workspaceDiff(id: workspaceID, path: path)
            diffs[key] = diff
            // The editor's gutter marks come from the same diff the Changes
            // panel shows, so the two cannot disagree about what changed.
            documents[key]?.applyDiff(diff)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-read the diffs of files that are open. Called after the working tree
    /// changed, so a diff on screen is never stale.
    func refreshOpenDiffs() async {
        for (workspaceID, paths) in openFiles {
            for path in paths where diffs[Self.treeKey(workspaceID, path)] != nil {
                await loadDiff(path, in: workspaceID)
            }
        }
    }

    /// Pick up changes an agent made to a file that is open here.
    ///
    /// This is the ordinary case rather than an edge one: the whole point of
    /// the app is that a session is editing the same repository. A document
    /// with unsaved changes is left alone, because `loadText` refuses to
    /// overwrite one, and the two edits are a conflict only a person can settle.
    func refreshOpenDocuments() async {
        for document in documents.values where !document.isDirty {
            await loadText(document.path, in: document.workspaceID)
        }
    }

    #if os(macOS)
    private var watcher: WorkspaceFileWatcher?
    private var refreshTask: Task<Void, Never>?
    #endif

    var selected: WorkspaceFolder? {
        folders.first { $0.id == selectedID }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            folders = try await Bridge.workspaces()
            errorMessage = nil
            // A folder removed elsewhere should not leave the detail pane
            // describing something that is no longer in the list.
            if let id = selectedID, !folders.contains(where: { $0.id == id }) {
                selectedID = folders.first?.id
            }
            if selectedID == nil { selectedID = folders.first?.id }
            #if os(macOS)
            syncWatcher()
            #endif
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #if os(macOS)
    /// Point the file watcher at the current folders.
    ///
    /// Creates the watcher once and re-points it after that, so a refresh does
    /// not tear the stream down. Watching nothing is a valid state: no folders
    /// registered, or all of them missing.
    private func syncWatcher() {
        if let watcher {
            watcher.watch(folders.map(\.path))
        } else {
            let watcher = WorkspaceFileWatcher(model: self)
            self.watcher = watcher
            watcher.watch(folders.map(\.path))
        }
    }

    /// Refresh after files changed, once they quiet down.
    ///
    /// A save lands as a burst of events, and a build writes continuously, so
    /// the refresh runs when the stream settles rather than once per event.
    /// Without the debounce a `cargo build` would turn into a git status a
    /// second.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }
    #endif

    /// Re-read git for the folders already registered.
    ///
    /// Separate from `load` only in intent: both call the same method, because
    /// the host reads git as part of listing. Kept as its own name so call
    /// sites read as what they mean.
    func refresh() async {
        await load()
        // Only histories somebody has already opened. Loading one nobody asked
        // for would put a `git log` behind every file save.
        for id in history.keys {
            await loadHistory(for: id)
        }
        // A diff on screen must not go stale while the file changes underneath,
        // and neither must the file itself: an agent running in the terminal
        // beside this pane edits the same repository.
        await refreshOpenDiffs()
        await refreshOpenDocuments()
    }

    /// Read the recent commits for a workspace.
    ///
    /// Keeps whatever was already loaded when the read fails, so a transient
    /// error empties the panel's error line rather than the panel.
    func loadHistory(for id: String) async {
        do {
            history[id] = try await Bridge.workspaceLog(id: id)
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }

    // MARK: - File tree

    func children(of path: String, in workspaceID: String) -> [TreeEntry]? {
        tree[Self.treeKey(workspaceID, path)]
    }

    func isExpanded(_ path: String, in workspaceID: String) -> Bool {
        expandedDirectories.contains(Self.treeKey(workspaceID, path))
    }

    /// Open or close a directory, reading it the first time it is opened.
    func toggleDirectory(_ path: String, in workspaceID: String) async {
        let key = Self.treeKey(workspaceID, path)
        if expandedDirectories.contains(key) {
            expandedDirectories.remove(key)
            return
        }
        expandedDirectories.insert(key)
        if tree[key] == nil {
            await loadTree(path, in: workspaceID)
        }
    }

    func loadTree(_ path: String, in workspaceID: String) async {
        do {
            tree[Self.treeKey(workspaceID, path)] = try await Bridge.workspaceTree(
                id: workspaceID, path: path
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-read every directory currently open. Called after a commit, when what
    /// is on disk has changed under the tree.
    func refreshTree() async {
        for key in tree.keys {
            guard let separator = key.firstIndex(of: ":") else { continue }
            let workspaceID = String(key[key.startIndex ..< separator])
            let path = String(key[key.index(after: separator)...])
            await loadTree(path, in: workspaceID)
        }
    }

    // MARK: - Staging and committing

    func isStaged(_ path: String, in workspaceID: String) -> Bool {
        stagedSelection[workspaceID]?.contains(path) ?? false
    }

    func toggleStaged(_ path: String, in workspaceID: String) {
        var set = stagedSelection[workspaceID] ?? []
        if set.contains(path) { set.remove(path) } else { set.insert(path) }
        stagedSelection[workspaceID] = set
    }

    func setAllStaged(_ staged: Bool, in folder: WorkspaceFolder) {
        stagedSelection[folder.id] = staged
            ? Set((folder.git?.files ?? []).map(\.path))
            : []
    }

    /// Stage the ticked paths and commit them.
    ///
    /// Stage and commit in one action rather than two buttons: the index is not
    /// a thing this panel exposes, so leaving a half-staged repository behind
    /// would be a state the user never asked for and cannot see. A failure at
    /// either step stops and reports git's own words.
    func commit(_ folder: WorkspaceFolder) async {
        let paths = Array(stagedSelection[folder.id] ?? [])
        let message = (commitMessage[folder.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paths.isEmpty else {
            gitOutcome = GitOutcome(ok: false, message: "Tick at least one file to commit.")
            return
        }
        guard !message.isEmpty else {
            gitOutcome = GitOutcome(ok: false, message: "A commit needs a message.")
            return
        }

        isCommitting = true
        defer { isCommitting = false }
        do {
            let staged = try await Bridge.stage(id: folder.id, paths: paths)
            guard staged.ok else {
                gitOutcome = staged
                return
            }
            let committed = try await Bridge.commit(id: folder.id, message: message)
            gitOutcome = committed
            guard committed.ok else { return }
            stagedSelection[folder.id] = []
            commitMessage[folder.id] = ""
            await refresh()
            await loadHistory(for: folder.id)
        } catch {
            gitOutcome = GitOutcome(ok: false, message: error.localizedDescription)
        }
    }

    func push(_ folder: WorkspaceFolder) async {
        isCommitting = true
        defer { isCommitting = false }
        do {
            gitOutcome = try await Bridge.push(id: folder.id)
            await refresh()
            await loadHistory(for: folder.id)
        } catch {
            gitOutcome = GitOutcome(ok: false, message: error.localizedDescription)
        }
    }

    #if os(macOS)
    /// Ask for a folder and register it.
    ///
    /// `NSOpenPanel` rather than a text field: the user is picking something
    /// that must exist, and a path typed by hand is a path typed wrong.
    func addFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Workspace"
        panel.message = "Choose a project folder. tokenstat only reads it."

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                let added = try await Bridge.addWorkspace(path: url.path)
                selectedID = added.id
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await load()
    }
    #endif

    /// Forget a folder. The folder itself is never touched.
    func remove(_ folder: WorkspaceFolder) async {
        do {
            try await Bridge.removeWorkspace(id: folder.id)
            if selectedID == folder.id { selectedID = nil }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ folder: WorkspaceFolder, to name: String) async {
        do {
            try await Bridge.renameWorkspace(id: folder.id, name: name)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #if os(macOS)
    /// Reveal in Finder. A hand-off, not a replacement: tokenstat is not a
    /// file manager.
    func revealInFinder(_ folder: WorkspaceFolder) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }
    #endif
}

/// Changed files grouped by the directory they sit in, as the reference layout
/// shows them. Directories in the order their first file appears, so the
/// busiest part of a change set stays at the top.
func groupByDirectory(_ files: [FileChange]) -> [(directory: String, files: [FileChange])] {
    var order: [String] = []
    var groups: [String: [FileChange]] = [:]
    for file in files {
        if groups[file.directory] == nil { order.append(file.directory) }
        groups[file.directory, default: []].append(file)
    }
    return order.map { ($0, groups[$0] ?? []) }
}
