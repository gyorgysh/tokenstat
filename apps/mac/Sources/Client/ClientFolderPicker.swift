// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// Choosing a folder on a machine that has no file panel.
///
/// A phone has no open panel and a server has no screen, so the machine
/// answers the question instead and this draws the answer. What may be
/// browsed is decided there, not here: a path outside the machine's own roots
/// is refused by the host, and this screen never tries to work around that.
struct ClientFolderPicker: View {
    let peer: String
    let hostName: String
    /// Called with the registered folder, so the screen behind can open it.
    var onAdded: ((WorkspaceFolder) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var listing: RemoteListing?
    @State private var loading = false
    @State private var error: String?
    @State private var showHidden = false
    @State private var newFolder = ""
    @State private var naming = false

    var body: some View {
        VStack(spacing: 0) {
            if let listing {
                header(listing)
                ThemeRule()
            }
            content
        }
        .background(Theme.background)
        .navigationTitle("Choose a folder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(showHidden ? "Hide dotfiles" : "Show dotfiles", .visibility) {
                        showHidden.toggle()
                    }
                    Button("New folder here", .create) { naming = true }
                        .disabled(listing == nil)
                } label: {
                    Image(systemName: ActionIcon.more.symbol)
                }
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
                VStack(spacing: Theme.Space.s) {
                    Button("Use this folder", .approve) {
                        Task { await add(path: listing.path) }
                    }
                    .clientProminentStyle()
                    .disabled(loading)
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .task { await load(nil) }
    }

    /// Where you are, and the way back up. The roots are the machine's own, so
    /// this is a real answer rather than a guess about somebody's disk.
    private func header(_ listing: RemoteListing) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
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
            if listing.roots.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(listing.roots) { root in
                            Button(root.label, .reveal) { Task { await load(root.path) } }
                                .font(ClientType.caption)
                                .buttonStyle(.plain)
                                .tint(Theme.accent)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                        .padding(Theme.Space.m)
                }
                if loading && listing == nil {
                    ClientWireframe.Rows(count: 6).padding(Theme.Space.m)
                } else if let listing {
                    let rows = listing.entries.filter { showHidden || !$0.hidden }
                    if rows.isEmpty {
                        Text(listing.entries.isEmpty
                            ? "This folder is empty."
                            : "Everything here is a dotfile. Show them from the menu.")
                            .font(ClientType.label)
                            .foregroundStyle(.secondary)
                            .padding(Theme.Space.m)
                    }
                    ForEach(rows) { entry in
                        row(entry)
                        ThemeRule()
                    }
                    if listing.truncated {
                        Text("Only the first 2000 entries are shown.")
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                            .padding(Theme.Space.m)
                    }
                }
            }
        }
    }

    private func row(_ entry: RemoteListing.Entry) -> some View {
        Button {
            guard entry.isDirectory, let path = entry.path else { return }
            Task { await load(path) }
        } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: symbol(entry))
                    .foregroundStyle(entry.isDirectory ? Theme.accent : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(ClientType.body)
                        .foregroundStyle(entry.isDirectory ? .primary : .secondary)
                        .lineLimit(1)
                    if entry.isRegistered {
                        Text("already registered")
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(Theme.fixed(12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!entry.isDirectory)
    }

    private func symbol(_ entry: RemoteListing.Entry) -> String {
        if entry.isRepo { return "shippingbox" }
        if entry.isDirectory { return "folder" }
        return "doc"
    }

    private func load(_ path: String?) async {
        loading = true
        error = nil
        defer { loading = false }
        do { listing = try await Bridge.browse(peer: peer, path: path) }
        catch { self.error = ClientSetupModel.readable(error) }
    }

    private func create() async {
        let name = newFolder.trimmingCharacters(in: .whitespaces)
        newFolder = ""
        guard !name.isEmpty, let here = listing?.path else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let made = try await Bridge.makeDirectory(peer: peer, path: "\(here)/\(name)")
            listing = try await Bridge.browse(peer: peer, path: made)
        } catch { self.error = ClientSetupModel.readable(error) }
    }

    private func add(path: String) async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let folder = try await Bridge.addWorkspace(peer: peer, path: path)
            onAdded?(folder)
            dismiss()
        } catch { self.error = ClientSetupModel.readable(error) }
    }
}

#endif
