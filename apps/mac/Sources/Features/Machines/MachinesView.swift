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
/// machine that is knocking, then check this machine's own fingerprint against
/// the one shown on the other end, then pair something new.
struct MachinesView: View {
    @Bindable var model: MachinesModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let message = model.errorMessage {
                    Banner(text: message, severity: .warning)
                }
                if let notice = model.noticeMessage {
                    Banner(text: notice, severity: .success)
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
        .task { if model.identity == nil { await model.load() } }
    }

    // MARK: - This machine

    private var thisMachine: some View {
        Card(
            title: "This machine",
            subtitle: "How other machines reach it, and what they check against."
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let identity = model.identity {
                    LabeledContent("Name") { Text(identity.label) }
                    LabeledContent("Fingerprint") {
                        Text(identity.fingerprint)
                            .font(Theme.mono(12))
                            .textSelection(.enabled)
                    }
                    if let link = model.connectLink {
                        LabeledContent("Connect link") {
                            HStack(spacing: Theme.Space.xs) {
                                Text(link)
                                    .font(Theme.mono(10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(link, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Copy the link to paste on another machine")
                            }
                        }
                    }
                }
                Divider()
                serving
                Text("""
                Machines on the same network appear under Found nearby, so there \
                is nothing to type. Anywhere else, copy this link and paste it \
                into the other machine's Connect box.
                """)
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
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
                // that showed only the setting would be lying.
                if status.serving && !status.listening {
                    Banner(
                        text: "Turned on, but not listening. Port \(status.port) is probably in use.",
                        severity: .warning
                    )
                } else if let address = status.address {
                    Text("Listening on \(address)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Peers

    private var discoveredMachines: some View {
        Card(
            title: "Found nearby",
            subtitle: "These daemons are advertising on the local network."
        ) {
            VStack(spacing: Theme.Space.s) {
                ForEach(model.discovered) { daemon in
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(daemon.label)
                                .font(.callout.weight(.medium))
                            Text(daemon.fingerprint)
                                .font(Theme.mono(11))
                                .foregroundStyle(.secondary)
                            Text(daemon.address ?? "Resolving address...")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Connect") { Task { await model.pair(daemon) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(daemon.address == nil)
                    }
                    .padding(Theme.Space.s)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                }
                Text("The fingerprint is compared with the one shown on that machine before it can reach this one.")
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
                Check the fingerprint against the one shown on that machine \
                before approving. They match, or something is answering in its \
                place.
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
                // The fingerprint rather than the key, because this line exists
                // to be compared with another screen by a person.
                Text(peer.fingerprint)
                    .font(Theme.mono(11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let address = peer.address {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            actions
        }
        .padding(Theme.Space.s)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
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

/// Connect to a machine by pasting its link.
///
/// One field accepts the whole thing, `key@host:port` or just the key. This
/// path works with no account and no network service at all, which is why it
/// is on the screen rather than behind an "advanced" disclosure: it is the
/// thing that makes the privacy claim checkable instead of promised.
private struct PairingForm: View {
    var pair: (String, String, String) async -> Void

    @State private var link = ""
    @State private var label = ""
    @State private var working = false

    var body: some View {
        Card(
            title: "Add a machine",
            subtitle: "Paste a connect link, or the key alone, from its Machines screen."
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField(
                    "Connect link or key",
                    text: $link,
                    prompt: Text("key@host:port, or just the key")
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
                will show this machine waiting. A key is a 64 character hex \
                string; the address after the @ is where to dial it.
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
