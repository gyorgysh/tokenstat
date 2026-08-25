// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if os(macOS)
/// One SSH section in the content column.
///
/// The list only. What is being edited is the inspector's job, and which
/// section is in front is the sidebar's, so this view has the whole width for
/// the thing it is actually for: finding a server in a list of forty.
///
/// Four sections share one view because they are one screen with a different
/// list in it. Splitting them would be four copies of the same header, the same
/// search field, the same empty state and the same add button.
struct SSHSectionView: View {
    @Bindable var model: SSHLibraryModel
    let section: SSHSection
    /// The account tier, unfiltered. What may write the vault is decided by
    /// `SSHLibraryModel.paidTier(for:)`, in one place.
    var vaultTier: String?
    /// Open a folder in the sidebar's own selection, so clicking a folder in
    /// the list and clicking it in the sidebar mean the same thing.
    var onOpenFolder: (String) -> Void

    @State private var connecting: SSHHost?
    @State private var terminal: SSHLiveTerminal?
    @State private var expanded: Set<String> = []
    @State private var vault = SSHVaultModel()
    @State private var showingVault = false

    private var paidVaultTier: String? { SSHLibraryModel.paidTier(for: vaultTier) }
    private var signedInUnpaid: Bool { vaultTier != nil && paidVaultTier == nil }

    var body: some View {
        VStack(spacing: 0) {
            DetailChromeBar {
                addMenu
            }
            HStack(spacing: Theme.Space.s) {
                SearchField(text: $model.search, prompt: "Search \(section.label.lowercased())")
                    .frame(maxWidth: 420)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)
            // The vault belongs to hosts and keys, not to a fingerprint list,
            // and only when there is an account to hold one.
            if vaultTier != nil, section != .knownHosts {
                SSHVaultRow(vault: vault, canWrite: paidVaultTier != nil) { showingVault = true }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, Theme.Space.s)
                // A vault that could not take a copy is a sync problem, and it
                // belongs on the vault's own row. Across the top of the screen
                // it read as "your server was not saved", which was never true.
                if let vaultError = model.vaultError {
                    let friendly = FriendlyError.from(vaultError)
                    InlineBanner(text: "Saved on this Mac, but not synced. \(friendly.message)") {
                        model.vaultError = nil
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, Theme.Space.s)
                }
            }
            if let error = model.error {
                InlineBanner(text: FriendlyError.from(error).message, kind: .danger) { model.error = nil }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, Theme.Space.s)
            }
            content
        }
        .background(Theme.background)
        .sheet(item: $connecting) { host in
            SSHConnectForm(host: host, model: model) { terminal = $0 }
        }
        .sheet(item: $terminal) {
            SSHLiveTerminalScreen(session: $0).frame(minWidth: 720, minHeight: 480)
        }
        .sheet(isPresented: $showingVault) {
            SSHVaultScreen(vault: vault, tier: vaultTier ?? "", canWrite: paidVaultTier != nil, library: model)
        }
        .task(id: vaultTier) {
            guard vaultTier != nil else { return }
            await vault.refresh()
        }
        // Opening the screen loads it. The shell warms the same model at
        // launch so the sidebar has counts, but that pass waits on the archive
        // and can fail, and a library that is empty because nothing loaded
        // must not look like a library with nothing in it.
        .task(id: vaultTier) {
            guard !model.loaded else { return }
            await model.load(vaultTier: SSHLibraryModel.paidTier(for: vaultTier))
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var addMenu: some View {
        if case .hosts = section {
            Menu {
                Button("Add host", .create) { model.selection = .newHost(folder: section.folderID) }
                Button("Add folder", .create) { model.selection = .newFolder(parent: section.folderID) }
                Divider()
                Button("Import from ssh config", .download) { model.selection = .importConfig }
                Button("Import cloud servers", .download) { model.selection = .importCloud }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else if section != .knownHosts {
            Button(section.addLabel, .create) { model.selection = addSelection }
                .buttonStyle(AccentButtonStyle(small: true))
        }
    }

    // MARK: - Lists

    @ViewBuilder
    private var content: some View {
        if signedInUnpaid, model.hosts.isEmpty, case .hosts = section {
            vaultUpgrade
            Spacer(minLength: 0)
        } else if isEmpty {
            EmptyState(symbol: section.symbol, title: emptyTitle, message: emptyMessage) {
                if section != .knownHosts {
                    Button(section.addLabel, .create) { model.selection = addSelection }
                        .buttonStyle(AccentButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchedOut {
            EmptyState(
                symbol: "magnifyingglass",
                title: "Nothing matched",
                message: "No \(section.label.lowercased()) match \u{201c}\(model.search)\u{201d}."
            ) {
                Button("Clear search", .dismiss) { model.search = "" }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        List {
            switch section {
            case .hosts:
                hostsList
            case .keys:
                ForEach(model.visibleKeys) { key in keyRow(key) }
            case .snippets:
                ForEach(model.visibleSnippets) { snippet in snippetRow(snippet) }
            case .knownHosts:
                ForEach(model.knownHosts) { known in knownHostRow(known) }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var hostsList: some View {
        // The handful somebody actually returns to, above the tree. Skipped
        // while searching: a search has already said what it wants.
        if !model.searching, !recentHosts.isEmpty {
            SwiftUI.Section("Recent") {
                ForEach(recentHosts) { host in hostRow(host, depth: 0) }
            }
        }
        SwiftUI.Section(model.searching ? "Results" : sectionTitle) {
            ForEach(rows) { row in
                switch row.kind {
                case let .folder(folder):
                    folderRow(folder, depth: row.depth)
                case let .host(host):
                    hostRow(host, depth: row.depth)
                }
            }
        }
    }

    /// The heading over the tree. A folder route says which folder, because the
    /// list is filtered to it and a heading saying "All servers" over one
    /// folder's worth of them is a heading that lies.
    private var sectionTitle: String {
        guard let folderID = section.folderID else { return "All servers" }
        return model.folderName(folderID) ?? "Folder"
    }

    /// Favourites first, then most recently connected. Scoped to the folder
    /// when the route names one.
    private var recentHosts: [SSHHost] {
        model.recentHosts.filter { section.folderID == nil || $0.folderID == section.folderID }
    }

    // MARK: - The host tree

    private struct Row: Identifiable {
        enum Kind {
            case folder(SSHFolder)
            case host(SSHHost)
        }

        let id: String
        let kind: Kind
        let depth: Int
    }

    /// One row per visible line, with its depth.
    ///
    /// Flattened rather than nested disclosure groups: a view that contains
    /// itself cannot be typed, and indentation reads the same to a person.
    private var rows: [Row] {
        // A folder route is that folder's contents, flat. The sidebar already
        // says where you are, so repeating the parent chain here would be the
        // same information twice.
        if let folderID = section.folderID {
            var out: [Row] = []
            for folder in model.folders(in: folderID) {
                out.append(Row(id: "folder:\(folder.id)", kind: .folder(folder), depth: 0))
            }
            // Scoped to the folder even while searching. `hosts(in:)` drops
            // its folder argument once a query is running, which is right at
            // the root and wrong here: the sidebar still lights this folder,
            // so a list holding somebody else's servers is a list that lies.
            for host in model.hosts(in: folderID) where host.folderID == folderID {
                out.append(Row(id: "host:\(host.id)", kind: .host(host), depth: 0))
            }
            return out
        }

        var out: [Row] = []
        func walk(parent: String?, depth: Int) {
            for folder in model.folders(in: parent) {
                out.append(Row(id: "folder:\(folder.id)", kind: .folder(folder), depth: depth))
                guard expanded.contains(folder.id) else { continue }
                walk(parent: folder.id, depth: depth + 1)
                for host in model.hosts(in: folder.id) {
                    out.append(Row(id: "host:\(host.id)", kind: .host(host), depth: depth + 1))
                }
            }
            if depth == 0 {
                for host in model.hosts(in: nil) {
                    out.append(Row(id: "host:\(host.id)", kind: .host(host), depth: 0))
                }
            }
        }
        walk(parent: nil, depth: 0)
        return out
    }

    // MARK: - Rows

    private func folderRow(_ folder: SSHFolder, depth: Int) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: expanded.contains(folder.id) ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Image(systemName: "folder")
                .foregroundStyle(SSHColor.color(folder.color))
            Text(folder.name)
            Spacer()
            Text("\(model.hosts.filter { $0.folderID == folder.id }.count)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .frame(height: Theme.Control.rowHeight)
        .contentShape(.rect)
        .onTapGesture {
            if expanded.contains(folder.id) { expanded.remove(folder.id) } else { expanded.insert(folder.id) }
        }
        .contextMenu {
            Button("Open folder") { onOpenFolder(folder.id) }
            Button("Rename folder") { model.selection = .folder(folder.id) }
            Button("Add server here") { model.selection = .newHost(folder: folder.id) }
            Button("Add sub-folder") { model.selection = .newFolder(parent: folder.id) }
            Divider()
            Button("Delete folder", role: .destructive) {
                Task { await model.delete(folder: folder) }
            }
        }
    }

    private func hostRow(_ host: SSHHost, depth: Int) -> some View {
        SSHHostRow(host: host, folder: model.folderName(host.folderID), searching: model.searching)
            .padding(.leading, CGFloat(depth) * 14)
            .listRowBackground(rowBackground(selected: model.selection == .host(host.id)))
            .contentShape(.rect)
            .onTapGesture { model.selection = .host(host.id) }
            .contextMenu {
                Button("Connect") { connecting = host }
                Button(host.favorite ? "Remove from favourites" : "Add to favourites") {
                    var updated = host
                    updated.favorite.toggle()
                    Task { _ = await model.save(host: updated) }
                }
                Button("Edit") { model.selection = .host(host.id) }
                Divider()
                Button("Delete", role: .destructive) { Task { await model.delete(host: host) } }
            }
    }

    private func keyRow(_ key: SSHKeyRecord) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.label)
                Text(key.fingerprint.isEmpty ? key.algorithm : key.fingerprint)
                    .font(Theme.mono(11)).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: {
            Image(systemName: key.hardwareBacked ? "key.radiowaves.forward" : "key.fill")
                .foregroundStyle(Theme.accent)
        }
        .frame(height: Theme.Control.rowHeight)
        .listRowBackground(rowBackground(selected: model.selection == .key(key.id)))
        .contentShape(.rect)
        .onTapGesture { model.selection = .key(key.id) }
        .contextMenu {
            Button("Delete", role: .destructive) { Task { await model.delete(key: key) } }
        }
    }

    private func snippetRow(_ snippet: SSHSnippet) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snippet.title)
            Text(snippet.command)
                .font(Theme.mono(11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(height: Theme.Control.rowHeight)
        .listRowBackground(rowBackground(selected: model.selection == .snippet(snippet.id)))
        .contentShape(.rect)
        .onTapGesture { model.selection = .snippet(snippet.id) }
        .contextMenu {
            Button("Delete", role: .destructive) { Task { await model.delete(snippet: snippet) } }
        }
    }

    private func knownHostRow(_ known: SSHKnownHost) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(known.label)
            Text("\(known.hostname):\(known.port)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(height: Theme.Control.rowHeight)
        .listRowBackground(rowBackground(selected: model.selection == .knownHost(known.id)))
        .contentShape(.rect)
        .onTapGesture { model.selection = .knownHost(known.id) }
        .contextMenu {
            Button("Forget", role: .destructive) {
                Task { await model.forgetKnownHost(known) }
            }
        }
    }

    /// Selection is the accent wash the sidebar uses, so a selected row means
    /// the same thing in both columns.
    @ViewBuilder
    private func rowBackground(selected: Bool) -> some View {
        if selected {
            Theme.rowSelected
        } else {
            Color.clear
        }
    }

    // MARK: - States

    private var addSelection: SSHLibraryRoute {
        switch section {
        case let .hosts(folder): .newHost(folder: folder)
        case .keys: .newKey
        case .snippets: .newSnippet
        // Trust is earned by connecting, not by typing a fingerprint in. The
        // add button is hidden for this section, and this is the unreachable
        // arm the compiler still wants an answer for.
        case .knownHosts: .knownHosts
        }
    }

    /// Whether this section has nothing in it at all.
    ///
    /// Counted from the unfiltered lists on purpose. `hosts(in:)` and
    /// `folders(in:)` narrow to the search, so asking them would tell somebody
    /// whose query matched nothing that they have never added a server, and
    /// offer to add their first one over the forty they already have.
    private var isEmpty: Bool {
        switch section {
        case let .hosts(folder):
            if let folder {
                return !model.hosts.contains { $0.folderID == folder }
                    && !model.folders.contains { $0.parentID == folder }
            }
            return model.hosts.isEmpty && model.folders.isEmpty
        case .keys: return model.keys.isEmpty
        case .snippets: return model.snippets.isEmpty
        case .knownHosts: return model.knownHosts.isEmpty
        }
    }

    /// The list has rows in it, but the search hid all of them.
    private var searchedOut: Bool {
        guard model.searching, !isEmpty else { return false }
        switch section {
        case .hosts: return rows.isEmpty && recentHosts.isEmpty
        case .keys: return model.visibleKeys.isEmpty
        case .snippets: return model.visibleSnippets.isEmpty
        case .knownHosts: return false
        }
    }

    private var emptyTitle: String {
        switch section {
        case .hosts: "No servers yet"
        case .keys: "No keys yet"
        case .snippets: "No snippets yet"
        case .knownHosts: "No trusted servers yet"
        }
    }

    private var emptyMessage: String {
        switch section {
        case .hosts: "Add a server once, then connect without retyping its address and username."
        case .keys: "Generate or import an SSH key to authenticate without a password."
        case .snippets: "Save commands you use often and run them from a terminal."
        case .knownHosts: "The first time you connect to a server you confirm its fingerprint. Confirmed servers are listed here."
        }
    }

    private var vaultUpgrade: some View {
        EmptyState(
            symbol: "lock.shield",
            title: "Sync SSH between your devices",
            message: "An encrypted vault keeps hosts and keys on every computer and phone signed in to this account. Supporter and above.",
            mark: "mark_plan"
        ) {
            Link("See plans", destination: URL(string: "https://tokenstat.ai/pricing")!)
                .buttonStyle(AccentButtonStyle())
        }
        .padding(Theme.Space.m)
    }
}
#endif
