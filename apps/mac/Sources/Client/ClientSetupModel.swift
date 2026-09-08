// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Observation
import SwiftUI

#if !os(macOS)

/// Setting up a machine from a phone, one step at a time.
///
/// This is the provisioning plane, and it has one rule: **it may install and
/// enroll, and it may not do work.** Cloning a folder, installing an agent and
/// opening a terminal all happen afterwards, over the tunnel, through the same
/// methods every other machine uses. The moment the server is a peer, this
/// model is finished and hands over.
///
/// Nothing here is a second copy of anything. The saved servers, the keys and
/// the vault are `SSHLibraryModel`'s, the install line is composed by the host
/// so every surface shows the same one, and the check is the host's verdict
/// rather than this screen's reading of raw facts.
@MainActor
@Observable
final class ClientSetupModel {
    // MARK: - Door 2, the six steps

    /// Where. A draft record, saved to the library only once it is trusted:
    /// a half-typed address is not a server somebody owns.
    var host = SSHHost(
        id: "", label: "", hostname: "", port: 22, username: "root",
        initialDirectory: "~", credentialID: nil, jumpHostID: nil,
        tags: [], provider: nil, hostKeys: []
    )
    /// A saved server picked instead of typing one.
    var pickedHostID: String?
    /// How to sign in. Resolved into an auth payload once, here, because the
    /// private key lives in this device's vault and nowhere else.
    var credential: SetupCredential = .none
    /// Typed once, used once, never stored. See `SetupCredential.password`.
    var password = ""

    var fingerprint: String?
    var trusted = false

    var check: ServerCheck?
    /// What this machine will be called on the account.
    var machineName = ""
    var agents: [String] = ["claude_code"]
    var printInvite = false

    var line: InstallLine?
    var terminal: SSHLiveTerminal?
    /// The machine's own answer, once it is a peer. The wizard's last step
    /// reads this rather than believing what scrolled past in the terminal.
    var finished: ProvisionStatus?
    var expectedPeer: String?
    var manualInstall = false
    var manualMachineKey = ""

    var canCheckMachine: Bool {
        !manualInstall || expectedPeer != nil || ClientSetupIdentity.normalize(manualMachineKey) != nil
    }

    private let coordinator = ClientSetupCoordinator()
    var working: Bool { coordinator.working }
    var error: String? {
        get { coordinator.error }
        set { coordinator.error = newValue }
    }
    var savedDraft: ClientSetupDraft? { coordinator.savedDraft }
    private(set) var prepared = false
    private(set) var resumingInstallation = false
    @ObservationIgnored private var scope: ClientSetupScope?
    @ObservationIgnored private var draftID = UUID()

    /// This device's public key, which is what `--allow` grants.
    private(set) var myKey: String?

    // MARK: - Loading

    func prepare(library: SSHLibraryModel) async {
        prepared = false
        do {
            let key = try await Bridge.machineIdentity().key
            let account = try await Bridge.account()
            if !library.loaded { await library.load() }
            try Task.checkCancellation()
            guard account.signedIn, let handle = account.handle, !handle.isEmpty else {
                throw BridgeError.core(code: "signed_out", message: "Sign in before setting up a machine.")
            }
            myKey = key
            let scope = ClientSetupScope(origin: account.host, account: handle, deviceKey: key)
            self.scope = scope
            coordinator.load(scope: scope)
            if machineName.isEmpty { machineName = "server" }
            prepared = true
        } catch {
            guard !Task.isCancelled else { return }
            self.error = Self.readable(error)
        }
    }

    /// True when this is a different account and everything held for the old
    /// one has been dropped. One account can never see another's draft, and a
    /// password typed for one server never survives the switch.
    @discardableResult
    func accountChanged(_ account: Account?) -> Bool {
        guard prepared, let scope else { return false }
        if let account, account.signedIn,
           account.host == scope.origin, account.handle == scope.account { return false }
        coordinator.clearAccount()
        self.scope = nil
        prepared = false
        password = ""
        credential = .none
        expectedPeer = nil
        finished = nil
        resetServer()
        return true
    }

    /// Start a different draft without changing anything on a remote server.
    func startNewSetup() -> Bool {
        guard prepared else { return false }
        do { try coordinator.discard() }
        catch { self.error = Self.readable(error); return false }
        resetServer()
        draftID = UUID()
        pickedHostID = nil
        password = ""
        credential = .none
        return true
    }

    func resume(library: SSHLibraryModel) -> SetupStep? {
        guard let draft = savedDraft else { return nil }
        if !draft.manualInstall {
            guard let saved = library.hosts.first(where: { $0.id == draft.hostID }),
                  let pin = draft.fingerprint, saved.hostKeys.contains(pin) else {
                error = "The saved server or its trusted fingerprint changed. Start a new setup and verify it again."
                return nil
            }
            host = saved
            pickedHostID = saved.id
            fingerprint = pin
            trusted = true
            if let id = saved.credentialID, library.keys.contains(where: { $0.id == id }) {
                credential = .key(id)
            } else { credential = .none }
        }
        draftID = draft.id
        machineName = draft.machineName
        agents = draft.agents
        manualInstall = draft.manualInstall
        expectedPeer = draft.machineKey
        manualMachineKey = draft.machineKey ?? ""
        resumingInstallation = draft.milestone.needsReconciliation
        if resumingInstallation, expectedPeer != nil || manualInstall { return .finish }
        return .credential
    }

    func checkpoint(_ milestone: ClientSetupMilestone) throws {
        guard let scope else { throw ClientSetupDraftError.invalid }
        try coordinator.save(ClientSetupDraft(
            id: draftID, scope: scope, hostID: pickedHostID, fingerprint: fingerprint,
            machineName: machineName, agents: agents, manualInstall: manualInstall,
            machineKey: expectedPeer, milestone: milestone
        ))
        resumingInstallation = milestone.needsReconciliation
    }

    func prepareManualInstall() throws {
        manualInstall = true
        expectedPeer = nil
        try checkpoint(.installRequested)
    }

    func completeSetup() -> Bool {
        do { try coordinator.discard(); return true }
        catch { self.error = Self.readable(error); return false }
    }

    /// The host record as it stands, whether picked or typed.
    func resolvedHost(library: SSHLibraryModel) -> SSHHost {
        if let pickedHostID, let saved = library.hosts.first(where: { $0.id == pickedHostID }) {
            return saved
        }
        return host
    }

    /// One auth payload, built once and used by every step.
    ///
    /// Built on this device because only this device can open the vault. A
    /// password is used for the connection and never written anywhere: that is
    /// what "used once and not stored" means, and it is the whole difference
    /// between this and saving a credential.
    func authPayload(library: SSHLibraryModel) throws -> [String: Any] {
        switch credential {
        case .none:
            throw BridgeError.core(
                code: "no_credential",
                message: "Choose how to sign in to this server."
            )
        case .password:
            guard !password.isEmpty else {
                throw BridgeError.core(
                    code: "no_credential",
                    message: "Enter the password for this server."
                )
            }
            return ["kind": "password", "password": password]
        case let .key(id):
            guard let key = library.keys.first(where: { $0.id == id }) else {
                throw BridgeError.core(
                    code: "no_credential",
                    message: "That key is no longer in your vault."
                )
            }
            if key.secretRef.hasPrefix("agent:") {
                return [
                    "kind": "agent",
                    "fingerprint": String(key.secretRef.dropFirst("agent:".count)),
                ]
            }
            return [
                "kind": "privateKey",
                "pem": try SSHSecretStore.load(reference: key.secretRef),
                "passphrase": nil as Any? as Any,
            ]
        }
    }

    /// Re-entering the address step invalidates every result tied to it.
    func resetServer() {
        cancelWork()
        fingerprint = nil
        trusted = false
        check = nil
        finished = nil
        expectedPeer = nil
        manualInstall = false
        resumingInstallation = false
        manualMachineKey = ""
        line = nil
        terminal?.stop()
        terminal = nil
        error = nil
    }

    /// Offer a distinct name when this account already has a server with it.
    func chooseAvailableMachineName() async throws {
        let account = try await Bridge.account()
        try Task.checkCancellation()
        guard account.signedIn, account.host == scope?.origin, account.handle == scope?.account else {
            throw BridgeError.core(code: "account_changed", message: "Your account changed. Close setup and open it again.")
        }
        let labels = Set(account.machines.compactMap(\.label))
        let base = machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = base.isEmpty ? "server" : base
        var candidate = stem
        var suffix = 2
        while labels.contains(candidate) {
            candidate = "\(stem.prefix(54))-\(suffix)"
            suffix += 1
        }
        machineName = candidate
    }

    // MARK: - Steps

    /// Ask the server for its host key, before any credential is offered.
    ///
    /// The one screen in this wizard where a mistake is permanent, which is
    /// why it is a step of its own rather than a line in another one.
    func probe(library: SSHLibraryModel) async {
        fingerprint = nil
        trusted = false
        check = nil
        await run {
            var host = self.resolvedHost(library: library)
            host.hostKeys = []
            let fingerprint = try await Bridge.probeSSHHost(host).fingerprint
            try Task.checkCancellation()
            self.fingerprint = fingerprint
        }
    }

    /// Keep the fingerprint, and the server with it.
    ///
    /// This is where a typed address becomes a saved one: trusting a host key
    /// is the moment somebody says this server is theirs.
    func trust(library: SSHLibraryModel) async {
        guard let fingerprint else { return }
        await run {
            var host = self.resolvedHost(library: library)
            host.hostKeys = [fingerprint]
            guard let saved = await library.save(host: host) else {
                throw BridgeError.core(
                    code: "not_saved",
                    message: library.error ?? "The fingerprint could not be saved."
                )
            }
            try Task.checkCancellation()
            self.pickedHostID = saved.id
            self.host = saved
            self.trusted = true
            try self.checkpoint(.trusted)
        }
    }

    func inspect(library: SSHLibraryModel) async {
        await run {
            let host = self.resolvedHost(library: library)
            let auth = try self.authPayload(library: library)
            let check = try await Bridge.probeServerForSetup(host, auth: auth)
            try Task.checkCancellation()
            self.check = check
            try self.checkpoint(.checked)
            if self.machineName == "server", let distro = check.distro {
                // A name somebody would recognise, offered rather than imposed.
                self.machineName = distro.split(separator: " ").first.map(String.init)?
                    .lowercased() ?? "server"
            }
        }
    }

    /// Mint a code, put it on the server as a private file, and type the line.
    ///
    /// The code never reaches the command line: there it would land in the
    /// shell history and, briefly, in `/proc`. It goes down its own channel
    /// into a `0600` file, and the line the person watches names that file.
    func install(library: SSHLibraryModel) async {
        await run {
            let host = self.resolvedHost(library: library)
            let auth = try self.authPayload(library: library)
            guard let myKey = self.myKey else {
                throw BridgeError.core(code: "identity_unavailable",
                    message: "This device’s identity could not be loaded. Close setup and try again.")
            }
            try await self.chooseAvailableMachineName()
            try Task.checkCancellation()
            // Save before starting any remote mutation. Resume checks what
            // happened; it never assumes an interrupted install should rerun.
            try self.checkpoint(.installRequested)
            let code = try await Bridge.mintPairingCode().code
            try Task.checkCancellation()
            try await Bridge.stagePairingCode(host, code: code, auth: auth)
            do {
                try Task.checkCancellation()
                let line = try await Bridge.installLine(
                    allow: myKey,
                    name: self.machineName,
                    agents: self.agents,
                    printInvite: self.printInvite,
                    codeFile: true
                )
                try Task.checkCancellation()
                self.line = line
                let handle = try await Bridge.openSSHWithResolvedAuth(
                    host, auth: auth, rows: 24, cols: 100
                )
                let terminal = SSHLiveTerminal(handle: handle, title: host.label, hostID: host.id)
                guard !Task.isCancelled else { terminal.stop(); throw CancellationError() }
                self.terminal = terminal
                // A moment for the shell to draw its prompt. Typing into a shell
                // that has not started echoing yet loses the first characters.
                try await Task.sleep(for: .milliseconds(700))
                try Task.checkCancellation()
                terminal.sendBytes(Array((line.oneLine + "\n").utf8))
            } catch {
                self.terminal?.stop()
                self.terminal = nil
                try? await Bridge.clearPairingCode(host, auth: auth)
                throw error
            }
        }
    }

    /// Ask the machine itself whether it is set up, over the tunnel it now has.
    ///
    /// Polled rather than assumed: the installer's output scrolling past is
    /// not the same as a machine that answers.
    func waitForMachine(library: SSHLibraryModel, account: AccountModel) async {
        await run {
            if self.expectedPeer == nil {
                if self.manualInstall {
                    guard let key = ClientSetupIdentity.normalize(self.manualMachineKey) else {
                        throw BridgeError.core(code: "identity_required",
                            message: "Paste the full machine key printed by the installer.")
                    }
                    self.expectedPeer = key
                } else {
                    let host = self.resolvedHost(library: library)
                    let auth = try self.authPayload(library: library)
                    let key = try await Bridge.setupServerIdentity(host, auth: auth)
                    try Task.checkCancellation()
                    self.expectedPeer = key
                }
            }
            guard let peer = self.expectedPeer else { return }
            try self.checkpoint(.verifying)
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                try Task.checkCancellation()
                // Use a fresh response, not AccountModel's retained offline snapshot.
                let fresh = try await Bridge.account()
                try Task.checkCancellation()
                guard fresh.signedIn, fresh.host == self.scope?.origin, fresh.handle == self.scope?.account else {
                    throw BridgeError.core(code: "account_changed", message: "Your account changed. Close setup and open it again.")
                }
                if fresh.machines.contains(where: {
                    $0.isHost && ClientSetupIdentity.matches($0.publicIdentity ?? "", expected: peer)
                }) {
                    guard try await Bridge.workspaceAccessAllowed(peer: peer) else {
                        throw BridgeError.core(code: "access_required",
                            message: "This machine is on your account, but this device is not allowed yet. Use Add this device in Machines.")
                    }
                    let status = try await Bridge.provisionStatus(peer: peer)
                    try Task.checkCancellation()
                    guard ClientSetupIdentity.matches(status.machineKey, expected: peer) else {
                        throw BridgeError.core(code: "identity_mismatch",
                            message: "The machine answered with a different identity. Reconnect and verify the server.")
                    }
                    try self.checkpoint(.hostReady)
                    self.finished = status
                    await account.load()
                    return
                }
                try await Task.sleep(for: .seconds(3))
            }
            throw BridgeError.core(code: "setup_pending",
                message: "This machine has not appeared on your account yet. Check that the install finished, then try again.")
        }
    }

    func cancelWork() { coordinator.cancel() }

    /// A message about this machine, rather than about the protocol.
    ///
    /// The helper this app talks to is replaced whenever the app is, so an
    /// `unknown method` here means a development build against an older
    /// library. Saying so beats repeating a method name at somebody, which is
    /// the rule the whole feature gate exists for.
    static func readable(_ error: Error) -> String {
        let message = error.localizedDescription
        let lower = message.lowercased()
        if lower.contains("unknown method") {
            return "This app is running against an older helper, which does not know how to "
                + "do that yet. Reinstall tokenstat and try again."
        }
        if lower.contains("not logged in") {
            // The wizard is behind the sign-in, so this is only reachable when
            // a token was revoked mid-flow. Telling a phone to run a CLI
            // command, which is what the shared message says, is not an answer
            // anybody holding a phone can act on.
            return "This phone is signed out. Sign in again, then set the machine up."
        }
        return message
    }

    private func run(_ body: @escaping () async throws -> Void) async {
        await coordinator.run {
            do { try await body() }
            catch is CancellationError { throw CancellationError() }
            catch { throw BridgeError.core(code: "setup_failed", message: Self.readable(error)) }
        }
    }
}

/// How this wizard will sign in to the server it is setting up.
enum SetupCredential: Equatable {
    case none
    /// A key already in the vault, on every device that shares the account.
    case key(String)
    /// Typed once, used for this connection, and never written down.
    case password
}

#endif
