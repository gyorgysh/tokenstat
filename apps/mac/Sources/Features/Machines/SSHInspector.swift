// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if os(macOS)
/// What is being edited, beside the list rather than on top of it.
///
/// The editors are the ones the library already had: they were written as a
/// form with a footer, which is exactly the shape an inspector column wants, so
/// they move here unchanged rather than being rebuilt.
struct SSHInspector: View {
    @Bindable var model: SSHLibraryModel
    let section: SSHSection
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, Theme.Space.m)
                Spacer(minLength: 0)
            }
            body(for: model.selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }

    /// Clearing the selection is what closes an editor. One assignment, so a
    /// Cancel, a Save and the chrome bar's close all end the same way.
    private func clear() { model.selection = nil }

    @ViewBuilder
    private func body(for selection: SSHLibraryRoute?) -> some View {
        switch selection {
        case let .host(id):
            SSHHostEditor(model: model, hostID: id, folderID: nil, onDone: clear).id(id)
        case let .newHost(folder):
            // Keyed by the folder: without it, "Add server here" on a second
            // folder reuses the open form, whose `loaded` guard means it never
            // reads the new folder and files the server under the first one.
            SSHHostEditor(model: model, hostID: nil, folderID: folder, onDone: clear)
                .id(folder ?? "")
        case let .key(id):
            SSHKeyEditor(model: model, keyID: id, onDone: clear).id(id)
        case .newKey:
            SSHKeyEditor(model: model, keyID: nil, onDone: clear)
        case let .snippet(id):
            SSHSnippetEditor(model: model, snippetID: id, onDone: clear).id(id)
        case .newSnippet:
            SSHSnippetEditor(model: model, snippetID: nil, onDone: clear)
        case let .folder(id):
            SSHFolderEditor(model: model, folderID: id, parentID: nil, onDone: clear).id(id)
        case let .newFolder(parent):
            SSHFolderEditor(model: model, folderID: nil, parentID: parent, onDone: clear)
                .id(parent ?? "")
        case let .knownHost(id):
            trustedServer(id)
        case .knownHosts:
            empty
        case .importConfig:
            SSHConfigImportView(model: model, onDone: clear)
        case .importCloud:
            CloudImportForm(model: model, onDone: clear)
        case nil:
            empty
        }
    }

    /// A trusted server is a fingerprint and one button. It is not a form, so
    /// it does not get one.
    @ViewBuilder
    private func trustedServer(_ id: String) -> some View {
        if let known = model.knownHosts.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(known.label).font(.headline)
                        Text("\(known.hostname):\(known.port)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Fingerprints").font(.caption).foregroundStyle(.secondary)
                        ForEach(known.fingerprints, id: \.self) { print in
                            Text(print)
                                .font(Theme.mono(10))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("Forgetting makes the next connection ask you to confirm this server's fingerprint again. Nothing on the server changes.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Forget", .revoke) {
                        Task {
                            await model.forgetKnownHost(known)
                            clear()
                        }
                    }
                    .buttonStyle(DestructiveButtonStyle())
                    Spacer(minLength: 0)
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            empty
        }
    }

    private var empty: some View {
        InspectorEmptyState(
            systemImage: section.symbol,
            title: emptyTitle,
            subtitle: emptySubtitle
        )
    }

    private var title: String {
        switch model.selection {
        case let .host(id): return model.hosts.first { $0.id == id }?.label ?? "Server"
        case .newHost: return "Add server"
        case let .key(id): return model.keys.first { $0.id == id }?.label ?? "Key"
        case .newKey: return "Add key"
        case let .snippet(id): return model.snippets.first { $0.id == id }?.title ?? "Snippet"
        case .newSnippet: return "Add snippet"
        case let .folder(id): return model.folderName(id) ?? "Folder"
        case .newFolder: return "Add folder"
        case let .knownHost(id): return model.knownHosts.first { $0.id == id }?.label ?? "Trusted server"
        case .importConfig: return "Import from ssh config"
        case .importCloud: return "Import cloud servers"
        case .knownHosts, nil: return section.label
        }
    }

    private var emptyTitle: String {
        switch section {
        case .hosts: "Pick a server"
        case .keys: "Pick a key"
        case .snippets: "Pick a snippet"
        case .knownHosts: "Pick a server"
        }
    }

    private var emptySubtitle: String {
        switch section {
        case .hosts: "Its address, authentication and settings open here."
        case .keys: "Its fingerprint and public half open here."
        case .snippets: "The command opens here, with room to write it."
        case .knownHosts: "Its fingerprint, and the button that forgets it, open here."
        }
    }
}
#endif
