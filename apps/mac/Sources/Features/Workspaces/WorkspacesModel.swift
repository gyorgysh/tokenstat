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
    private static let localModelKey = "workspace.localModel"
    /// Sidebar order for the merged local and remote list.
    private static let orderKey = "workspace.order"
    /// The centre pane's open tabs, per workspace.
    private static let tabsKey = "workspace.tabs"

    static func bypassPermissions(for workspaceID: String) -> Bool {
        UserDefaults.standard.bool(forKey: "\(bypassKey).\(workspaceID)")
    }

    static func setBypassPermissions(_ on: Bool, for workspaceID: String) {
        UserDefaults.standard.set(on, forKey: "\(bypassKey).\(workspaceID)")
    }

    static func localModel(for workspaceID: String) -> String? {
        UserDefaults.standard.string(forKey: "\(localModelKey).\(workspaceID)")
    }

    static func setLocalModel(_ key: String?, for workspaceID: String) {
        let defaults = UserDefaults.standard
        let fullKey = "\(localModelKey).\(workspaceID)"
        if let key, !key.isEmpty {
            defaults.set(key, forKey: fullKey)
        } else {
            defaults.removeObject(forKey: fullKey)
        }
    }

    static func order() -> [String] {
        UserDefaults.standard.stringArray(forKey: orderKey) ?? []
    }

    static func setOrder(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: orderKey)
    }

    /// The tabs a workspace was left with, as `WorkspaceSurface` ids.
    ///
    /// Furniture, so it lives here rather than in the daemon: which tab a
    /// window is showing is that window's business and not something another
    /// machine should learn on sync.
    static func tabs(for workspaceID: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: "\(tabsKey).\(workspaceID)") ?? []
    }

    static func setTabs(_ ids: [String], for workspaceID: String) {
        let key = "\(tabsKey).\(workspaceID)"
        if ids.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(ids, forKey: key)
        }
    }
}

extension Notification.Name {
    /// A peer connection succeeded, so its folders can be fetched now instead
    /// of waiting for the 60-second peer sweep.
    static let remotePeerDidConnect = Notification.Name("tokenstat.remotePeerDidConnect")
    /// A peer's workspaces were explicitly disconnected, so its folders leave
    /// the sidebar now instead of after the failure sweep notices.
    static let remotePeerDidDisconnect = Notification.Name("tokenstat.remotePeerDidDisconnect")
    /// A previously connected peer stopped answering. UI should drop the
    /// Connected state, but must **not** suppress re-dial the way Disconnect
    /// does: a machine that sleeps and wakes should come back on the next sweep.
    static let remotePeerBecameUnreachable = Notification.Name("tokenstat.remotePeerBecameUnreachable")
}

/// The tabs of the workspace inspector.
enum InspectorTab: String, CaseIterable, Identifiable, Sendable {
    case files = "Files"
    case changes = "Changes"
    case history = "History"

    var id: String { rawValue }
}

/// One thing the centre pane can show.
///
/// One value in front, one ordered strip behind it. A surface cannot be put
/// in front without also being in the strip. Chips are for documents only.
enum WorkspaceSurface: Hashable, Identifiable, Sendable {
    /// The terminal stack. Which session is `TerminalsModel`'s business.
    case sessions
    /// The launch grid, over the sessions rather than beside them.
    case launcher
    case files
    case file(String)
    case commit(String)
    case changes
    case browser(String)

    var id: String {
        switch self {
        case .sessions: return "sessions"
        case .launcher: return "launcher"
        case .files: return "files"
        case .changes: return "changes"
        case let .file(path): return "file:\(path)"
        case let .commit(commit): return "commit:\(commit)"
        case let .browser(browser): return "browser:\(browser)"
        }
    }

    /// Rebuild a surface from its `id`. Unknown text is not a surface, which
    /// is how a tab written by a later version is skipped rather than crashed
    /// on.
    init?(id: String) {
        switch id {
        case "sessions": self = .sessions
        case "launcher": self = .launcher
        case "files": self = .files
        case "changes": self = .changes
        default:
            guard let split = id.firstIndex(of: ":") else { return nil }
            let value = String(id[id.index(after: split)...])
            guard !value.isEmpty else { return nil }
            switch id[..<split] {
            case "file": self = .file(value)
            case "commit": self = .commit(value)
            case "browser": self = .browser(value)
            default: return nil
            }
        }
    }

    /// Whether this surface carries a chip in the tab strip.
    ///
    /// Sessions and the launcher do not. The strip is where the sessions
    /// already are, and the launcher is a mode over them rather than a
    /// document beside them.
    var isTab: Bool {
        switch self {
        case .sessions, .launcher: return false
        default: return true
        }
    }
}

/// A browser tab kept with its workspace, not with the window.
struct WorkspaceBrowserTab: Identifiable, Hashable, Sendable {
    let id: String
    var url: String
    var number: Int
    var peer: String?
    var port: Int?
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
    /// Local model selection per workspace, same reason as bypass: a value
    /// that lives only in `UserDefaults` or in view `@State` does not survive
    /// the folder-list refresh, so the picker looked like it did nothing
    /// until the user left Workspaces and came back.
    private(set) var localModels: [String: String] = [:]

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
    /// Last Auto commit backend / model picked per folder.
    var autoCommitBackend: [String: String] = [:]
    var autoCommitModel: [String: String] = [:]
    /// Result of the last write, for the banner. Cleared on the next attempt.
    var gitOutcome: GitOutcome?
    var isCommitting = false

    /// What each workspace has open beside its terminals, in the order opened.
    ///
    /// The centre pane holds terminals and documents side by side, so opening
    /// a diff does not close the session you were watching. A terminal is
    /// where the work happens and must not be something you lose by looking at
    /// a file.
    private(set) var tabs: [String: [WorkspaceSurface]] = [:]
    /// What is actually on screen per workspace. Absent means `.sessions`.
    private(set) var front: [String: WorkspaceSurface] = [:]
    /// Payload for `.browser` surfaces: the url, and the forwarded peer port
    /// when the page lives on another machine.
    private(set) var browserTabs: [String: [WorkspaceBrowserTab]] = [:]
    /// What another machine says its folders are holding, keyed by the
    /// prefixed id this side uses.
    ///
    /// Only remote folders are in here. A local folder's counts come from the
    /// models this app is already polling, which are instant and free; a
    /// remote folder's are not knowable without asking, which is why the
    /// sidebar drew no task, workflow or automation badge on one at all.
    private(set) var summaries: [String: WorkspaceSummary] = [:]
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

    /// Loaded commits, keyed workspace and commit, for the `.commit` surface.
    private(set) var commits: [String: CommitDetail] = [:]
    /// The commit whose read is in flight, per workspace.
    private(set) var loadingCommit: [String: String] = [:]
    /// Why a commit failed to load, keyed the same way as `commits`.
    private(set) var commitErrors: [String: String] = [:]

    /// This workspace's strip, in the order the tabs were opened.
    func tabs(in workspaceID: String) -> [WorkspaceSurface] { tabs[workspaceID] ?? [] }

    /// What this workspace's centre pane is showing.
    func front(in workspaceID: String) -> WorkspaceSurface { front[workspaceID] ?? .sessions }

    func isFront(_ surface: WorkspaceSurface, in workspaceID: String) -> Bool {
        front(in: workspaceID) == surface
    }

    /// Read back the tabs this workspace was left with.
    ///
    /// Chips only. Nothing is fetched here: a restored file, commit or page
    /// loads when it is brought forward, so reopening the app does not read a
    /// dozen files somebody may not look at.
    func restoreTabs(in workspaceID: String) {
        guard tabs[workspaceID] == nil else { return }
        tabs[workspaceID] = WorkspacePreference.tabs(for: workspaceID)
            .compactMap(WorkspaceSurface.init(id:))
            .filter(\.isTab)
    }

    /// Write the strip back, minus the browser.
    ///
    /// A page opened here is a local server a session started, and the port it
    /// was on is not listening after a quit. Restoring that chip would restore
    /// a failed load, so a browser tab is the one thing the strip forgets.
    private func persistTabs(in workspaceID: String) {
        let ids = tabs(in: workspaceID).compactMap { surface -> String? in
            if case .browser = surface { return nil }
            return surface.id
        }
        WorkspacePreference.setTabs(ids, for: workspaceID)
    }

    /// Put a surface in front, adding it to the strip when it belongs there.
    ///
    /// The one way the pane changes. Every navigation goes through here, so a
    /// surface cannot be shown without a chip to close it by, and no flag can
    /// survive a navigation that put something else in front of it.
    func show(_ surface: WorkspaceSurface, in workspaceID: String) {
        if surface.isTab, !(tabs[workspaceID] ?? []).contains(surface) {
            tabs[workspaceID, default: []].append(surface)
            persistTabs(in: workspaceID)
        }
        front[workspaceID] = surface
    }

    /// Close a tab and drop what it was holding.
    ///
    /// What comes forward is the sessions surface rather than the neighbouring
    /// tab: the terminal is what this pane is mainly for.
    func close(_ surface: WorkspaceSurface, in workspaceID: String) {
        tabs[workspaceID]?.removeAll { $0 == surface }
        persistTabs(in: workspaceID)
        if isFront(surface, in: workspaceID) { front[workspaceID] = .sessions }
        switch surface {
        case let .file(path):
            let key = Self.treeKey(workspaceID, path)
            diffs[key] = nil
            documents[key] = nil
        case let .commit(commit):
            commits[Self.treeKey(workspaceID, commit)] = nil
            commitErrors[Self.treeKey(workspaceID, commit)] = nil
            if loadingCommit[workspaceID] == commit { loadingCommit[workspaceID] = nil }
        case let .browser(browser):
            forgetBrowser(browser, in: workspaceID)
        default:
            break
        }
    }

    /// The paths this workspace has open, in strip order.
    func openFiles(in workspaceID: String) -> [String] {
        tabs(in: workspaceID).compactMap {
            if case let .file(path) = $0 { return path }
            return nil
        }
    }

    /// What another machine reports this folder is holding, if it has said.
    func summary(for workspaceID: String) -> WorkspaceSummary? {
        summaries[workspaceID]
    }

    func commit(_ id: String, in workspaceID: String) -> CommitDetail? {
        commits[Self.treeKey(workspaceID, id)]
    }

    func commitError(_ id: String, in workspaceID: String) -> String? {
        commitErrors[Self.treeKey(workspaceID, id)]
    }

    /// Read a commit and show it. The tab appears at once and fills in.
    func showCommit(_ id: String, in workspaceID: String) async {
        show(.commit(id), in: workspaceID)
        guard commit(id, in: workspaceID) == nil else { return }
        let key = Self.treeKey(workspaceID, id)
        loadingCommit[workspaceID] = id
        commitErrors[key] = nil
        do {
            let detail = try await Bridge.workspaceShow(id: workspaceID, commit: id)
            guard loadingCommit[workspaceID] == id else { return }
            commits[key] = detail
            errorMessage = nil
        } catch {
            guard loadingCommit[workspaceID] == id else { return }
            commitErrors[key] = error.localizedDescription
        }
        if loadingCommit[workspaceID] == id { loadingCommit[workspaceID] = nil }
    }

    /// Close whichever commit this workspace has open.
    func closeCommit(in workspaceID: String) {
        for tab in tabs(in: workspaceID) {
            if case .commit = tab { close(tab, in: workspaceID) }
        }
    }

    func reviewWorkingTree(in workspaceID: String) {
        show(.changes, in: workspaceID)
    }

    func closeWorkingTreeReview(in workspaceID: String) {
        close(.changes, in: workspaceID)
    }

    /// Show a file in the centre pane, opening it if it is not already there.
    func openFile(_ path: String, in workspaceID: String) async {
        show(.file(path), in: workspaceID)
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
        close(.file(path), in: workspaceID)
    }

    /// Put the terminal back in front without closing any open tab.
    func showTerminal(in workspaceID: String) {
        show(.sessions, in: workspaceID)
    }

    func browserTabs(in workspaceID: String) -> [WorkspaceBrowserTab] {
        browserTabs[workspaceID] ?? []
    }

    /// Open a new browser tab, or select an existing one when an id is given.
    @discardableResult
    func showBrowser(in workspaceID: String, id: String? = nil) -> WorkspaceBrowserTab {
        if let id, let tab = browserTabs[workspaceID]?.first(where: { $0.id == id }) {
            show(.browser(id), in: workspaceID)
            return tab
        }
        let pages = browserTabs[workspaceID] ?? []
        let tab = WorkspaceBrowserTab(
            id: UUID().uuidString,
            url: "",
            number: pages.count + 1
        )
        browserTabs[workspaceID] = pages + [tab]
        show(.browser(tab.id), in: workspaceID)
        return tab
    }

    func closeBrowser(_ tab: WorkspaceBrowserTab, in workspaceID: String) {
        close(.browser(tab.id), in: workspaceID)
    }

    /// Drop a browser tab's payload, and the port forward it was holding open.
    private func forgetBrowser(_ id: String, in workspaceID: String) {
        guard let tab = browserTabs[workspaceID]?.first(where: { $0.id == id }) else { return }
        if let peer = tab.peer, let port = tab.port {
            Task { await Bridge.proxyUnlisten(peer: peer, host: "127.0.0.1", port: port) }
        }
        browserTabs[workspaceID]?.removeAll { $0.id == id }
    }

    func setBrowserURL(_ url: String, in workspaceID: String, tabID: String) {
        guard let index = browserTabs[workspaceID]?.firstIndex(where: { $0.id == tabID }) else { return }
        browserTabs[workspaceID]?[index].url = url
    }

    /// After a launch that starts a local web UI, wait for the port then open
    /// it in the in-app browser. The session stays running as the server.
    ///
    /// The wait is the point: `npx` may still be fetching the package, and
    /// opening a dead tab then is a failed load the user has to reload by
    /// hand. Time out and open anyway, so a slow first run is not a stuck
    /// terminal with no page.
    func openHarnessPage(_ url: String, in folder: WorkspaceFolder) async {
        guard let parsed = URL(string: url), let port = parsed.port else { return }
        if folder.id.hasPrefix("remote:") {
            try? await Task.sleep(for: .seconds(2))
            await openRemotePort(port, in: folder)
            return
        }
        _ = await Self.waitForLoopback(port: port)
        let tab = showBrowser(in: folder.id)
        setBrowserURL(url, in: folder.id, tabID: tab.id)
    }

    /// True when something on this machine's loopback answered.
    ///
    /// Any HTTP status counts, including 404. The question is whether the
    /// process bound the port, not whether `/` is the document it serves.
    private nonisolated static func waitForLoopback(port: Int, timeout: TimeInterval = 45) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            request.httpMethod = "GET"
            if let (_, response) = try? await URLSession.shared.data(for: request),
               response is HTTPURLResponse {
                return true
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    /// True when the remote harness answered through the local proxy.
    ///
    /// The proxy writes 502 while the peer port is still closed, so that
    /// status is "not yet". Time out and return false so the caller can
    /// still open the tab.
    private nonisolated static func waitForProxyPage(_ url: URL, timeout: TimeInterval = 45) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            request.httpMethod = "GET"
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse,
               http.statusCode != 502 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    /// Open a browser tab pointed at a service on a remote machine's own
    /// localhost. The daemon binds a loopback port here and bridges it over
    /// the authenticated stream, so the tab is an ordinary local URL.
    func openRemotePort(_ port: Int, in folder: WorkspaceFolder) async {
        let parts = folder.id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "remote" else {
            errorMessage = "Port forwarding works on a workspace on another device."
            return
        }
        do {
            let proxy = try await Bridge.proxyListen(peer: parts[1], host: "127.0.0.1", port: port)
            if let url = URL(string: proxy.url) {
                _ = await Self.waitForProxyPage(url)
            }
            let tab = showBrowser(in: folder.id)
            if let index = browserTabs[folder.id]?.firstIndex(where: { $0.id == tab.id }) {
                browserTabs[folder.id]?[index].peer = parts[1]
                browserTabs[folder.id]?[index].port = port
            }
            setBrowserURL(proxy.url, in: folder.id, tabID: tab.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func showFiles(in workspaceID: String) {
        show(.files, in: workspaceID)
    }

    func closeFiles(in workspaceID: String) {
        close(.files, in: workspaceID)
    }

    /// Leave the launch surface, if it is what is up.
    func exitLauncher(in workspaceID: String) {
        guard isShowingLauncher(in: workspaceID) else { return }
        show(.sessions, in: workspaceID)
    }

    /// Put the launch grid in front. Sessions stay mounted underneath.
    ///
    /// The Launch tab calls this. It does not toggle: clicking Launch while
    /// already there is a no-op, the same way clicking the selected session
    /// does not hide it.
    func showLauncher(in workspaceID: String) {
        show(.launcher, in: workspaceID)
    }

    /// Second click on a folder: swap between the running surface and the
    /// launcher, so a new agent can be started without hiding the sessions
    /// that are already there.
    func toggleLauncher(in workspaceID: String) {
        if isShowingLauncher(in: workspaceID) {
            showTerminal(in: workspaceID)
        } else {
            showLauncher(in: workspaceID)
        }
    }

    func isShowingLauncher(in workspaceID: String) -> Bool {
        isFront(.launcher, in: workspaceID)
    }

    /// True when the pane is showing a terminal rather than a document.
    func isShowingTerminal(in workspaceID: String) -> Bool {
        isFront(.sessions, in: workspaceID)
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
        for workspaceID in tabs.keys {
            for path in openFiles(in: workspaceID)
            where diffs[Self.treeKey(workspaceID, path)] != nil {
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
    /// Peers that have answered a workspace list at least once this session.
    /// The ones that never do are dialled far less often. See `loadRemote`.
    private var remotePeerEverAnswered: Set<String> = []
    /// Peers the user explicitly disconnected. Their folders stay out of the
    /// sidebar until Connect is chosen again; without this the peer sweep
    /// would re-dial an approved, reachable machine on its next pass and the
    /// Disconnect would last one refresh.
    private var suppressedPeers: Set<String> = []

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
                summaries = summaries.filter { !$0.key.hasPrefix("remote:\(key):") }
            }
            for peer in peers {
                if suppressedPeers.contains(peer.key) {
                    continue
                }
                if let nextDial = remotePeerNextDial[peer.key], Date() < nextDial { continue }
                do {
                    remoteFolders[peer.key] = try await Bridge.remoteWorkspaces(peer: peer)
                    // One call for every badge on every folder that machine
                    // has. Best effort: a host too old to answer leaves the
                    // badges off, which is what they were before this existed.
                    if let counts = try? await Bridge.remoteWorkspaceSummaries(peer: peer) {
                        for summary in counts { summaries[summary.id] = summary }
                    }
                    remotePeerNextDial[peer.key] = Date().addingTimeInterval(Self.peerRefreshSeconds)
                    remotePeerFailures[peer.key] = 0
                    remotePeerEverAnswered.insert(peer.key)
                    NotificationCenter.default.post(name: .remotePeerDidConnect, object: peer.key)
                } catch {
                    let failures = (remotePeerFailures[peer.key] ?? 0) + 1
                    remotePeerFailures[peer.key] = failures
                    // A machine that answered before is worth asking again
                    // soon: it is probably asleep and will be back. One that
                    // has never answered at all is usually a phone or a tablet,
                    // which cannot host a folder in the first place, and asking
                    // it every thirty seconds for the rest of the session is
                    // three pointless tunnel dials a minute, forever.
                    let neverAnswered = !remotePeerEverAnswered.contains(peer.key)
                    let wait = neverAnswered && failures >= Self.failuresBeforeBackingOff
                        ? Self.peerColdRetrySeconds
                        : Self.peerRetrySeconds
                    remotePeerNextDial[peer.key] = Date().addingTimeInterval(wait)
                    if failures >= Self.maxPeerFailures {
                        let hadFolders = remoteFolders.removeValue(forKey: peer.key) != nil
                        // Clear the Devices "Connected" mark without suppressing
                        // re-dial. Using the Disconnect path here would hide a
                        // machine that only went to sleep until the user pressed
                        // Connect again.
                        if hadFolders {
                            NotificationCenter.default.post(
                                name: .remotePeerBecameUnreachable,
                                object: peer.key
                            )
                        }
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
    /// How long a peer that has never answered is left alone, once it has
    /// missed enough times to have made the point. An approved peer is not
    /// necessarily a machine that can host: an iPhone and an iPad are paired
    /// like anything else and have no workspaces to list, because the mobile
    /// build has no host in it at all.
    private static let peerColdRetrySeconds: TimeInterval = 600
    /// Misses before a peer that has never answered moves to the slow rate.
    private static let failuresBeforeBackingOff = 3
    /// Consecutive failures before a peer's folders leave the sidebar.
    private static let maxPeerFailures = 2

    /// Move a sidebar folder so it sits before `targetID`, or at the end.
    ///
    /// Order is a local overlay. The host list has no rank, and remotes from
    /// other machines cannot be reordered there, so the merged sidebar keeps
    /// its own sequence on this Mac.
    func moveWorkspace(_ id: String, before targetID: String?) {
        guard folders.count > 1, folders.contains(where: { $0.id == id }) else { return }
        if id == targetID { return }
        var ids = folders.map(\.id)
        ids.removeAll { $0 == id }
        if let targetID, let to = ids.firstIndex(of: targetID) {
            ids.insert(id, at: to)
        } else {
            ids.append(id)
        }
        WorkspacePreference.setOrder(ids)
        folders = Self.applyOrder(folders, ids)
    }

    /// Remembered ids first, then anything new in the order it arrived.
    static func applyOrder(_ folders: [WorkspaceFolder], _ order: [String]) -> [WorkspaceFolder] {
        guard !order.isEmpty else { return folders }
        var leftover = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var ranked: [WorkspaceFolder] = []
        ranked.reserveCapacity(folders.count)
        for id in order {
            if let folder = leftover.removeValue(forKey: id) {
                ranked.append(folder)
            }
        }
        for folder in folders where leftover[folder.id] != nil {
            ranked.append(folder)
        }
        return ranked
    }

    /// Drop one peer's workspaces from the sidebar immediately, on an explicit
    /// Disconnect. Without this the folders stay until the sweep has failed
    /// twice, which is seconds to a minute of the machine still looking
    /// reachable after somebody asked to disconnect.
    func disconnect(peer key: String) {
        suppressedPeers.insert(key)
        remoteFolders.removeValue(forKey: key)
        remotePeerNextDial.removeValue(forKey: key)
        remotePeerFailures.removeValue(forKey: key)
        publishFolders()
        // Do not re-post `remotePeerDidDisconnect` here. Callers (Machines, or
        // RootView reacting to that notification) already own the broadcast;
        // posting again re-entered this method and made Disconnect look like a
        // no-op when the second pass found nothing left to drop.
    }

    /// An explicit Connect undoes a Disconnect: the peer's folders are
    /// allowed back and fetched immediately rather than after the next sweep.
    func reconnect(peer key: String) {
        suppressedPeers.remove(key)
        // Clear the backoff too. Somebody pressing Connect is asking now, and
        // a peer that had been dialled down to the slow rate would otherwise
        // sit out most of the next ten minutes before being tried.
        remotePeerNextDial.removeValue(forKey: key)
        remotePeerFailures.removeValue(forKey: key)
        Task { await loadRemote() }
    }

    /// Put local and remote folders together and keep the selection valid.
    private func publishFolders() {
        let merged = localFolders + remoteFolders.values.flatMap { $0 }
        folders = Self.applyOrder(merged, WorkspacePreference.order())
        // Chips a folder was left with, put back the first time it is listed.
        // Cheap: `restoreTabs` reads a string array and returns at once for a
        // folder it has already restored.
        for folder in folders { restoreTabs(in: folder.id) }
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

    func localModel(for workspaceID: String) -> String? {
        if let stored = localModels[workspaceID] {
            return stored.isEmpty ? nil : stored
        }
        return WorkspacePreference.localModel(for: workspaceID)
    }

    func setLocalModel(_ key: String?, for workspaceID: String) {
        let value = key ?? ""
        localModels[workspaceID] = value
        WorkspacePreference.setLocalModel(key, for: workspaceID)
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
            forgetTabs(in: folder.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Drop everything a folder had open. Called when it leaves the sidebar,
    /// so a folder added back does not arrive carrying last month's tabs, and
    /// the other folders' tabs are untouched.
    func forgetTabs(in workspaceID: String) {
        for tab in tabs(in: workspaceID) { close(tab, in: workspaceID) }
        tabs[workspaceID] = nil
        front[workspaceID] = nil
        browserTabs[workspaceID] = nil
        WorkspacePreference.setTabs([], for: workspaceID)
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
