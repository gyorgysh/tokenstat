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
    var saveIcon: ActionIcon = .save
    var canSave: Bool
    var working: Bool
    /// What to say while the work is in flight. Defaults from the icon, so
    /// Connect says "Connecting…" and a save says "Saving…" without every
    /// caller having to pass a second string.
    var workingTitle: String?
    var onSave: () -> Void
    var onCancel: () -> Void
    var onDelete: (() -> Void)?

    /// The sentence for the state the button is in.
    private var busyTitle: String {
        if let workingTitle { return workingTitle }
        switch saveIcon {
        case .connect: return "Connecting…"
        case .download: return "Importing…"
        case .security, .approve: return "Checking…"
        default: return "Saving…"
        }
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let onDelete {
                Button("Delete", .delete, action: onDelete)
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(working)
            }
            Spacer()
            // Never disabled, including while a request is in flight. Held
            // shut, it left the one way out of a connect that was going to sit
            // there until the socket gave up unavailable for exactly as long
            // as somebody wanted it: the screen looked frozen and the button
            // that would have got them out was the greyed-out one.
            Button("Cancel", .dismiss, action: onCancel)
                .buttonStyle(SecondaryButtonStyle())
                .frame(minWidth: Theme.Control.pairedWidth)
            // A spinner and a verb, rather than the same button greyed out.
            // Disabled on its own is what a button that will never work looks
            // like, so a slow connect read as a dead control and people
            // pressed it again.
            //
            // The spinner sits where the glyph does, inside the button. Beside
            // it, it was a loose piece of chrome floating in the gap between
            // Cancel and the action, and it moved the action along the row
            // every time the work started.
            Group {
                if working {
                    Button(action: {}) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(busyTitle)
                        }
                    }
                } else {
                    // Keep the glyph literals visible to the design guard. The
                    // footer accepts a semantic action, but a dynamic value in
                    // `Button` would make a future bare button indistinguishable
                    // from this deliberate choice to the source check.
                    switch saveIcon {
                    case .download: Button(saveTitle, .download, action: onSave)
                    case .done: Button(saveTitle, .done, action: onSave)
                    case .connect: Button(saveTitle, .connect, action: onSave)
                    case .security: Button(saveTitle, .security, action: onSave)
                    case .approve: Button(saveTitle, .approve, action: onSave)
                    default: Button(saveTitle, .save, action: onSave)
                    }
                }
            }
            .buttonStyle(AccentButtonStyle())
            .frame(minWidth: Theme.Control.pairedWidth)
            .disabled(!canSave || working)
        }
        .padding(Theme.Space.m)
        // The same tone as the chrome bar at the top of the inspector, so the
        // editor reads as content between two pieces of chrome. A material
        // here resolved to a flat grey that belonged to no part of the theme.
        .background(Theme.sidebar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}

/// The scrolling body of an editor, on the app's own background.
///
/// Deliberately not `Form` with `.formStyle(.grouped)`. That style paints its
/// own grey on macOS and ignores the theme, which made the SSH screens the only
/// ones in the app that looked like a System Settings pane: a flat grey slab
/// beside panels that are all `Theme.background` with `Theme.panel` cards on
/// them. Insights, Tasks and the workspace inspectors all draw their own
/// groups, so these do too.
struct SSHEditorBody<Content: View>: View {
    /// Whether a save or a connect is in flight. The fields go read-only and
    /// fade while it is, so the form says the same thing the footer's spinner
    /// does: this is busy, and typing into it now changes nothing that is
    /// about to be sent.
    var working = false
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                content
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .disabled(working)
        .opacity(working ? 0.6 : 1)
        .animation(.easeOut(duration: 0.15), value: working)
    }
}

/// A titled group of fields: a quiet caption, then one card.
struct SSHEditorSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                content
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
        }
    }
}

/// One labelled control, label above rather than beside.
///
/// The inspector column is narrow. A two-column form squeezes the field down
/// to a few characters there, which is what made typing an address in the
/// inspector worse than typing it in the sheet it replaced.
struct SSHEditorField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A caption under a group, for the sentence that explains it.
struct SSHEditorNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            SSHEditorBody(working: working) {
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                SSHEditorSection(title: "Connection") {
                    SSHEditorField(label: "Name") {
                        TextField("Name", text: $host.label).textFieldStyle(.themed)
                    }
                    SSHEditorField(label: "Address") {
                        TextField("Address", text: $host.hostname).textFieldStyle(.themed)
                    }
                    SSHEditorField(label: "Username") {
                        TextField("Username", text: $host.username).textFieldStyle(.themed)
                    }
                    SSHEditorField(label: "Port") {
                        TextField("Port", value: $host.port, format: .number)
                            .textFieldStyle(.themed)
                            .frame(maxWidth: 100)
                    }
                    SSHEditorField(label: "Starting directory") {
                        TextField(
                            "Starting directory",
                            text: Binding(
                                get: { host.initialDirectory ?? "~" },
                                set: { host.initialDirectory = $0 }
                            ),
                            prompt: Text("~")
                        )
                        .textFieldStyle(.themed)
                    }
                }

                SSHEditorSection(title: "Authentication") {
                    SSHEditorField(label: "Use") {
                        Picker("Use", selection: Binding(
                            get: { host.credentialID ?? "" },
                            set: { host.credentialID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("Ask when connecting").tag("")
                            ForEach(model.keys) { Text($0.label).tag($0.id) }
                        }
                    }
                    SSHEditorField(label: "Connect through") {
                        Picker("Connect through", selection: Binding(
                            get: { host.jumpHostID ?? "" },
                            set: { host.jumpHostID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("Nothing, connect directly").tag("")
                            ForEach(model.hosts.filter { $0.id != host.id }) { Text($0.label).tag($0.id) }
                        }
                    }
                    Toggle("Forward the SSH agent", isOn: $host.agentForwarding)
                        .toggleStyle(.brandCheckbox)

                    SSHEditorNote(text: "Passwords are asked for when you connect and are never saved. A key is stored in this device's vault and, if you have one, in the encrypted vault.")
                }

                SSHEditorSection(title: "In the list") {
                    SSHEditorField(label: "Folder") {
                        Picker("Folder", selection: Binding(
                            get: { host.folderID ?? "" },
                            set: { host.folderID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("Top level").tag("")
                            ForEach(model.folders) { Text($0.name).tag($0.id) }
                        }
                    }
                    SSHColorPicker(selection: $host.color)
                    Toggle("Favourite", isOn: $host.favorite)
                        .toggleStyle(.brandCheckbox)

                }

                SSHEditorSection(title: "Advanced") {
                    Stepper(
                        keepaliveLabel,
                        value: $host.keepaliveSeconds,
                        in: 0...300,
                        step: 15
                    )
                    envEditor
                }

                if !host.hostKeys.isEmpty {
                    SSHEditorSection(title: "Trusted server key") {
                        ForEach(host.hostKeys, id: \.self) { key in
                            Text(key)
                                .font(Theme.mono(11))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button("Forget this key", .revoke) {
                            host.hostKeys = []
                        }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        SSHEditorNote(text: "Forgetting makes the next connection ask you to confirm the server's fingerprint again.")
                    }
                }
            }

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
            SSHEditorBody(working: working) {
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                SSHEditorSection(title: "Key") {
                    SSHEditorField(label: "Name") {
                        TextField("Name", text: $label).textFieldStyle(.themed)
                    }
                    if let record {
                        SSHEditorField(label: "Algorithm") {
                            Text(record.algorithm)
                        }
                        SSHEditorField(label: "Fingerprint") {
                            Text(record.fingerprint.isEmpty ? "Not computed" : record.fingerprint)
                                .font(Theme.mono(11))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if record.passphraseProtected {
                            Label("Protected by a passphrase", systemImage: "lock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let record {
                    SSHEditorSection(title: "Public key") {
                        Text(record.publicKey)
                            .font(Theme.mono(11))
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(copied ? "Copied" : "Copy public key", .copy) {
                            copy(record.publicKey)
                        }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        SSHEditorNote(text: "Add this line to ~/.ssh/authorized_keys on a server to let this key in. tokenstat never edits that file for you.")
                    }
                } else {
                    SSHEditorSection(title: "Add") {
                        SSHEditorNote(text: "Generate a new Ed25519 key, or paste an existing private key. The private half goes into this device's vault, never into the connection list.")
                        ThemedEditor(text: $pem, font: Theme.mono(11), minHeight: 160)
                        SSHEditorField(label: "Private-key passphrase (if it has one)") {
                            SecureField("Passphrase", text: $passphrase).themedFieldBox()
                        }
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
            // `SSHEditorBody`, like every other editor in this file. This one
            // was a bare VStack, which is why it and no other could take the
            // window apart: a stack cannot absorb content taller than the
            // column it is in, so a long command box, a wrapped explanation
            // and a checkbox together demanded more height than the inspector
            // had and the hosted column grew to satisfy them. The split view
            // then pushed the rest of the window out of place, and it stayed
            // wrong until a different destination remounted the column. A
            // scroll view answers the same demand by scrolling.
            SSHEditorBody(working: working) {
                TextField("Name", text: $snippet.title)
                    .textFieldStyle(.themed)
                Text("Command")
                    .font(.caption).foregroundStyle(.secondary)
                // The border used to be drawn over a bare TextEditor, which
                // themed the outline of the platform's grey slab and left the
                // slab. ThemedEditor hides that background so the fill is the
                // app's own panel, like the name field above it.
                // No infinite maximum. Inside a scroll view an unbounded
                // height is a request for as much as the content wants, and a
                // text editor's content grows with what is typed into it.
                ThemedEditor(text: $snippet.command, minHeight: 140)
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
                    .toggleStyle(.brandCheckbox)
                    .disabled(snippet.hostIDs.isEmpty || !placeholders.isEmpty)
                if snippet.hostIDs.isEmpty {
                    Text("Pick the servers this snippet belongs to before it can run by itself. A snippet kept for every server would fire into every connection.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !placeholders.isEmpty {
                    Text("A snippet that asks for values cannot run by itself: the question would arrive on its own the moment you connected.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            }

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
            SSHEditorBody(working: working) {
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                SSHEditorSection(title: "Folder") {
                    SSHEditorField(label: "Name") {
                        TextField("Name", text: $folder.name).textFieldStyle(.themed)
                    }
                    SSHEditorField(label: "Inside") {
                        Picker("Inside", selection: Binding(
                            get: { folder.parentID ?? "" },
                            set: { folder.parentID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("Top level").tag("")
                            ForEach(model.folders.filter { $0.id != folder.id }) { Text($0.name).tag($0.id) }
                        }
                    }
                    SSHColorPicker(selection: $folder.color)
                }
                SSHEditorNote(text: "Deleting a folder keeps what is in it. Servers and sub-folders move up one level.")
            }

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
