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
        ThemedSheet(title: L10n.text("apple.desktopsavedwork.saved_conversation.20844222"), subtitle: L10n.text("apple.desktopsavedwork.work_kept_on_this_mac.6d1f8dc8"), icon: .comment,
                    onClose: { dismiss() }) {
            if current {
                if available {
                    ChatView(model: model, workspaceID: model.folderID ?? destination.reference.workspaceID,
                             showingOverview: .constant(false),
                             loadsWorkspace: false)
                } else if loaded {
                    Text(L10n.text("apple.desktopsavedwork.this_conversation_has_no_readable_saved_co.f49077e3"))
                        .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                } else { ProgressView(L10n.text("apple.desktopsavedwork.opening_saved_conversation.0d440015")) }
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
