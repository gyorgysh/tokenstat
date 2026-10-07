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
    var saveTitle = L10n.text("common.save")
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
        case .connect: return L10n.text("apple.sshlibraryeditors.connecting.72021eb7")
        case .download: return L10n.text("apple.sshlibraryeditors.importing.c01c4324")
        case .security, .approve: return L10n.text("apple.sshlibraryeditors.checking.ec963ffc")
        default: return L10n.text("apple.sshlibraryeditors.saving.23e39291")
        }
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let onDelete {
                Button(L10n.text("common.delete"), .delete, action: onDelete)
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(working)
            }
            Spacer()
            // Never disabled, including while a request is in flight. Held
            // shut, it left the one way out of a connect that was going to sit
            // there until the socket gave up unavailable for exactly as long
            // as somebody wanted it: the screen looked frozen and the button
            // that would have got them out was the greyed-out one.
            Button(L10n.text("common.cancel"), .dismiss, action: onCancel)
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
                    .font(Theme.font(10, weight: .semibold))
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
                .font(Theme.caption)
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
            .font(Theme.caption)
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

    @Bindable private var draft: SSHHostDraft
    init(model: SSHLibraryModel, hostID: String?, folderID: String?, onDone: @escaping () -> Void) {
        self.model = model; self.onDone = onDone
        self.hostID = hostID; self.folderID = folderID
        self.draft = model.drafts.draft(for: hostID.map(SSHLibraryRoute.host) ?? .newHost(folder: folderID), make: SSHHostDraft.init)
    }
    private var host: SSHHost { get { draft.host } nonmutating set { draft.host = newValue } }
    private var loaded: Bool { get { draft.loaded } nonmutating set { draft.loaded = newValue } }
    private var working: Bool { get { draft.working } nonmutating set { draft.working = newValue } }
    private var error: String? { get { draft.error } nonmutating set { draft.error = newValue } }
    private var confirmingDelete: Bool { get { draft.confirmingDelete } nonmutating set { draft.confirmingDelete = newValue } }
    private var newEnvName: String { get { draft.newEnvName } nonmutating set { draft.newEnvName = newValue } }
    private var newEnvValue: String { get { draft.newEnvValue } nonmutating set { draft.newEnvValue = newValue } }

    private func claim() -> SSHOperationOwner.Ticket? {
        guard draft.active else { return nil }
        return model.ownership.claim()
    }
    private func permits(_ owner: SSHOperationOwner.Ticket) -> Bool {
        draft.active && model.ownership.permits(owner)
    }

    private var isNew: Bool { hostID == nil }

    /// Leave the editor. On the Mac this is the inspector column, so
    /// `Environment.dismiss` would close the window. On the phone, `onDone`
    /// already pops the pushed screen by clearing the route.
    private func finish() {
        guard claim() != nil else { return }
        model.drafts.remove(hostID.map(SSHLibraryRoute.host) ?? .newHost(folder: folderID))
        onDone()
    }

    var body: some View {
        VStack(spacing: 0) {
            SSHEditorBody(working: working) {
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                SSHEditorSection(title: L10n.text("apple.sshlibraryeditors.connection.639a40e8")) {
                    SSHEditorField(label: L10n.text("apple.sshlibraryeditors.name.dcd1d522")) {
                        TextField(L10n.text("apple.sshlibraryeditors.name.dcd1d522"), text: $draft.host.label).textFieldStyle(.themed)
                    }
                    SSHEditorField(label: L10n.text("apple.sshlibraryeditors.address.56ef8f20")) {
                        TextField(L10n.text("apple.sshlibraryeditors.address.56ef8f20"), text: $draft.host.hostname).textFieldStyle(.themed)
                    }
                    SSHEditorField(label: L10n.text("apple.sshlibraryeditors.username.e3b89e9d")) {
                        TextField(L10n.text("apple.sshlibraryeditors.username.e3b89e9d"), text: $draft.host.username).textFieldStyle(.themed)
                    }
                    SSHEditorField(label: L10n.text("apple.sshlibraryeditors.port.72e9a59f")) {
                        TextField(L10n.text("apple.sshlibraryeditors.port.72e9a59f"), value: $draft.host.port, format: .number)
                            .textFieldStyle(.themed)
                            .frame(maxWidth: 100)
                    }
                    SSHEditorField(label: L10n.text("apple.sshlibraryeditors.starting_directory.43eff379")) {
                        TextField(
                            L10n.text("apple.sshlibraryeditors.starting_directory.43eff379"),
                            text: Binding(
                                get: { host.initialDirectory ?? "~" },
                                set: { host.initialDirectory = $0 }
                            ),
                            prompt: Text("~")
                        )
                        .textFieldStyle(.themed)
                    }
                }

                SSHEditorSection(title: L10n.text("apple.sshlibraryeditors.authentication.66880d2d")) {
                    SSHEditorField(label: L10n.text("apple.sshlibraryeditors.use.c36d819e")) {
                        Picker(L10n.text("apple.sshlibraryeditors.use.c36d819e"), selection: Binding(
                            get: { host.credentialID ?? "" },
                            set: { host.credentialID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text(L10n.text("apple.sshlibraryeditors.ask_when_connecting.f16c5b52")).tag("")
                            ForEach(model.keys) { Text($0.label).tag($0.id) }
                        }
                    }
                    SSHEditorField(label: L10n.text("apple.sshlibraryeditors.connect_through.33b4cdfc")) {
                        Picker(L10n.text("apple.sshlibraryeditors.connect_through.33b4cdfc"), selection: Binding(
                            get: { host.jumpHostID ?? "" },
                            set: { host.jumpHostID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text(L10n.text("apple.sshlibraryeditors.nothing_connect_directly.af6bb305")).tag("")
                            ForEach(model.hosts.filter { $0.id != host.id }) { Text($0.label).tag($0.id) }
                        }
                    }
                    Toggle(L10n.text("apple.sshlibraryeditors.forward_the_ssh_agent.9a9a736c"), isOn: $draft.host.agentForwarding)
                        .toggleStyle(.brandCheckbox)

                    SSHEditorNote(text: L10n.text("apple.sshlibraryeditors.passwords_are_asked_for_when_you_connect_a.786d5eb5"))
                }

                SSHEditorSection(title: L10n.text("apple.sshlibraryeditors.in_the_list.54b44e0b")) {
                    SSHEditorField(label: L10n.text("apple.sshlibraryeditors.folder.74ccd433")) {
                        Picker(L10n.text("apple.sshlibraryeditors.folder.74ccd433"), selection: Binding(
                            get: { host.folderID ?? "" },
                            set: { host.folderID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text(L10n.text("apple.sshlibraryeditors.top_level.f61dd254")).tag("")
                            ForEach(model.folders) { Text($0.name).tag($0.id) }
                        }
                    }
                    SSHColorPicker(selection: $draft.host.color)
                    Toggle(L10n.text("apple.sshlibraryeditors.favourite.e39b2499"), isOn: $draft.host.favorite)
                        .toggleStyle(.brandCheckbox)

                }

                SSHEditorSection(title: L10n.text("apple.sshlibraryeditors.advanced.9f088dbe")) {
                    Stepper(
                        keepaliveLabel,
                        value: $draft.host.keepaliveSeconds,
                        in: 0...300,
                        step: 15
                    )
                    envEditor
                }

                if !host.hostKeys.isEmpty {
                    SSHEditorSection(title: L10n.text("apple.sshlibraryeditors.trusted_server_key.0cf9a352")) {
                        ForEach(host.hostKeys, id: \.self) { key in
                            Text(key)
                                .font(Theme.mono(11))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button(L10n.text("apple.sshlibraryeditors.forget_this_key.aa28ad3b"), .revoke) {
                            host.hostKeys = []
                        }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        SSHEditorNote(text: L10n.text("apple.sshlibraryeditors.forgetting_makes_the_next_connection_ask_y.7dece06c"))
                    }
                }
            }

            SSHEditorFooter(
                saveTitle: isNew ? L10n.text("apple.sshlibraryeditors.add_server.1099b2a9") : L10n.text("common.save"),
                canSave: !host.label.isEmpty && !host.hostname.isEmpty && !host.username.isEmpty,
                working: working,
                onSave: { Task { await save() } },
                onCancel: finish,
                onDelete: isNew ? nil : { confirmingDelete = true }
            )
        }
        .navigationTitle(isNew ? L10n.text("apple.sshlibraryeditors.add_server.1099b2a9") : host.label)
        .task {
            guard claim() != nil, !loaded else { return }
            loaded = true
            if let hostID, let existing = model.hosts.first(where: { $0.id == hostID }) {
                host = existing
            } else {
                host.folderID = folderID
            }
        }
        .confirmationDialog(L10n.text("apple.sshlibraryeditors.delete_this_server.c1a65300"), isPresented: $draft.confirmingDelete, titleVisibility: .visible) {
            Button(L10n.text("common.delete"), role: .destructive) {
                // Leave first, then delete. The delete reloads the list,
                // and a detail view still bound to the record that just left
                // it is a row being read while it is removed.
                finish()
                Task { await model.delete(host: host) }
            }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("apple.sshlibraryeditors.the_saved_address_and_settings_are_removed.c54d8484"))
        }
    }

    private var keepaliveLabel: String {
        host.keepaliveSeconds == 0
            ? L10n.text("apple.sshlibraryeditors.keepalive_off.57e99fb2")
            : L10n.text("apple.sshlibraryeditors.keepalive_every_0_s.b2a5973d", "\(host.keepaliveSeconds)")
    }

    @ViewBuilder
    private var envEditor: some View {
        ForEach(host.env) { pair in
            HStack {
                Text(pair.name).font(Theme.mono(11))
                Text("=").foregroundStyle(.secondary)
                Text(pair.value).font(Theme.mono(11)).lineLimit(1)
                Spacer()
                Button(L10n.text("common.remove"), .delete) {
                    host.env.removeAll { $0.name == pair.name }
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
            }
        }
        HStack(spacing: Theme.Space.s) {
            TextField(L10n.text("apple.sshlibraryeditors.variable.e57e9987"), text: $draft.newEnvName)
            TextField(L10n.text("apple.sshlibraryeditors.value.8e37953d"), text: $draft.newEnvValue)
            Button(L10n.text("common.add"), .create) {
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
        guard let owner = claim(), !working else { return }
        working = true
        defer { if permits(owner) { working = false } }
        if host.initialDirectory?.isEmpty != false { host.initialDirectory = "~" }
        let saved = await model.save(host: host)
        guard permits(owner) else { return }
        if saved != nil {
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
            Text(L10n.text("apple.sshlibraryeditors.colour.3a9dfa58"))
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

    @Bindable private var draft: SSHKeyDraft
    init(model: SSHLibraryModel, keyID: String?, onDone: @escaping () -> Void) {
        self.model = model; self.onDone = onDone
        self.keyID = keyID
        self.draft = model.drafts.draft(for: keyID.map(SSHLibraryRoute.key) ?? .newKey, make: SSHKeyDraft.init)
    }
    private var label: String { get { draft.label } nonmutating set { draft.label = newValue } }
    private var pem: String { get { draft.pem } nonmutating set { draft.pem = newValue } }
    private var passphrase: String { get { draft.passphrase } nonmutating set { draft.passphrase = newValue } }
    private var record: SSHKeyRecord? { get { draft.record } nonmutating set { draft.record = newValue } }
    private var loaded: Bool { get { draft.loaded } nonmutating set { draft.loaded = newValue } }
    private var working: Bool { get { draft.working } nonmutating set { draft.working = newValue } }
    private var error: String? { get { draft.error } nonmutating set { draft.error = newValue } }
    private var copied: Bool { get { draft.copied } nonmutating set { draft.copied = newValue } }
    private var confirmingDelete: Bool { get { draft.confirmingDelete } nonmutating set { draft.confirmingDelete = newValue } }
    private var algorithm: SSHKeyAlgorithm { get { draft.algorithm } nonmutating set { draft.algorithm = newValue } }

    private func claim() -> SSHOperationOwner.Ticket? {
        guard draft.active else { return nil }
        return model.ownership.claim()
    }
    private func permits(_ owner: SSHOperationOwner.Ticket) -> Bool {
        draft.active && model.ownership.permits(owner)
    }

    private var isNew: Bool { keyID == nil }

    /// Leave the editor. On the Mac this is the inspector column, so
    /// `Environment.dismiss` would close the window. On the phone, `onDone`
    /// already pops the pushed screen by clearing the route.
    private func finish() {
        guard claim() != nil else { return }
        model.drafts.remove(keyID.map(SSHLibraryRoute.key) ?? .newKey)
        onDone()
    }

    var body: some View {
        VStack(spacing: 0) {
            SSHEditorBody(working: working) {
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                SSHEditorSection(title: L10n.text("apple.sshlibraryeditors.key.99a52df3")) {
                    SSHEditorField(label: L10n.text("apple.sshlibraryeditors.name.dcd1d522")) {
                        TextField(L10n.text("apple.sshlibraryeditors.name.dcd1d522"), text: $draft.label).textFieldStyle(.themed)
                    }
                    if let record {
                        SSHEditorField(label: L10n.text("apple.sshlibraryeditors.algorithm.d704d8af")) {
                            Text(record.algorithm)
                        }
                        SSHEditorField(label: L10n.text("apple.sshlibraryeditors.fingerprint.ba7af0b7")) {
                            Text(record.fingerprint.isEmpty ? L10n.text("apple.sshlibraryeditors.not_computed.9292f2b0") : record.fingerprint)
                                .font(Theme.mono(11))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if record.passphraseProtected {
                            Label(L10n.text("apple.sshlibraryeditors.protected_by_a_passphrase.e1da5704"), systemImage: "lock")
                                .font(Theme.caption).foregroundStyle(.secondary)
                        }
                        if SSHSecretStore.requiresBiometrics(record.secretRef) {
                            Label(L10n.text("apple.sshlibraryeditors.touch_id_this_device_only.bdd18977"), systemImage: "touchid")
                                .font(Theme.caption).foregroundStyle(Theme.accent)
                            SSHEditorNote(text: L10n.text("apple.sshlibraryeditors.not_synced_to_vault_touch_id_protects_acce.f3bcabb6"))
                        }
                    }
                }

                if let record {
                    SSHEditorSection(title: L10n.text("apple.sshlibraryeditors.public_key.4ee252fb")) {
                        Text(record.publicKey)
                            .font(Theme.mono(11))
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(copied ? L10n.text("apple.sshlibraryeditors.copied.8d525e5f") : L10n.text("apple.sshlibraryeditors.copy_public_key.5f2f4548"), .copy) {
                            copy(record.publicKey)
                        }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        SSHEditorNote(text: L10n.text("apple.sshlibraryeditors.add_this_line_to_ssh_authorized_keys_on_a.711df410"))
                    }
                } else {
                    SSHEditorSection(title: L10n.text("common.add")) {
                        SSHEditorField(label: L10n.text("apple.sshlibraryeditors.new_key_type.2ea9dfe1")) {
                            AppMenuPicker(options: SSHKeyAlgorithm.allCases.filter {
                                $0 != .ecdsaP256TouchID || SSHVaultBiometrics.name == "Touch ID"
                            }.map { (value: $0, label: $0.label) }, selection: $draft.algorithm)
                        }
                        SSHEditorNote(text: algorithm.explanation)
                        #if os(macOS)
                        if SSHVaultBiometrics.name != "Touch ID" {
                            SSHEditorNote(text: L10n.text("apple.sshlibraryeditors.touch_id_key_protection_is_available_when.32815577"))
                        }
                        #endif
                        Button(L10n.text("apple.sshlibraryeditors.generate_key.3dbb721a"), .create) { Task { await generate() } }
                            .buttonStyle(AccentButtonStyle())
                        SSHEditorNote(text: L10n.text("apple.sshlibraryeditors.or_import_an_existing_private_key_below_th.d754e12b"))
                        ThemedEditor(text: $draft.pem, font: Theme.mono(11), minHeight: 160)
                        SSHEditorField(label: L10n.text("apple.sshlibraryeditors.private_key_passphrase_if_it_has_one.948cec1e")) {
                            SecureField(L10n.text("apple.sshlibraryeditors.passphrase.e7611f05"), text: $draft.passphrase).themedFieldBox()
                        }
                        HStack(spacing: Theme.Space.s) {
                            Button(L10n.text("apple.sshlibraryeditors.import_pasted_key.92d28e76"), .upload) { Task { await importPasted() } }
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
        .navigationTitle(isNew ? L10n.text("apple.sshlibraryeditors.add_key.12626d65") : label)
        .task {
            guard claim() != nil, !loaded else { return }
            loaded = true
            if let keyID, let existing = model.keys.first(where: { $0.id == keyID }) {
                record = existing
                label = existing.label
            }
        }
        .confirmationDialog(L10n.text("apple.sshlibraryeditors.delete_this_key.a5c8994b"), isPresented: $draft.confirmingDelete, titleVisibility: .visible) {
            Button(L10n.text("common.delete"), role: .destructive) {
                let doomed = record
                finish()
                Task { if let doomed { await model.delete(key: doomed) } }
            }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("apple.sshlibraryeditors.the_private_key_is_removed_from_this_devic.52587af1"))
        }
    }

    private func generate() async {
        guard let owner = claim(), !working else { return }
        guard !working else { return }
        let requestedAlgorithm = algorithm
        working = true
        defer { if permits(owner) { working = false } }
        do {
            let material: SSHKeyMaterial
            switch requestedAlgorithm {
            case .ed25519:
                material = try await Bridge.generateSSHKey()
                guard permits(owner) else { return }
            case .ecdsaP256, .ecdsaP256TouchID:
                let pem = await Task.detached { SSHKeyAlgorithm.makeP256PEM() }.value
                guard permits(owner) else { return }
                material = try await Bridge.inspectSSHKey(pem: pem, passphrase: nil)
                guard permits(owner) else { return }
            }
            await keep(material, protected: false, biometric: requestedAlgorithm == .ecdsaP256TouchID)
        }
        catch { if permits(owner) { self.error = error.localizedDescription } }
    }

    private func importPasted() async {
        guard let owner = claim(), !working else { return }
        guard !working else { return }
        let requestedPassphrase = passphrase
        working = true
        defer { if permits(owner) { working = false } }
        do {
            let material = try await Bridge.inspectSSHKey(
                pem: pem, passphrase: requestedPassphrase.isEmpty ? nil : requestedPassphrase
            )
            guard permits(owner) else { return }
            await keep(material, protected: !requestedPassphrase.isEmpty)
        } catch { if permits(owner) { self.error = error.localizedDescription } }
    }

    private func keep(_ material: SSHKeyMaterial, protected: Bool, biometric: Bool = false) async {
        guard let owner = claim() else { return }
        do {
            let id = "key_\(UUID().uuidString)"
            // The store and ownership check are one actor turn. A detached
            // store could import a key after this editor's account retired.
            let reference = try SSHSecretStore.store(material.privateKey, id: id, biometric: biometric)
            let key = SSHKeyRecord(
                id: id, label: label, algorithm: material.algorithm,
                publicKey: material.publicKey, secretRef: reference,
                hardwareBacked: false, fingerprint: material.fingerprint,
                createdMs: Int64(Date().timeIntervalSince1970 * 1000),
                passphraseProtected: protected
            )
            let saved = await model.save(key: key, privateKey: material.privateKey,
                onLocalFailure: { SSHSecretStore.delete(reference: reference) })
            guard permits(owner) else { return }
            if let saved {
                record = saved
                pem = ""
                passphrase = ""
            } else {
                error = model.error
                model.error = nil
            }
        } catch { if permits(owner) { self.error = error.localizedDescription } }
    }

    private func rename() async {
        guard let owner = claim(), !working else { return }
        guard var record else { return }
        working = true
        defer { if permits(owner) { working = false } }
        record.label = label
        let saved = await model.save(key: record, privateKey: nil)
        guard permits(owner) else { return }
        if saved != nil {
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

    @Bindable private var draft: SSHSnippetDraft
    init(model: SSHLibraryModel, snippetID: String?, onDone: @escaping () -> Void) {
        self.model = model; self.onDone = onDone
        self.snippetID = snippetID
        self.draft = model.drafts.draft(for: snippetID.map(SSHLibraryRoute.snippet) ?? .newSnippet, make: SSHSnippetDraft.init)
    }
    private var snippet: SSHSnippet { get { draft.snippet } nonmutating set { draft.snippet = newValue } }
    private var loaded: Bool { get { draft.loaded } nonmutating set { draft.loaded = newValue } }
    private var working: Bool { get { draft.working } nonmutating set { draft.working = newValue } }
    private var error: String? { get { draft.error } nonmutating set { draft.error = newValue } }
    private var confirmingDelete: Bool { get { draft.confirmingDelete } nonmutating set { draft.confirmingDelete = newValue } }

    private func claim() -> SSHOperationOwner.Ticket? {
        guard draft.active else { return nil }
        return model.ownership.claim()
    }
    private func permits(_ owner: SSHOperationOwner.Ticket) -> Bool {
        draft.active && model.ownership.permits(owner)
    }

    private var isNew: Bool { snippetID == nil }

    /// Leave the editor. On the Mac this is the inspector column, so
    /// `Environment.dismiss` would close the window. On the phone, `onDone`
    /// already pops the pushed screen by clearing the route.
    private func finish() {
        guard claim() != nil else { return }
        model.drafts.remove(snippetID.map(SSHLibraryRoute.snippet) ?? .newSnippet)
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
                TextField(L10n.text("apple.sshlibraryeditors.name.dcd1d522"), text: $draft.snippet.title)
                    .textFieldStyle(.themed)
                Text(L10n.text("apple.sshlibraryeditors.command.71316697"))
                    .font(Theme.caption).foregroundStyle(.secondary)
                // The border used to be drawn over a bare TextEditor, which
                // themed the outline of the platform's grey slab and left the
                // slab. ThemedEditor hides that background so the fill is the
                // app's own panel, like the name field above it.
                // No infinite maximum. Inside a scroll view an unbounded
                // height is a request for as much as the content wants, and a
                // text editor's content grows with what is typed into it.
                ThemedEditor(text: $draft.snippet.command, minHeight: 140)
                if placeholders.isEmpty {
                    Text(L10n.text("apple.sshlibraryeditors.wrap_a_value_in_braces_to_be_asked_for_it.76780e5c"))
                        .font(Theme.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: Theme.Space.xs) {
                        Text(L10n.text("apple.sshlibraryeditors.asks_for.e07b5c1a")).font(Theme.caption).foregroundStyle(.secondary)
                        ForEach(placeholders, id: \.self) { name in
                            Text(name)
                                .font(Theme.mono(10))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.accentSoft, in: Capsule())
                        }
                    }
                }
                Toggle(L10n.text("apple.sshlibraryeditors.run_automatically_after_connecting.b531eae1"), isOn: $draft.snippet.runOnConnect)
                    .toggleStyle(.brandCheckbox)
                    .disabled(snippet.hostIDs.isEmpty || !placeholders.isEmpty)
                if snippet.hostIDs.isEmpty {
                    Text(L10n.text("apple.sshlibraryeditors.pick_the_servers_this_snippet_belongs_to_b.ecbd238b"))
                        .font(Theme.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !placeholders.isEmpty {
                    Text(L10n.text("apple.sshlibraryeditors.a_snippet_that_asks_for_values_cannot_run.46222c41"))
                        .font(Theme.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            }

            SSHEditorFooter(
                saveTitle: isNew ? L10n.text("apple.sshlibraryeditors.add_snippet.a1f802b9") : L10n.text("common.save"),
                canSave: !snippet.title.isEmpty && !snippet.command.isEmpty,
                working: working,
                onSave: { Task { await save() } },
                onCancel: finish,
                onDelete: isNew ? nil : { confirmingDelete = true }
            )
        }
        .navigationTitle(isNew ? L10n.text("apple.sshlibraryeditors.add_snippet.a1f802b9") : snippet.title)
        .task {
            guard claim() != nil, !loaded else { return }
            loaded = true
            if let snippetID, let existing = model.snippets.first(where: { $0.id == snippetID }) {
                snippet = existing
            }
        }
        .confirmationDialog(L10n.text("apple.sshlibraryeditors.delete_this_snippet.58a04ce8"), isPresented: $draft.confirmingDelete, titleVisibility: .visible) {
            Button(L10n.text("common.delete"), role: .destructive) {
                finish()
                Task { await model.delete(snippet: snippet) }
            }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        }
    }

    private func save() async {
        guard let owner = claim(), !working else { return }
        working = true
        defer { if permits(owner) { working = false } }
        snippet.variables = placeholders
        let saved = await model.save(snippet: snippet)
        guard permits(owner) else { return }
        if saved != nil {
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

    @Bindable private var draft: SSHFolderDraft
    init(model: SSHLibraryModel, folderID: String?, parentID: String?, onDone: @escaping () -> Void) {
        self.model = model; self.onDone = onDone
        self.folderID = folderID; self.parentID = parentID
        self.draft = model.drafts.draft(for: folderID.map(SSHLibraryRoute.folder) ?? .newFolder(parent: parentID), make: SSHFolderDraft.init)
    }
    private var folder: SSHFolder { get { draft.folder } nonmutating set { draft.folder = newValue } }
    private var loaded: Bool { get { draft.loaded } nonmutating set { draft.loaded = newValue } }
    private var working: Bool { get { draft.working } nonmutating set { draft.working = newValue } }
    private var error: String? { get { draft.error } nonmutating set { draft.error = newValue } }
    private var confirmingDelete: Bool { get { draft.confirmingDelete } nonmutating set { draft.confirmingDelete = newValue } }

    private func claim() -> SSHOperationOwner.Ticket? {
        guard draft.active else { return nil }
        return model.ownership.claim()
    }
    private func permits(_ owner: SSHOperationOwner.Ticket) -> Bool {
        draft.active && model.ownership.permits(owner)
    }

    private var isNew: Bool { folderID == nil }

    /// Leave the editor. On the Mac this is the inspector column, so
    /// `Environment.dismiss` would close the window. On the phone, `onDone`
    /// already pops the pushed screen by clearing the route.
    private func finish() {
        guard claim() != nil else { return }
        model.drafts.remove(folderID.map(SSHLibraryRoute.folder) ?? .newFolder(parent: parentID))
        onDone()
    }

    var body: some View {
        VStack(spacing: 0) {
            SSHEditorBody(working: working) {
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                SSHEditorSection(title: L10n.text("apple.sshlibraryeditors.folder.74ccd433")) {
                    SSHEditorField(label: L10n.text("apple.sshlibraryeditors.name.dcd1d522")) {
                        TextField(L10n.text("apple.sshlibraryeditors.name.dcd1d522"), text: $draft.folder.name).textFieldStyle(.themed)
                    }
                    SSHEditorField(label: L10n.text("apple.sshlibraryeditors.inside.123a3ebc")) {
                        Picker(L10n.text("apple.sshlibraryeditors.inside.123a3ebc"), selection: Binding(
                            get: { folder.parentID ?? "" },
                            set: { folder.parentID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text(L10n.text("apple.sshlibraryeditors.top_level.f61dd254")).tag("")
                            ForEach(model.folders.filter { $0.id != folder.id }) { Text($0.name).tag($0.id) }
                        }
                    }
                    SSHColorPicker(selection: $draft.folder.color)
                }
                SSHEditorNote(text: L10n.text("apple.sshlibraryeditors.deleting_a_folder_keeps_what_is_in_it_serv.285fdc6d"))
            }

            SSHEditorFooter(
                saveTitle: isNew ? L10n.text("apple.sshlibraryeditors.add_folder.5bbfc5a6") : L10n.text("common.save"),
                canSave: !folder.name.isEmpty,
                working: working,
                onSave: { Task { await save() } },
                onCancel: finish,
                onDelete: isNew ? nil : { confirmingDelete = true }
            )
        }
        .navigationTitle(isNew ? L10n.text("apple.sshlibraryeditors.add_folder.5bbfc5a6") : folder.name)
        .task {
            guard claim() != nil, !loaded else { return }
            loaded = true
            if let folderID, let existing = model.folders.first(where: { $0.id == folderID }) {
                folder = existing
            } else {
                folder.parentID = parentID
            }
        }
        .confirmationDialog(L10n.text("apple.sshlibraryeditors.delete_this_folder.76764808"), isPresented: $draft.confirmingDelete, titleVisibility: .visible) {
            Button(L10n.text("common.delete"), role: .destructive) {
                finish()
                Task { await model.delete(folder: folder) }
            }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("apple.sshlibraryeditors.servers_and_sub_folders_inside_it_move_up.c429a85f"))
        }
    }

    private func save() async {
        guard let owner = claim(), !working else { return }
        working = true
        defer { if permits(owner) { working = false } }
        let saved = await model.save(folder: folder)
        guard permits(owner) else { return }
        if saved != nil {
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
                    title: L10n.text("apple.sshlibraryeditors.no_trusted_servers_yet.c7540d35"),
                    message: L10n.text("apple.sshlibraryeditors.the_first_time_you_connect_to_a_server_you.379e18b6")
                )
            } else {
                List {
                    ForEach(model.knownHosts) { known in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(known.label)
                            Text("\(known.hostname):\(known.port)")
                                .font(Theme.caption).foregroundStyle(.secondary)
                            ForEach(known.fingerprints, id: \.self) { print in
                                Text(print).font(Theme.mono(10)).textSelection(.enabled)
                            }
                            Button(L10n.text("apple.sshlibraryeditors.forget.a6bd489d"), .revoke) {
                                Task { await model.forgetKnownHost(known) }
                            }
                            .buttonStyle(SecondaryButtonStyle(small: true))
                        }
                        .padding(.vertical, Theme.Space.xs)
                    }
                }
            }
        }
        .navigationTitle(L10n.text("apple.sshlibraryeditors.trusted_servers.b101ed86"))
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

    @Bindable private var draft: SSHConfigDraft
    init(model: SSHLibraryModel, onDone: @escaping () -> Void) {
        self.model = model; self.onDone = onDone
        self.draft = model.drafts.draft(for: .importConfig, make: SSHConfigDraft.init)
    }
    private var candidates: [SSHConfigCandidate] { get { draft.candidates } nonmutating set { draft.candidates = newValue } }
    private var loading: Bool { get { draft.loading } nonmutating set { draft.loading = newValue } }
    private var working: Bool { get { draft.working } nonmutating set { draft.working = newValue } }
    private var imported: SSHConfigImport? { get { draft.imported } nonmutating set { draft.imported = newValue } }
    private var error: String? { get { draft.error } nonmutating set { draft.error = newValue } }

    private func claim() -> SSHOperationOwner.Ticket? {
        guard draft.active else { return nil }
        return model.ownership.claim()
    }
    private func permits(_ owner: SSHOperationOwner.Ticket) -> Bool {
        draft.active && model.ownership.permits(owner)
    }

    private var newCount: Int { candidates.filter { !$0.alreadySaved }.count }

    /// Leave the editor. On the Mac this is the inspector column, so
    /// `Environment.dismiss` would close the window. On the phone, `onDone`
    /// already pops the pushed screen by clearing the route.
    private func finish() {
        guard claim() != nil else { return }
        model.drafts.remove(.importConfig)
        onDone()
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if loading {
                    ProgressView(L10n.text("apple.sshlibraryeditors.reading_ssh_config.c68950fc"))
                } else if candidates.isEmpty {
                    EmptyState(
                        symbol: "doc.text.magnifyingglass",
                        title: L10n.text("apple.sshlibraryeditors.nothing_to_import.c4497f32"),
                        message: L10n.text("apple.sshlibraryeditors.there_is_no_ssh_config_on_this_machine_or.d3ad32d2")
                    )
                } else {
                    List {
                        if let imported {
                            InlineBanner(
                                text: imported.imported == 1
                                    ? L10n.text("apple.sshlibraryeditors.imported_1_server.55a1249f")
                                    : L10n.text("apple.sshlibraryeditors.imported_0_servers.7b286af3", "\(imported.imported)"),
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
                                        .font(Theme.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if candidate.alreadySaved {
                                    Text(L10n.text("apple.sshlibraryeditors.already_saved.748a428f"))
                                        .font(Theme.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(minHeight: Theme.Control.rowHeight)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            SSHEditorFooter(
                saveTitle: newCount == 1 ? L10n.text("apple.sshlibraryeditors.import_1_server.6af4f169") : L10n.text("apple.sshlibraryeditors.import_0_servers.2c452fd7", "\(newCount)"),
                canSave: newCount > 0,
                working: working,
                onSave: { Task { await run() } },
                onCancel: finish,
                onDelete: nil
            )
        }
        .navigationTitle(L10n.text("apple.sshlibraryeditors.import_from_ssh_config.1b6e8c38"))
        .task {
            guard let owner = claim(), loading else { return }
            let fresh = (try? await Bridge.sshConfigCandidates()) ?? []
            guard permits(owner) else { return }
            candidates = fresh; loading = false
        }
    }

    private func run() async {
        guard let owner = claim(), !working else { return }
        working = true
        defer { if permits(owner) { working = false } }
        do {
            let result = try await Bridge.importSSHConfig()
            guard permits(owner) else { return }
            imported = result
            let fresh = try? await Bridge.sshConfigCandidates()
            guard permits(owner) else { return }
            if let fresh { candidates = fresh }
            await model.reload()
        } catch { if permits(owner) { self.error = error.localizedDescription } }
    }
}
