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

/// Per-workspace settings, remembered on this machine.
///
/// Keyed by workspace id so the same folder keeps its choices across launches.
enum WorkspacePreference {
    private static let bypassKey = "workspace.bypassPermissions"

    static func bypassPermissions(for workspaceID: String) -> Bool {
        UserDefaults.standard.bool(forKey: "\(bypassKey).\(workspaceID)")
    }

    static func setBypassPermissions(_ on: Bool, for workspaceID: String) {
        UserDefaults.standard.set(on, forKey: "\(bypassKey).\(workspaceID)")
    }
}

extension Notification.Name {
    /// A peer connection succeeded, so its folders can be fetched now instead
    /// of waiting for the 60-second peer sweep.
    static let remotePeerDidConnect = Notification.Name("tokenstat.remotePeerDidConnect")
}

/// The tabs of the workspace inspector.
enum InspectorTab: String, CaseIterable, Identifiable, Sendable {
    case files = "Files"
    case changes = "Changes"
    case history = "History"

    var id: String { rawValue }
}

/// A browser tab kept with its workspace, not with the window.
struct WorkspaceBrowserTab: Identifiable, Hashable, Sendable {
    let id: String
    var url: String
    var number: Int
    var title: String { "Browser \(number)" }
}

/// The folders the user chose to work in.
///
/// Nothing here reads the usage archive. Workspaces are a separate idea: a
/// folder you want a terminal open in, not a project an agent happened to touch.
@Observable
@MainActor
final class WorkspacesModel {
    /// Bypass-permission preference per workspace, mirrored from UserDefaults.
    ///
    /// Kept as observable state so the checkbox reflects a click immediately:
    /// a binding straight into `UserDefaults` has no way to tell the view the
    /// value changed. Persistence still happens on every write.
    private(set) var bypassPermissions: [String: Bool] = [:]

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
    var inspectorTab: InspectorTab = .files

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
    var commitDescription: [String: String] = [:]
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
    private(set) var browserTabs: [String: [WorkspaceBrowserTab]] = [:]
    private(set) var activeBrowserID: [String: String] = [:]
    /// Folders whose centre pane is showing the launch surface, even though
    /// sessions may already be running underneath it.
    private(set) var showingLauncher: Set<String> = []
    private(set) var filesShown: Set<String> = []
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
    private(set) var reviewingWorkingTree: Set<String> = []

    /// Read a commit and show it. Replaces whatever the pane was showing.
    func showCommit(_ id: String, in workspaceID: String) async {
        loadingCommit[workspaceID] = id
        activeFile[workspaceID] = nil
        reviewingWorkingTree.remove(workspaceID)
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

    func reviewWorkingTree(in workspaceID: String) {
        exitLauncher(in: workspaceID)
        activeFile[workspaceID] = nil
        activeBrowserID[workspaceID] = nil
        filesShown.remove(workspaceID)
        closeCommit(in: workspaceID)
        reviewingWorkingTree.insert(workspaceID)
    }

    func closeWorkingTreeReview(in workspaceID: String) {
        reviewingWorkingTree.remove(workspaceID)
    }

    /// Show a file in the centre pane, opening it if it is not already there.
    func openFile(_ path: String, in workspaceID: String) async {
        // A file and a commit are both "what the pane is showing", so opening
        // one puts the other away.
        exitLauncher(in: workspaceID)
        closeCommit(in: workspaceID)
        reviewingWorkingTree.remove(workspaceID)
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
        exitLauncher(in: workspaceID)
        activeFile[workspaceID] = nil
        activeBrowserID[workspaceID] = nil
        filesShown.remove(workspaceID)
        closeCommit(in: workspaceID)
        reviewingWorkingTree.remove(workspaceID)
    }

    func browserTabs(in workspaceID: String) -> [WorkspaceBrowserTab] {
        browserTabs[workspaceID] ?? []
    }

    /// Open a new browser tab, or select an existing one when an id is given.
    @discardableResult
    func showBrowser(in workspaceID: String, id: String? = nil) -> WorkspaceBrowserTab {
        exitLauncher(in: workspaceID)
        activeFile[workspaceID] = nil
        filesShown.remove(workspaceID)
        closeCommit(in: workspaceID)
        reviewingWorkingTree.remove(workspaceID)
        if let id, let tab = browserTabs[workspaceID]?.first(where: { $0.id == id }) {
            activeBrowserID[workspaceID] = id
            return tab
        }
        let tabs = browserTabs[workspaceID] ?? []
        let tab = WorkspaceBrowserTab(
            id: UUID().uuidString,
            url: "",
            number: tabs.count + 1
        )
        browserTabs[workspaceID] = tabs + [tab]
        activeBrowserID[workspaceID] = tab.id
        return tab
    }

    func closeBrowser(_ tab: WorkspaceBrowserTab, in workspaceID: String) {
        browserTabs[workspaceID]?.removeAll { $0.id == tab.id }
        guard activeBrowserID[workspaceID] == tab.id else { return }
        activeBrowserID[workspaceID] = browserTabs[workspaceID]?.last?.id
    }

    func setBrowserURL(_ url: String, in workspaceID: String, tabID: String) {
        guard let index = browserTabs[workspaceID]?.firstIndex(where: { $0.id == tabID }) else { return }
        browserTabs[workspaceID]?[index].url = url
    }

    func showFiles(in workspaceID: String) {
        exitLauncher(in: workspaceID)
        activeFile[workspaceID] = nil
        activeBrowserID[workspaceID] = nil
        filesShown.insert(workspaceID)
        closeCommit(in: workspaceID)
    }

    func closeFiles(in workspaceID: String) {
        filesShown.remove(workspaceID)
    }

    /// Leave the launch surface. Called by every surface switch; kept separate
    /// so the flag cannot silently survive a navigation that put something
    /// else in front of it.
    func exitLauncher(in workspaceID: String) {
        showingLauncher.remove(workspaceID)
    }

    /// Second click on a folder: swap between the running surface and the
    /// launcher, so a new agent can be started without hiding the sessions
    /// that are already there.
    func toggleLauncher(in workspaceID: String) {
        if showingLauncher.contains(workspaceID) {
            showTerminal(in: workspaceID)
        } else {
            showingLauncher.insert(workspaceID)
        }
    }

    /// True when the pane is showing a terminal rather than a file or a commit.
    func isShowingTerminal(in workspaceID: String) -> Bool {
        activeFile[workspaceID] == nil
            && activeBrowserID[workspaceID] == nil
            && !filesShown.contains(workspaceID)
            && openCommit[workspaceID] == nil
            && loadingCommit[workspaceID] == nil
            && !reviewingWorkingTree.contains(workspaceID)
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

    /// This machine's folders, as the host last reported them.
    private var localFolders: [WorkspaceFolder] = []
    /// Remote folders by peer key, so the list can be refreshed without
    /// re-dialling every peer on every file change.
    private var remoteFolders: [String: [WorkspaceFolder]] = [:]
    /// When each peer may be dialled again, whether the last dial worked or
    /// not. A single failure keeps the last known folders (the peer may just
    /// be reconnecting), and a live one is not re-dialled at the rate files
    /// change; after enough consecutive failures the folders leave the list.
    private var remotePeerNextDial: [String: Date] = [:]
    /// Consecutive dial failures per peer. One failure is a reconnect and the
    /// last-known folders stay; a machine that keeps failing is gone, and its
    /// folders must not linger in the sidebar pretending to be reachable.
    private var remotePeerFailures: [String: Int] = [:]

    /// Everything: this machine's folders and every reachable peer's.
    ///
    /// The full version, for opening the screen and for an explicit refresh.
    /// The file watcher does **not** call this, see `refresh()`.
    func load() async {
        await loadLocal()
        await loadRemote()
    }

    /// This machine's registered folders, with their git state.
    ///
    /// One host call. Cheap enough to run whenever files change, which is what
    /// separates it from `loadRemote`.
    func loadLocal() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await Bridge.workspaces()
            localFolders = loaded
            publishFolders()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Folders on other machines, read through the local daemon.
    ///
    /// Deliberately not part of the file-watcher path. Every peer here is a TCP
    /// dial with a connect timeout and a handshake, and this used to run inside
    /// `load()` on every debounced file change: an agent writing files in a
    /// terminal had the app dialling every paired machine roughly twice a
    /// second. A peer's folder list does not change that fast, and a machine
    /// being asleep is not news worth re-learning at that rate.
    ///
    /// A peer that is offline does not make local folders disappear: its
    /// failure is remembered rather than raised, and its last known folders
    /// stay listed.
    func loadRemote() async {
        do {
            // A peer without an address is dialled through the tunnel, which is
            // how same-account machines behind NAT are reached. The sweep must
            // include those peers when this machine's tunnel is on, or a
            // successfully connected machine never appears in the sidebar.
            let tunnelOn = (try? await Bridge.remoteStatus())?.tunnel == true
            let peers = try await Bridge.peers().filter {
                $0.trust == .approved && ($0.address?.isEmpty == false || tunnelOn)
            }
            let liveKeys = Set(peers.map(\.key))
            for key in remoteFolders.keys where !liveKeys.contains(key) {
                remoteFolders.removeValue(forKey: key)
                remotePeerFailures.removeValue(forKey: key)
            }
            for peer in peers {
                if let nextDial = remotePeerNextDial[peer.key], Date() < nextDial { continue }
                do {
                    remoteFolders[peer.key] = try await Bridge.remoteWorkspaces(peer: peer)
                    remotePeerNextDial[peer.key] = Date().addingTimeInterval(Self.peerRefreshSeconds)
                    remotePeerFailures[peer.key] = 0
                } catch {
                    remotePeerNextDial[peer.key] = Date().addingTimeInterval(Self.peerRetrySeconds)
                    let failures = (remotePeerFailures[peer.key] ?? 0) + 1
                    remotePeerFailures[peer.key] = failures
                    if failures >= Self.maxPeerFailures {
                        remoteFolders.removeValue(forKey: peer.key)
                    }
                }
            }
            publishFolders()
        } catch {
            // Not surfaced. The peer list failing is not a reason to put an
            // error over a screen full of working local folders.
        }
    }

    /// Keep peer folders current while the app is open.
    ///
    /// A slow loop of its own, because the thing that used to keep them current
    /// was the file watcher, and that made a save on this machine dial every
    /// other machine. Runs from the root view's `.task`, so it stops when the
    /// window does.
    func watchPeers() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.peerRefreshSeconds))
            guard !Task.isCancelled else { return }
            await loadRemote()
        }
    }

    /// How long a peer that answered is left alone before being asked again.
    private static let peerRefreshSeconds: TimeInterval = 60
    /// How long a peer that did not answer is left alone. Shorter, because a
    /// machine waking up should show up reasonably soon.
    private static let peerRetrySeconds: TimeInterval = 30
    /// Consecutive failures before a peer's folders leave the sidebar.
    private static let maxPeerFailures = 2

    /// Put local and remote folders together and keep the selection valid.
    private func publishFolders() {
        folders = localFolders + remoteFolders.values.flatMap { $0 }
        // A folder removed elsewhere should not leave the detail pane
        // describing something that is no longer in the list.
        if let id = selectedID, !folders.contains(where: { $0.id == id }) {
            selectedID = folders.first?.id
        }
        if selectedID == nil { selectedID = folders.first?.id }
        #if os(macOS)
        syncWatcher()
        #endif
    }

    #if os(macOS)
    /// Point the file watcher at the current folders.
    ///
    /// Creates the watcher once and re-points it after that, so a refresh does
    /// not tear the stream down. Watching nothing is a valid state: no folders
    /// registered, or all of them missing.
    private func syncWatcher() {
        if let watcher {
            watcher.watch(folders.filter { !$0.isRemote }.map(\.path))
        } else {
            let watcher = WorkspaceFileWatcher(model: self)
            self.watcher = watcher
            watcher.watch(folders.filter { !$0.isRemote }.map(\.path))
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
    /// The file watcher's path, so it is local only. Peers are on their own
    /// slower schedule in `loadRemote`, because dialling every paired machine
    /// is not something a file save should cause.
    func refresh() async {
        await loadLocal()
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
        let title = (commitMessage[folder.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (commitDescription[folder.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let message = description.isEmpty ? title : "\(title)\n\n\(description)"
        guard !paths.isEmpty else {
            gitOutcome = GitOutcome(ok: false, message: "Tick at least one file to commit.")
            return
        }
        guard !title.isEmpty else {
            gitOutcome = GitOutcome(ok: false, message: "A commit needs a title.")
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
            commitDescription[folder.id] = ""
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
    /// Whether the onboarding sheet that explains workspaces is up.
    ///
    /// The sheet, not the folder panel, is the entry point: a raw `NSOpenPanel`
    /// gives a new user no idea what they are being asked to pick or why.
    var isAddSheetPresented = false

    /// Open the onboarding sheet. Every "Add workspace" affordance funnels
    /// through here so the explanation is never skipped.
    func requestAdd() {
        isAddSheetPresented = true
    }

    func bypassPermissions(for workspaceID: String) -> Bool {
        bypassPermissions[workspaceID] ?? WorkspacePreference.bypassPermissions(for: workspaceID)
    }

    func setBypassPermissions(_ on: Bool, for workspaceID: String) {
        bypassPermissions[workspaceID] = on
        WorkspacePreference.setBypassPermissions(on, for: workspaceID)
    }

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
