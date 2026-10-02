// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import SwiftUI

@MainActor
struct ProjectBrowserView: View {
    let workspaceID: String
    var initialURL = ""
    var waitsForService = false
    var allowsExternalNavigation = false
    var onURLChange: (String) -> Void = { _ in }

    var body: some View {
        let owner = WorkViewedChange.owner(folderID: workspaceID)
        let route = WorkDestinationResolver.route(folderID: workspaceID)
        ProjectBrowserContent(owner: owner, peer: route.peer, initialURL: initialURL, waitsForService: waitsForService,
            allowsExternalNavigation: allowsExternalNavigation, onURLChange: onURLChange)
            .id(BrowserHistory.key(for: owner) ?? workspaceID)
    }
}

@MainActor
private struct ProjectBrowserContent: View {
    let initialURL: String
    let waitsForService: Bool
    let allowsExternalNavigation: Bool
    let onURLChange: (String) -> Void
    let owner: WorkReference?
    let peer: String?
    @State private var session: ProjectBrowserSession

    init(owner: WorkReference?, peer: String?, initialURL: String, waitsForService: Bool,
         allowsExternalNavigation: Bool, onURLChange: @escaping (String) -> Void) {
        self.initialURL = initialURL
        self.waitsForService = waitsForService
        self.allowsExternalNavigation = allowsExternalNavigation
        self.onURLChange = onURLChange
        self.owner = owner
        self.peer = peer
        _session = State(initialValue: ProjectBrowserSession(owner: owner, peer: peer, isCurrent: {
            WorkSessionContext.shared.scope == owner?.scope
                && (peer != nil || WorkSessionContext.shared.localHostIdentity == owner?.hostIdentity)
        }))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = session.error { Banner(text: error, severity: .danger) }
            BrowserView(url: session.transportURL, allowsExternalNavigation: allowsExternalNavigation,
                navigationGeneration: session.navigationGeneration, loadRevision: session.loadRevision,
                displayURL: session.targetURL, recentPorts: session.recentPorts,
                onNavigate: { address in Task { await session.open(address) } },
                displayAddress: session.canonicalURL,
                onLocalNavigation: { request, isMainFrame, traversal in
                    session.intercept(request, isMainFrame: isMainFrame, historyItemID: traversal?.id,
                        historyDirection: traversal?.direction ?? 0)
                },
                canGoBack: session.canGoBack, canGoForward: session.canGoForward,
                onBack: { Task { await session.goBack() } },
                onForward: { Task { await session.goForward() } },
                historyItemToRestore: session.historyItemToRestore,
                onPageHistoryChange: { mutation, items, currentID, generation in
                    session.observedHistory(mutation, items: items, currentID: currentID, generation: generation)
                },
                onPageHistoryTraverse: { delta, generation in session.traverseHistory(delta, generation: generation) },
                onURLChange: { actual, completion in
                    session.observed(actual, generation: completion.generation, registered: completion.registered,
                        nativeHistoryID: completion.nativeHistoryID)
                })
                .id(session.id)
        }
        .task(id: initialURL) {
            if session.isClosed {
                session = ProjectBrowserSession(owner: owner, peer: peer, isCurrent: {
                    WorkSessionContext.shared.scope == owner?.scope
                        && (peer != nil || WorkSessionContext.shared.localHostIdentity == owner?.hostIdentity)
                })
            }
            if !initialURL.isEmpty, initialURL != session.targetURL || session.transportURL.isEmpty {
                await session.open(initialURL, waitsForService: waitsForService)
            }
        }
        .onChange(of: session.targetURL) { _, target in
            if !session.transportURL.isEmpty { onURLChange(target) }
        }
        .onDisappear { session.close() }
    }
}
#endif
