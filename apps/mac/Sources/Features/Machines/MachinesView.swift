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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let message = model.errorMessage {
                    Banner(text: message, severity: .warning)
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
                if !model.known.isEmpty {
                    knownMachines
                }
                pairing
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
        .task { if model.identity == nil { await model.load() } }
    }

    // MARK: - This machine

    private var thisMachine: some View {
        Card(
            title: "This machine",
            subtitle: "What the other machine sees when it finds this one."
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let identity = model.identity {
                    LabeledContent("Name") { Text(identity.label) }
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
                    if let code = model.pairingCode {
                        LabeledContent("Pairing code") {
                            HStack(spacing: Theme.Space.xs) {
                                Text(code)
                                    .font(Theme.mono(10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(code, forType: .string)
                                    model.noticeMessage = "Pairing code copied."
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Copy it, then paste it on the other machine")
                            }
                        }
                    }
                }
                Divider()
                serving
                Text("""
                Machines on the same network find each other, so there is \
                nothing to type. Anywhere else, copy the pairing code and paste \
                it into the other machine.
                """)
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
                        Text("Let other machines reach this one")
                        Text("""
                        Off until you turn it on. A machine that connects can \
                        run commands and change files here, so nothing is \
                        served until you approve it by name.
                        """)
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
                        text: """
                        Turned on, but not reachable. This machine refused to \
                        accept connections at all, which is usually a firewall.
                        """,
                        severity: .warning
                    )
                }
            }
        }
    }

    // MARK: - Peers

    private var discoveredMachines: some View {
        Card(
            title: "Machines nearby",
            subtitle: "Found on this network. Nothing to type."
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
                Text("""
                Check the two words against the ones on that machine's screen \
                before it can reach this one.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var waitingForApproval: some View {
        Card(
            title: "Waiting for you",
            subtitle: "These machines tried to connect and were turned away."
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
                Text("""
                Check the two words against the ones on that machine before \
                approving. They match, or something is answering in its place.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var knownMachines: some View {
        Card(title: "Known machines", subtitle: nil) {
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

    // MARK: - Pairing

    private var pairing: some View {
        PairingForm { key, label, address in
            await model.pair(key: key, label: label, address: address)
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
            title: "Add a machine",
            subtitle: "Paste the pairing code from its Machines screen."
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
