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
    @State private var statusAttempt = 0
    @State private var visible = false
    @State private var requestGeneration = 0

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
        .navigationTitle(L10n.text("apple.clientclonerepository.clone_a_repository.749e5d4d"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $picking) {
            ClientFolderPickerForClone(peer: peer, hostName: hostName) { chosen in
                parent = chosen
            }
        }
        .task { await defaultParent() }
        .onAppear { visible = true }
        .onDisappear { visible = false; requestGeneration &+= 1 }
        .onChange(of: WorkSessionContext.shared.scope) { _, _ in
            requestGeneration &+= 1
            session = nil
            status = nil
            parent = nil
            url = ""
            name = ""
            error = nil
            dismiss()
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(L10n.text("apple.clientclonerepository.clone_onto_0.56da4378", "\(hostName)"))
                    .font(Theme.title.weight(.semibold))
                Text(
                    L10n.text("apple.clientclonerepository.tokenstat_runs_git_on_that_machine_and_reg.c316bf55")
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
                                Text(parent ?? L10n.text("apple.clientclonerepository.choose_a_folder.5c71b8cd"))
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
                        TextField(L10n.text("apple.clientclonerepository.taken_from_the_address.1d24ffb4"), text: $name)
                            .textFieldStyle(.themed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
                Text(
                    L10n.text("apple.clientclonerepository.a_private_repository_asks_for_its_credenti.7173fc9d")
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
                Button(working ? L10n.text("apple.clientclonerepository.starting.bbe5fc3b") : L10n.text("apple.clientclonerepository.clone.5779f32f"), .download) { Task { await start() } }
                    .clientProminentStyle()
                    .disabled(!ready || working)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity)
            .background(Theme.background)
        }
    }

    private func running(_ session: ClientTerminalSession) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(headline)
                    .font(ClientType.label)
                    .foregroundStyle(.secondary)
                Spacer()
                if error == nil && (status?.state == "running" || status == nil) {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            ThemeRule()
            if let error {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(error).font(ClientType.caption).foregroundStyle(Theme.controlGlyph)
                    Button(L10n.text("apple.clientclonerepository.check_status_again.84baa61b"), .refresh) { statusAttempt += 1 }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(Theme.Space.m)
            }
            ClientTerminalScreen(session: session, hostName: hostName)
            ThemeRule()
            VStack(spacing: Theme.Space.s) {
                if status?.state == "done", let id = status?.workspaceId {
                    Button(L10n.text("apple.clientclonerepository.open_the_folder.e241ab00"), .next) {
                        onCloned?(id)
                        dismiss()
                    }
                    .clientProminentStyle()
                } else if status?.state == "failed" {
                    Button(L10n.text("common.back"), .back) { self.session = nil; status = nil }
                        .clientProminentStyle()
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)
        }
        .task(id: statusAttempt) { await watch() }
    }

    private var headline: String {
        if error != nil { return L10n.text("apple.clientclonerepository.clone_status_unavailable.a25ebbc8") }
        return switch status?.state {
        case "done": L10n.text("apple.clientclonerepository.cloned_the_folder_is_registered_on_0.9404dac1", "\(hostName)")
        case "failed": status?.error ?? L10n.text("apple.clientclonerepository.the_clone_did_not_finish.fa812d0f")
        default: L10n.text("apple.clientclonerepository.cloning_onto_0.fd24885d", "\(hostName)")
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
        let scope = WorkSessionContext.shared.scope
        let suggested = try? await Bridge.browse(peer: peer, path: nil).path
        guard parent == nil, !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
        parent = suggested
    }

    private func start() async {
        guard visible, !Task.isCancelled, !working, session == nil, ready,
              let parent, let scope = WorkSessionContext.shared.scope else { return }
        let generation = requestGeneration
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
            guard visible, !Task.isCancelled, generation == requestGeneration,
                  scope == WorkSessionContext.shared.scope else { return }
            session = ClientTerminalSession(peer: peer, info: info)
        } catch {
            guard visible, !Task.isCancelled, generation == requestGeneration,
                  scope == WorkSessionContext.shared.scope else { return }
            self.error = ClientSetupModel.readable(error)
        }
    }

    /// The machine registers the folder itself when git exits, so this asks it
    /// what happened rather than deciding from what scrolled past. The poll is
    /// tied to the view's lifetime and surfaces a timeout instead of sitting
    /// on "Cloning…" forever.
    private func watch() async {
        guard let id = session?.hostID else { return }
        error = nil
        let deadline = Date().addingTimeInterval(1800)
        while Date() < deadline, !Task.isCancelled {
            if let answer = try? await Bridge.cloneStatus(peer: peer, sessionID: id) {
                guard !Task.isCancelled, session?.hostID == id else { return }
                status = answer
                if answer.state != "running" { return }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        guard !Task.isCancelled else { return }
        if status?.state == "running" || status == nil {
            self.error = L10n.text("apple.clientclonerepository.status_checks_stopped_after_30_minutes_the.aff07dba")
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
    @State private var generation = 0
    @State private var visible = false
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            if let listing {
                HStack(spacing: Theme.Space.s) {
                    if let parent = listing.parent {
                        Button(L10n.text("apple.clientclonerepository.up.55490a4b"), .back) { Task { await load(parent) } }
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
        .navigationTitle(L10n.text("apple.clientclonerepository.where_it_lands.452fbb26"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L10n.text("apple.clientclonerepository.new_folder.cf28f49e"), .create) { naming = true }
                    .disabled(listing == nil || creating)
            }
        }
        .alert(L10n.text("apple.clientclonerepository.new_folder.cf28f49e"), isPresented: $naming) {
            TextField(L10n.text("apple.clientclonerepository.name.dcd1d522"), text: $newFolder)
            Button(L10n.text("common.cancel"), role: .cancel) { newFolder = "" }
            Button(L10n.text("apple.clientclonerepository.create.4759498a")) { Task { await create() } }
        } message: {
            Text(L10n.text("apple.clientclonerepository.it_is_made_on_0_inside_the_folder_you_are.7077098c", "\(hostName)"))
        }
        .safeAreaInset(edge: .bottom) {
            if let listing {
                Button(L10n.text("apple.clientclonerepository.land_it_here.40ae2d76"), .approve) {
                    onChosen(listing.path)
                    dismiss()
                }
                .clientProminentStyle()
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .frame(maxWidth: .infinity)
                .background(Theme.background)
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; generation &+= 1 }
        .task(id: WorkSessionContext.shared.scope) {
            listing = nil
            error = nil
            naming = false
            newFolder = ""
            await load(nil)
        }
    }

    private func load(_ path: String?) async {
        guard visible, !Task.isCancelled else { return }
        generation &+= 1
        let current = generation
        let scope = WorkSessionContext.shared.scope
        error = nil
        do {
            let answer = try await Bridge.browse(peer: peer, path: path)
            guard visible, !Task.isCancelled, current == generation,
                  scope == WorkSessionContext.shared.scope else { return }
            listing = answer
        }
        catch {
            guard visible, !Task.isCancelled, current == generation,
                  scope == WorkSessionContext.shared.scope else { return }
            self.error = ClientSetupModel.readable(error)
        }
    }

    private func create() async {
        guard visible, !creating, !Task.isCancelled else { return }
        let name = newFolder.trimmingCharacters(in: .whitespaces)
        newFolder = ""
        guard !name.isEmpty, let here = listing?.path else { return }
        guard !name.contains("/"), !name.contains("\\"), name != "..", name != "." else {
            self.error = L10n.text("apple.clientclonerepository.a_folder_name_is_one_name_without_a_path_i.d41badd4")
            return
        }
        generation &+= 1
        let current = generation
        let scope = WorkSessionContext.shared.scope
        creating = true
        error = nil
        defer { creating = false }
        do {
            let made = try await Bridge.makeDirectory(peer: peer, path: "\(here)/\(name)")
            guard visible, !Task.isCancelled, current == generation,
                  scope == WorkSessionContext.shared.scope else { return }
            let answer = try await Bridge.browse(peer: peer, path: made)
            guard visible, !Task.isCancelled, current == generation,
                  scope == WorkSessionContext.shared.scope else { return }
            listing = answer
        } catch {
            guard visible, !Task.isCancelled, current == generation,
                  scope == WorkSessionContext.shared.scope else { return }
            self.error = ClientSetupModel.readable(error)
        }
    }
}

#endif
