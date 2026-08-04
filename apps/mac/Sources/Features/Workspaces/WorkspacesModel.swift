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

    private static func treeKey(_ workspaceID: String, _ path: String) -> String {
        "\(workspaceID):\(path)"
    }

    // MARK: - The centre pane

    /// Show a file in the centre pane, opening it if it is not already there.
    func openFile(_ path: String, in workspaceID: String) async {
        var files = openFiles[workspaceID] ?? []
        if !files.contains(path) {
            files.append(path)
            openFiles[workspaceID] = files
        }
        activeFile[workspaceID] = path
        await loadDiff(path, in: workspaceID)
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
        diffs[Self.treeKey(workspaceID, path)] = nil
    }

    /// Put the terminal back in front without closing any open file.
    func showTerminal(in workspaceID: String) {
        activeFile[workspaceID] = nil
    }

    func diff(for path: String, in workspaceID: String) -> FileDiff? {
        diffs[Self.treeKey(workspaceID, path)]
    }

    func loadDiff(_ path: String, in workspaceID: String) async {
        do {
            diffs[Self.treeKey(workspaceID, path)] = try await Bridge.workspaceDiff(
                id: workspaceID, path: path
            )
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
        // A diff on screen must not go stale while the file changes underneath.
        await refreshOpenDiffs()
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
