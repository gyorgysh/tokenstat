// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct TeamStopSharingRequest: Identifiable {
    let id = UUID()
    let name: String
    let publications: [TeamLocalPublication]
}

extension TeamStore {
    func stopSharing(_ publications: [TeamLocalPublication]) async throws -> Bool {
        guard let context = mutationContext else { throw CancellationError() }
        var cleanupPending = false
        do {
            for publication in publications {
                let result: TeamCheckoutWithdrawn = try await perform(.checkoutWithdraw,
                    fields: ["checkout": .string(publication.id), "expectedRevision": .uint(publication.revision)], context: context)
                guard result.withdrawn else { throw CancellationError() }
                cleanupPending = cleanupPending || result.accountCleanupPending == true
            }
        } catch {
            await refreshLocalProjects()
            throw error
        }
        await refreshLocalProjects()
        await reloadAfterChange()
        return cleanupPending
    }
}

struct TeamStopSharingConfirm: ViewModifier {
    let store: TeamStore
    @Binding var request: TeamStopSharingRequest?
    var onStopped: () -> Void = {}
    var onFinished: () -> Void = {}
    @State private var outcome: String?
    @State private var failed = false

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                L10n.text("common.teams.stop_sharing_project", request?.name ?? ""),
                isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                titleVisibility: .visible,
                presenting: request
            ) { request in
                Button(L10n.text("common.teams.stop_sharing"), role: .destructive) { Task { await stop(request) } }
                Button(L10n.text("common.cancel"), role: .cancel) { self.request = nil }
            } message: { request in
                Text(L10n.text("common.teams.stop_sharing_project_detail", request.name))
            }
            .alert(
                failed ? L10n.text("common.teams.stop_sharing_failed") : L10n.text("common.teams.sharing_stopped"),
                isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil; if !failed { onFinished() } } })
            ) {
                Button(L10n.text("common.done"), role: .cancel) {}
            } message: { Text(outcome ?? "") }
    }

    private func stop(_ request: TeamStopSharingRequest) async {
        self.request = nil
        do {
            let pending = try await store.stopSharing(request.publications)
            onStopped()
            if pending { failed = false; outcome = L10n.text("common.teams.cleanup_pending") } else { onFinished() }
        } catch is CancellationError {
        } catch {
            onStopped()
            failed = true; outcome = error.localizedDescription
        }
    }
}
