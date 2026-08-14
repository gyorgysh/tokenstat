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
        @State private var confirmForget: Peer?
    @State private var confirmRevoke: Peer?

@Bindable var model: MachinesModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var addingDevice = false
    @State private var encryptionExpanded = false
    /// The account machine waiting on a Remove confirmation. Destructive on
    /// the server, so it never happens from a single click.
    @State private var pendingUnlink: Machine?

    var body: some View {
        VStack(spacing: 0) {
            DetailChromeBar {
                if model.remoteReachAllowed {
                    ToolbarIconButton(
                        systemImage: "plus",
                        help: "Paste a key from another device to pair it"
                    ) {
                        addingDevice = true
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let message = model.errorMessage {
                        ErrorBanner(message: message) { Task { await model.load() } }
                    }
                    if !Bridge.isHosted {
                        hostSetup
                    }
                    if model.remoteReachAllowed {
                        remoteReadyContent
                    } else {
                        remoteLockedContent
                    }
                }
                .padding(Theme.Space.m)
            }
        }
        .navigationTitle("Devices")
        .background(Theme.background)
        .confirmationDialog(
            "Remove from account?",
            isPresented: Binding(
                get: { pendingUnlink != nil },
                set: { if !$0 { pendingUnlink = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let machine = pendingUnlink {
                    Task { await model.unlink(machine) }
                }
                pendingUnlink = nil
            }
            Button("Cancel", role: .cancel) { pendingUnlink = nil }
        } message: {
            Text(pendingUnlink.map {
                "\(model.resolvedName(for: $0) ?? $0.displayName) will be removed from this account and its uploaded history deleted. Use this for a device id that no longer exists, for example after a reinstall."
            } ?? "")
        }
        .overlay(alignment: .bottomTrailing) {
            TransientToast(message: $model.noticeMessage, severity: .success)
                .padding(Theme.Space.l)
        }
        .task {
            if model.identity == nil { await model.load() }
            await model.ensureHelper()
            // The sleep is where cancellation lands when this screen goes away,
            // and it throws rather than returning, so the check afterwards is
            // what stops a final refresh going out on a torn-down view.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await model.refresh()
            }
        }
        // The sidebar sweep is the source of truth for who is actually
        // connected; keep the Connect/Disconnect buttons in step with it.
        .onReceive(NotificationCenter.default.publisher(for: .remotePeerDidConnect)) { note in
            if let key = note.object as? String {
                model.markConnected(key)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remotePeerDidDisconnect)) { note in
            if let key = note.object as? String {
                model.markDisconnected(key)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remotePeerBecameUnreachable)) { note in
            if let key = note.object as? String {
                model.markDisconnected(key)
            }
        }
        .sheet(isPresented: $addingDevice) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    InspectorCloseButton(
                        action: { addingDevice = false },
                        help: "Close",
                        label: "Close add device"
                    )
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.s)
                PairingForm { key, label, address in
                    await model.pair(key: key, label: label, address: address)
                    addingDevice = false
                }
                .padding(Theme.Space.l)
            }
            .frame(width: 500)
        }
    }

    /// The full pairing screen: approvals, this machine, peers, add, e2e.
    @ViewBuilder
    private var remoteReadyContent: some View {
        // First, because it is the only thing here that is waiting on a
        // person. Everything else can be read at leisure.
        if !model.pending.isEmpty {
            waitingForApproval
        }
        thisMachine
        if !model.accountMachines.isEmpty {
            accountDevices
        }
        if !model.known.isEmpty {
            knownMachines
        }
        addDeviceAction
        encryptionNote
    }

    /// Free and Supporter already share usage. The pairing chrome, the
    /// disabled tunnel switch and a See plans link at the foot of a long
    /// scroll are the wrong empty state: the action that ends it never
    /// reaches the first screenful. Match the phone Remote tab: one
    /// upgrade card, the machine list, then e2e.
    @ViewBuilder
    private var remoteLockedContent: some View {
        remotePlanEmpty
        if !model.accountMachines.isEmpty {
            lockedMachineList
        }
        encryptionNote
    }

    private var remotePlanEmpty: some View {
        EmptyState(
            symbol: "lock.laptopcomputer",
            title: "Remote is on Patron",
            message: model.account?.signedIn == true
                ? "This Mac already shares the account and sees usage from every device on it. Opening folders and terminals from another device is a paid feature."
                : "Sign in with a Patron or Legend account to open folders and terminals on this Mac from another device."
        ) {
            Link("See plans", destination: URL(string: "https://tokenstat.ai/pricing")!)
                .buttonStyle(AccentButtonStyle())
        }
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    /// Names and presence only. Connect, revoke and forget belong on
    /// the plan that can actually open a tunnel.
    private var lockedMachineList: some View {
        Card(
            title: "Devices on this account",
            subtitle: "Usage from every linked device is already here."
        ) {
            VStack(spacing: 0) {
                ForEach(model.listedAccountMachines) { machine in
                    lockedMachineRow(machine)
                    if machine.id != model.listedAccountMachines.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func lockedMachineRow(_ machine: Machine) -> some View {
        let isSelf = machine.machineID == model.account?.thisMachineID
            || machine.publicIdentity == model.identity?.key
        let resolved = model.resolvedName(for: machine)
        let symbol = machine.isHost
            ? (isSelf ? "laptopcomputer" : "desktopcomputer")
            : "iphone"
        return HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .foregroundStyle(isSelf ? Theme.accent : .secondary)
                .frame(width: 24)
            if isSelf {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 8, height: 8)
            } else {
                StatusDot(online: machine.online)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(resolved
                    ?? machine.machineID.map { "Machine \($0)" }
                    ?? "Unnamed device")
                    .font(.callout.weight(.medium))
                Text(statusLine(for: machine, isSelf: isSelf))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, Theme.Space.s)
        .accessibilityElement(children: .combine)
    }

    private var addDeviceAction: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add a device")
                    .font(.callout.weight(.medium))
                Text("Paste the key from the other machine. Everything goes through the tunnel, so it works from any network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add device") { addingDevice = true }
                .buttonStyle(AccentButtonStyle())
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
                .buttonStyle(AccentButtonStyle())
                .disabled(model.settingUpHelper)
            }
        }
    }

    // MARK: - This machine

    private var thisMachine: some View {
        Card(
            title: "This device",
            subtitle: "One simple identity for every connection."
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let identity = model.identity {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        LabeledContent("Name") {
                            MachineNameField(identity: identity) { name in
                                await model.rename(to: name)
                            }
                        }
                        if let words = model.words {
                            LabeledContent("Known as") {
                                // The comparison a person actually performs.
                                // The fingerprint and the key still exist and
                                // are one disclosure away, under Connection
                                // details. The words are derived from a public
                                // key: there is nothing private in them, so
                                // they are shown plain and selectable.
                                Text(words)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .textSelection(.enabled)
                            }
                        }
                        if model.pairingCode != nil {
                            LabeledContent("Connection invite") {
                                Button {
                                    model.copyInvite()
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(AccentButtonStyle(small: true))
                                .help("Paste this in the other machine's Add device box")
                            }
                        }
                    }
                    .transition(.smoothIn(reduceMotion: reduceMotion))
                } else {
                    // The identity comes from the daemon, so this card is empty
                    // for a moment on a cold launch. Two grey rows keep the card
                    // the height it will be rather than letting the whole screen
                    // shuffle upward when the name arrives.
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Skeleton.Bar(width: 220)
                        Skeleton.Bar(width: 160)
                    }
                    .transition(.opacity)
                }
                Divider()
                serving
                Text("Machines connect through the tokenstat tunnel, so they work from any network. Add a device once with its key and approve the connection on both sides.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .animation(.easeOut(duration: 0.22), value: model.identity != nil)
        }
    }

    @ViewBuilder
    private var serving: some View {
        Group {
            if let status = model.status {
                let allowed = model.remoteReachAllowed
                let planExpired = status.tunnel
                    && status.tunnelError?.contains("not_on_this_plan") == true
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(alignment: .center, spacing: Theme.Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reach devices from anywhere").font(.callout)
                            Text("Everything between machines goes through the tunnel, end to end encrypted. The service can see which machines talked, when, and how much, but not what they said.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Space.m)
                        Toggle("", isOn: Binding(
                            get: { allowed && status.tunnel },
                            set: { enabled in Task { await model.setTunnel(enabled) } }
                        ))
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                        .labelsHidden()
                        .accessibilityLabel("Reach devices from anywhere")
                        .disabled(!allowed)
                        .fixedSize()
                    }

                    if !allowed {
                        // The relay enforces the plan at every HELLO; this is
                        // the courtesy copy of the same gate, so nobody is
                        // invited to flip a switch the relay will refuse. A
                        // switch that was left on reads as off until the
                        // account qualifies again.
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(model.account?.signedIn == true
                                ? "This computer and a phone already share the account."
                                : "Remote reach needs a signed-in Patron account.")
                                .font(.callout.weight(.medium))
                            Text(model.account?.signedIn == true
                                ? "Free and Supporter add up usage from every device you link. Opening folders and terminals on this Mac from another device is on Patron."
                                : "Sign in with an account that includes it, then turn the switch on.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if model.account?.signedIn == true {
                                Link("See plans", destination: URL(string: "https://tokenstat.ai/pricing")!)
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .padding(Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                    } else if planExpired {
                        Banner(
                            text: "Your plan no longer includes remote reach. The relay is refusing this machine until the plan is restored.",
                            severity: .warning
                        )
                    }

                    if status.tunnel && status.tunnelOnline == false && !planExpired {
                        // The toggle is on but the daemon is not holding a
                        // socket. The plan gate, a revoked token and a dead
                        // endpoint all land here, and each needs different
                        // words from "wait".
                        Banner(
                            text: status.tunnelError.map {
                                "Remote reach is on, but the tunnel is not connected: \($0)"
                            } ?? "Remote reach is on, but the tunnel has not connected yet. It retries automatically.",
                            severity: .warning
                        )
                    }
                    if status.tunnel, status.tunnelOnline == true, status.tunnelRegistered == false {
                        Banner(
                            text: "This machine is on the tunnel, but the account directory does not list it yet. It will retry registration automatically.",
                            severity: .warning
                        )
                    }
                }
                .transition(.smoothIn(reduceMotion: reduceMotion))
            }
        }
        .confirmationDialog(
            "Forget this device?",
            isPresented: Binding(
                get: { confirmForget != nil },
                set: { if !$0 { confirmForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                if let peer = confirmForget {
                    Task { await model.forget(peer) }
                }
                confirmForget = nil
            }
            Button("Keep it", role: .cancel) { confirmForget = nil }
        } message: {
            Text("It is removed from this machine's peer list. You can approve it again later if it connects.")
        }
        .confirmationDialog(
            "Revoke access?",
            isPresented: Binding(
                get: { confirmRevoke != nil },
                set: { if !$0 { confirmRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                if let peer = confirmRevoke {
                    Task { await model.revoke(peer) }
                }
                confirmRevoke = nil
            }
            Button("Keep access", role: .cancel) { confirmRevoke = nil }
        } message: {
            Text("That device can no longer reach this machine until you approve it again.")
        }
        .animation(.easeOut(duration: 0.22), value: model.status != nil)
    }

    private var waitingForApproval: some View {
        Card(
            title: "Needs your approval",
            subtitle: "Nothing can run here until you approve it."
        ) {
            VStack(spacing: Theme.Space.s) {
                ForEach(model.pending) { peer in
                    PeerRow(peer: peer, resolvedName: model.accountName(for: peer)) {
                        HStack(spacing: Theme.Space.s) {
                            Button("Approve") { Task { await model.approve(peer) } }
                                .buttonStyle(AccentButtonStyle())
                            Button("Forget", role: .destructive) { confirmForget = peer }
                                .buttonStyle(SecondaryButtonStyle())
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
                    PeerRow(
                        peer: peer,
                        resolvedName: model.accountName(for: peer),
                        symbol: model.peerSymbol(for: peer)
                    ) {
                        HStack(spacing: Theme.Space.s) {
                            if peer.trust == .approved {
                                Button("Revoke", role: .destructive) { confirmRevoke = peer }
                                    .buttonStyle(SecondaryButtonStyle())
                            } else {
                                Button("Approve") { Task { await model.approve(peer) } }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                            Button("Forget", role: .destructive) { confirmForget = peer }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }
            .transition(.smoothIn(reduceMotion: reduceMotion))
        }
        .animation(.easeOut(duration: 0.22), value: model.known.isEmpty)
    }

    private var accountDevices: some View {
        Card(title: "Account-linked devices", subtitle: "Connect to any computer on this account in one click, over the tunnel. Phones are listed too, and dial you rather than the other way round.") {
            VStack(spacing: 0) {
                ForEach(model.listedAccountMachines) { machine in
                    // Phones are shown but never dialled: a client reaches a
                    // host, not the reverse (P5). Hiding them made a device
                    // somebody had signed in on look like it was not there.
                    // "This device" can also be matched by its key: a stale
                    // record whose id no longer equals thisMachineID must not
                    // suddenly look like a stranger with Connect buttons.
                    let isSelf = machine.machineID == model.account?.thisMachineID
                        || machine.publicIdentity == model.identity?.key
                    // The row's title: the machine's own name, or the name we
                    // know it by (this machine, or an approved peer) when the
                    // account has never named it. The code stays as the
                    // subtitle either way, so a resolved title never hides
                    // which machine the row is.
                    let resolved = model.resolvedName(for: machine)
                    let symbol = machine.isHost
                        ? (isSelf ? "laptopcomputer" : "desktopcomputer")
                        : "iphone"
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: symbol)
                            .foregroundStyle(isSelf ? Theme.accent : .secondary)
                            .frame(width: 24)
                        if isSelf {
                            // This machine's own presence: the accent colour
                            // when the tunnel is actually up (so the row reads
                            // as "this device, reachable"), grey when remote
                            // reach is off or the socket is not connected.
                            Circle()
                                .fill(model.status?.tunnelOnline == true ? Theme.accent : .gray)
                                .frame(width: 8, height: 8)
                        } else {
                            // The industry-standard presence light, before the
                            // name: solid when the machine is reachable right
                            // now, blinking while its state is not confirmed,
                            // grey when it is definitively offline.
                            StatusDot(online: machine.online)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            // An unnamed machine is still known by name when it
                            // is this one or a peer this Mac has approved: the
                            // account row keeps its code, but the title says
                            // who it actually is instead of "Device abc".
                            if let name = resolved {
                                Text(name)
                                    .font(.callout.weight(.medium))
                            } else {
                                Text(machine.machineID.map { "Machine \($0)" } ?? "Unnamed device")
                                    .font(.callout.weight(.medium))
                            }
                            if let id = machine.machineID, machine.label?.isEmpty == false || resolved != nil {
                                Text(id)
                                    .font(Theme.mono(11))
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                            // The detail line sits under the name, on its own
                            // row: the presence light is the quick read, this
                            // is the answer to "when did I last hear from it".
                            Text(statusLine(for: machine, isSelf: isSelf))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isSelf || !machine.isHost {
                            // The machine you are sitting at has no Connect and
                            // no revoke; "This device" under the name is the
                            // whole mark. A phone has none either: it is the
                            // side that dials, and approving it happens in
                            // "Your devices" when it knocks.
                            EmptyView()
                        } else {
                            if let peer = model.peer(for: machine) {
                                if model.isConnected(machine) {
                                    Button("Disconnect") {
                                        model.disconnect(peer)
                                    }
                                    .buttonStyle(SecondaryButtonStyle(small: true))
                                    .help("Removes this device's workspaces from the sidebar")
                                } else {
                                    accountPeerActions(peer, machine: machine)
                                }
                            } else if let key = machine.publicIdentity, !key.isEmpty {
                                // Offline machines cannot answer a dial. Showing
                                // Connect here was a button whose only outcome
                                // was a failure.
                                if model.canConnect(machine) {
                                    Button("Connect") { Task { await model.connect(machine) } }
                                        .buttonStyle(AccentButtonStyle(small: true))
                                        .help("Connects through the tunnel from anywhere")
                                }
                            }
                            Button {
                                pendingUnlink = machine
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(SecondaryButtonStyle(small: true))
                            .help("Remove from account (deletes its uploaded history)")
                        }
                    }
                    .padding(.vertical, Theme.Space.s)
                    if machine.id != model.listedAccountMachines.last?.id { Divider() }
                }
            }
            .transition(.smoothIn(reduceMotion: reduceMotion))
        }
        .animation(.easeOut(duration: 0.22), value: model.accountMachines.isEmpty)
    }

    /// One caption line under a machine's name. The presence light is the
    /// quick read; this carries the detail, and the two never collide.
    private func statusLine(for machine: Machine, isSelf: Bool) -> String {
        if isSelf { return "This device" }
        if !machine.isHost {
            // A phone holds the tunnel only while somebody is using it, so
            // "offline" here means "not in the app right now", not "broken".
            if machine.online == true { return "Phone · in the app now" }
            if let seen = formatRelativeDate(machine.lastSeenAt) { return "Phone · last used \(seen)" }
            return "Phone · signed in on this account"
        }
        if machine.publicIdentity?.isEmpty != false { return "No connection key yet" }
        if machine.online == false {
            if let seen = formatRelativeDate(machine.lastSeenAt) {
                return "Offline · last seen \(seen)"
            }
            return "Offline"
        }
        if model.isConnected(machine) { return "Connected · workspaces in sidebar" }
        if let seen = formatRelativeDate(machine.lastSeenAt) { return "Seen \(seen)" }
        if let sync = formatRelativeDate(machine.lastSyncAt) { return "Last synced \(sync)" }
        return "No sync recorded"
    }

    @ViewBuilder
    private func accountPeerActions(_ peer: Peer, machine: Machine) -> some View {
        switch peer.trust {
        case .pending:
            Button("Approve") { Task { await model.approve(peer) } }
                .buttonStyle(AccentButtonStyle())
        case .approved:
            if model.canConnect(machine) {
                Button("Connect") { Task { await model.connect(peer) } }
                    .buttonStyle(AccentButtonStyle())
                    .help("Connects through the tunnel from anywhere")
            }
            Button("Revoke", role: .destructive) { confirmRevoke = peer }
                .buttonStyle(SecondaryButtonStyle())
                .help("Stops this device from reaching you; workspaces leave the sidebar")
        case .revoked:
            Button("Approve") { Task { await model.approve(peer) } }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    /// What protects a connection, with the keys it actually runs on.
    ///
    /// The paragraph used to sit at the foot of this screen as grey text, which
    /// is where a claim goes to be skipped. It is the product, so it gets a
    /// card, and it carries the fingerprints somebody can compare against the
    /// other machine rather than asking them to take the sentence on trust.
    private var encryptionNote: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    encryptionExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("End to end encrypted")
                            .font(.system(size: DisplayFit.dp(13), weight: .semibold))
                        Text(encryptionExpanded
                            ? "Keys and fingerprints are visible"
                            : "Keys are hidden until you choose to view them")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Theme.Space.s)
                    Image(systemName: encryptionExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(encryptionExpanded
                ? "Hides the encryption keys"
                : "Shows the encryption keys")

            if encryptionExpanded {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("""
                    A connection between two machines carries terminal output, file \
                    contents and diffs. It is encrypted on one machine and \
                    decrypted on the other, with keys that never leave them. The \
                    tunnel relays the encrypted bytes and cannot read them, and \
                    neither can tokenstat. Only aggregate counters are ever \
                    eligible for sync.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if let identity = model.identity {
                        keyLine(
                            title: "This machine",
                            words: identity.words,
                            fingerprint: identity.fingerprint
                        )
                    }
                    ForEach(model.known.filter { $0.trust == .approved }) { peer in
                        keyLine(
                            title: peer.label.isEmpty
                                ? (model.accountName(for: peer) ?? "Approved device")
                                : peer.label,
                            words: peer.words,
                            fingerprint: peer.fingerprint
                        )
                    }

                    Text("Noise XX handshake, X25519 keys, ChaCha20-Poly1305. "
                        + "Two machines showing the same words for each other are talking "
                        + "to each other and to nothing in between.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private func keyLine(title: String, words: String?, fingerprint: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(title)
                .font(.callout)
                .frame(width: 160, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(words ?? fingerprint)
                .font(.callout.weight(.medium))
            Spacer(minLength: Theme.Space.s)
            Text(fingerprint)
                .font(Theme.mono(11))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// The presence light before a machine's name: solid when reachable, blinking
/// while its state is not confirmed yet, grey when offline.
private struct StatusDot: View {
    /// nil means presence is not known yet (connecting), which is the state
    /// that blinks.
    var online: Bool?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private var ready: Bool { online == true }

    private var color: Color {
        switch online {
        case .some(true): return Theme.success
        case .some(false): return .gray
        case nil: return Theme.warning
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(ready || reduceMotion ? 1 : (pulsing ? 0.3 : 1))
            .onAppear {
                guard !ready, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .accessibilityLabel(accessibilityText)
            .help(helpText)
    }

    private var accessibilityText: String {
        switch online {
        case .some(true): return "Online"
        case .some(false): return "Offline"
        case nil: return "Connecting"
        }
    }

    private var helpText: String {
        switch online {
        case .some(true): return "Online"
        case .some(false): return "Offline"
        case nil: return "Presence not confirmed yet"
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
                #if os(macOS)
                .buttonStyle(.link)
                #else
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                #endif
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
    /// The account directory's name for this machine, when the peer itself
    /// was never named. Shown in place of "Unnamed device".
    var resolvedName: String?
    /// SF Symbol: phone for iOS clients, desktop otherwise.
    var symbol: String = "desktopcomputer"
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Text(peer.label.isEmpty ? (resolvedName ?? "Unnamed device") : peer.label)
                        .font(.callout.weight(.medium))
                    TrustBadge(trust: peer.trust)
                }
                // The words rather than the key or the fingerprint: this line
                // exists to be compared with another screen by a person, and
                // that is the form they will read whole. They derive from a
                // public key, so there is nothing to hide.
                Text(peer.words ?? "Approved device")
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
                    prompt: Text("Paste the code from the other device")
                )
                .font(Theme.mono(11))
                TextField("Name", text: $label, prompt: Text("What you call that device (optional)"))

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
                    .buttonStyle(AccentButtonStyle())
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
