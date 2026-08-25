// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

/// Footer for an editor: the same two buttons, the same size, in the same place
/// on every screen in the library.
///
/// A shared view rather than a convention, because the convention is what
/// failed: the old forms each built their own row and ended up with three
/// button sizes and delete styled as a link.
struct SSHEditorFooter: View {
    var saveTitle = "Save"
    var canSave: Bool
    var working: Bool
    var onSave: () -> Void
    var onCancel: () -> Void
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let onDelete {
                Button("Delete", .delete, action: onDelete)
                    .buttonStyle(DestructiveButtonStyle())
            }
            Spacer()
            Button("Cancel", .dismiss, action: onCancel)
                .buttonStyle(SecondaryButtonStyle())
                .frame(minWidth: Theme.Control.pairedWidth)
            Button(saveTitle, .save, action: onSave)
                .buttonStyle(AccentButtonStyle())
                .frame(minWidth: Theme.Control.pairedWidth)
                .disabled(!canSave || working)
        }
        .padding(Theme.Space.m)
        .background(.thinMaterial)
    }
}

/// Everything a saved server knows, on one screen.
///
/// Grouped by what somebody is deciding: where to connect, how to authenticate,
/// where it lives in the list, and the settings that only matter when something
/// is wrong. The old sheet had the first two and nowhere to put the rest.
struct SSHHostEditor: View {
    let model: SSHLibraryModel
    let hostID: String?
    let folderID: String?
    let onDone: () -> Void

    @State private var host = SSHHost(
        id: "", label: "", hostname: "", port: 22, username: "root",
        initialDirectory: "~", credentialID: nil, jumpHostID: nil,
        tags: [], provider: nil, hostKeys: []
    )
    @State private var loaded = false
    @State private var working = false
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var newEnvName = ""
    @State private var newEnvValue = ""

    private var isNew: Bool { hostID == nil }

    /// Leave the editor. On the Mac this is the inspector column, so
    /// `Environment.dismiss` would close the window. On the phone, `onDone`
    /// already pops the pushed screen by clearing the route.
    private func finish() {
        onDone()
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                Section("Connection") {
                    TextField("Name", text: $host.label)
                    TextField("Address", text: $host.hostname)
                    TextField("Username", text: $host.username)
                    TextField("Port", value: $host.port, format: .number)
                    TextField(
                        "Starting directory",
                        text: Binding(
                            get: { host.initialDirectory ?? "~" },
                            set: { host.initialDirectory = $0 }
                        ),
                        prompt: Text("~")
                    )
                }

                Section("Authentication") {
                    Picker("Use", selection: Binding(
                        get: { host.credentialID ?? "" },
                        set: { host.credentialID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Ask when connecting").tag("")
                        ForEach(model.keys) { Text($0.label).tag($0.id) }
                    }
                    Picker("Connect through", selection: Binding(
                        get: { host.jumpHostID ?? "" },
                        set: { host.jumpHostID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Nothing, connect directly").tag("")
                        ForEach(model.hosts.filter { $0.id != host.id }) { Text($0.label).tag($0.id) }
                    }
                    Toggle("Forward the SSH agent", isOn: $host.agentForwarding)
                    Text("Passwords are asked for when you connect and are never saved. A key is stored in this device's vault and, if you have one, in the encrypted vault.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("In the list") {
                    Picker("Folder", selection: Binding(
                        get: { host.folderID ?? "" },
                        set: { host.folderID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Top level").tag("")
                        ForEach(model.folders) { Text($0.name).tag($0.id) }
                    }
                    SSHColorPicker(selection: $host.color)
                    Toggle("Favourite", isOn: $host.favorite)
                }

                Section("Advanced") {
                    Stepper(
                        keepaliveLabel,
                        value: $host.keepaliveSeconds,
                        in: 0...300,
                        step: 15
                    )
                    envEditor
                }

                if !host.hostKeys.isEmpty {
                    Section("Trusted server key") {
                        ForEach(host.hostKeys, id: \.self) { key in
                            Text(key).font(Theme.mono(11)).textSelection(.enabled)
                        }
                        Button("Forget this key", .revoke) {
                            host.hostKeys = []
                        }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        Text("Forgetting makes the next connection ask you to confirm the server's fingerprint again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            SSHEditorFooter(
                saveTitle: isNew ? "Add server" : "Save",
                canSave: !host.label.isEmpty && !host.hostname.isEmpty && !host.username.isEmpty,
                working: working,
                onSave: { Task { await save() } },
                onCancel: finish,
                onDelete: isNew ? nil : { confirmingDelete = true }
            )
        }
        .navigationTitle(isNew ? "Add server" : host.label)
        .task {
            guard !loaded else { return }
            loaded = true
            if let hostID, let existing = model.hosts.first(where: { $0.id == hostID }) {
                host = existing
            } else {
                host.folderID = folderID
            }
        }
        .confirmationDialog("Delete this server?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                // Leave first, then delete. The delete reloads the list,
                // and a detail view still bound to the record that just left
                // it is a row being read while it is removed.
                finish()
                Task { await model.delete(host: host) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved address and settings are removed from this device and from the encrypted vault. Nothing on the server changes.")
        }
    }

    private var keepaliveLabel: String {
        host.keepaliveSeconds == 0
            ? "Keepalive: off"
            : "Keepalive: every \(host.keepaliveSeconds)s"
    }

    @ViewBuilder
    private var envEditor: some View {
        ForEach(host.env) { pair in
            HStack {
                Text(pair.name).font(Theme.mono(11))
                Text("=").foregroundStyle(.secondary)
                Text(pair.value).font(Theme.mono(11)).lineLimit(1)
                Spacer()
                Button("Remove", .delete) {
                    host.env.removeAll { $0.name == pair.name }
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
            }
        }
        HStack(spacing: Theme.Space.s) {
            TextField("Variable", text: $newEnvName)
            TextField("Value", text: $newEnvValue)
            Button("Add", .create) {
                let name = newEnvName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                host.env.removeAll { $0.name == name }
                host.env.append(SSHEnvPair(name: name, value: newEnvValue))
                newEnvName = ""
                newEnvValue = ""
            }
            .buttonStyle(SecondaryButtonStyle(small: true))
            .disabled(newEnvName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        if host.initialDirectory?.isEmpty != false { host.initialDirectory = "~" }
        if await model.save(host: host) != nil {
            finish()
        } else {
            error = model.error
            model.error = nil
        }
    }
}

/// The fixed palette, as swatches.
struct SSHColorPicker: View {
    @Binding var selection: String?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text("Colour")
            Spacer()
            ForEach(SSHColor.names, id: \.self) { name in
                Button {
                    selection = selection == name ? nil : name
                } label: {
                    Circle()
                        .fill(SSHColor.color(name))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().strokeBorder(
                                selection == name ? Color.primary : Color.clear,
                                lineWidth: 2
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
            }
        }
    }
}

/// A key: generate one, paste one, see its fingerprint, copy the public half.
struct SSHKeyEditor: View {
    let model: SSHLibraryModel
    let keyID: String?
    let onDone: () -> Void

    @State private var label = "My SSH key"
    @State private var pem = ""
    @State private var passphrase = ""
    @State private var record: SSHKeyRecord?
    @State private var loaded = false
    @State private var working = false
    @State private var error: String?
    @State private var copied = false
    @State private var confirmingDelete = false

    private var isNew: Bool { keyID == nil }

    /// Leave the editor. On the Mac this is the inspector column, so
    /// `Environment.dismiss` would close the window. On the phone, `onDone`
    /// already pops the pushed screen by clearing the route.
    private func finish() {
        onDone()
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                Section("Key") {
                    TextField("Name", text: $label)
                    if let record {
                        LabeledContent("Algorithm", value: record.algorithm)
                        LabeledContent("Fingerprint") {
                            Text(record.fingerprint.isEmpty ? "Not computed" : record.fingerprint)
                                .font(Theme.mono(11)).textSelection(.enabled)
                        }
                        if record.passphraseProtected {
                            Label("Protected by a passphrase", systemImage: "lock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let record {
                    Section("Public key") {
                        Text(record.publicKey)
                            .font(Theme.mono(11))
                            .textSelection(.enabled)
                            .lineLimit(4)
                        HStack(spacing: Theme.Space.s) {
                            Button(copied ? "Copied" : "Copy public key", .copy) {
                                copy(record.publicKey)
                            }
                            .buttonStyle(SecondaryButtonStyle(small: true))
                        }
                        Text("Add this line to ~/.ssh/authorized_keys on a server to let this key in. tokenstat never edits that file for you.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Add") {
                        Text("Generate a new Ed25519 key, or paste an existing private key. The private half goes into this device's vault, never into the connection list.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $pem)
                            .font(Theme.mono(11))
                            .frame(minHeight: 160)
                        SecureField("Private-key passphrase (if it has one)", text: $passphrase)
                        HStack(spacing: Theme.Space.s) {
                            Button("Generate a key", .create) { Task { await generate() } }
                                .buttonStyle(SecondaryButtonStyle())
                            Button("Import pasted key", .upload) { Task { await importPasted() } }
                                .buttonStyle(AccentButtonStyle())
                                .disabled(pem.isEmpty)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            SSHEditorFooter(
                canSave: record != nil && !label.isEmpty,
                working: working,
                onSave: { Task { await rename() } },
                onCancel: finish,
                onDelete: record == nil ? nil : { confirmingDelete = true }
            )
        }
        .navigationTitle(isNew ? "Add key" : label)
        .task {
            guard !loaded else { return }
            loaded = true
            if let keyID, let existing = model.keys.first(where: { $0.id == keyID }) {
                record = existing
                label = existing.label
            }
        }
        .confirmationDialog("Delete this key?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let doomed = record
                finish()
                Task { if let doomed { await model.delete(key: doomed) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The private key is removed from this device's vault. Servers that trust it keep trusting it, so remove the public key there as well.")
        }
    }

    private func generate() async {
        working = true
        defer { working = false }
        do { await keep(try await Bridge.generateSSHKey(), protected: false) }
        catch { self.error = error.localizedDescription }
    }

    private func importPasted() async {
        working = true
        defer { working = false }
        do {
            let material = try await Bridge.inspectSSHKey(
                pem: pem, passphrase: passphrase.isEmpty ? nil : passphrase
            )
            await keep(material, protected: !passphrase.isEmpty)
        } catch { self.error = error.localizedDescription }
    }

    private func keep(_ material: SSHKeyMaterial, protected: Bool) async {
        do {
            let id = "key_\(UUID().uuidString)"
            let reference = try SSHSecretStore.store(material.privateKey, id: id)
            let key = SSHKeyRecord(
                id: id, label: label, algorithm: material.algorithm,
                publicKey: material.publicKey, secretRef: reference,
                hardwareBacked: false, fingerprint: material.fingerprint,
                createdMs: Int64(Date().timeIntervalSince1970 * 1000),
                passphraseProtected: protected
            )
            if let saved = await model.save(key: key, privateKey: material.privateKey) {
                record = saved
                pem = ""
                passphrase = ""
            } else {
                error = model.error
                model.error = nil
            }
        } catch { self.error = error.localizedDescription }
    }

    private func rename() async {
        guard var record else { return }
        working = true
        defer { working = false }
        record.label = label
        if await model.save(key: record, privateKey: nil) != nil {
            finish()
        } else {
            error = model.error
            model.error = nil
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        copied = true
    }
}

/// A snippet, with the whole screen to write it in.
struct SSHSnippetEditor: View {
    let model: SSHLibraryModel
    let snippetID: String?
    let onDone: () -> Void

    @State private var snippet = SSHSnippet(id: "", title: "", command: "", tags: [], hostIDs: [])
    @State private var loaded = false
    @State private var working = false
    @State private var error: String?
    @State private var confirmingDelete = false

    private var isNew: Bool { snippetID == nil }

    /// Leave the editor. On the Mac this is the inspector column, so
    /// `Environment.dismiss` would close the window. On the phone, `onDone`
    /// already pops the pushed screen by clearing the route.
    private func finish() {
        onDone()
    }

    private var placeholders: [String] { SSHSnippet.placeholders(in: snippet.command) }

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                InlineBanner(text: error, kind: .danger) { self.error = nil }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.s)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField("Name", text: $snippet.title)
                    .textFieldStyle(.roundedBorder)
                Text("Command")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $snippet.command)
                    .font(Theme.mono(12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                if placeholders.isEmpty {
                    Text("Wrap a value in {{braces}} to be asked for it every time this runs, so one snippet covers every server.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: Theme.Space.xs) {
                        Text("Asks for:").font(.caption).foregroundStyle(.secondary)
                        ForEach(placeholders, id: \.self) { name in
                            Text(name)
                                .font(Theme.mono(10))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.accentSoft, in: Capsule())
                        }
                    }
                }
                Toggle("Run automatically after connecting", isOn: $snippet.runOnConnect)
            }
            .padding(Theme.Space.m)

            SSHEditorFooter(
                saveTitle: isNew ? "Add snippet" : "Save",
                canSave: !snippet.title.isEmpty && !snippet.command.isEmpty,
                working: working,
                onSave: { Task { await save() } },
                onCancel: finish,
                onDelete: isNew ? nil : { confirmingDelete = true }
            )
        }
        .navigationTitle(isNew ? "Add snippet" : snippet.title)
        .task {
            guard !loaded else { return }
            loaded = true
            if let snippetID, let existing = model.snippets.first(where: { $0.id == snippetID }) {
                snippet = existing
            }
        }
        .confirmationDialog("Delete this snippet?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                finish()
                Task { await model.delete(snippet: snippet) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        snippet.variables = placeholders
        if await model.save(snippet: snippet) != nil {
            finish()
        } else {
            error = model.error
            model.error = nil
        }
    }
}

/// A folder: a name, a colour, and where it sits.
struct SSHFolderEditor: View {
    let model: SSHLibraryModel
    let folderID: String?
    let parentID: String?
    let onDone: () -> Void

    @State private var folder = SSHFolder(id: "", name: "", parentID: nil, color: nil)
    @State private var loaded = false
    @State private var working = false
    @State private var error: String?
    @State private var confirmingDelete = false

    private var isNew: Bool { folderID == nil }

    /// Leave the editor. On the Mac this is the inspector column, so
    /// `Environment.dismiss` would close the window. On the phone, `onDone`
    /// already pops the pushed screen by clearing the route.
    private func finish() {
        onDone()
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                Section("Folder") {
                    TextField("Name", text: $folder.name)
                    Picker("Inside", selection: Binding(
                        get: { folder.parentID ?? "" },
                        set: { folder.parentID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Top level").tag("")
                        ForEach(model.folders.filter { $0.id != folder.id }) { Text($0.name).tag($0.id) }
                    }
                    SSHColorPicker(selection: $folder.color)
                }
                Section {
                    Text("Deleting a folder keeps what is in it. Servers and sub-folders move up one level.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            SSHEditorFooter(
                saveTitle: isNew ? "Add folder" : "Save",
                canSave: !folder.name.isEmpty,
                working: working,
                onSave: { Task { await save() } },
                onCancel: finish,
                onDelete: isNew ? nil : { confirmingDelete = true }
            )
        }
        .navigationTitle(isNew ? "Add folder" : folder.name)
        .task {
            guard !loaded else { return }
            loaded = true
            if let folderID, let existing = model.folders.first(where: { $0.id == folderID }) {
                folder = existing
            } else {
                folder.parentID = parentID
            }
        }
        .confirmationDialog("Delete this folder?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                finish()
                Task { await model.delete(folder: folder) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Servers and sub-folders inside it move up one level. Nothing is deleted with it.")
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        if await model.save(folder: folder) != nil {
            finish()
        } else {
            error = model.error
            model.error = nil
        }
    }
}

/// Which servers this machine has decided to trust.
///
/// A screen because it is the answer to a real question ("why is it asking me
/// again?") and to a real emergency ("this fingerprint changed").
struct SSHKnownHostsView: View {
    let model: SSHLibraryModel

    var body: some View {
        Group {
            if model.knownHosts.isEmpty {
                EmptyState(
                    symbol: "checkmark.shield",
                    title: "No trusted servers yet",
                    message: "The first time you connect to a server you confirm its fingerprint. Confirmed servers are listed here."
                )
            } else {
                List {
                    ForEach(model.knownHosts) { known in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(known.label)
                            Text("\(known.hostname):\(known.port)")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(known.fingerprints, id: \.self) { print in
                                Text(print).font(Theme.mono(10)).textSelection(.enabled)
                            }
                            Button("Forget", .revoke) {
                                Task { await model.forgetKnownHost(known) }
                            }
                            .buttonStyle(SecondaryButtonStyle(small: true))
                        }
                        .padding(.vertical, Theme.Space.xs)
                    }
                }
            }
        }
        .navigationTitle("Trusted servers")
    }
}

/// What `~/.ssh/config` already describes, offered as a checklist.
///
/// Read only: the file belongs to ssh and tokenstat does not write to another
/// tool's data. Servers already saved are shown and skipped rather than hidden,
/// so the count on screen matches the file.
struct SSHConfigImportView: View {
    let model: SSHLibraryModel
    let onDone: () -> Void

    @State private var candidates: [SSHConfigCandidate] = []
    @State private var loading = true
    @State private var working = false
    @State private var imported: SSHConfigImport?
    @State private var error: String?

    private var newCount: Int { candidates.filter { !$0.alreadySaved }.count }

    /// Leave the editor. On the Mac this is the inspector column, so
    /// `Environment.dismiss` would close the window. On the phone, `onDone`
    /// already pops the pushed screen by clearing the route.
    private func finish() {
        onDone()
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if loading {
                    ProgressView("Reading ssh config…")
                } else if candidates.isEmpty {
                    EmptyState(
                        symbol: "doc.text.magnifyingglass",
                        title: "Nothing to import",
                        message: "There is no ~/.ssh/config on this machine, or it has no named servers in it."
                    )
                } else {
                    List {
                        if let imported {
                            InlineBanner(
                                text: imported.imported == 1
                                    ? "Imported 1 server."
                                    : "Imported \(imported.imported) servers.",
                                kind: .info
                            )
                        }
                        if let error {
                            InlineBanner(text: error, kind: .danger) { self.error = nil }
                        }
                        ForEach(candidates) { candidate in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.label)
                                    Text("\(candidate.username)@\(candidate.hostname):\(candidate.port)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if candidate.alreadySaved {
                                    Text("Already saved")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(minHeight: Theme.Control.rowHeight)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            SSHEditorFooter(
                saveTitle: newCount == 1 ? "Import 1 server" : "Import \(newCount) servers",
                canSave: newCount > 0,
                working: working,
                onSave: { Task { await run() } },
                onCancel: finish,
                onDelete: nil
            )
        }
        .navigationTitle("Import from ssh config")
        .task {
            candidates = (try? await Bridge.sshConfigCandidates()) ?? []
            loading = false
        }
    }

    private func run() async {
        working = true
        defer { working = false }
        do {
            imported = try await Bridge.importSSHConfig()
            candidates = (try? await Bridge.sshConfigCandidates()) ?? candidates
            await model.reload()
        } catch { self.error = error.localizedDescription }
    }
}
