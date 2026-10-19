#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise production desktop navigation, side reviews and native pane lifetimes."""
from pathlib import Path
import subprocess
import tempfile

def declaration(text, marker):
    start = text.index(marker)
    end, depth = text.index('{', start) + 1, 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatChangesWorkbenchView.swift').read_text()
start = source.index('    private func loadCommit(')
end, depth = source.index('{', start) + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method = source[start:end].replace('private func', 'func')
swift = r'''import Foundation
struct CommitDetail: Equatable { let id: String }
struct Folder { let id: String }
enum Failure: Error { case unavailable }
@MainActor enum Bridge {
    static var requests: [(String, String, CheckedContinuation<CommitDetail, Error>?)] = []
    static func workspaceShow(id: String, commit: String) async throws -> CommitDetail {
        try await withCheckedThrowingContinuation { requests.append((id, commit, $0)) }
    }
    static func answer(_ index: Int, failure: Bool = false) {
        let request = requests[index]; requests[index].2 = nil
        if failure { request.2?.resume(throwing: Failure.unavailable) }
        else { request.2?.resume(returning: .init(id: request.1)) }
    }
}
@MainActor final class Review {
    let folder = Folder(id: "workspace")
    var commitDetail: CommitDetail?
    var commitError: String?
    var loadedCommitID: String?
    var commitLoadGeneration = UUID()
''' + method + r'''
}
@MainActor func pending(_ count: Int) async {
    for _ in 0..<10000 { if Bridge.requests.count == count { return }; await Task.yield() }
    preconditionFailure("Commit read did not start")
}
@main struct Check {
    @MainActor static func main() async {
        let side = Review(), other = Review()
        let a = Task { await side.loadCommit("A") }; await pending(1)
        let b = Task { await other.loadCommit("B") }; await pending(2)
        Bridge.answer(1); await b.value
        Bridge.answer(0); await a.value
        precondition(side.commitDetail?.id == "A" && other.commitDetail?.id == "B",
                     "Concurrent surfaces must own independent immutable snapshots")
        let old = Task { await side.loadCommit("old") }; await pending(3)
        let new = Task { await side.loadCommit("new") }; await pending(4)
        Bridge.answer(3); await new.value
        Bridge.answer(2, failure: true); await old.value
        precondition(side.commitDetail?.id == "new" && side.commitError == nil,
                     "A late failure cannot replace the current commit")
        let retired = Task { await side.loadCommit("retired") }; await pending(5)
        await side.loadCommit(nil)
        Bridge.answer(4); await retired.value
        precondition(side.commitDetail == nil && side.loadedCommitID == nil,
                     "Working tree must invalidate pending commit reads")
        let failed = Task { await side.loadCommit("retry") }; await pending(6)
        Bridge.answer(5, failure: true); await failed.value
        precondition(side.loadedCommitID == "retry" && side.commitError != nil)
        let retry = Task { await side.loadCommit("retry") }; await pending(7)
        Bridge.answer(6); await retry.value
        precondition(side.commitDetail?.id == "retry" && side.commitError == nil)
        let cancelled = Task { await side.loadCommit("cancelled") }; await pending(8)
        cancelled.cancel(); Bridge.answer(7); await cancelled.value
        precondition(side.commitDetail == nil && side.loadedCommitID == nil)
        print("PASS: actual side commit reads isolate surfaces, reject stale replies, clear scope and retry failures")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-chat-workbench-') as temporary:
    folder = Path(temporary)
    (folder / 'main.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5',
                    str(folder / 'main.swift'), '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check')], check=True)

# Exercise the production desktop action coordinator separately from native
# windows. Readiness, account ownership and consumed shell intents must not
# depend on a restored window or a live host being available in the test.
desktop_root = (root / 'apps/mac/Sources/App/RootView.swift').read_text()
coordinator = r'''import Foundation
enum Fixture { static let project = "/workspace/project app" }
enum WorkReference { struct Scope: Equatable { let id: String } }
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope?
}
enum Section { case chat, files }
enum Route: Equatable {
    case home, workspace(id: String, section: Section)
    var workspaceID: String? { if case .workspace(let id, _) = self { id } else { nil } }
    var workspaceSection: Section? { if case .workspace(_, let section) = self { section } else { nil } }
}
struct Folder { let id: String }
final class Folders {
    var folders = [Folder(id: Fixture.project), Folder(id: "other")]
    var isLoading = true
    var hasLoadedDirectory = false
    var errorMessage: String?
    var chatInspectorShowsSettings = true
    var inspectorTab = DesktopOpenRequest.InspectorTab.files
}
@MainActor enum WorkViewedChange {
    static var hostReady = false
    static func owner(folderID: String) -> String? { hostReady ? folderID : nil }
}
enum L10n { static func text(_ key: String) -> String { key } }
@MainActor final class Desktop {
    var placeSettled = false
    var desktopActionScope: WorkReference.Scope?
    var desktopActionError: String?
    let workspaces = Folders()
    var pendingDesktopOpen: PendingDesktopOpen?
    var route = Route.home
    var navigation: [Route] = []
    var desktopWorkbench = DesktopWorkbenchSession()
    var desktopTurnReviews: [String: String] = [:]
    var desktopCommitReviews: [String: String] = [:]
    var workspaceBrowserURLs: [String: String] = [:]
    var desktopTerminalRequests: [String: DesktopTerminalIntent] = [:]
    var simulatorRequests: [String: String] = [:]
    func navigate(to value: Route) { route = value; navigation.append(value) }
''' + '\n'.join(declaration(desktop_root, marker).replace('private ', '') for marker in [
    'private struct PendingDesktopOpen', 'private func openDesktop(',
    'private func resolvePendingDesktopOpen(', 'private func openWorkbench(',
    'private func closeWorkbench(',
]) + r'''
}
@main struct DesktopChecks {
    static func request(_ options: String) -> DesktopOpenRequest {
        DesktopOpenRequest(url: URL(string: "tokenstat://workbench/open?workspace=" + Fixture.project.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "&" + options)!)!
    }
    @MainActor static func main() {
        let account = WorkReference.Scope(id: "first")
        let app = Desktop()
        app.openDesktop(request("tool=terminal&new=1"))
        precondition(app.pendingDesktopOpen != nil && app.navigation.isEmpty)
        app.placeSettled = true
        app.resolvePendingDesktopOpen()
        precondition(app.pendingDesktopOpen != nil, "Loading folders consumed a cold request")
        app.workspaces.isLoading = false
        app.resolvePendingDesktopOpen()
        precondition(app.pendingDesktopOpen != nil, "Unknown account consumed a cold request")
        WorkSessionContext.shared.scope = account
        app.resolvePendingDesktopOpen()
        precondition(app.pendingDesktopOpen != nil, "Action ran before scope-owned state reset")
        app.desktopActionScope = account
        app.resolvePendingDesktopOpen()
        precondition(app.pendingDesktopOpen != nil, "Missing host identity consumed a cold request")
        WorkViewedChange.hostReady = true
        app.resolvePendingDesktopOpen()
        let first = app.desktopTerminalRequests[Fixture.project]!
        precondition(first.newTerminal && app.pendingDesktopOpen == nil && app.navigation.count == 1)
        precondition(app.desktopWorkbench.state(in: Fixture.project).selected == .terminal)
        app.resolvePendingDesktopOpen()
        precondition(app.desktopTerminalRequests[Fixture.project]?.id == first.id && app.navigation.count == 1)
        app.closeWorkbench(.terminal, in: Fixture.project)
        app.openDesktop(request("tool=terminal"))
        precondition(app.desktopTerminalRequests[Fixture.project] == nil, "Reopening replayed a shell intent")
        app.openDesktop(request("tool=terminal&session=session-a"))
        precondition(app.desktopTerminalRequests[Fixture.project]?.sessionID == "session-a")
        app.openDesktop(request("tool=terminal&new=1"))
        precondition(app.desktopTerminalRequests[Fixture.project]?.id != first.id)
        app.openDesktop(request("tool=browser&url=http%3A%2F%2Flocalhost%3A8000%2Fpreview"))
        precondition(app.workspaceBrowserURLs[Fixture.project] == "http://localhost:8000/preview")
        precondition(app.desktopWorkbench.state(in: Fixture.project).selected == .browser)
        app.openDesktop(request("tool=inspector&tab=history"))
        precondition(app.workspaces.inspectorTab == .history && !app.workspaces.chatInspectorShowsSettings)
        app.desktopTurnReviews = [Fixture.project: "turn", "other": "retained"]
        let commit = String(repeating: "a", count: 40)
        app.openDesktop(request("tool=changes&commit=" + commit))
        precondition(app.desktopTurnReviews[Fixture.project] == nil && app.desktopTurnReviews["other"] == "retained")
        precondition(app.desktopCommitReviews[Fixture.project] == commit)
        app.openDesktop(request("tool=changes"))
        precondition(app.desktopCommitReviews[Fixture.project] == nil)
        let stale = Desktop()
        stale.openDesktop(request("tool=terminal&new=1"))
        WorkSessionContext.shared.scope = WorkReference.Scope(id: "second")
        stale.resolvePendingDesktopOpen()
        precondition(stale.pendingDesktopOpen == nil && stale.navigation.isEmpty && stale.desktopTerminalRequests.isEmpty)
        let missing = Desktop()
        missing.placeSettled = true; missing.desktopActionScope = WorkSessionContext.shared.scope
        missing.workspaces.isLoading = false; missing.workspaces.folders = []
        missing.openDesktop(request("tool=changes"))
        precondition(missing.pendingDesktopOpen != nil && missing.desktopActionError == nil,
                     "An idle initial inventory was mistaken for an authoritative empty list")
        missing.workspaces.hasLoadedDirectory = true
        missing.resolvePendingDesktopOpen()
        precondition(missing.desktopActionError != nil && missing.pendingDesktopOpen == nil && missing.navigation.isEmpty)
        let refreshing = Desktop()
        refreshing.placeSettled = true; refreshing.desktopActionScope = WorkSessionContext.shared.scope
        refreshing.workspaces.isLoading = true
        refreshing.openDesktop(request("tool=inspector"))
        precondition(refreshing.pendingDesktopOpen == nil && refreshing.navigation.count == 1,
                     "A background refresh blocked a known registered project")
        print("PASS: actual desktop coordinator waits for launch, folders, scope reset and host identity, rejects retired accounts and missing projects, and consumes scoped tool intents once")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-desktop-navigation-') as temporary:
    folder = Path(temporary)
    (folder / 'main.swift').write_text(coordinator)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5',
                    str(root / 'apps/mac/Sources/App/DesktopOpenRequest.swift'),
                    str(root / 'apps/mac/Sources/App/DesktopWorkbenchState.swift'),
                    str(folder / 'main.swift'), '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check')], check=True)

# Use the actual representable and WebKit coordinator, without a project host
# or URL. This catches native surfaces that survive SwiftUI opacity changes.

browser = (root / 'apps/mac/Sources/Features/Workspaces/BrowserView.swift').read_text()
target = (root / 'apps/mac/Sources/Features/Workspaces/BrowserHistory.swift').read_text()
native = '\n'.join([
    'import SwiftUI\nimport AppKit\nimport WebKit\nimport Observation',
    'enum L10n { static func text(_ key: String) -> String { key } }',
    declaration(target, 'struct BrowserTarget:'),
    declaration(browser, 'private func isLoopbackHost('),
    declaration(browser, 'private enum BrowserCommand'),
    declaration(browser, 'private struct WebBrowser:'),
    'enum Theme { static let border = Color.gray; static let accent = Color.purple }',
    declaration((root / 'apps/mac/Sources/App/ShellChrome.swift').read_text(), 'struct ColumnResizeCursorArea:'),
    declaration((root / 'apps/mac/Sources/App/ShellChrome.swift').read_text(), 'final class ColumnResizeCursorView:'),
    (root / 'apps/mac/Sources/App/DesktopWorkbenchState.swift').read_text(),
    (root / 'apps/mac/Sources/App/DesktopWorkbenchResize.swift').read_text(),
    (root / 'apps/mac/Sources/App/RetainedPaneLayout.swift').read_text(),
    '''extension View {
        func retainedPane(isActive: Bool) -> some View { RetainedPaneLayout(isActive: isActive) { self } }
    }''',
]) + r'''
@Observable private final class Probe { var visible = true }
private struct Surface: View {
    let probe: Probe
    var body: some View {
        WebBrowser(allowsExternalNavigation: false, isSurfaceVisible: probe.visible,
            url: nil, navigationGeneration: 0, historyItemToRestore: nil, command: .none, commandID: 0,
            onURLChange: { _, _ in true }, onRemoteNavigation: { _ in }, onLoadingChange: { _ in },
            onHistoryChange: { _, _ in }, onError: { _ in }, onLocalNavigation: nil,
            onPageHistoryTraverse: nil, onPageHistoryChange: { _, _, _, _ in true })
            .opacity(probe.visible ? 1 : 0)
    }
}
private final class Measurements {
    var roots = 0
    var toolWidth = 0.0
    var reservedWidth = 0.0
}
private struct ResizeSurface: View {
    let resize: DesktopWorkbenchResizeState
    let measurements: Measurements
    @State private var preferred = 520.0
    var body: some View {
        let _ = { measurements.roots += 1 }()
        HStack(spacing: 0) {
            Color.clear
            DesktopWorkbenchSpace(resize: resize, preferred: preferred, cap: 900)
                .onGeometryChange(for: Double.self, of: { $0.size.width }) { measurements.reservedWidth = $0 }
        }
        .overlay(alignment: .trailing) {
            DesktopWorkbenchPanel(resize: resize, preferred: $preferred, cap: 900, isVisible: true) {
                Color.clear.onGeometryChange(for: Double.self, of: { $0.size.width }) { measurements.toolWidth = $0 }
            }
        }
    }
}
@Observable private final class NavigationProbe {
    var workspace = "first"
    var workbench = DesktopWorkbenchSession()
}
private struct Folder: Identifiable { let id: String }
private struct Folders { let folders = [Folder(id: "first"), Folder(id: "second")] }
private struct DesktopWorkbenchBar: View {
    let state: DesktopWorkbenchState
    let open: (DesktopWorkbenchState.Tool) -> Void
    let close: (DesktopWorkbenchState.Tool) -> Void
    let hide: () -> Void
    var body: some View { Color.clear.frame(height: 44) }
}
private final class PaneIdentities { var values: [String: UUID] = [:] }
private struct IdentityProbe: View {
    let tool: DesktopWorkbenchState.Tool
    let workspace: String
    let identities: PaneIdentities
    @State private var identity = UUID()
    var body: some View {
        Text(workspace).onChange(of: workspace, initial: true) { _, workspace in
            identities.values["\(tool.rawValue):\(workspace)"] = identity
        }
    }
}
private struct NavigationSurface: View {
    let probe: NavigationProbe
    let identities: PaneIdentities
    let workspaces = Folders()
    var chatFolder: String? { probe.workspace }
    var desktopWorkbench: DesktopWorkbenchSession { probe.workbench }
    var showsWorkspaceCompanion: Bool { probe.workbench.isPresented }
    var body: some View { workspaceCompanionPane }
    func openWorkbench(_ tool: DesktopWorkbenchState.Tool, in workspace: String) { probe.workbench.open(tool, in: workspace) }
    func closeWorkbench(_ tool: DesktopWorkbenchState.Tool, in workspace: String) { probe.workbench.close(tool, in: workspace) }
    func hideWorkbench() { probe.workbench.hide() }
    func workbenchContent(_ tool: DesktopWorkbenchState.Tool, folder: Folder, active: Bool) -> some View {
        IdentityProbe(tool: tool, workspace: folder.id, identities: identities)
    }
''' + declaration((root / 'apps/mac/Sources/App/RootView.swift').read_text(), '@ViewBuilder private var workspaceCompanionPane:') + r'''
}
@main struct NativeCheck {
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Retained native browser did not adopt visibility")
    }
    @MainActor static func browser(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { browser(in: $0) }.first
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let probe = Probe()
        let host = NSHostingView(rootView: Surface(probe: probe))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        await wait { browser(in: host) != nil }
        let web = browser(in: host)!
        precondition(!web.isHidden)
        _ = try await web.evaluateJavaScript("window.workbenchProbe = 'retained'; true")
        probe.visible = false
        await wait { web.isHidden }
        probe.visible = true
        await wait { !web.isHidden }
        precondition(browser(in: host) === web, "Switching tools recreated WebKit")
        let marker = try await web.evaluateJavaScript("window.workbenchProbe") as? String
        precondition(marker == "retained", "Hiding a tool discarded its browser page")
        print("PASS: actual retained WebKit surface hides natively and restores the same page")
        let resize = DesktopWorkbenchResizeState(), measurements = Measurements()
        window.setContentSize(NSSize(width: 1280, height: 850))
        window.contentView = NSHostingView(rootView: ResizeSurface(resize: resize, measurements: measurements))
        await wait { measurements.toolWidth == 520 && measurements.reservedWidth == 525 }
        let rootRenders = measurements.roots
        for delta in 0...160 { resize.drag(translation: Double(delta), preferred: 520, cap: 900) }
        await wait { measurements.toolWidth == 360 && measurements.reservedWidth == 365 }
        precondition(measurements.roots == rootRenders, "Dragging rebuilt the chat shell instead of only its layout leaves")
        resize.drag(translation: 1000, preferred: 520, cap: 900)
        await wait { measurements.toolWidth == 320 }
        resize.drag(translation: -1000, preferred: 520, cap: 900)
        await wait { measurements.toolWidth == 900 }
        precondition(resize.finish() == 900 && !resize.isDragging)
        await wait { measurements.toolWidth == 520 }
        precondition(measurements.roots == rootRenders)
        print("PASS: actual resize leaves track both pane widths and clamps without rebuilding the chat shell")
        let navigation = NavigationProbe(), identities = PaneIdentities()
        navigation.workbench.open(.browser, in: "first")
        navigation.workbench.open(.inspector, in: "first")
        window.contentView = NSHostingView(rootView: NavigationSurface(probe: navigation, identities: identities))
        await wait { identities.values["inspector:first"] != nil && identities.values["browser:first"] != nil }
        let inspector = identities.values["inspector:first"]!, browserIdentity = identities.values["browser:first"]!
        navigation.workbench.activate(in: "second")
        navigation.workspace = "second"
        await wait { identities.values["inspector:second"] != nil }
        precondition(identities.values["inspector:second"] == inspector,
                     "Repository navigation rebuilt the inspector shell instead of updating its owner")
        navigation.workbench.open(.browser, in: "second")
        await wait { identities.values["browser:second"] != nil }
        precondition(identities.values["browser:second"] != browserIdentity,
                     "A repository-specific native tool inherited another repository's state")
        print("PASS: actual workbench keeps inspector identity across repositories while scoping native tools independently")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-workbench-browser-') as temporary:
    folder = Path(temporary)
    (folder / 'main.swift').write_text(native)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5',
                    str(root / 'apps/mac/Sources/Features/Workspaces/BrowserNavigationEpoch.swift'),
                    str(folder / 'main.swift'), '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check')], check=True)
