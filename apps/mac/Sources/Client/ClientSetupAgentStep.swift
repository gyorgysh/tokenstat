// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// Step seven: the agent's own sign-in, which is not the machine's.
///
/// The step everybody used to discover by sending a prompt and reading
/// somebody else's auth error. A server can be installed, paired and reachable
/// and still have no login for the tool that does the work, because that login
/// belongs to an account tokenstat has nothing to do with.
///
/// Two honest halves. The machine says what it can see: a credential store the
/// agent wrote, or nothing, or nothing it can check. Then the sign-in happens
/// in a terminal on that machine, which is where the agent prints the code
/// that has to reach a browser. Nothing about the login comes back here.
struct ClientSetupAgentStep: View {
    @Bindable var model: ClientSetupModel
    @Binding var path: [SetupStep]

    @State private var profiles: [RemoteLaunchProfile] = []
    @State private var loading = true
    @State private var busyID: String?
    @State private var failure: ClientSetupFailure?
    @State private var supported: Bool?
    @State private var session: ClientTerminalSession?
    @State private var loadGeneration = UUID()

    private var peer: String? { model.expectedPeer }

    /// What was chosen during setup, then anything else already installed.
    /// A machine that came with an agent should not hide it.
    private var shown: [RemoteLaunchProfile] {
        let chosen = Set(model.agents)
        return profiles.filter { chosen.contains($0.id) || $0.installed }
    }

    var body: some View {
        StepScaffold(
            title: "Sign in to your agent",
            subtitle: "The machine is yours now. The coding agent signs in to its own "
                + "account, on the machine, once.",
            number: 7,
            failure: failure,
            onDismissError: { failure = nil },
            onRecover: { recover($0, model: model, path: $path) }
        ) {
            if loading {
                HStack(spacing: Theme.Space.s) {
                    ProgressView()
                    Text("Asking the machine what it has.")
                        .font(ClientType.label)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if supported == false {
                StepSection(title: "This machine is older") {
                    Text("Its tokenstat helper cannot report agent sign-in yet. Open the "
                        + "machine, start the agent from the launcher, and sign in there.")
                        .font(ClientType.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if shown.isEmpty {
                StepSection(title: "No agent yet") {
                    Text("No coding agent is installed on this machine. Open it and install "
                        + "one from the launcher, then come back and sign in.")
                        .font(ClientType.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(shown, id: \.id) { profile in
                    AgentCard(
                        profile: profile,
                        busy: busyID == profile.id,
                        anyBusy: busyID != nil,
                        onInstall: { Task { await install(profile) } },
                        onSignIn: { Task { await signIn(profile) } }
                    )
                }
                Text("Signing in opens a terminal on the machine. The agent prints a link "
                    + "and a code: open the link here on this device, enter the code, and "
                    + "the terminal finishes on its own.")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Button("Continue", .next) { path.append(.project) }
                .setupPrimaryStyle()
            Button("Check again", .refresh) { Task { await load() } }
                .disabled(loading || busyID != nil)
        }
        .navigationTitle("Agent")
        .accessibilityIdentifier("setup.agents")
        .task(id: peer) {
            supported = nil
            profiles = []
            await load()
        }
        .onDisappear { loadGeneration = UUID() }
        .fullScreenCover(item: $session) { open in
            ClientTerminalScreen(
                session: open,
                hostName: model.machineName,
                // A finished sign-in changes what the machine reports, so the
                // list is asked again rather than left saying "not signed in"
                // under a terminal that just said otherwise.
                onClosedProcess: { Task { await load() } }
            )
        }
        .onChange(of: session == nil) { _, closed in
            if closed { Task { await load() } }
        }
    }

    private func load() async {
        guard let peer else {
            failure = ClientSetupFailure(
                explanation: "This machine's identity is missing. Close setup and open it again.",
                action: .retry,
                details: nil
            )
            loading = false
            return
        }
        let generation = UUID()
        loadGeneration = generation
        loading = true
        failure = nil
        defer {
            if loadGeneration == generation { loading = false }
        }
        func isCurrent() -> Bool {
            !Task.isCancelled && loadGeneration == generation && self.peer == peer
        }
        // Asked every time, and only a definite answer is remembered. A peer
        // that cannot be reached is not an old peer: this step is entered
        // seconds after a server came up, which is exactly when the tunnel is
        // least settled, and caching that first stumble as "older machine"
        // would leave somebody stuck in front of a host this app just built.
        if supported != true {
            do {
                let version = try await Bridge.peerProtocolVersion(peer)
                guard isCurrent() else { return }
                supported = version >= RemoteHostFeature.agentSignIn.minimumProtocol
            } catch {
                guard isCurrent() else { return }
                failure = ClientSetupFailure.from(error)
                return
            }
        }
        guard supported == true else { return }
        do {
            let loaded = try await ClientRemote.launcherCatalog(peer: peer)
            guard isCurrent() else { return }
            profiles = loaded
        } catch {
            guard isCurrent() else { return }
            failure = ClientSetupFailure.from(error)
        }
    }

    private func install(_ profile: RemoteLaunchProfile) async {
        guard let peer, busyID == nil else { return }
        busyID = profile.id
        defer { busyID = nil }
        failure = nil
        do {
            _ = try await ClientRemote.launcherInstall(peer: peer, id: profile.id)
            profiles = try await ClientRemote.launcherCatalog(peer: peer)
        } catch { failure = ClientSetupFailure.from(error) }
    }

    private func signIn(_ profile: RemoteLaunchProfile) async {
        guard let peer, busyID == nil else { return }
        busyID = profile.id
        defer { busyID = nil }
        failure = nil
        let dark = UITraitCollection.current.userInterfaceStyle == .dark
        let pending = ClientTerminalSession(
            peer: peer,
            pendingCommand: profile.command,
            cwd: "",
            rows: 40,
            cols: 100
        )
        session = pending
        do {
            let info = try await ClientRemote.launcherSignIn(
                peer: peer, id: profile.id, rows: 40, cols: 100, dark: dark
            )
            pending.attach(info: info)
        } catch {
            pending.stop()
            session = nil
            failure = ClientSetupFailure.from(error)
        }
    }
}

/// One agent, what the machine can say about it, and the one thing to do next.
private struct AgentCard: View {
    let profile: RemoteLaunchProfile
    let busy: Bool
    let anyBusy: Bool
    var onInstall: () -> Void
    var onSignIn: () -> Void

    private var state: AgentReadiness {
        profile.installed ? (profile.readiness ?? .unknown) : .notInstalled
    }

    private var canSignIn: Bool { profile.installed && profile.signIn?.supported == true }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                HarnessMark(id: profile.id, size: 38).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(ClientType.body.weight(.medium))
                    Text(detail)
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.s)
                StatePill(state: state)
            }
            if busy {
                ProgressView().controlSize(.small)
            } else if state == .notInstalled {
                if profile.installCommand != nil {
                    Button("Install", .download, action: onInstall)
                        .buttonStyle(.bordered)
                        .disabled(anyBusy)
                        .accessibilityIdentifier("setup.agent.install.\(profile.id)")
                } else {
                    Text("This one has no installer we have checked on this machine.")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
            } else if canSignIn {
                Button(state == .signedIn ? "Sign in again" : "Sign in", .signIn, action: onSignIn)
                    .buttonStyle(.bordered)
                    .disabled(anyBusy)
                    .accessibilityIdentifier("setup.agent.signIn.\(profile.id)")
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// Says what happens next, in the words of the thing about to happen.
    private var detail: String {
        switch state {
        case .notInstalled:
            "Not on this machine yet."
        case .needsSignIn:
            profile.signIn?.kind == "deviceCode"
                ? "It will show a code to enter on a page in your browser."
                : "It will show a link, then ask for a code from your browser."
        case .signedIn:
            expiry.map { "Signed in on the machine. Expires \($0)." }
                ?? "Signed in on the machine."
        case .expired:
            "Its stored sign-in has expired. Signing in again fixes it."
        case .unknown:
            "This machine keeps this agent's login somewhere it cannot check. "
                + "Sign in if the agent refuses to work."
        }
    }

    /// The agent's own expiry, when it states one. Relative, because "in 27
    /// days" is what somebody needs and a date is what they would have to
    /// subtract today from.
    private var expiry: String? {
        guard let milliseconds = profile.expiresAt, milliseconds > 0 else { return nil }
        let when = Date(timeIntervalSince1970: milliseconds / 1000)
        return when.formatted(.relative(presentation: .named))
    }
}

/// The verdict, as a word rather than a colour alone.
private struct StatePill: View {
    let state: AgentReadiness

    var body: some View {
        Text(state.summary)
            .font(ClientType.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private var tint: Color {
        switch state {
        case .signedIn: Theme.success
        case .expired, .needsSignIn: Theme.warning
        case .notInstalled, .unknown: Color.secondary
        }
    }
}

#endif
