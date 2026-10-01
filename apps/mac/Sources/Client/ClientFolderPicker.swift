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
    /// Guards against stale responses when rows are tapped in quick succession.
    @State private var generation = 0

    var body: some View {
        VStack(spacing: 0) {
            if let listing {
                header(listing)
                ThemeRule()
            }
            content
        }
        .background(Theme.background)
        .navigationTitle(L10n.text("apple.clientfolderpicker.choose_a_folder.5c71b8cd"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(showHidden ? L10n.text("apple.clientfolderpicker.hide_dotfiles.6f372c94") : L10n.text("apple.clientfolderpicker.show_dotfiles.13e0a8dc"), .visibility) {
                        showHidden.toggle()
                    }
                    Button(L10n.text("apple.clientfolderpicker.new_folder_here.8d63070d"), .create) { naming = true }
                        .disabled(listing == nil)
                } label: {
                    Image(systemName: ActionIcon.more.symbol)
                }
            }
        }
        .alert(L10n.text("apple.clientfolderpicker.new_folder.cf28f49e"), isPresented: $naming) {
            TextField(L10n.text("apple.clientfolderpicker.name.dcd1d522"), text: $newFolder)
            Button(L10n.text("common.cancel"), role: .cancel) { newFolder = "" }
            Button(L10n.text("apple.clientfolderpicker.create.4759498a")) { Task { await create() } }
        } message: {
            Text(L10n.text("apple.clientfolderpicker.it_is_made_on_0_inside_the_folder_you_are.7077098c", "\(hostName)"))
        }
        .safeAreaInset(edge: .bottom) {
            if let listing {
                VStack(spacing: Theme.Space.s) {
                    Button(L10n.text("apple.clientfolderpicker.use_this_folder.30cbaeca"), .approve) {
                        Task { await add(path: listing.path) }
                    }
                    .clientProminentStyle()
                    .disabled(loading)
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .frame(maxWidth: .infinity)
                .background(Theme.background)
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
                    Button(L10n.text("apple.clientfolderpicker.up.55490a4b"), .back) { Task { await load(parent) } }
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
                            ? L10n.text("apple.clientfolderpicker.this_folder_is_empty.bd88d713")
                            : L10n.text("apple.clientfolderpicker.everything_here_is_a_dotfile_show_them_fro.49521138"))
                            .font(ClientType.label)
                            .foregroundStyle(.secondary)
                            .padding(Theme.Space.m)
                    }
                    ForEach(rows) { entry in
                        row(entry)
                        ThemeRule()
                    }
                    if listing.truncated {
                        Text(L10n.text("apple.clientfolderpicker.only_the_first_2000_entries_are_shown.9134432a"))
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
                        Text(L10n.text("apple.clientfolderpicker.already_registered.7a14f6c9"))
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
        generation &+= 1
        let current = generation
        loading = true
        error = nil
        defer { if current == generation { loading = false } }
        do {
            let answer = try await Bridge.browse(peer: peer, path: path)
            guard current == generation else { return }
            listing = answer
        }
        catch {
            guard current == generation else { return }
            self.error = ClientSetupModel.readable(error)
        }
    }

    private func create() async {
        let name = newFolder.trimmingCharacters(in: .whitespaces)
        newFolder = ""
        guard !name.isEmpty, let here = listing?.path else { return }
        guard !name.contains("/"), !name.contains("\\"), name != "..", name != "." else {
            self.error = L10n.text("apple.clientfolderpicker.a_folder_name_is_one_name_without_a_path_i.d41badd4")
            return
        }
        // Same guard as a browse: creating and then listing is two awaits, and
        // a browse started while they run must win the screen.
        generation &+= 1
        let current = generation
        loading = true
        error = nil
        defer { if current == generation { loading = false } }
        do {
            let made = try await Bridge.makeDirectory(peer: peer, path: "\(here)/\(name)")
            guard current == generation else { return }
            let answer = try await Bridge.browse(peer: peer, path: made)
            guard current == generation else { return }
            listing = answer
        } catch {
            guard current == generation else { return }
            self.error = ClientSetupModel.readable(error)
        }
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
