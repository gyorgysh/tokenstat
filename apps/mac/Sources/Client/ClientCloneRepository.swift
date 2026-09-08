// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// Getting a repository onto a machine that has none.
///
/// A folder has to exist before it can be registered, and on a fresh server
/// nothing does. The clone runs in a real terminal rather than behind a
/// spinner: one that asks for a passphrase or an unknown host key can be
/// answered, and one that hangs looks like a terminal that stopped moving.
///
/// Nothing is ever removed, including a clone that failed halfway. It is
/// somebody's disk.
struct ClientCloneRepository: View {
    let peer: String
    let hostName: String
    var onCloned: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var parent: String?
    @State private var name = ""
    @State private var session: ClientTerminalSession?
    @State private var status: RemoteCloneStatus?
    @State private var working = false
    @State private var error: String?
    @State private var picking = false

    private var ready: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty && parent != nil
    }

    var body: some View {
        Group {
            if let session {
                running(session)
            } else {
                form
            }
        }
        .background(Theme.background)
        .navigationTitle("Clone a repository")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $picking) {
            ClientFolderPickerForClone(peer: peer, hostName: hostName) { chosen in
                parent = chosen
            }
        }
        .task { await defaultParent() }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Clone onto \(hostName)")
                    .font(Theme.title.weight(.semibold))
                Text(
                    "tokenstat runs git on that machine and registers the folder when it "
                    + "finishes. You watch the whole thing."
                )
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    field("Repository") {
                        TextField("https://github.com/owner/repo.git", text: $url)
                            .textFieldStyle(.themed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    field("Where it lands") {
                        Button {
                            picking = true
                        } label: {
                            HStack {
                                Text(parent ?? "Choose a folder")
                                    .font(Theme.monoText(13))
                                    .foregroundStyle(parent == nil ? .secondary : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(Theme.fixed(12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    field("Folder name") {
                        TextField("taken from the address", text: $name)
                            .textFieldStyle(.themed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
                Text(
                    "A private repository asks for its credentials in the terminal, and you "
                    + "can answer there."
                )
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Space.s) {
                Button(working ? "Starting…" : "Clone", .download) { Task { await start() } }
                    .clientProminentStyle()
                    .disabled(!ready || working)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func running(_ session: ClientTerminalSession) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(headline)
                    .font(ClientType.label)
                    .foregroundStyle(.secondary)
                Spacer()
                if status?.state == "running" || status == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            ThemeRule()
            ClientTerminalScreen(session: session, hostName: hostName)
            ThemeRule()
            VStack(spacing: Theme.Space.s) {
                if status?.state == "done", let id = status?.workspaceId {
                    Button("Open the folder", .next) {
                        onCloned?(id)
                        dismiss()
                    }
                    .clientProminentStyle()
                } else if status?.state == "failed" {
                    Button("Back", .back) { self.session = nil; status = nil }
                        .clientProminentStyle()
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)
        }
        .task { await watch() }
    }

    private var headline: String {
        switch status?.state {
        case "done": "Cloned. The folder is registered on \(hostName)."
        case "failed": status?.error ?? "The clone did not finish."
        default: "Cloning onto \(hostName)…"
        }
    }

    private func field<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(ClientType.caption).foregroundStyle(.secondary)
            content()
        }
    }

    /// Start at the machine's own home, so the common case needs no picking.
    private func defaultParent() async {
        guard parent == nil else { return }
        parent = try? await Bridge.browse(peer: peer, path: nil).path
    }

    private func start() async {
        guard let parent else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            let info = try await Bridge.clone(
                peer: peer,
                url: url.trimmingCharacters(in: .whitespaces),
                parent: parent,
                name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
            )
            session = ClientTerminalSession(peer: peer, info: info)
        } catch { self.error = ClientSetupModel.readable(error) }
    }

    /// The machine registers the folder itself when git exits, so this asks it
    /// what happened rather than deciding from what scrolled past.
    private func watch() async {
        guard let id = session?.hostID else { return }
        let deadline = Date().addingTimeInterval(1800)
        while Date() < deadline, !Task.isCancelled {
            if let answer = try? await Bridge.cloneStatus(peer: peer, sessionID: id) {
                status = answer
                if answer.state != "running" { return }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// The picker, in the shape the clone screen needs: a folder to land in
/// rather than a folder to register.
private struct ClientFolderPickerForClone: View {
    let peer: String
    let hostName: String
    let onChosen: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var listing: RemoteListing?
    @State private var error: String?
    @State private var newFolder = ""
    @State private var naming = false

    var body: some View {
        VStack(spacing: 0) {
            if let listing {
                HStack(spacing: Theme.Space.s) {
                    if let parent = listing.parent {
                        Button("Up", .back) { Task { await load(parent) } }
                            .font(ClientType.label)
                            .buttonStyle(.plain)
                            .tint(Theme.accent)
                    }
                    Text(listing.path)
                        .font(Theme.monoText(13))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                ThemeRule()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error {
                        InlineBanner(text: error, kind: .danger) { self.error = nil }
                            .padding(Theme.Space.m)
                    }
                    ForEach((listing?.entries ?? []).filter { $0.isDirectory && !$0.hidden }) { entry in
                        Button {
                            guard let path = entry.path else { return }
                            Task { await load(path) }
                        } label: {
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: "folder").foregroundStyle(Theme.accent)
                                Text(entry.name).font(ClientType.body)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(Theme.fixed(12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, Theme.Space.m)
                            .padding(.vertical, Theme.Space.s)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        ThemeRule()
                    }
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Where it lands")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New folder", .create) { naming = true }
                    .disabled(listing == nil)
            }
        }
        .alert("New folder", isPresented: $naming) {
            TextField("Name", text: $newFolder)
            Button("Cancel", role: .cancel) { newFolder = "" }
            Button("Create") { Task { await create() } }
        } message: {
            Text("It is made on \(hostName), inside the folder you are looking at.")
        }
        .safeAreaInset(edge: .bottom) {
            if let listing {
                Button("Land it here", .approve) {
                    onChosen(listing.path)
                    dismiss()
                }
                .clientProminentStyle()
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .task { await load(nil) }
    }

    private func load(_ path: String?) async {
        do { listing = try await Bridge.browse(peer: peer, path: path) }
        catch { self.error = ClientSetupModel.readable(error) }
    }

    private func create() async {
        let name = newFolder.trimmingCharacters(in: .whitespaces)
        newFolder = ""
        guard !name.isEmpty, let here = listing?.path else { return }
        do {
            let made = try await Bridge.makeDirectory(peer: peer, path: "\(here)/\(name)")
            listing = try await Bridge.browse(peer: peer, path: made)
        } catch { self.error = ClientSetupModel.readable(error) }
    }
}

#endif
