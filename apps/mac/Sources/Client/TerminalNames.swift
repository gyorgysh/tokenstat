// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// Presentation labels are local to an account and the terminal's owning host.
/// Renaming a shell never writes commands into its input or changes its OSC title.
@MainActor @Observable
final class SidebarTerminalNames {
    static let shared = SidebarTerminalNames()
    private var revision = 0

    func name(for reference: WorkReference?) -> String? {
        _ = revision
        guard let reference, let key = key(reference) else { return nil }
        return UserDefaults.standard.string(forKey: key)
    }

    func name(peer: String, workspaceID: String?, sessionID: String) -> String? {
        guard let scope = WorkSessionContext.shared.scope, let workspaceID, !workspaceID.isEmpty else { return nil }
        return name(for: WorkReference(scope: scope, hostIdentity: peer, workspaceID: workspaceID, kind: .terminal, itemID: sessionID))
    }

    func rename(_ reference: WorkReference?, to name: String, folderName: String) {
        guard let reference, let key = key(reference) else { return }
        UserDefaults.standard.set(name, forKey: key)
        revision &+= 1
        if PinnedWorkStore.shared.isPinned(reference) {
            PinnedWorkStore.shared.pin(reference, label: name, folderName: folderName)
        }
    }

    private func key(_ reference: WorkReference) -> String? {
        guard reference.kind == .terminal, let item = reference.itemID else { return nil }
        return "terminal.name.v1." + WorkReferenceKey.folder(scope: reference.scope,
            hostIdentity: reference.hostIdentity, workspaceID: reference.workspaceID)
            + WorkReferenceKey.encode(item)
    }
}
