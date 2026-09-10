// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import SwiftUI
import Observation

@MainActor @Observable final class DesktopSavedWorkCatalog {
    private var scope: WorkReference.Scope?
    private var ids: Set<String> = []

    func contains(_ reference: WorkReference) -> Bool {
        guard scope == reference.scope, let id = WorkCache.recordID(for: reference) else { return false }
        return ids.contains(id) && WorkCacheAccess.canRead(reference)
    }

    func observe(scope: WorkReference.Scope?) async {
        self.scope = scope
        ids = []
        guard let scope else { return }
        let changes = await WorkSearchCache.shared.changes()
        await refresh(scope)
        for await _ in changes {
            guard !Task.isCancelled, self.scope == scope else { return }
            await refresh(scope)
        }
    }

    private func refresh(_ scope: WorkReference.Scope) async {
        let wireScope = WorkCache.scope(for: scope)
        let listing = try? await Bridge.cacheList(scope: wireScope)
        guard !Task.isCancelled, self.scope == scope else { return }
        ids = Set(listing?.records.filter { $0.scope == wireScope && $0.kind == "conversation" }.map(\.id) ?? [])
    }
}

struct DesktopSavedConversation: View {
    struct Destination: Identifiable {
        let reference: WorkReference
        var id: WorkReference { reference }
    }
    let destination: Destination
    @Environment(\.dismiss) private var dismiss
    @State private var model = ChatModel()
    @State private var loaded = false
    @State private var available = false

    private var current: Bool { WorkCacheAccess.canRead(destination.reference) }

    var body: some View {
        ThemedSheet(title: "Saved conversation", subtitle: "Work kept on this Mac", icon: .comment,
                    onClose: { dismiss() }) {
            if current {
                if available {
                    ChatView(model: model, workspaceID: model.folderID ?? destination.reference.workspaceID,
                             showingOverview: .constant(false),
                             loadsWorkspace: false)
                } else if loaded {
                    Text("This conversation has no readable saved copy on this Mac. Reconnect its machine and open the folder to read it live.")
                        .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                } else { ProgressView("Opening saved conversation") }
            }
        }
        .modalFrame(width: 900, height: 760)
        .task {
            available = await model.loadSavedConversation(destination.reference)
            if available, let anchor = destination.reference.anchor {
                var reference = destination.reference
                reference.anchor = anchor
                _ = model.restoreSearchReadingPosition(reference)
            }
            loaded = true
        }
        .onChange(of: current) { _, value in if !value { dismiss() } }
        .onDisappear { model.saveDraftNow() }
    }
}
#endif
