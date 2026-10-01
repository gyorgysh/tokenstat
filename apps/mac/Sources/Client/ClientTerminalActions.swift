// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI
import UIKit

struct ClientTerminalActions: ViewModifier {
    let peer: String
    let workspaceID: String
    let folderName: String
    let info: PtySessionInfo
    let onDuplicate: (PtySessionInfo) -> Void
    @State private var owner = WorkSessionContext.shared.scope
    @State private var rename = false
    @State private var error: String?
    @State private var duplicating = false

    private var reference: WorkReference? {
        guard !workspaceID.isEmpty else { return nil }
        return owner.map { WorkReference(scope: $0, hostIdentity: peer, workspaceID: workspaceID, kind: .terminal, itemID: info.id) }
    }
    private var title: String { SidebarTerminalNames.shared.name(for: reference) ?? L10n.text("apple.clientterminalactions.terminal.e0926fda") }

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(L10n.text("apple.clientterminalactions.rename_terminal.68e0c2a6"), .edit) { rename = true }.disabled(reference == nil)
            Button(L10n.text("apple.clientterminalactions.duplicate_terminal.4d6bc239"), .copy) {
                guard !duplicating, owner != nil, owner == WorkSessionContext.shared.scope else { return }
                duplicating = true
                Task {
                    defer { duplicating = false }
                    do {
                        let catalog = try await ClientRemote.launcherCatalog(peer: peer)
                        guard owner == WorkSessionContext.shared.scope else { throw ClientActionOwnership.changed }
                        guard let shell = catalog.first(where: { $0.id == "shell" && $0.installed }) else {
                            throw NSError(domain: L10n.text("apple.clientterminalactions.terminal.e0926fda"), code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("apple.clientterminalactions.the_project_s_computer_has_no_shell_launch.87c80761")])
                        }
                        let copied = try await ClientRemote.ptySpawn(peer: peer, workspaceID: workspaceID,
                            command: shell.command, args: shell.args, rows: info.rows, cols: info.cols,
                            dark: UITraitCollection.current.userInterfaceStyle == .dark)
                        guard owner == WorkSessionContext.shared.scope else { throw ClientActionOwnership.changed }
                        let copiedReference = owner.map { WorkReference(scope: $0, hostIdentity: peer, workspaceID: workspaceID, kind: .terminal, itemID: copied.id) }
                        SidebarTerminalNames.shared.rename(copiedReference, to: title + " copy", folderName: folderName)
                        onDuplicate(copied)
                    } catch { self.error = error.localizedDescription }
                }
            }.disabled(duplicating || reference == nil)
            if let reference {
                Button(PinnedWorkStore.shared.isPinned(reference) ? L10n.text("apple.clientterminalactions.unpin_terminal.5d0dea07") : L10n.text("apple.clientterminalactions.pin_terminal.f3b6f5d8"), .pin) {
                    guard owner == WorkSessionContext.shared.scope else { return }
                    if PinnedWorkStore.shared.isPinned(reference) { PinnedWorkStore.shared.unpin(reference) }
                    else if !PinnedWorkStore.shared.pin(reference, label: title, folderName: folderName) {
                        error = L10n.text("apple.clientterminalactions.pinned_work_holds_eight_items_unpin_one_be.e716eb5e")
                    }
                }
            }
        }
        .sheet(isPresented: $rename) {
            ClientNameEditor(title: L10n.text("apple.clientterminalactions.rename_terminal.68e0c2a6"), initial: title) { name in
                guard owner != nil, owner == WorkSessionContext.shared.scope else { throw ClientActionOwnership.changed }
                SidebarTerminalNames.shared.rename(reference, to: name, folderName: folderName)
            }
        }
        .alert(L10n.text("apple.clientterminalactions.terminal_action_failed.39ba0051"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.text("apple.clientterminalactions.ok.565339bc"), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}
#endif
