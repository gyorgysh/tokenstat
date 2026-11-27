// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

#if os(macOS)
import AppKit
#endif

enum WorkspacePreference {
    private static let bypassKey = "workspace.bypassPermissions"
    private static let localModelKey = "workspace.localModel"
    private static let orderKey = "workspace.order"
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
    static let remotePeerDidConnect = Notification.Name("tokenstat.remotePeerDidConnect")
    static let remotePeerDidDisconnect = Notification.Name("tokenstat.remotePeerDidDisconnect")
    static let remotePeerBecameUnreachable = Notification.Name("tokenstat.remotePeerBecameUnreachable")
}

enum InspectorTab: String, CaseIterable, Identifiable, Sendable {
    case files = "Files"
    case changes = "Changes"
    case history = "History"

    var id: String { rawValue }
}

enum WorkspaceSurface: Hashable, Identifiable, Sendable {
    case sessions
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

    var isTab: Bool {
        switch self {
        case .sessions, .launcher: return false
        default: return true
        }
    }
}

struct WorkspaceBrowserTab: Identifiable, Hashable, Sendable {
    let id: String
    var url: String
    var number: Int
    var waitsForService = false
    var title: String { L10n.text("apple.workspacesmodel.browser_0.d9e7db6c", "\(number)") }
}

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
    private(set) var hasLoadedDirectory = false
    private(set) var directoryError: String?
    var directoryPresentation: WorkspaceDirectoryPresentation {
        .resolve(hasContent: !folders.isEmpty, hasLoaded: hasLoadedDirectory,
                 isLoading: isLoading, error: directoryError)
    }

    var inspectorTab: InspectorTab = .files
    var chatInspectorShowsSettings = true

    struct ChangeFocus: Equatable {
        let folderID: String
        let path: String
        let generation: Int
    }
    private(set) var changeFocus: ChangeFocus?
    private(set) var workingTreeReviewFocus: ChangeFocus?
    @ObservationIgnored private var changeFocusGeneration = 0

    func focusChange(_ path: String, in folderID: String) {
        changeFocusGeneration += 1
        changeFocus = ChangeFocus(folderID: folderID, path: path, generation: changeFocusGeneration)
    }

    func consumeChangeFocus(_ focus: ChangeFocus) {
        if changeFocus == focus { changeFocus = nil }
    }

    func inspectorTabTitle(_ tab: InspectorTab) -> String {
        switch tab {
        case .changes:
            let count = selected?.changeCount ?? 0
            let name = L10n.text("apple.rootview.git.b949c922")
            return count > 0 ? "\(name) (\(count))" : name
        case .files:
            return L10n.text("common.files")
        case .history:
            return L10n.text("common.history")
        }
    }

    private(set) var history: [String: [Commit]] = [:]
    private(set) var historyErrors: [String: String] = [:]

    private(set) var tree: [String: [TreeEntry]] = [:]
    var expandedDirectories: Set<String> = []

    var stagedSelection: [String: Set<String>] = [:]
    var commitMessage: [String: String] = [:]
    var commitDescription: [String: String] = [:]
    var autoCommitBackend: [String: String] = [:]
    var autoCommitModel: [String: String] = [:]
    private(set) var gitOutcome: [String: GitOutcome] = [:]
    private(set) var gitOutcomeAction: [String: GitOutcomeAction] = [:]
    @ObservationIgnored private var gitOutcomeDismissTasks: [String: Task<Void, Never>] = [:]
    var isCommitting = false

    private(set) var tabs: [String: [WorkspaceSurface]] = [:]
    private(set) var front: [String: WorkspaceSurface] = [:]
    private(set) var browserTabs: [String: [WorkspaceBrowserTab]] = [:]
    private(set) var summaries: [String: WorkspaceSummary] = [:]
    private(set) var diffs: [String: FileDiff] = [:]
    private(set) var diffErrors: [String: String] = [:]
    private(set) var diffRefreshRevisions: [String: UInt64] = [:]
    private(set) var documents: [String: EditorDocument] = [:]
    var editorError: String?

    private static func treeKey(_ workspaceID: String, _ path: String) -> String {
        "\(workspaceID):\(path)"
    }


    private(set) var commits: [String: CommitDetail] = [:]
    private(set) var loadingCommit: [String: String] = [:]
    private(set) var commitErrors: [String: String] = [:]

    func tabs(in workspaceID: String) -> [WorkspaceSurface] { tabs[workspaceID] ?? [] }

    func front(in workspaceID: String) -> WorkspaceSurface { front[workspaceID] ?? .sessions }

    func isFront(_ surface: WorkspaceSurface, in workspaceID: String) -> Bool {
        front(in: workspaceID) == surface
    }

    func restoreTabs(in workspaceID: String) {
        guard tabs[workspaceID] == nil else { return }
        tabs[workspaceID] = WorkspacePreference.tabs(for: workspaceID)
            .compactMap(WorkspaceSurface.init(id:))
            .filter(\.isTab)
    }

    private func persistTabs(in workspaceID: String) {
        let ids = tabs(in: workspaceID).compactMap { surface -> String? in
            if case .browser = surface { return nil }
            return surface.id
        }
        WorkspacePreference.setTabs(ids, for: workspaceID)
    }

    func show(_ surface: WorkspaceSurface, in workspaceID: String) {
        if surface.isTab, !(tabs[workspaceID] ?? []).contains(surface) {
            tabs[workspaceID, default: []].append(surface)
            persistTabs(in: workspaceID)
        }
        front[workspaceID] = surface
    }

    func close(_ surface: WorkspaceSurface, in workspaceID: String) {
        tabs[workspaceID]?.removeAll { $0 == surface }
        persistTabs(in: workspaceID)
        if isFront(surface, in: workspaceID) { front[workspaceID] = .sessions }
        switch surface {
        case let .file(path):
            let key = Self.treeKey(workspaceID, path)
            if diffPreviewUsers[key, default: 0] == 0 {
                pendingDiffLoads[key] = nil
                diffs[key] = nil
                diffErrors[key] = nil
            }
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

    func openFiles(in workspaceID: String) -> [String] {
        tabs(in: workspaceID).compactMap {
            if case let .file(path) = $0 { return path }
            return nil
        }
    }

    func summary(for workspaceID: String) -> WorkspaceSummary? {
        summaries[workspaceID]
    }

    func commit(_ id: String, in workspaceID: String) -> CommitDetail? {
        commits[Self.treeKey(workspaceID, id)]
    }

    func commitError(_ id: String, in workspaceID: String) -> String? {
        commitErrors[Self.treeKey(workspaceID, id)]
    }

    func gitOutcome(for workspaceID: String) -> GitOutcome? {
        gitOutcome[workspaceID]
    }

    func gitOutcomeAction(for workspaceID: String) -> GitOutcomeAction? {
        gitOutcomeAction[workspaceID]
    }

    func historyError(for workspaceID: String) -> String? {
        historyErrors[workspaceID]
    }

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

    func closeCommit(in workspaceID: String) {
        for tab in tabs(in: workspaceID) {
            if case .commit = tab { close(tab, in: workspaceID) }
        }
    }

    func reviewWorkingTree(in workspaceID: String, focusing path: String? = nil) {
        focusWorkingTree(in: workspaceID, path: path)
        show(.changes, in: workspaceID)
    }

    func focusWorkingTree(in workspaceID: String, path: String?) {
        if let path {
            changeFocusGeneration += 1
            workingTreeReviewFocus = ChangeFocus(folderID: workspaceID, path: path, generation: changeFocusGeneration)
        } else if workingTreeReviewFocus?.folderID == workspaceID {
            workingTreeReviewFocus = nil
        }
    }

    func closeWorkingTreeReview(in workspaceID: String) {
        if workingTreeReviewFocus?.folderID == workspaceID { workingTreeReviewFocus = nil }
        close(.changes, in: workspaceID)
    }

    func openFile(_ path: String, in workspaceID: String) async {
        show(.file(path), in: workspaceID)
        await loadText(path, in: workspaceID)
    }

    struct PendingClose: Identifiable {
        let workspaceID: String
        let path: String
        var id: String { "\(workspaceID):\(path)" }
    }

    var pendingClose: PendingClose?

    func requestClose(_ path: String, in workspaceID: String) {
        if isEditorDirty(path, in: workspaceID) {
            pendingClose = PendingClose(workspaceID: workspaceID, path: path)
            return
        }
        closeFile(path, in: workspaceID)
    }

    func saveAndClosePending() async {
        guard let pending = pendingClose else { return }
        pendingClose = nil
        await saveText(pending.path, in: pending.workspaceID)
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

    func showTerminal(in workspaceID: String) {
        show(.sessions, in: workspaceID)
    }

    func browserTabs(in workspaceID: String) -> [WorkspaceBrowserTab] {
        browserTabs[workspaceID] ?? []
    }

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

    private func forgetBrowser(_ id: String, in workspaceID: String) {
        browserTabs[workspaceID]?.removeAll { $0.id == id }
    }

    func setBrowserURL(_ url: String, in workspaceID: String, tabID: String, waitsForService: Bool = false) {
        guard let index = browserTabs[workspaceID]?.firstIndex(where: { $0.id == tabID }) else { return }
        browserTabs[workspaceID]?[index].url = url
        browserTabs[workspaceID]?[index].waitsForService = waitsForService
    }

    func openHarnessPage(_ url: String, in folder: WorkspaceFolder) async {
        guard let target = BrowserTarget(url) else { return }
        let owner = WorkViewedChange.owner(folderID: folder.id)
        let remote = folder.id.hasPrefix("remote:")
        if !remote {
            _ = await Self.waitForLoopback(port: target.port)
        }
        guard !Task.isCancelled, WorkViewedChange.owner(folderID: folder.id) == owner else { return }
        let tab = showBrowser(in: folder.id)
        setBrowserURL(target.url, in: folder.id, tabID: tab.id, waitsForService: remote)
    }

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

    func openRemotePort(_ port: Int, in folder: WorkspaceFolder) async {
        let parts = folder.id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "remote", let target = BrowserTarget(String(port)) else {
            errorMessage = L10n.text("apple.workspacesmodel.choose_a_port_from_1_to_65535_on_a_project.905c6034")
            return
        }
        let tab = showBrowser(in: folder.id)
        setBrowserURL(target.url, in: folder.id, tabID: tab.id)
        errorMessage = nil
    }

    func showFiles(in workspaceID: String) {
        show(.files, in: workspaceID)
    }

    func closeFiles(in workspaceID: String) {
        close(.files, in: workspaceID)
    }

    func exitLauncher(in workspaceID: String) {
        guard isShowingLauncher(in: workspaceID) else { return }
        show(.sessions, in: workspaceID)
    }

    func showLauncher(in workspaceID: String) {
        show(.launcher, in: workspaceID)
    }

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

    var hasUnsavedWork: Bool {
        documents.values.contains(where: \.isDirty)
    }

    func hasUnsavedWork(in workspaceID: String) -> Bool {
        documents.values.contains { $0.workspaceID == workspaceID && $0.isDirty }
    }

    func loadText(_ path: String, in workspaceID: String) async {
        let key = Self.treeKey(workspaceID, path)
        if let existing = documents[key], existing.isDirty { return }
        do {
            let file = try await Bridge.workspaceRead(id: workspaceID, path: path)
            if let existing = documents[key] {
                guard !existing.isDirty else { return }
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

    func saveText(_ path: String, in workspaceID: String) async {
        let key = Self.treeKey(workspaceID, path)
        guard let document = documents[key], document.isDirty else { return }
        let sent = document.text
        do {
            let outcome = try await Bridge.workspaceWrite(
                id: workspaceID, path: path, content: sent
            )
            guard outcome.ok else {
                editorError = outcome.message
                return
            }
            document.markSaved(content: sent)
            editorError = nil
            await loadDiff(path, in: workspaceID)
        } catch {
            editorError = error.localizedDescription
        }
    }

    @discardableResult
    func saveAllDirty(in workspaceID: String) async -> Bool {
        let dirty = documents.values.filter { $0.workspaceID == workspaceID && $0.isDirty }
        var savedAll = true
        for document in dirty {
            await saveText(document.path, in: workspaceID)
            if document.isDirty { savedAll = false }
        }
        return savedAll
    }

    func discardUnsavedBuffers(in workspaceID: String) async {
        let dirty = documents.values.filter { $0.workspaceID == workspaceID && $0.isDirty }
        for document in dirty {
            let path = document.path
            document.adopt(saved: document.savedText)
            await loadText(path, in: workspaceID)
        }
    }

    private var nextDiffLoad: UInt64 = 0
    private var pendingDiffLoads: [String: UInt64] = [:]
    @ObservationIgnored private var diffPreviewUsers: [String: Int] = [:]
    @ObservationIgnored private var diffReadRevisions: [String: UInt64] = [:]
    @ObservationIgnored private var parkedPreviews: [(key: String, workspaceID: String, path: String)] = []
    private static let parkedPreviewLimit = 12

    func retainDiffPreview(_ path: String, in workspaceID: String) {
        let key = Self.treeKey(workspaceID, path)
        diffPreviewUsers[key, default: 0] += 1
        parkedPreviews.removeAll { $0.key == key }
    }

    func diffError(for path: String, in workspaceID: String) -> String? {
        diffErrors[Self.treeKey(workspaceID, path)]
    }

    func releaseDiffPreview(_ path: String, in workspaceID: String) {
        let key = Self.treeKey(workspaceID, path)
        let users = max(0, diffPreviewUsers[key, default: 0] - 1)
        diffPreviewUsers[key] = users == 0 ? nil : users
        guard users == 0, !openFiles(in: workspaceID).contains(path) else { return }
        parkedPreviews.removeAll { $0.key == key }
        parkedPreviews.append((key, workspaceID, path))
        while parkedPreviews.count > Self.parkedPreviewLimit {
            let oldest = parkedPreviews.removeFirst()
            guard diffPreviewUsers[oldest.key] == nil,
                  !openFiles(in: oldest.workspaceID).contains(oldest.path) else { continue }
            pendingDiffLoads[oldest.key] = nil
            diffs[oldest.key] = nil
            diffErrors[oldest.key] = nil
            diffReadRevisions[oldest.key] = nil
        }
    }

    func loadPreviewDiff(_ path: String, in workspaceID: String) async {
        let key = Self.treeKey(workspaceID, path)
        if diffs[key] != nil, diffReadRevisions[key] == (diffRefreshRevisions[workspaceID] ?? 0) { return }
        await loadDiff(path, in: workspaceID)
    }

    @discardableResult
    func loadDiff(_ path: String, in workspaceID: String) async -> Bool {
        let key = Self.treeKey(workspaceID, path)
        nextDiffLoad &+= 1
        let request = nextDiffLoad
        let revision = diffRefreshRevisions[workspaceID] ?? 0
        pendingDiffLoads[key] = request
        defer {
            if pendingDiffLoads[key] == request { pendingDiffLoads[key] = nil }
        }
        do {
            let diff = try await Bridge.workspaceDiff(id: workspaceID, path: path)
            guard !Task.isCancelled, pendingDiffLoads[key] == request else { return false }
            if diffs[key] != diff { diffs[key] = diff }
            diffReadRevisions[key] = revision
            diffErrors[key] = nil
            documents[key]?.applyDiff(diff)
            errorMessage = nil
            return true
        } catch {
            guard !Task.isCancelled, pendingDiffLoads[key] == request else { return false }
            diffErrors[key] = error.localizedDescription
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshOpenDiffs(in only: Set<String>? = nil) async {
        for workspaceID in tabs.keys where only?.contains(workspaceID) ?? true {
            for path in openFiles(in: workspaceID)
            where diffs[Self.treeKey(workspaceID, path)] != nil {
                await loadDiff(path, in: workspaceID)
            }
        }
    }

    func refreshOpenDocuments(in only: Set<String>? = nil) async {
        for document in documents.values
        where !document.isDirty && (only?.contains(document.workspaceID) ?? true) {
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

    private var localFolders: [WorkspaceFolder] = []
    private var remoteFolders: [String: [WorkspaceFolder]] = [:]
    private var remotePeerNextDial: [String: Date] = [:]
    private var remotePeerFailures: [String: Int] = [:]
    var connectedRemotePeerKeys: Set<String> {
        Set(remoteFolders.keys.filter {
            !suppressedPeers.contains($0) && (remotePeerFailures[$0] ?? 0) == 0
        })
    }
    func isRemoteStale(_ peer: String) -> Bool {
        remoteFolders[peer] != nil && (remotePeerFailures[peer] ?? 0) > 0
    }
    private var remotePeerEverAnswered: Set<String> = []
    private struct RemoteFetch: Sendable {
        let peer: Peer
        let folders: [WorkspaceFolder]?
        let summaries: [WorkspaceSummary]?
        let failure: String?
    }

    private struct RemoteFetchError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func fetchRemote(_ peer: Peer) async -> RemoteFetch {
        do {
            let folders = try await Bridge.remoteWorkspaces(peer: peer)
            let summaries = try? await Bridge.remoteWorkspaceSummaries(peer: peer)
            return RemoteFetch(peer: peer, folders: folders, summaries: summaries, failure: nil)
        } catch {
            return RemoteFetch(peer: peer, folders: nil, summaries: nil, failure: error.localizedDescription)
        }
    }
    private var remoteOwnerScope: WorkReference.Scope?
    private var suppressedPeers: Set<String> = []
    private static var autoConnectRevisions: [String: UInt64] = [:]
    private static func autoConnectRevision(for peerKey: String) -> UInt64 {
        autoConnectRevisions[peerKey] ?? 0
    }
    static func autoConnectKey(for peerKey: String) -> String? {
        guard let scope = WorkSessionContext.shared.scope else { return nil }
        let owner = [scope.kind.rawValue, scope.origin, scope.identity]
            .map(WorkReferenceKey.encode).joined(separator: "|")
        return "workspace.autoconnect.v2.\(owner).\(WorkReferenceKey.encode(peerKey))"
    }
    static func isAutoConnectEnabled(for peerKey: String) -> Bool {
        guard let key = autoConnectKey(for: peerKey) else { return false }
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
    static func setAutoConnect(_ on: Bool, for peerKey: String) {
        guard let key = autoConnectKey(for: peerKey) else { return }
        autoConnectRevisions[peerKey, default: 0] &+= 1
        UserDefaults.standard.set(on, forKey: key)
    }
    private static func migrateLegacyAutoConnect(peers: [Peer]) {
        for peer in peers {
            let legacy = "workspace.autoconnect.\(peer.key)"
            guard let key = autoConnectKey(for: peer.key),
                  UserDefaults.standard.object(forKey: key) == nil,
                  let old = UserDefaults.standard.object(forKey: legacy) as? Bool else { continue }
            UserDefaults.standard.set(old, forKey: key)
            UserDefaults.standard.removeObject(forKey: legacy)
        }
    }
    private static func knownWorkspaceHostsKey() -> String? {
        guard let scope = WorkSessionContext.shared.scope else { return nil }
        let owner = [scope.kind.rawValue, scope.origin, scope.identity]
            .map(WorkReferenceKey.encode).joined(separator: "|")
        return "workspace.knownHosts.v1.\(owner)"
    }
    private static func knownWorkspaceHosts() -> Set<String> {
        guard let key = knownWorkspaceHostsKey() else { return [] }
        return Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
    private static func rememberWorkspaceHost(_ peerKey: String) {
        guard let key = knownWorkspaceHostsKey() else { return }
        var known = knownWorkspaceHosts()
        guard known.insert(peerKey).inserted else { return }
        UserDefaults.standard.set(known.sorted(), forKey: key)
    }
    private var askedWorkspace: Set<String> = []

    func load() async {
        await loadLocal()
        await loadRemote()
    }

    @discardableResult
    func loadLocal() async -> Bool {
        let ecosystemLease = EcosystemPublisher.lease
        let scope = WorkSessionContext.shared.scope
        let announces = !hasLoadedDirectory || directoryError != nil
        if announces { isLoading = true }
        defer { if announces { isLoading = false } }
        do {
            let loaded = try await Bridge.workspaces()
            guard WorkSessionContext.shared.scope == scope else { return false }
            if EcosystemPublisher.lease == ecosystemLease {
                EcosystemPublisher.publish(projects: loaded.filter(\.exists).map {
                    EcosystemProject(id: $0.id, name: $0.name, host: "This Mac")
                }, lease: ecosystemLease, replacing: .local)
            }
            if localFolders != loaded {
                localFolders = loaded
                publishFolders()
            }
            if !hasLoadedDirectory { hasLoadedDirectory = true }
            if directoryError != nil { directoryError = nil }
            if errorMessage != nil { errorMessage = nil }
            if let counts = try? await Bridge.workspaceSummaries() {
                let localIDs = Set(loaded.map(\.id))
                var next = summaries.filter { key, _ in
                    key.hasPrefix("remote:") || localIDs.contains(key)
                }
                for summary in counts {
                    next[summary.id] = summary
                }
                if next != summaries { summaries = next }
            }
            return true
        } catch {
            guard WorkSessionContext.shared.scope == scope else { return false }
            directoryError = error.localizedDescription
            errorMessage = error.localizedDescription
            return false
        }
    }

    private var nextRemoteLoad: UInt64 = 0

    func loadRemote() async {
        let scope = WorkSessionContext.shared.scope
        if remoteOwnerScope != scope {
            remoteOwnerScope = scope
            remoteFolders.removeAll()
            remotePeerFailures.removeAll()
            remotePeerNextDial.removeAll()
            remotePeerEverAnswered.removeAll()
            suppressedPeers.removeAll()
            askedWorkspace.removeAll()
            summaries = summaries.filter { !$0.key.hasPrefix("remote:") }
            publishFolders()
        }
        guard scope != nil else { return }
        let ecosystemLease = EcosystemPublisher.lease
        nextRemoteLoad &+= 1
        let generation = nextRemoteLoad
        do {
            let tunnelOn = (try? await Bridge.remoteStatus())?.tunnel == true
            let peers = try await Bridge.peers().filter {
                $0.trust == .approved && ($0.address?.isEmpty == false || tunnelOn)
            }
            guard generation == nextRemoteLoad, EcosystemPublisher.lease == ecosystemLease,
                  WorkSessionContext.shared.scope == scope else { return }
            Self.migrateLegacyAutoConnect(peers: peers)
            var stagedFolders = remoteFolders
            var stagedFailures = remotePeerFailures
            var stagedNextDial = remotePeerNextDial
            var stagedEverAnswered = remotePeerEverAnswered
            var stagedSummaries = summaries
            var unreachableKeys: [String] = []
            let liveKeys = Set(peers.map(\.key))
            for key in stagedFolders.keys where !liveKeys.contains(key) {
                stagedFolders.removeValue(forKey: key)
                stagedFailures.removeValue(forKey: key)
                stagedSummaries = stagedSummaries.filter { !$0.key.hasPrefix("remote:\(key):") }
            }
            for key in suppressedPeers {
                if stagedFolders.removeValue(forKey: key) != nil {
                    stagedSummaries = stagedSummaries.filter { !$0.key.hasPrefix("remote:\(key):") }
                }
            }
            let knownHosts = Self.knownWorkspaceHosts()
            let candidates = peers.filter { peer in
                !suppressedPeers.contains(peer.key)
                    && Self.isAutoConnectEnabled(for: peer.key)
                    && (stagedNextDial[peer.key].map { Date() >= $0 } ?? true)
            }.sorted { lhs, rhs in
                let lhsKnown = knownHosts.contains(lhs.key) || stagedEverAnswered.contains(lhs.key)
                let rhsKnown = knownHosts.contains(rhs.key) || stagedEverAnswered.contains(rhs.key)
                if lhsKnown != rhsKnown { return lhsKnown }
                if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
                return lhs.key < rhs.key
            }
            let candidateRevisions = Dictionary(uniqueKeysWithValues: candidates.map {
                ($0.key, Self.autoConnectRevision(for: $0.key))
            })
            let results = await withTaskGroup(of: RemoteFetch.self, returning: [String: RemoteFetch].self) { group in
                var remaining = candidates.makeIterator()
                for _ in 0..<min(4, candidates.count) {
                    if let peer = remaining.next() {
                        group.addTask { await Self.fetchRemote(peer) }
                    }
                }
                var fetched: [String: RemoteFetch] = [:]
                while let result = await group.next() {
                    if generation != nextRemoteLoad || EcosystemPublisher.lease != ecosystemLease
                        || WorkSessionContext.shared.scope != scope {
                        group.cancelAll()
                        break
                    }
                    fetched[result.peer.key] = result
                    if let listed = result.folders,
                       !suppressedPeers.contains(result.peer.key),
                       Self.isAutoConnectEnabled(for: result.peer.key),
                       candidateRevisions[result.peer.key] == Self.autoConnectRevision(for: result.peer.key) {
                        let key = result.peer.key
                        let newlySeen = stagedFolders[key] == nil || (stagedFailures[key] ?? 0) > 0
                        stagedFolders[key] = listed
                        if let counts = result.summaries {
                            for summary in counts { stagedSummaries[summary.id] = summary }
                        }
                        stagedNextDial[key] = Date().addingTimeInterval(Self.peerRefreshSeconds)
                        stagedFailures[key] = 0
                        stagedEverAnswered.insert(key)
                        Self.rememberWorkspaceHost(key)
                        for stopped in suppressedPeers {
                            if stagedFolders.removeValue(forKey: stopped) != nil {
                                stagedSummaries = stagedSummaries.filter {
                                    !$0.key.hasPrefix("remote:\(stopped):")
                                }
                            }
                        }
                        remoteFolders = stagedFolders
                        remotePeerFailures = stagedFailures
                        remotePeerNextDial = stagedNextDial
                        remotePeerEverAnswered = stagedEverAnswered
                        summaries = stagedSummaries
                        EcosystemPublisher.publish(projects: listed.filter(\.exists).map {
                            EcosystemProject(id: $0.id, name: $0.name, host: $0.machineLabel ?? "Computer")
                        }, lease: ecosystemLease, replacing: .peer(key))
                        publishFolders()
                        if newlySeen {
                            NotificationCenter.default.post(
                                name: .remotePeerDidConnect,
                                object: key,
                                userInfo: ["workspaceFoldersReady": true]
                            )
                        }
                    }
                    if let peer = remaining.next() {
                        group.addTask { await Self.fetchRemote(peer) }
                    }
                }
                return fetched
            }
            guard generation == nextRemoteLoad, EcosystemPublisher.lease == ecosystemLease,
                  WorkSessionContext.shared.scope == scope else { return }
            for peer in peers {
                guard WorkSessionContext.shared.scope == scope else { return }
                if suppressedPeers.contains(peer.key) {
                    continue
                }
                if !Self.isAutoConnectEnabled(for: peer.key) {
                    continue
                }
                guard let candidateRevision = candidateRevisions[peer.key],
                      candidateRevision == Self.autoConnectRevision(for: peer.key) else { continue }
                if let nextDial = stagedNextDial[peer.key], Date() < nextDial { continue }
                do {
                    guard let result = results[peer.key] else { continue }
                    guard let fetched = result.folders else {
                        throw RemoteFetchError(message: result.failure ?? "Remote workspace unavailable")
                    }
                    guard generation == nextRemoteLoad, EcosystemPublisher.lease == ecosystemLease,
                          WorkSessionContext.shared.scope == scope else { return }
                    guard !suppressedPeers.contains(peer.key) else { continue }
                    let newlySeen = stagedFolders[peer.key] == nil || (stagedFailures[peer.key] ?? 0) > 0
                    EcosystemPublisher.publish(projects: fetched.filter(\.exists).map {
                        EcosystemProject(id: $0.id, name: $0.name, host: $0.machineLabel ?? "Computer")
                    }, lease: ecosystemLease, replacing: .peer(peer.key))
                    stagedFolders[peer.key] = fetched
                    if let counts = result.summaries {
                        guard generation == nextRemoteLoad, EcosystemPublisher.lease == ecosystemLease,
                              WorkSessionContext.shared.scope == scope else { return }
                        for summary in counts { stagedSummaries[summary.id] = summary }
                    }
                    stagedNextDial[peer.key] = Date().addingTimeInterval(Self.peerRefreshSeconds)
                    stagedFailures[peer.key] = 0
                    stagedEverAnswered.insert(peer.key)
                    Self.rememberWorkspaceHost(peer.key)
                    if newlySeen {
                        NotificationCenter.default.post(
                            name: .remotePeerDidConnect,
                            object: peer.key,
                            userInfo: ["workspaceFoldersReady": true]
                        )
                    }
                } catch {
                    guard generation == nextRemoteLoad, EcosystemPublisher.lease == ecosystemLease,
                          WorkSessionContext.shared.scope == scope else { return }
                    let text = error.localizedDescription
                    if Self.isWorkspaceRefusal(text) {
                        if askedWorkspace.insert(peer.key).inserted {
                            _ = try? await Bridge.askWorkspaceAccess(peer: peer.key)
                        }
                        guard generation == nextRemoteLoad, EcosystemPublisher.lease == ecosystemLease,
                              WorkSessionContext.shared.scope == scope else { return }
                        if stagedFolders.removeValue(forKey: peer.key) != nil {
                            stagedSummaries = stagedSummaries.filter {
                                !$0.key.hasPrefix("remote:\(peer.key):")
                            }
                            EcosystemPublisher.publish(projects: [], lease: ecosystemLease,
                                replacing: .peer(peer.key))
                            unreachableKeys.append(peer.key)
                        }
                        let refusals = (stagedFailures[peer.key] ?? 0) + 1
                        stagedFailures[peer.key] = refusals
                        let neverOpened = !stagedEverAnswered.contains(peer.key)
                        stagedNextDial[peer.key] = Date().addingTimeInterval(
                            neverOpened && refusals >= Self.failuresBeforeBackingOff
                                ? Self.peerColdRetrySeconds
                                : Self.peerRetrySeconds
                        )
                        continue
                    }
                    let failures = (stagedFailures[peer.key] ?? 0) + 1
                    stagedFailures[peer.key] = failures
                    if failures == 1 && stagedFolders[peer.key] != nil {
                        EcosystemPublisher.publish(projects: [], lease: ecosystemLease,
                            replacing: .peer(peer.key))
                        unreachableKeys.append(peer.key)
                    }
                    let neverAnswered = !stagedEverAnswered.contains(peer.key)
                    let wait = neverAnswered
                        && (failures >= Self.failuresBeforeBackingOff || Self.isLongUnseen(peer))
                        ? Self.peerColdRetrySeconds
                        : Self.peerRetrySeconds
                    stagedNextDial[peer.key] = Date().addingTimeInterval(wait)
                    if failures >= Self.maxPeerFailures {
                        let hadFolders = stagedFolders.removeValue(forKey: peer.key) != nil
                        if hadFolders {
                            unreachableKeys.append(peer.key)
                        }
                    }
                }
            }
            guard generation == nextRemoteLoad, EcosystemPublisher.lease == ecosystemLease,
                  WorkSessionContext.shared.scope == scope else { return }
            for key in suppressedPeers {
                if stagedFolders.removeValue(forKey: key) != nil {
                    stagedSummaries = stagedSummaries.filter { !$0.key.hasPrefix("remote:\(key):") }
                }
            }
            remoteFolders = stagedFolders
            remotePeerFailures = stagedFailures
            remotePeerNextDial = stagedNextDial
            remotePeerEverAnswered = stagedEverAnswered
            summaries = stagedSummaries
            publishFolders()
            for key in unreachableKeys {
                NotificationCenter.default.post(
                    name: .remotePeerBecameUnreachable,
                    object: key
                )
            }
        } catch {
        }
    }

    static func isWorkspaceRefusal(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("has not let this device")
            || lower.contains("workspace_not_allowed")
            || lower.contains("open its work")
    }

    func watchPeers() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.peerRefreshSeconds))
            guard !Task.isCancelled else { return }
            await loadRemote()
        }
    }

    private static let peerRefreshSeconds: TimeInterval = 60
    private static let peerRetrySeconds: TimeInterval = 30
    private static let peerColdRetrySeconds: TimeInterval = 600
    private static let failuresBeforeBackingOff = 3
    private static let longUnseenSeconds: TimeInterval = 7 * 86_400

    private static func isLongUnseen(_ peer: Peer) -> Bool {
        guard let seen = ISO8601DateFormatter().date(from: peer.lastSeen) else { return false }
        return Date().timeIntervalSince(seen) > longUnseenSeconds
    }
    private static let maxPeerFailures = 2

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

    func disconnect(peer key: String) {
        Self.setAutoConnect(false, for: key)
        suppressedPeers.insert(key)
        remoteFolders.removeValue(forKey: key)
        remotePeerNextDial.removeValue(forKey: key)
        remotePeerFailures.removeValue(forKey: key)
        publishFolders()
    }

    func reconnect(peer key: String) {
        suppressedPeers.remove(key)
        Self.setAutoConnect(true, for: key)
        askedWorkspace.remove(key)
        remotePeerNextDial.removeValue(forKey: key)
        remotePeerFailures.removeValue(forKey: key)
        Task { await loadRemote() }
    }

    func refreshRemotePeer(_ key: String) {
        remotePeerNextDial.removeValue(forKey: key)
        Task { await loadRemote() }
    }

    func acceptRegisteredRemoteProject(_ folder: WorkspaceFolder, peer: String, label: String?) {
        var remote = folder
        remote.id = "remote:\(peer):\(folder.id)"
        remote.machineID = peer
        remote.machineLabel = label
        var existing = remoteFolders[peer] ?? []
        existing.removeAll { $0.id == remote.id }
        existing.append(remote)
        remoteFolders[peer] = existing
        publishFolders()
        refreshRemotePeer(peer)
    }

    private func publishFolders() {
        let merged = localFolders + remoteFolders.values.flatMap { $0 }
        let ordered = Self.applyOrder(merged, WorkspacePreference.order())
        if ordered != folders { folders = ordered }
        for folder in folders { restoreTabs(in: folder.id) }
        if let id = selectedID, !folders.contains(where: { $0.id == id }) {
            selectedID = folders.first?.id
        }
        if selectedID == nil { selectedID = folders.first?.id }
        #if os(macOS)
        syncWatcher()
        #endif
    }

    #if os(macOS)
    private func syncWatcher() {
        if let watcher {
            watcher.watch(folders.filter { !$0.isRemote }.map(\.path))
        } else {
            let watcher = WorkspaceFileWatcher(model: self)
            self.watcher = watcher
            watcher.watch(folders.filter { !$0.isRemote }.map(\.path))
        }
    }

    func scheduleRefresh(roots: Set<String>? = nil) {
        if let roots {
            pendingRefreshRoots.formUnion(roots)
        } else {
            pendingRefreshAll = true
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            let roots = self.pendingRefreshRoots
            let all = self.pendingRefreshAll
            self.pendingRefreshRoots = []
            self.pendingRefreshAll = false
            if all {
                await self.refresh()
            } else {
                await self.refresh(roots: roots)
            }
        }
    }

    private var pendingRefreshRoots: Set<String> = []
    private var pendingRefreshAll = false

    func refresh(roots: Set<String>) async {
        let ids = localFolders.filter { roots.contains($0.path) }.map(\.id)
        guard !ids.isEmpty, ids.count <= 3 else {
            await refresh()
            return
        }
        for id in ids {
            guard let fresh = try? await Bridge.workspaceStatus(id: id),
                  let index = localFolders.firstIndex(where: { $0.id == id }) else { continue }
            localFolders[index] = fresh
        }
        publishFolders()
        let changed = Set(ids)
        for id in ids { diffRefreshRevisions[id, default: 0] &+= 1 }
        for id in history.keys where changed.contains(id) {
            await loadHistory(for: id)
        }
        await refreshOpenDiffs(in: changed)
        await refreshOpenDocuments(in: changed)
    }
    #endif

    func refresh() async {
        await loadLocal()
        for folder in localFolders { diffRefreshRevisions[folder.id, default: 0] &+= 1 }
        for id in history.keys {
            await loadHistory(for: id)
        }
        await refreshOpenDiffs()
        await refreshOpenDocuments()
    }

    private var historyLoads: [String: UInt64] = [:]
    private var nextHistoryLoad: UInt64 = 0

    func loadHistory(for id: String) async {
        nextHistoryLoad &+= 1
        let request = nextHistoryLoad
        historyLoads[id] = request
        defer {
            if historyLoads[id] == request { historyLoads.removeValue(forKey: id) }
        }
        do {
            let commits = try await Bridge.workspaceLog(id: id)
            guard historyLoads[id] == request else { return }
            history[id] = commits
            historyErrors[id] = nil
        } catch {
            guard historyLoads[id] == request else { return }
            historyErrors[id] = error.localizedDescription
        }
    }


    func children(of path: String, in workspaceID: String) -> [TreeEntry]? {
        tree[Self.treeKey(workspaceID, path)]
    }

    func isExpanded(_ path: String, in workspaceID: String) -> Bool {
        expandedDirectories.contains(Self.treeKey(workspaceID, path))
    }

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

    func refreshTree() async {
        for key in tree.keys {
            guard let separator = key.firstIndex(of: ":") else { continue }
            let workspaceID = String(key[key.startIndex ..< separator])
            let path = String(key[key.index(after: separator)...])
            await loadTree(path, in: workspaceID)
        }
    }


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

    func prepareCommit(_ folder: WorkspaceFolder) async -> GitCommitSession? {
        guard !isCommitting else { return nil }
        isCommitting = true
        defer { isCommitting = false }
        let changed = Set((folder.git?.files ?? []).map(\.path))
        let paths = (stagedSelection[folder.id] ?? []).intersection(changed)
        let title = (commitMessage[folder.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let target = Bridge.reviewedGitTarget(id: folder.id)
        if target.peer == nil { await WorkSessionContext.shared.resolveLocalHostIdentity() }
        let session = GitCommitSessions.session(target: target)
        await session.load()
        if session.draft.submitted == nil {
            if !paths.isEmpty { session.draft.paths = paths }
            if !title.isEmpty {
                session.draft.title = title
                session.draft.details = commitDescription[folder.id] ?? ""
            }
            await session.persist()
            await session.prepareReview()
        }
        return session
    }

    func commitCompleted(_ folder: WorkspaceFolder) async {
        stagedSelection[folder.id] = []
        commitMessage[folder.id] = ""
        commitDescription[folder.id] = ""
        report(folder.id, .commit, GitOutcome(ok: true, message: L10n.text("apple.workspacesmodel.committed_the_reviewed_selection.6566b601")))
        await refresh()
        await loadHistory(for: folder.id)
    }

    func pushCompleted(_ folder: WorkspaceFolder) async {
        report(folder.id, .push, GitOutcome(ok: true, message: L10n.text("apple.workspacesmodel.pushed_the_reviewed_commit.6edb2bd0")))
        await refresh()
        await loadHistory(for: folder.id)
    }

    func pullRefreshed(_ folder: WorkspaceFolder) async {
        await refresh()
        await loadHistory(for: folder.id)
    }

    private func report(_ workspaceID: String, _ action: GitOutcomeAction, _ outcome: GitOutcome) {
        gitOutcomeDismissTasks.removeValue(forKey: workspaceID)?.cancel()
        gitOutcomeAction[workspaceID] = action
        gitOutcome[workspaceID] = outcome
        if outcome.ok {
            gitOutcomeDismissTasks[workspaceID] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.dismissGitOutcome(for: workspaceID)
            }
        }
    }

    func dismissGitOutcome(for workspaceID: String) {
        gitOutcomeDismissTasks.removeValue(forKey: workspaceID)?.cancel()
        gitOutcome.removeValue(forKey: workspaceID)
        gitOutcomeAction.removeValue(forKey: workspaceID)
    }

    #if os(macOS)
    /// Whether the onboarding sheet that explains workspaces is up.
    ///
    /// The sheet, not the folder panel, is the entry point: a raw `NSOpenPanel`
    /// gives a new user no idea what they are being asked to pick or why.
    var isAddSheetPresented = false

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
        panel.prompt = L10n.text("apple.workspacesmodel.add_project.44b7ce21")
        panel.message = L10n.text("apple.workspacesmodel.choose_a_project_folder_tokenstat_only_rea.90507456")

        guard panel.runModal() == .OK else { return }
        await add(panel.urls)
    }

    @discardableResult
    func add(_ urls: [URL]) async -> String? {
        var lastAdded: String?
        for url in urls {
            do {
                let added = try await Bridge.addWorkspace(path: url.path)
                selectedID = added.id
                lastAdded = added.id
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await load()
        return lastAdded
    }
    #endif

    func remove(_ folder: WorkspaceFolder) async {
        if let dirty = documents.values.first(where: {
            $0.workspaceID == folder.id && $0.isDirty
        }) {
            requestClose(dirty.path, in: folder.id)
            return
        }
        do {
            if folder.isRemote, let peer = folder.machineID {
                let prefix = "remote:\(peer):"
                let raw: String = folder.id.hasPrefix(prefix)
                    ? String(folder.id.dropFirst(prefix.count))
                    : {
                        let parts = folder.id.split(separator: ":", maxSplits: 2).map(String.init)
                        return parts.count == 3 ? parts[2] : folder.id
                    }()
                struct RemovedAck: Codable, Sendable { var removed: Bool? }
                if raw == folder.id {
                    if selectedID == folder.id { selectedID = nil }
                    forgetTabs(in: folder.id)
                    remoteFolders[peer]?.removeAll(where: { $0.id == folder.id })
                    publishFolders()
                    return
                }
                _ = try await Bridge.onPeer(peer, "workspace.remove", ["id": raw], as: RemovedAck.self)
                if selectedID == folder.id { selectedID = nil }
                forgetTabs(in: folder.id)
                remoteFolders[peer]?.removeAll(where: { $0.id == folder.id })
                publishFolders()
                refreshRemotePeer(peer)
                return
            }
            try await Bridge.removeWorkspace(id: folder.id)
            if selectedID == folder.id { selectedID = nil }
            forgetTabs(in: folder.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

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
    func revealInFinder(_ folder: WorkspaceFolder) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }
    #endif
}

func groupByDirectory(_ files: [FileChange]) -> [(directory: String, files: [FileChange])] {
    var order: [String] = []
    var groups: [String: [FileChange]] = [:]
    for file in files {
        if groups[file.directory] == nil { order.append(file.directory) }
        groups[file.directory, default: []].append(file)
    }
    return order.map { ($0, groups[$0] ?? []) }
}
