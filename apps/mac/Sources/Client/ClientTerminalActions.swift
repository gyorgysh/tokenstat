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
    private var title: String { SidebarTerminalNames.shared.name(for: reference) ?? "Terminal" }

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Rename terminal", .edit) { rename = true }.disabled(reference == nil)
            Button("Duplicate terminal", .copy) {
                guard !duplicating, owner != nil, owner == WorkSessionContext.shared.scope else { return }
                duplicating = true
                Task {
                    defer { duplicating = false }
                    do {
                        let catalog = try await ClientRemote.launcherCatalog(peer: peer)
                        guard owner == WorkSessionContext.shared.scope else { throw ClientActionOwnership.changed }
                        guard let shell = catalog.first(where: { $0.id == "shell" && $0.installed }) else {
                            throw NSError(domain: "Terminal", code: 1, userInfo: [NSLocalizedDescriptionKey: "The project's computer has no shell launcher."])
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
                Button(PinnedWorkStore.shared.isPinned(reference) ? "Unpin terminal" : "Pin terminal", .pin) {
                    guard owner == WorkSessionContext.shared.scope else { return }
                    if PinnedWorkStore.shared.isPinned(reference) { PinnedWorkStore.shared.unpin(reference) }
                    else if !PinnedWorkStore.shared.pin(reference, label: title, folderName: folderName) {
                        error = "Pinned work holds eight items. Unpin one before adding another."
                    }
                }
            }
        }
        .sheet(isPresented: $rename) {
            ClientNameEditor(title: "Rename terminal", initial: title) { name in
                guard owner != nil, owner == WorkSessionContext.shared.scope else { throw ClientActionOwnership.changed }
                SidebarTerminalNames.shared.rename(reference, to: name, folderName: folderName)
            }
        }
        .alert("Terminal action failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}
#endif
