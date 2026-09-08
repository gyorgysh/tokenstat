// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientSetupState.swift. No account, network or credentials used.
//
// The two stubs below stand in for `ActionIcon` and `BridgeError`, which live
// in files that pull in the whole app. They mirror only what this file uses.
import Foundation

enum ActionIcon {
    case search, security, token, pair, signIn, docs, refresh
}

/// The wizard's steps, as far as `ClientSetupFailure.Action` names them.
enum SetupStep: Hashable {
    case `where`, credential, fingerprint, check, install, finish, agents, project
    case byHand, cloud, mac, needServer
}

enum BridgeError: LocalizedError {
    case core(code: String, message: String)
    case decoding(method: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case let .core(_, message): message
        case let .decoding(method, underlying): "Could not read the response to \(method): \(underlying)"
        }
    }
}

@main
struct ClientSetupStateTests {
    static func main() throws {
        identities()
        drafts()
        failures()
        print("ClientSetupStateTests passed")
    }

    static func identities() {
        let a = String(repeating: "ab", count: 32)
        let b = String(repeating: "cd", count: 32)
        precondition(ClientSetupIdentity.normalize(" \(a.uppercased())\n") == a)
        precondition(ClientSetupIdentity.matches(a.uppercased(), expected: a))
        precondition(!ClientSetupIdentity.matches(b, expected: a), "A different host cannot satisfy setup")
        for bad in ["", "server", String(a.dropLast()), String(repeating: "z", count: 64)] {
            precondition(ClientSetupIdentity.normalize(bad) == nil)
            precondition(!ClientSetupIdentity.matches(bad, expected: bad))
        }
    }

    static func scope(account: String = "someone") -> ClientSetupScope {
        ClientSetupScope(
            origin: "https://example.invalid",
            account: account,
            deviceKey: String(repeating: "ab", count: 32)
        )
    }

    static func draft(
        account: String = "someone",
        manual: Bool = false,
        machineKey: String? = nil,
        milestone: ClientSetupMilestone = .trusted
    ) -> ClientSetupDraft {
        ClientSetupDraft(
            scope: scope(account: account),
            hostID: manual ? nil : "host-1",
            fingerprint: manual ? nil : "SHA256:aaaa",
            machineName: "server",
            agents: ["claude_code"],
            manualInstall: manual,
            machineKey: machineKey,
            milestone: milestone
        )
    }

    static func drafts() {
        // A draft that names its server is valid; one that claims an SSH
        // install with no host or fingerprint is not, because resuming it
        // would have nothing to reconnect to.
        try! draft().validate()
        try! draft(manual: true).validate()
        var headless = draft()
        headless.hostID = nil
        precondition(rejects(headless), "An SSH draft needs the host it trusted")
        headless = draft()
        headless.fingerprint = ""
        precondition(rejects(headless), "An SSH draft needs the fingerprint it verified")

        // A finished machine is identified by its key. Without one there is
        // nothing to tell two servers with the same label apart.
        precondition(rejects(draft(milestone: .hostReady)))
        try! draft(machineKey: String(repeating: "cd", count: 32), milestone: .hostReady).validate()

        var wrongKey = draft()
        wrongKey.machineKey = "not-a-key"
        precondition(rejects(wrongKey))

        var noAccount = draft()
        noAccount.scope.account = ""
        precondition(rejects(noAccount), "A draft with no account belongs to nobody")

        var badDevice = draft()
        badDevice.scope.deviceKey = "short"
        precondition(rejects(badDevice), "A restored backup cannot adopt another device's setup")

        var future = draft()
        future.version = ClientSetupDraft.currentVersion + 1
        precondition(rejects(future), "A newer schema offers a fresh start, never a guess")

        // One account's draft is never another's.
        precondition(scope() != scope(account: "somebody-else"))

        // Only the installing states need reconciling. Resuming a verified
        // fingerprint must not go looking at the server.
        precondition(!ClientSetupMilestone.trusted.needsReconciliation)
        precondition(!ClientSetupMilestone.checked.needsReconciliation)
        for state in [ClientSetupMilestone.installRequested, .verifying, .hostReady] {
            precondition(state.needsReconciliation)
            precondition(!state.summary.isEmpty)
        }
    }

    static func rejects(_ draft: ClientSetupDraft) -> Bool {
        do { try draft.validate(); return false } catch { return true }
    }

    static func failures() {
        // The action comes from the code, never from the words. Rewording any
        // of these messages must not change where somebody is sent.
        let cases: [(String, ClientSetupFailure.Action)] = [
            ("ssh_unreachable", .checkAddress),
            ("ssh_host_key_changed", .reviewFingerprint),
            ("ssh_host_key_unverified", .reviewFingerprint),
            ("ssh_auth_refused", .checkCredential),
            ("setup_pending", .checkServer),
            ("access_required", .checkServer),
            ("identity_mismatch", .reviewFingerprint),
            ("pairing_expired", .newCode),
            ("account_changed", .signInToAccount),
            ("unknown_method", .updateMachine),
        ]
        for (code, expected) in cases {
            let failure = ClientSetupFailure.from(
                BridgeError.core(code: code, message: "whatever the machine said")
            )
            precondition(failure.action == expected, "\(code) must offer \(expected.title)")
            precondition(!failure.explanation.isEmpty)
            precondition(!failure.explanation.contains("whatever"), "\(code) explains itself")
            precondition(failure.details == "whatever the machine said", "\(code) keeps the detail")
        }

        // A connection that never happened changed nothing, and saying so is
        // the difference between trying again and being afraid to.
        let changed = ClientSetupFailure.from(
            BridgeError.core(code: "ssh_host_key_changed", message: "refused")
        )
        precondition(changed.changed?.isEmpty == false)

        // An unrecognised code keeps its own message and offers a retry.
        let unknown = ClientSetupFailure.from(
            BridgeError.core(code: "something_new", message: "the machine said this")
        )
        precondition(unknown.action == .retry)
        precondition(unknown.explanation == "the machine said this")

        // The two old text-matched cases still land somewhere useful.
        let older = ClientSetupFailure.from(
            BridgeError.core(code: "call_failed", message: "unknown method: host.identity")
        )
        precondition(older.action == .updateMachine)
        let signedOut = ClientSetupFailure.from(
            BridgeError.core(code: "call_failed", message: "not logged in: run tokenstat login")
        )
        precondition(signedOut.action == .signInToAccount)
        precondition(!signedOut.explanation.contains("tokenstat login"), "No CLI advice on a hand-held device")

        // Anything that is not a bridge failure still says something.
        struct Plain: Error {}
        precondition(ClientSetupFailure.from(Plain()).action == .retry)

        // A drawn button has to lead somewhere. The three that lead nowhere
        // are the three that happen outside the wizard, or are the screen's
        // own primary button repeated.
        for action: ClientSetupFailure.Action in [
            .checkAddress, .reviewFingerprint, .checkCredential,
            .checkServer, .newCode, .signInToAgent,
        ] {
            precondition(action.isActionable, "\(action.title) is offered")
            precondition(action.destination != nil, "\(action.title) must go somewhere")
        }
        for action: ClientSetupFailure.Action in [.signInToAccount, .updateMachine, .retry] {
            precondition(!action.isActionable, "\(action.title) must not draw a dead button")
        }
        for action: ClientSetupFailure.Action in [.signInToAccount, .updateMachine, .retry] {
            precondition(action.destination == nil)
        }
    }
}
