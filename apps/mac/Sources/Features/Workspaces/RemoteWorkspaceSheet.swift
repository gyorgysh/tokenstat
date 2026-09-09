// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

// The phone can put a folder on a machine that has none. The Mac could only
// watch those folders arrive. This is the same two routes, reached from the
// same "+" sheet: register a folder the machine already has, or clone a
// repository onto it.
#if os(macOS)
import SwiftUI

/// A folder on another machine, from this Mac.
///
/// Peer first, then the route, then the work. Registering asks the host to add
/// a folder it already has. Cloning runs git on the host and polls what
/// happened; there is no remote terminal surface on the Mac to watch it in,
/// so this shows progress and the outcome rather than the scrolling output.
/// The host registers the folder itself when git exits, and the sidebar picks
/// it up through the ordinary remote refresh.
struct RemoteWorkspaceSheet: View {
    @Bindable var model: WorkspacesModel
    /// Account machines, for telling computers from companions. A peer the
    /// account knows as a phone or tablet is not listed: nothing can be
    /// registered or cloned onto it. A peer the account does not know stays
    /// listed, like everywhere else that reads the directory.
    var machines: [Machine] = []
    var onBack: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var peers: [Peer]?
    @State private var error: String?
    @State private var peer: Peer?
    @State private var route: Route?

    private enum Route: Hashable {
        case register, clone
    }

    /// Approved peers that can hold a folder: everything but the companions.
    private var hosts: [Peer]? {
        peers?.filter { !isCompanion($0) }
    }

    private func isCompanion(_ peer: Peer) -> Bool {
        machines.contains {
            let identity = $0.publicIdentity ?? $0.machineID
            return (identity == peer.key || identity == peer.fingerprint) && !$0.isHost
        }
    }

    var body: some View {
        ThemedSheet(
            title: title,
            subtitle: subtitle,
            icon: .create,
            scrolls: true,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let error {
                    ErrorBanner(message: error) {
                        Task { await loadPeers() }
                    }
                }
                if let peer, let route {
                    switch route {
                    case .register:
                        RemoteFolderRegisterView(model: model, peer: peer) {
                            dismiss()
                        }
                    case .clone:
                        RemoteCloneView(model: model, peer: peer) {
                            dismiss()
                        }
                    }
                } else if let peer {
                    routeRow(
                        .clone,
                        title: "Clone a repository",
                        body: "tokenstat runs git on \(name(of: peer)) and registers the folder "
                            + "when it finishes. A private repository asks for its credentials "
                            + "on that machine."
                    )
                    routeRow(
                        .register,
                        title: "A folder already on the machine",
                        body: "Browse \(name(of: peer))'s disk and register a folder that is "
                            + "there. Nothing is copied and nothing is changed."
                    )
                } else if let hosts {
                    if hosts.isEmpty, (peers ?? []).isEmpty {
                        emptyState(
                            symbol: "display.2",
                            title: "No paired computer yet",
                            body: "Pair one on the Machines screen first. Folders live on "
                                + "computers, so this list waits until one shows up."
                        )
                    } else if hosts.isEmpty {
                        emptyState(
                            symbol: "iphone",
                            title: "Only companions so far",
                            body: "The paired devices are phones and tablets, and folders live "
                                + "on computers. Pair one on the Machines screen."
                        )
                    } else {
                        ForEach(hosts) { candidate in
                            Button {
                                peer = candidate
                            } label: {
                                HStack(spacing: Theme.Space.m) {
                                    Image(systemName: "desktopcomputer")
                                        .foregroundStyle(Theme.accent)
                                    Text(name(of: candidate))
                                        .font(Theme.body.weight(.medium))
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(Theme.font(11, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(Theme.Space.m)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Finding paired machines…")
                            .font(Theme.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } actions: {
            Button("Back", .back) {
                if route != nil {
                    route = nil
                } else if peer != nil {
                    peer = nil
                } else {
                    onBack()
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            Spacer()
        }
        .modalFrame(width: 560, height: 480)
        .task { await loadPeers() }
    }

    private var title: String {
        if route == .clone { return "Clone onto a machine" }
        if route == .register { return "Register a folder" }
        if peer != nil { return "What should it get" }
        return "On another machine"
    }

    private var subtitle: String {
        if let peer {
            return "The folder ends up on \(name(of: peer)), and in this sidebar."
        }
        return "Give a paired machine its first folder."
    }

    private func routeRow(_ value: Route, title: String, body: String) -> some View {
        Button {
            route = value
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: value == .clone ? "arrow.down.doc" : "folder")
                    .font(Theme.font(18, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.body.weight(.medium))
                    Text(body)
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Theme.font(11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func emptyState(symbol: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(Theme.font(18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body.weight(.medium))
                Text(body)
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadPeers() async {
        do {
            peers = try await Bridge.peers().filter { $0.trust == .approved }
            error = nil
        } catch {
            self.error = error.localizedDescription
            peers = []
        }
    }

    private func name(of peer: Peer) -> String {
        peer.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(peer.key.prefix(8))
            : peer.label
    }
}

/// Browse the machine's disk and register the folder showing.
///
/// The same roots as the phone picker, because the host enforces them: a
/// folder browsing would not show cannot be registered either.
private struct RemoteFolderRegisterView: View {
    @Bindable var model: WorkspacesModel
    let peer: Peer
    var onDone: () -> Void

    @State private var working = false
    @State private var error: String?
    @State private var lastPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let error {
                let retryPath = lastPath
                ErrorBanner(message: error) {
                    if let retryPath { Task { await register(retryPath) } }
                }
            }
            RemoteFolderBrowser(
                peer: peer,
                selectTitle: working ? "Registering…" : "Register this folder",
                selectEnabled: !working,
                onSelect: { path in
                    lastPath = path
                    Task { await register(path) }
                }
            )
            .frame(minHeight: 220)
        }
    }

    private func register(_ path: String) async {
        working = true
        defer { working = false }
        do {
            _ = try await Bridge.addWorkspace(peer: peer.key, path: path)
            model.refreshRemotePeer(peer.key)
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Clone a repository onto the machine, then wait for the host to say what
/// happened. The host registers the folder itself when git exits, so the
/// outcome comes from `cloneStatus` rather than from any output this Mac saw.
private struct RemoteCloneView: View {
    @Bindable var model: WorkspacesModel
    let peer: Peer
    var onDone: () -> Void

    @State private var url = ""
    @State private var parent: String?
    @State private var name = ""
    @State private var working = false
    @State private var status: RemoteCloneStatus?
    @State private var error: String?
    @State private var watchTask: Task<Void, Never>?

    private var ready: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty && parent != nil && !working
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let error {
                ErrorBanner(message: error) {
                    Task { await start() }
                }
            }
            if working || status != nil {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.s) {
                        if status?.state == "running" || status == nil {
                            ProgressView().controlSize(.small)
                        }
                        Text(headline)
                            .font(Theme.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let detail = failedDetail {
                        Text(detail)
                            .font(Theme.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minHeight: 120, alignment: .topLeading)
            } else {
                TextField("https://github.com/owner/repo.git", text: $url)
                    .textFieldStyle(.themed)
                RemoteFolderBrowser(
                    peer: peer,
                    selectTitle: "Clone here",
                    selectEnabled: true,
                    allowNewFolder: true,
                    onSelect: { path in parent = path }
                )
                .frame(minHeight: 160)
                if let parent {
                    Text(parent)
                        .font(Theme.mono(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                TextField("Folder name, taken from the address when empty", text: $name)
                    .textFieldStyle(.themed)
                Button(working ? "Starting…" : "Clone", .download) { Task { await start() } }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!ready)
            }
            if status?.state == "done" {
                Button("Done", .approve) {
                    model.refreshRemotePeer(peer.key)
                    onDone()
                }
                .buttonStyle(AccentButtonStyle())
            } else if status?.state == "failed" {
                Button("Back", .back) { status = nil }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .onDisappear { watchTask?.cancel() }
    }

    private var headline: String {
        switch status?.state {
        case "done": "Cloned. The folder is registered on the machine."
        case "failed":
            if let raw = status?.error, !raw.isEmpty {
                FriendlyError.from(raw).title
            } else {
                "The clone did not finish."
            }
        default: "Cloning…"
        }
    }

    /// The fix, under the headline. Raw git output never leads.
    private var failedDetail: String? {
        guard status?.state == "failed",
              let raw = status?.error, !raw.isEmpty
        else { return nil }
        return FriendlyError.from(raw).message
    }

    private func start() async {
        guard let parent else { return }
        working = true
        error = nil
        status = nil
        defer { working = false }
        do {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            let info = try await Bridge.clone(
                peer: peer.key,
                url: url.trimmingCharacters(in: .whitespaces),
                parent: parent,
                name: trimmed.isEmpty ? nil : trimmed
            )
            watchTask?.cancel()
            watchTask = Task { await watch(sessionID: info.id) }
            await watchTask?.value
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func watch(sessionID: String) async {
        let deadline = Date().addingTimeInterval(1800)
        while Date() < deadline, !Task.isCancelled {
            if let answer = try? await Bridge.cloneStatus(peer: peer.key, sessionID: sessionID) {
                status = answer
                if answer.state != "running" { return }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        // Do not leave the UI on "Cloning…" forever: the poll is over, either
        // by timeout or by the sheet going away (which cancels this task and
        // skips this write).
        guard !Task.isCancelled else { return }
        if status?.state == "running" || status == nil {
            let path = status?.path ?? parent ?? ""
            status = RemoteCloneStatus(state: "failed", path: path, workspaceId: nil, error: "The clone timed out. Check the machine, or try again.")
        }
    }
}

/// The machine's disk, one directory at a time. Selecting means the directory
/// showing, not one of its rows: the clone needs somewhere to land and the
/// register needs the folder itself.
private struct RemoteFolderBrowser: View {
    let peer: Peer
    let selectTitle: String
    var selectEnabled: Bool = true
    var allowNewFolder = false
    var onSelect: (String) -> Void

    @State private var path: String?
    @State private var listing: RemoteListing?
    @State private var error: String?
    @State private var newName = ""
    @State private var naming = false
    /// Guards against stale responses: rapid taps let an older `browse` finish
    /// last and overwrite the listing for the directory showing.
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let listing {
                HStack(spacing: Theme.Space.s) {
                    if listing.parent != nil {
                        Button("Up", .back) { path = listing.parent }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                    }
                    Text(listing.path)
                        .font(Theme.mono(12))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                    if allowNewFolder {
                        Button("New folder", .create) { naming = true }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                            .disabled(listing.path.isEmpty)
                    }
                }
            }
            if let error {
                ErrorBanner(message: error) {
                    Task { await load() }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach((listing?.entries ?? []).filter { $0.isDirectory && !$0.hidden }) { entry in
                        Button {
                            if let next = entry.path { path = next }
                        } label: {
                            HStack(spacing: Theme.Space.s) {
                                Image(systemName: "folder")
                                    .foregroundStyle(Theme.accent)
                                Text(entry.name)
                                    .font(Theme.body)
                                if entry.isRegistered {
                                    Text("registered")
                                        .font(Theme.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(Theme.font(10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 5)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: listing == nil ? 0 : 180)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(selectTitle, .approve) {
                if let path { onSelect(path) }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!selectEnabled || path == nil)
        }
        .alert("New folder", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") { Task { await create() } }
        }
        .task(id: path) {
            // Seed the initial path once without retriggering: assigning `path`
            // from inside this task restarts it and browses twice on appear.
            if path == nil {
                await load(initial: true)
            } else {
                await load()
            }
        }
    }

    private func load(initial: Bool = false) async {
        generation &+= 1
        let current = generation
        do {
            let answer = try await Bridge.browse(peer: peer.key, path: path)
            guard current == generation else { return }
            listing = answer
            error = nil
            if initial, path == nil { path = answer.path }
        } catch {
            guard current == generation else { return }
            self.error = error.localizedDescription
        }
    }

    private func create() async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        guard !trimmed.isEmpty, let here = listing?.path, !here.isEmpty else { return }
        guard !trimmed.contains("/"), trimmed != "..", trimmed != "." else {
            self.error = "A folder name is one name, without a path in it."
            return
        }
        do {
            let made = try await Bridge.makeDirectory(peer: peer.key, path: "\(here)/\(trimmed)")
            path = made
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#endif
