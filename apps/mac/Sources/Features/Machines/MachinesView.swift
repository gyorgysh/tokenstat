// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// This machine, who may reach it, and who it can reach.
///
/// The screen is ordered by what somebody came here to do: decide about a
/// machine that is knocking, then read this machine's own two words to compare
/// with the other end, then add something new.
///
/// It says nothing about ports, addresses or keys. A person setting up their
/// second computer has a laptop and a desktop, not a host and a socket, and the
/// vocabulary here follows `docs/remote-transport.md`: a name, two words to
/// compare, and one code to paste. The raw facts stay one disclosure away for
/// whoever is debugging their own network.
struct MachinesView: View {
    @Bindable var model: MachinesModel
    @State private var addingDevice = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let message = model.errorMessage {
                    Banner(text: message, severity: .warning)
                }
                if !Bridge.isHosted {
                    hostSetup
                }
                // First, because it is the only thing here that is waiting on a
                // person. Everything else can be read at leisure.
                if !model.pending.isEmpty {
                    waitingForApproval
                }

                thisMachine
                if !model.discovered.isEmpty {
                    discoveredMachines
                }
                if !model.accountMachines.isEmpty {
                    accountDevices
                }
                if !model.known.isEmpty {
                    knownMachines
                }
                addDeviceAction
                privacyNote
            }
            .padding(Theme.Space.m)
        }
        .navigationTitle("Machines")
        .background(Theme.background)
        .overlay(alignment: .bottomTrailing) {
            TransientToast(message: $model.noticeMessage, severity: .success)
                .padding(Theme.Space.l)
        }
        .task {
            if model.identity == nil { await model.load() }
            await model.ensureHelper()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await model.refresh()
            }
        }
        .sheet(isPresented: $addingDevice) {
            PairingForm { key, label, address in
                await model.pair(key: key, label: label, address: address)
                addingDevice = false
            }
            .padding(Theme.Space.l)
            .frame(width: 500)
        }
    }

    private var addDeviceAction: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add a device")
                    .font(.callout.weight(.medium))
                Text("Use nearby discovery or paste a connection invite for a device elsewhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add device") { addingDevice = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    private var hostSetup: some View {
        Card(title: "This Mac is not ready for background connections", subtitle: "The app can still show local data. A small background helper is needed for machines and automations to keep working when this window is closed.") {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                Text("Local app mode")
                    .font(.callout.weight(.medium))
                Spacer()
                Button {
                    Task { await model.setupHelper() }
                } label: {
                    if model.settingUpHelper {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Set up helper")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.settingUpHelper)
            }
        }
    }

    // MARK: - This machine

    private var thisMachine: some View {
        Card(
            title: "This machine",
            subtitle: "One simple identity for every connection."
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let identity = model.identity {
                    LabeledContent("Name") {
                        MachineNameField(identity: identity) { name in
                            await model.rename(to: name)
                        }
                    }
                    if let words = model.words {
                        LabeledContent("Known as") {
                            // The comparison a person actually performs. The
                            // fingerprint and the key still exist and are one
                            // disclosure away, under Connection details.
                            Text(words)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .textSelection(.enabled)
                        }
                    }
                }
                Divider()
                serving
                Text("Nearby Macs appear automatically. For a machine elsewhere, use Add device once and approve the connection on both sides.")
                .font(.caption)
                .foregroundStyle(.tertiary)

                connectionDetails
            }
        }
    }

    /// The addresses, ports and keys, for whoever is debugging their own
    /// network.
    ///
    /// Present but closed. Hiding them entirely would mean the honest version of
    /// this screen is the one we do not show, and somebody whose connection is
    /// failing needs exactly these three facts.
    @ViewBuilder
    private var connectionDetails: some View {
        if let identity = model.identity {
            DisclosureGroup("Connection details") {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    LabeledContent("Fingerprint") {
                        Text(identity.fingerprint)
                            .font(Theme.mono(11))
                            .textSelection(.enabled)
                    }
                    if let status = model.status {
                        LabeledContent("Port") { Text("\(status.port)") }
                        if let address = status.address, status.listening {
                            LabeledContent("Address") {
                                Text(address)
                                    .font(Theme.mono(11))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.top, Theme.Space.xs)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var serving: some View {
        if let status = model.status {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Toggle(isOn: Binding(
                    get: { status.serving },
                    set: { enabled in Task { await model.setServing(enabled) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Link devices")
                        Text("Only approved devices can open sessions or change files here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: Binding(
                    get: { status.tunnel },
                    set: { enabled in Task { await model.setTunnel(enabled) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reach machines from anywhere")
                        Text("Uses end-to-end encryption. The service can see which machines talked, when, and how much, but not what they said.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                // The setting and the truth are different facts. A port already
                // in use leaves the first on and the second off, and a screen
                // that showed only the setting would be lying. Which port is
                // under Connection details, where somebody debugging will look.
                if status.serving && !status.listening {
                    // Rare now that a taken port falls back to a free one, so
                    // this means the machine would not let us listen at all.
                    Banner(
                        text: "The helper is not listening yet. Set up the background helper, then try again.",
                        severity: .warning
                    )
                }
            }
        }
    }

    // MARK: - Peers

    private var discoveredMachines: some View {
        Card(
            title: "Nearby devices",
            subtitle: "Connect with one click, then approve the pairing."
        ) {
            VStack(spacing: Theme.Space.s) {
                ForEach(model.discovered) { daemon in
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(daemon.label)
                                .font(.callout.weight(.medium))
                            Text(daemon.words ?? daemon.fingerprint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if daemon.address == nil {
                                Text("Still finding it…")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button("Connect") { Task { await model.pair(daemon) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(daemon.address == nil)
                    }
                    .padding(Theme.Space.s)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
                }
                Text("Check the matching device name before approving access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var waitingForApproval: some View {
        Card(
            title: "Needs your approval",
            subtitle: "Nothing can run here until you approve it."
        ) {
            VStack(spacing: Theme.Space.s) {
                ForEach(model.pending) { peer in
                    PeerRow(peer: peer) {
                        HStack(spacing: Theme.Space.s) {
                            Button("Approve") { Task { await model.approve(peer) } }
                                .buttonStyle(.borderedProminent)
                            Button("Forget") { Task { await model.forget(peer) } }
                        }
                    }
                }
                Text("Approve only devices you recognize. You can revoke access later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var knownMachines: some View {
        Card(title: "Your devices", subtitle: "Manage connections you have already approved.") {
            VStack(spacing: Theme.Space.s) {
                ForEach(model.known) { peer in
                    PeerRow(peer: peer) {
                        HStack(spacing: Theme.Space.s) {
                            if peer.trust == .approved {
                                Button("Revoke") { Task { await model.revoke(peer) } }
                            } else {
                                Button("Approve") { Task { await model.approve(peer) } }
                            }
                            Button("Forget") { Task { await model.forget(peer) } }
                        }
                    }
                }
            }
        }
    }

    private var accountDevices: some View {
        Card(title: "Account-linked devices", subtitle: "Machines linked to this account. Presence and direct connection arrive when the host reports them.") {
            VStack(spacing: 0) {
                ForEach(model.accountMachines) { machine in
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: machine.machineID == model.account?.thisMachineID ? "laptopcomputer" : "desktopcomputer")
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(machine.displayName)
                                .font(.callout.weight(.medium))
                            Text(machine.machineID == model.account?.thisMachineID
                                ? "This device"
                                : (formatRelativeDate(machine.lastSyncAt).map { "Last synced \($0)" } ?? "No sync recorded"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if machine.machineID == model.account?.thisMachineID {
                            Text("Here")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.accent)
                        } else if let online = machine.online {
                            Text(online ? "Online" : "Offline")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(online ? AnyShapeStyle(Theme.success) : AnyShapeStyle(.tertiary))
                        } else if let seen = formatRelativeDate(machine.lastSeenAt) {
                            Text("Seen \(seen)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        DeviceStateBadge(state: model.state(for: machine))
                        if let peer = model.peer(for: machine) {
                            accountPeerActions(peer)
                        } else if machine.online == true {
                            Button("Connect") { }
                                .buttonStyle(.bordered)
                                .disabled(true)
                                .help("Connection details are not available from this account record yet")
                        }
                    }
                    .padding(.vertical, Theme.Space.s)
                    if machine.id != model.accountMachines.last?.id { Divider() }
                }
            }
        }
    }

    @ViewBuilder
    private func accountPeerActions(_ peer: Peer) -> some View {
        switch peer.trust {
        case .pending:
            Button("Approve") { Task { await model.approve(peer) } }
                .buttonStyle(.borderedProminent)
        case .approved:
            if peer.address?.isEmpty == false {
                Button("Connect") { Task { await model.connect(peer) } }
                    .buttonStyle(.borderedProminent)
            }
            Button("Revoke") { Task { await model.revoke(peer) } }
                .buttonStyle(.bordered)
        case .revoked:
            Button("Approve") { Task { await model.approve(peer) } }
                .buttonStyle(.bordered)
        }
    }

    private var privacyNote: some View {
        Text("""
        A connection between two machines carries terminal output, file \
        contents and diffs. It is encrypted end to end and goes straight to \
        the other machine, so nothing passes through tokenstat.ai. Only \
        aggregate counters are ever eligible for sync.
        """)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.top, Theme.Space.xs)
    }
}

private struct DeviceStateBadge: View {
    let state: MachinesModel.DeviceState

    var body: some View {
        Text(state.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case .connected, .ready: return Theme.success
        case .settingUp, .waitingApproval: return Theme.warning
        case .needsPermission, .needsSignIn: return Theme.accent
        case .unavailable: return .secondary
        }
    }
}

// MARK: - Naming this machine

/// The machine's name, editable in place.
///
/// A text field rather than a sheet, because renaming a computer is not a
/// decision with consequences: the key is the identity, so this changes only how
/// the machine reads on somebody else's screen. Committed on return or on losing
/// focus, and emptying it puts the computer's own name back.
private struct MachineNameField: View {
    var identity: MachineIdentity
    var rename: (String) async -> Void

    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            TextField("Name", text: $draft, prompt: Text(identity.label))
                .textFieldStyle(.plain)
                .focused($editing)
                .onSubmit { commit() }
                .frame(maxWidth: 220)
            if identity.labelIsChosen == true {
                Button("Use the computer's name") {
                    draft = ""
                    commit()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .onAppear { draft = identity.label }
        .onChange(of: identity.label) { _, new in
            // Only while nobody is typing, so a refresh underneath somebody
            // mid-edit does not take the characters back out of the field.
            if !editing { draft = new }
        }
        .onChange(of: editing) { _, focused in
            if !focused { commit() }
        }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != identity.label else { return }
        Task { await rename(name) }
    }
}

// MARK: - One peer

private struct PeerRow<Actions: View>: View {
    var peer: Peer
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Text(peer.label)
                        .font(.callout.weight(.medium))
                    TrustBadge(trust: peer.trust)
                }
                // The words rather than the key or the fingerprint: this line
                // exists to be compared with another screen by a person, and
                // that is the form they will read whole.
                Text(peer.words ?? peer.fingerprint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            actions
        }
        .padding(Theme.Space.s)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private var tint: Color {
        switch peer.trust {
        case .approved: return Theme.success
        case .pending: return Theme.warning
        case .revoked: return .secondary
        }
    }
}

private struct TrustBadge: View {
    var trust: Peer.Trust

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private var label: String {
        switch trust {
        case .approved: return "approved"
        case .pending: return "waiting"
        case .revoked: return "revoked"
        }
    }

    private var tint: Color {
        switch trust {
        case .approved: return Theme.success
        case .pending: return Theme.warning
        case .revoked: return Theme.danger
        }
    }
}

// MARK: - Pairing by hand

/// Connect to a machine by pasting its pairing code.
///
/// One field, whatever the other machine showed. This path works with no
/// account and no network service at all, which is why it is on the screen
/// rather than behind an "advanced" disclosure: it is the thing that makes the
/// privacy claim checkable instead of promised.
private struct PairingForm: View {
    var pair: (String, String, String) async -> Void

    @State private var link = ""
    @State private var label = ""
    @State private var working = false

    var body: some View {
        Card(
            title: "Connect another device",
            subtitle: "Paste an invite from the other device. Nearby devices do not need this step."
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField(
                    "Pairing code",
                    text: $link,
                    prompt: Text("Paste the code from the other machine")
                )
                .font(Theme.mono(11))
                TextField("Name", text: $label, prompt: Text("What you call that machine"))

                HStack {
                    Spacer()
                    Button {
                        working = true
                        Task {
                            let (key, address) = splitLink(link)
                            await pair(key, label, address)
                            working = false
                            link = ""
                            label = ""
                        }
                    } label: {
                        Label("Connect", systemImage: "link")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || link.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Text("""
                Connecting here approves that machine to reach this one. The \
                other machine has to approve this one too, and its own screen \
                will show this machine waiting.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    /// `key@host:port` splits at the last @; a bare key has no address, which
    /// is right for a machine that only ever connects *to* this one.
    private func splitLink(_ raw: String) -> (String, String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.lastIndex(of: "@") else { return (trimmed, "") }
        return (
            String(trimmed[..<at]),
            String(trimmed[trimmed.index(after: at)...])
        )
    }
}
