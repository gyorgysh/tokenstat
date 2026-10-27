// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// One folder's sharing on this computer, about to end. A folder can be
/// shared with more than one team, and stopping it from the sidebar ends all
/// of them, because the sidebar names the folder rather than a team.
struct TeamStopSharingRequest: Identifiable {
    let id = UUID()
    let name: String
    let publications: [TeamLocalPublication]
}

extension TeamStore {
    /// Ends these publications on this computer. Only the sharing ends: the
    /// folder, its chats and its history stay as they are. Returns whether
    /// the account server still has cleanup to do for any of them.
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
            // Some may have stopped before the failure. Show what is true now.
            await refreshLocalProjects()
            throw error
        }
        await refreshLocalProjects()
        // The team's lists count sharing computers, so read them again.
        await reloadAfterChange()
        return cleanupPending
    }
}

/// Asks before ending sharing, and says plainly that the project stays here.
struct TeamStopSharingConfirm: ViewModifier {
    let store: TeamStore
    @Binding var request: TeamStopSharingRequest?
    /// Runs as soon as the attempt ends, to reread what it changed.
    var onStopped: () -> Void = {}
    /// Runs once sharing has stopped and the person has seen any notice. A
    /// sheet that closes itself belongs here: closing it earlier would take
    /// the alert with it, and after a failure it stays open for a retry.
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
