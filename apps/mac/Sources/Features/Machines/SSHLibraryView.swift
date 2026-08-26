// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

/// What the detail side of the library is showing.
///
/// A value rather than a pile of `@State` booleans, because the old screen had
/// one flag per sheet and no way to say "editing this host": adding was the
/// only thing it could express.
enum SSHLibraryRoute: Hashable {
    case host(String)
    case newHost(folder: String?)
    case key(String)
    case newKey
    case snippet(String)
    case newSnippet
    case folder(String)
    case newFolder(parent: String?)
    case knownHost(String)
    case knownHosts
    case importConfig
    case importCloud
}

/// The SSH library: hosts, keys and snippets, with folders and search.
///
/// One screen with a list and a detail side, rather than a segmented picker
/// over three lists and a fixed-size sheet per action. The sheets were the
/// problem: a snippet is a shell script and it was being edited in a box 380
/// points tall, and a host had nowhere to show what it was actually configured
/// to do. Sheets are kept for the two things that really are modal and
/// dangerous: the recovery code, and confirming a deletion.
///
/// The phone and the iPad only. The Mac used to present this same view in a
/// sheet over Devices; it has an SSH section in the sidebar and three columns
/// of its own now, so what is left here is the push stack, which was already
/// the right shape for a phone.
#if !os(macOS)
struct SSHLibraryView: View {
    var vaultTier: String?
    var onClose: (() -> Void)?

    enum Section: String, CaseIterable, Identifiable {
        case hosts = "Hosts"
        case keys = "Keys"
        case snippets = "Snippets"
        var id: String { rawValue }
    }

    @Environment(ClientStore.self) private var store
    @State private var model = SSHLibraryModel()
    @State private var section = Section.hosts
    @State private var route: SSHLibraryRoute?
    @State private var connecting: SSHHost?
    /// Live sessions. Recreated with this screen, and that is fine: the shells
    /// belong to the host process, so `reconcile` finds them again and reading
    /// from offset zero replays what is still buffered. Leaving the screen
    /// leaves them running, which is the whole change.
    @State private var sessions = SSHSessionsModel()
    @State private var showingTerminal = false
    @State private var vault = SSHVaultModel()
    @State private var showingVault = false
    @State private var expanded: Set<String> = []

    private var paidVaultTier: String? { SSHLibraryModel.paidTier(for: vaultTier) }

    private var signedInUnpaid: Bool { vaultTier != nil && paidVaultTier == nil }

    var body: some View {
        content
            .task { await model.load(vaultTier: paidVaultTier) }
            .task { await vault.refresh() }
            .sheet(isPresented: $showingVault) {
                SSHVaultScreen(
                    vault: vault,
                    tier: vaultTier ?? "",
                    canWrite: paidVaultTier != nil,
                    library: model
                )
            }
            .task { await sessions.watch() }
            .sheet(item: $connecting) { host in
                SSHConnectForm(host: host, model: model) { session in
                    sessions.adopt(
                        session,
                        startup: session.hostID.map { model.startupSnippets(for: $0) } ?? []
                    )
                    showingTerminal = true
                }
            }
            .fullScreenCover(isPresented: $showingTerminal) {
                if let session = sessions.selected {
                    SSHLiveTerminalScreen(
                        sessions: sessions,
                        session: session,
                        library: model,
                        onNewSession: {
                            guard let hostID = session.hostID,
                                  let host = model.hosts.first(where: { $0.id == hostID })
                            else { return }
                            showingTerminal = false
                            connecting = host
                        }
                    )
                    // Keyed on the session, so switching tabs rebuilds the
                    // screen around the new one rather than leaving the old
                    // emulator mounted under a new title.
                    .id(session.id)
                }
            }
    }

    // MARK: - The screen

    /// One pushed screen, on the stack it was opened from.
    ///
    /// The Mac used to present this same view in a sheet with a list pane and a
    /// detail pane inside it. It has a sidebar section and three columns of its
    /// own now, so what is left here is the phone's shape, which was already
    /// the right one.
    private var content: some View {
        listSide
            .navigationTitle("SSH")
            .toolbar { toolbarContent }
            // Pushed onto whichever stack this screen was opened from, rather
            // than onto one of its own: Devices already owns a stack, and a
            // second one inside it draws a second title bar.
            .navigationDestination(item: $route) { destination($0) }
    }

    @ViewBuilder
    private func destination(_ route: SSHLibraryRoute) -> some View {
        switch route {
        case let .host(id):
            SSHHostEditor(model: model, hostID: id, folderID: nil, onDone: close)
                .toolbar {
                    // Same reason as the Mac inspector: the screen showing the
                    // whole server had no way to reach it.
                    if let host = model.hosts.first(where: { $0.id == id }) {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Connect", .connect) { connecting = host }
                        }
                    }
                }
        case let .newHost(folder):
            SSHHostEditor(model: model, hostID: nil, folderID: folder, onDone: close)
        case let .key(id):
            SSHKeyEditor(model: model, keyID: id, onDone: close)
        case .newKey:
            SSHKeyEditor(model: model, keyID: nil, onDone: close)
        case let .snippet(id):
            SSHSnippetEditor(model: model, snippetID: id, onDone: close)
        case .newSnippet:
            SSHSnippetEditor(model: model, snippetID: nil, onDone: close)
        case let .folder(id):
            SSHFolderEditor(model: model, folderID: id, parentID: nil, onDone: close)
        case let .newFolder(parent):
            SSHFolderEditor(model: model, folderID: nil, parentID: parent, onDone: close)
        // The Mac shell selects one trusted server at a time; the phone shows
        // the list and forgets from a row, so both land on the same screen.
        case .knownHost, .knownHosts:
            SSHKnownHostsView(model: model)
        case .importConfig:
            SSHConfigImportView(model: model, onDone: close)
        case .importCloud:
            CloudImportForm(model: model, onDone: close)
        }
    }

    // MARK: - The list side

    private var listSide: some View {
        VStack(spacing: 0) {
            header
            if let error = model.error {
                InlineBanner(text: FriendlyError.from(error).message, kind: .danger) { model.error = nil }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, Theme.Space.s)
            }
            // A save that landed here but not in the vault. Said out loud, the
            // way the Mac says it: silence is what made an edit that another
            // device later overwrote look like the save had never happened.
            if let vaultError = model.vaultError {
                let friendly = FriendlyError.from(vaultError)
                InlineBanner(text: "Saved on this device, but not synced. \(friendly.message)") {
                    model.vaultError = nil
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, Theme.Space.s)
            }
            if signedInUnpaid, model.hosts.isEmpty {
                vaultUpgrade
                Spacer(minLength: 0)
            } else if isEmpty {
                EmptyState(symbol: emptySymbol, title: emptyTitle, message: emptyMessage) {
                    Button(emptyActionTitle, .create) { open(addRoute) }
                        .buttonStyle(AccentButtonStyle())
                }
                .frame(maxHeight: .infinity)
            } else {
                list
            }
        }
        // One tone, not two. The header sat on the sidebar colour and the list
        // on the background, which drew a hard band across the screen at the
        // seam and made the two halves look like separate screens.
        .background(Theme.background)
    }

    private var header: some View {
        VStack(spacing: Theme.Space.s) {
            // One row, not a control panel. Unlock, a new recovery code and
            // delete live inside the screen it opens, where each of them has
            // room for the sentence it needs.
            if vaultTier != nil {
                SSHVaultRow(vault: vault, canWrite: paidVaultTier != nil) { showingVault = true }
            }
            SegmentedTabs(options: Section.allCases, selection: $section)
                .accessibilityLabel("SSH library")
            SearchField(text: $model.search, prompt: "Search \(section.rawValue.lowercased())")
        }
        .padding(Theme.Space.m)
    }

    @ViewBuilder
    private var list: some View {
        List {
            switch section {
            case .hosts:
                // Live shells, above everything. A session outlives this
                // screen now, so there has to be a way back to one: without
                // this row a shell somebody left running is running with
                // nothing on any screen that mentions it.
                if !model.searching, !sessions.sessions.isEmpty {
                    SwiftUI.Section("Open sessions") {
                        ForEach(sessions.sessions) { session in sessionRow(session) }
                    }
                }
                if !model.searching, !model.recentHosts.isEmpty {
                    SwiftUI.Section("Recent") {
                        ForEach(model.recentHosts) { host in hostRow(host, depth: 0) }
                    }
                }
                SwiftUI.Section(model.searching ? "Results" : "All servers") {
                    ForEach(rows) { row in
                        switch row.kind {
                        case let .folder(folder):
                            folderRow(folder, depth: row.depth)
                        case let .host(host):
                            hostRow(host, depth: row.depth)
                        }
                    }
                }
            case .keys:
                ForEach(model.visibleKeys) { key in keyRow(key) }
            case .snippets:
                ForEach(model.visibleSnippets) { snippet in snippetRow(snippet) }
            }
        }
        .listStyle(.insetGrouped)
        // The grouped styles paint their own grey twice: once behind the
        // scroll view, and once behind every row. This deals with the first.
        // The second is `themedRow` on each row builder, because
        // `listRowBackground` applied to the List itself reaches nothing: it
        // is a per-row modifier and the rows are what have to carry it.
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .listRowSeparatorTint(Theme.border)
    }

    /// One row per visible line, with its depth.
    ///
    /// Flattened rather than nested `DisclosureGroup`s: a view that contains
    /// itself cannot be typed, and indentation reads the same to a person.
    private struct Row: Identifiable {
        enum Kind {
            case folder(SSHFolder)
            case host(SSHHost)
        }

        let id: String
        let kind: Kind
        let depth: Int
    }

    private var rows: [Row] {
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
            Text("\(model.hosts(in: folder.id).count)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .frame(height: Theme.Control.rowHeight)
        .contentShape(.rect)
        .onTapGesture {
            if expanded.contains(folder.id) { expanded.remove(folder.id) } else { expanded.insert(folder.id) }
        }
        .contextMenu {
            Button("Rename folder") { open(.folder(folder.id)) }
            Button("Add server here") { open(.newHost(folder: folder.id)) }
            Button("Add sub-folder") { open(.newFolder(parent: folder.id)) }
            Button("Delete folder", role: .destructive) {
                Task { await model.delete(folder: folder) }
            }
        }
        .themedRow()
    }

    /// One live session, as a way back into it.
    private func sessionRow(_ session: SSHLiveTerminal) -> some View {
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(session.alive ? Theme.accent : Theme.stateIdle)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).lineLimit(1)
                Text(session.alive ? "Running" : "Ended")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(height: Theme.Control.rowHeight)
        .contentShape(.rect)
        .onTapGesture {
            sessions.select(session)
            showingTerminal = true
        }
        .swipeActions(edge: .trailing) {
            Button("End", role: .destructive) { Task { await sessions.close(session) } }
        }
        .themedRow()
    }

    private func hostRow(_ host: SSHHost, depth: Int) -> some View {
        SSHHostRow(
            host: host,
            folder: model.folderName(host.folderID),
            searching: model.searching,
            onConnect: { connecting = host }
        )
            .padding(.leading, CGFloat(depth) * 14)
            .contentShape(.rect)
            .onTapGesture { open(.host(host.id)) }
            .contextMenu {
                Button("Connect") { connecting = host }
                Button(host.favorite ? "Remove from favourites" : "Add to favourites") {
                    var updated = host
                    updated.favorite.toggle()
                    Task { _ = await model.save(host: updated) }
                }
                Button("Edit") { open(.host(host.id)) }
                Button("Delete", role: .destructive) { Task { await model.delete(host: host) } }
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", role: .destructive) { Task { await model.delete(host: host) } }
            }
            .swipeActions(edge: .leading) {
                Button("Connect") { connecting = host }.tint(Theme.accent)
            }
        .themedRow()
    }

    private func keyRow(_ key: SSHKeyRecord) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.label).font(SSHRowType.name)
                // The tail, not the whole line. A full SHA256 fingerprint is
                // wider than a phone, so the row printed a wall of base64 that
                // was cut off exactly where the part you compare against lives.
                Text(SSHLibraryView.shortFingerprint(key.fingerprint) ?? key.algorithm)
                    .font(SSHRowType.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        } icon: {
            Image(systemName: key.hardwareBacked ? "key.radiowaves.forward" : "key.fill")
                .foregroundStyle(Theme.accent)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .onTapGesture { open(.key(key.id)) }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { Task { await model.delete(key: key) } }
        }
        .themedRow()
    }

    private func snippetRow(_ snippet: SSHSnippet) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snippet.title).font(SSHRowType.name)
            Text(snippet.command)
                .font(SSHRowType.mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .onTapGesture { open(.snippet(snippet.id)) }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { Task { await model.delete(snippet: snippet) } }
        }
        .themedRow()
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let onClose {
            ToolbarItem(placement: .cancellationAction) {
                InspectorCloseButton(action: onClose, help: "Close", label: "Close SSH library")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Add \(section.rawValue.dropLast().lowercased())") { open(addRoute) }
                if section == .hosts {
                    Button("Add folder") { open(.newFolder(parent: nil)) }
                    Divider()
                    Button("Import from ssh config") { open(.importConfig) }
                    Button("Import cloud servers") { open(.importCloud) }
                    Button("Trusted servers") { open(.knownHosts) }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    // MARK: - Plumbing

    /// Leave an editor: clear the detail pane on macOS, pop the push on iOS.
    /// One assignment does both, because both are driven by `route`.
    private func close() { route = nil }

    private func open(_ destination: SSHLibraryRoute) { route = destination }

    /// A fingerprint without its algorithm prefix.
    ///
    /// Nil for an empty one, so the caller can fall back to the algorithm
    /// rather than print an empty line.
    ///
    /// The prefix is dropped in every case, so the column holds one shape
    /// rather than two. Nothing else is cut here: the row asks for head
    /// truncation, and a string this trimmed by hand as well came out with
    /// two ellipses on a narrow phone. Where a fingerprint has to be compared
    /// in full, that is the editor's job, not a list row's.
    static func shortFingerprint(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        guard let separator = value.firstIndex(of: ":") else { return value }
        let body = String(value[value.index(after: separator)...])
        return body.isEmpty ? value : body
    }

    private var addRoute: SSHLibraryRoute {
        switch section {
        case .hosts: .newHost(folder: nil)
        case .keys: .newKey
        case .snippets: .newSnippet
        }
    }

    private var isEmpty: Bool {
        switch section {
        case .hosts: model.hosts.isEmpty && model.folders.isEmpty
        case .keys: model.keys.isEmpty
        case .snippets: model.snippets.isEmpty
        }
    }

    private var emptySymbol: String {
        switch section {
        case .hosts: "server.rack"
        case .keys: "key"
        case .snippets: "text.badge.plus"
        }
    }

    private var emptyTitle: String { "No \(section.rawValue.lowercased()) yet" }

    private var emptyMessage: String {
        switch section {
        case .hosts: "Add a server once, then connect without retyping its address and username."
        case .keys: "Generate or import an SSH key to authenticate without a password."
        case .snippets: "Save commands you use often and run them from a terminal."
        }
    }

    private var emptyActionTitle: String {
        switch section {
        case .hosts: "Add host"
        case .keys: "Add key"
        case .snippets: "Add snippet"
        }
    }

    private var vaultUpgrade: some View {
        ClientEmptyState(
            kind: .needsAccount,
            title: "Sync SSH between your devices",
            message: "An encrypted vault keeps hosts and keys on every computer and phone signed in to this account. Supporter and above.",
            actionTitle: "See plans",
            actionIcon: .plans,
            action: { store.showPaywall = true },
            art: .vault
        )
        .padding(.horizontal, Theme.Space.m)
    }
}
#endif

/// The theme's own colours behind a list row.
///
/// `scrollContentBackground(.hidden)` deals with the scroll view and nothing
/// else: an inset-grouped row paints its own light neutral card on top of
/// whatever is behind it, which on this screen left the host cards as the one
/// grey thing among the panels. `listRowBackground` is per row and does not
/// travel down from the List, so every row builder says it.
extension View {
    func themedRow() -> some View {
        listRowBackground(Theme.panel)
            .listRowSeparatorTint(Theme.border)
    }
}

/// The type scale the library's rows share.
///
/// The Mac's default body size on a phone is a Mac list pretending to be a
/// phone one: the client next door reads its sizes from `ClientType` so a row
/// scales with Dynamic Type, and these rows were the only ones in the app
/// still asking for a fixed system default. One place for both platforms, so
/// a name means the same weight on each.
enum SSHRowType {
    #if os(macOS)
    static let name = Font.system(size: 13)
    static let detail = Font.caption
    #else
    static let name = ClientType.label.weight(.medium)
    static let detail = ClientType.caption
    #endif

    /// A fingerprint or a command: content, so monospaced.
    static let mono = Theme.mono(11)
}

/// One server in the list.
///
/// Name in body weight, address in caption, folder colour as a leading bar, so
/// ten servers scan as a list rather than as ten paragraphs.
struct SSHHostRow: View {
    let host: SSHHost
    let folder: String?
    let searching: Bool
    /// Connect to this server. Nil where the row is not a place to do it.
    ///
    /// The row used to carry no way to connect at all: it was in the context
    /// menu and nowhere else, which on a phone is a long press nobody finds,
    /// and on the Mac is a right click on a screen whose whole purpose is
    /// reaching a server.
    var onConnect: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            RoundedRectangle(cornerRadius: 2)
                .fill(SSHColor.color(host.color))
                #if os(macOS)
                .frame(width: 3)
                #else
                .frame(width: 4)
                #endif
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Space.xs) {
                    Text(host.label)
                        .font(SSHRowType.name)
                        .lineLimit(1)
                    if host.favorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.warning)
                    }
                }
                HStack(spacing: Theme.Space.xs) {
                    Text(host.address)
                        .font(SSHRowType.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if searching, let folder {
                        Text(folder)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.rowHighlight, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let onConnect {
                // The Mac has a pointer, so the button waits for it, stays
                // quiet and lets the list read as a list. A phone has no hover
                // to wait for and no pointer to aim with: this is the reason
                // the screen exists, it has to be the one obviously pressable
                // thing on the row, and it has to be big enough to hit with a
                // thumb. Two platforms, two answers, one button.
                #if os(macOS)
                Button("Connect", .connect, action: onConnect)
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                #else
                Button("Connect", .connect, action: onConnect)
                    .buttonStyle(AccentButtonStyle())
                    .frame(minHeight: 44)
                #endif
            }
        }
        // A fixed height on a phone is a row that cannot hold a second line of
        // Dynamic Type and a tap target that shrinks with the text. A floor
        // instead, so the row grows and never goes under 44.
        #if os(macOS)
        .frame(height: Theme.Control.rowHeight)
        .onHover { hovering = $0 }
        #else
        .frame(minHeight: 44)
        #endif
    }
}

/// A search field that looks the same on both platforms.
///
/// `.searchable` puts the field somewhere different on each, and this screen
/// needs it above the list on both.
struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.Control.height)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }
}

/// A message attached to the thing that produced it.
///
/// The old screen printed errors as loose red text between a picker and an
/// empty state, which reads as part of the layout rather than as a problem.
struct InlineBanner: View {
    enum Kind { case danger, info }
    let text: String
    var kind: Kind = .info
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: kind == .danger ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(kind == .danger ? Theme.danger : Theme.accent)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(Theme.Space.s)
        .background(
            (kind == .danger ? Theme.danger : Theme.accent).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}
