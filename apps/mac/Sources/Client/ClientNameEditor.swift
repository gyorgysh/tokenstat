// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

struct ClientNameEditor: View {
    let title: String
    let initial: String
    let save: @MainActor (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    private var clean: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.text("apple.clientnameeditor.name.dcd1d522"), text: $name).disabled(saving)
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("common.cancel")) { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("common.save"), .save) {
                        saving = true
                        Task {
                            do { try await save(clean); dismiss() }
                            catch { self.error = error.localizedDescription; saving = false }
                        }
                    }.disabled(saving || clean.isEmpty || clean.count > 120 || clean.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
                }
            }
            .onAppear { name = initial }
        }
    }
}

struct ClientProjectRename: ViewModifier {
    let peer: String
    let folder: WorkspaceFolder
    var onChanged: @MainActor () async -> Void = {}
    @State private var showing = false
    @State private var owner = WorkSessionContext.shared.scope
    func body(content: Content) -> some View {
        content.contextMenu {
            Button(L10n.text("apple.clientnameeditor.rename_project.2a0478ee"), .edit) { showing = true }
        }
        .sheet(isPresented: $showing) {
            ClientNameEditor(title: L10n.text("apple.clientnameeditor.rename_project.2a0478ee"), initial: folder.name) { name in
                guard owner != nil, owner == WorkSessionContext.shared.scope else { throw ClientActionOwnership.changed }
                let id = "remote:\(peer):\(ClientRemote.rawWorkspaceID(of: folder) ?? folder.id)"
                _ = try await Bridge.renameWorkspace(id: id, name: name)
                guard owner == WorkSessionContext.shared.scope else { throw ClientActionOwnership.changed }
                await onChanged()
            }
        }
    }
}

struct ClientProjectRenameButton: View {
    let peer: String
    let folder: WorkspaceFolder
    var onChanged: @MainActor () async -> Void = {}
    @State private var showing = false
    @State private var owner = WorkSessionContext.shared.scope
    var body: some View {
        Button(L10n.text("apple.clientnameeditor.rename_project.2a0478ee"), .edit) { showing = true }
        .sheet(isPresented: $showing) {
            ClientNameEditor(title: L10n.text("apple.clientnameeditor.rename_project.2a0478ee"), initial: folder.name) { name in
                guard owner != nil, owner == WorkSessionContext.shared.scope else { throw ClientActionOwnership.changed }
                _ = try await Bridge.renameWorkspace(id: "remote:\(peer):\(ClientRemote.rawWorkspaceID(of: folder) ?? folder.id)", name: name)
                guard owner == WorkSessionContext.shared.scope else { throw ClientActionOwnership.changed }
                await onChanged()
            }
        }
    }
}

enum ClientActionOwnership: LocalizedError {
    case changed
    var errorDescription: String? { L10n.text("apple.clientnameeditor.the_account_changed_open_this_project_agai.5ed7dc73") }
}
#endif
