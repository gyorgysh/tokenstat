// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Public identity, not a mutable display name, binds provisioning to a peer.
enum ClientSetupIdentity {
    static func normalize(_ key: String) -> String? {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return nil }
        return value.lowercased()
    }

    static func matches(_ actual: String, expected: String) -> Bool {
        guard let actual = normalize(actual), let expected = normalize(expected) else { return false }
        return actual == expected
    }
}

/// The service origin and account handle are both required. A renamed account
/// starts a fresh draft rather than guessing ownership. The device key also
/// prevents a restored app backup from adopting another device's progress.
struct ClientSetupScope: Codable, Equatable {
    var origin: String
    var account: String
    var deviceKey: String

    /// Whose setup this is. The handle when the account has claimed one, else
    /// the server's own id for it. A new account has no handle, and it still
    /// gets setup. An empty answer means the draft goes unpersisted. The
    /// store is keyed by scope, and one account must never resume another's.
    static func accountIdentity(handle: String?, id: String?) -> String {
        if let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty {
            return handle
        }
        if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        return ""
    }
}

enum ClientSetupMilestone: String, Codable {
    case trusted, checked, installRequested, verifying, hostReady

    var needsReconciliation: Bool {
        switch self {
        case .trusted, .checked: false
        case .installRequested, .verifying, .hostReady: true
        }
    }

    /// What happened, in the words somebody would use about their own server.
    /// The installing states say what setup will do next, because the honest
    /// answer after an interruption is that nobody knows how far it got.
    var summary: String {
        switch self {
        case .trusted:
            "Its fingerprint is verified. Setup carries on from your sign-in details."
        case .checked:
            "It is checked and ready to install."
        case .installRequested:
            "The installer was started. Setup asks the server what actually happened before it does anything again."
        case .verifying:
            "The server is installed. Setup is waiting for it to reach your account."
        case .hostReady:
            "The server answered. One last check finishes this."
        }
    }
}

struct ClientSetupDraft: Codable, Equatable {
    static let currentVersion = 1
    var version = currentVersion
    var id = UUID()
    var scope: ClientSetupScope
    var hostID: String?
    var fingerprint: String?
    var machineName: String
    var agents: [String]
    var manualInstall: Bool
    var machineKey: String?
    var milestone: ClientSetupMilestone
    var updatedAt = Date()

    func validate() throws {
        guard version == Self.currentVersion else { throw ClientSetupDraftError.unsupportedVersion }
        guard !scope.origin.isEmpty, !scope.account.isEmpty,
              ClientSetupIdentity.normalize(scope.deviceKey) != nil,
              machineName.utf8.count <= 256, agents.count <= 32,
              agents.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 })
        else { throw ClientSetupDraftError.invalid }
        if let machineKey, ClientSetupIdentity.normalize(machineKey) == nil {
            throw ClientSetupDraftError.invalid
        }
        if !manualInstall, hostID?.isEmpty != false || fingerprint?.isEmpty != false {
            throw ClientSetupDraftError.invalid
        }
        if milestone == .hostReady, machineKey == nil { throw ClientSetupDraftError.invalid }
    }
}

enum ClientSetupDraftError: Error, LocalizedError {
    case invalid, unsupportedVersion
    var errorDescription: String? {
        switch self {
        case .invalid: "Saved setup is incomplete or belongs to another account."
        case .unsupportedVersion: "Saved setup was created by a different version of tokenstat."
        }
    }
}

/// A failure somebody can act on, rather than a sentence they can only read.
///
/// Three things, every time: what failed, what changed if anything, and one
/// concrete next action. The action is chosen from the host's error code, never
/// from the words in the message: those are free to be reworded and one day
/// translated, and a screen that branches on English breaks silently when
/// either happens.
///
/// The raw message is kept beside the explanation rather than instead of it.
/// Somebody debugging a server wants the transport's own words, and somebody
/// setting one up does not.
struct ClientSetupFailure: Equatable {
    enum Action: Equatable {
        case checkAddress
        case reviewFingerprint
        case checkCredential
        case checkServer
        case newCode
        case signInToAgent
        case signInToAccount
        case updateMachine
        case retry

        var title: String {
            switch self {
            case .checkAddress: "Check the address"
            case .reviewFingerprint: "Review the fingerprint"
            case .checkCredential: "Check the credential"
            case .checkServer: "Check the server"
            case .newCode: "Get a new code"
            case .signInToAgent: "Sign in"
            case .signInToAccount: "Sign in"
            case .updateMachine: "How to update"
            case .retry: "Try again"
            }
        }

        /// Where this action goes inside the wizard, when it is a place.
        ///
        /// A failure whose answer is a screen navigates to it. The two that
        /// are not a place at all, signing in to the account and updating the
        /// machine, both happen outside this wizard, and a button that cannot
        /// take somebody there would be a button that does nothing.
        var destination: SetupStep? {
            switch self {
            case .checkAddress: .where
            case .reviewFingerprint: .where
            case .checkCredential: .credential
            case .checkServer: .finish
            case .newCode: .install
            case .signInToAgent: .project
            case .signInToAccount, .updateMachine, .retry: nil
            }
        }

        /// Whether a button for this is worth drawing.
        ///
        /// `.retry` is not: every screen's own primary button already is the
        /// retry, and a second one beside it would be the same action twice.
        /// The two that happen elsewhere say so in words instead.
        var isActionable: Bool {
            switch self {
            case .signInToAccount, .updateMachine, .retry: false
            default: true
            }
        }

        var icon: ActionIcon {
            switch self {
            case .checkAddress, .checkServer: .search
            case .reviewFingerprint: .security
            case .checkCredential: .token
            case .newCode: .pair
            case .signInToAgent, .signInToAccount: .signIn
            case .updateMachine: .docs
            case .retry: .refresh
            }
        }
    }

    var explanation: String
    /// What happened to the server, when anything did. Silence here means
    /// nothing on it was touched, which is the answer people want first.
    var changed: String?
    var action: Action
    /// The words the machine used, kept for somebody who wants them.
    var details: String?

    /// Read a failure from whatever was thrown.
    ///
    /// Codes come from `tokenstat-host::error`. Anything unrecognised keeps
    /// its own message and offers a retry, which is honest: an unknown failure
    /// is not evidence that nothing can be done.
    static func from(_ error: Error) -> ClientSetupFailure {
        guard case let BridgeError.core(code, message) = error else {
            return ClientSetupFailure(
                explanation: error.localizedDescription, action: .retry, details: nil
            )
        }
        switch code {
        case "ssh_unreachable":
            return ClientSetupFailure(
                explanation: "We couldn't reach this server. Check its address, and that "
                    + "it is running and accepting connections.",
                action: .checkAddress,
                details: message
            )
        case "ssh_host_key_changed":
            return ClientSetupFailure(
                explanation: "This server's identity has changed since it was trusted. "
                    + "That can be a reinstall, or it can be the wrong machine answering. "
                    + "Verify the fingerprint before connecting again.",
                changed: "Nothing was sent to it.",
                action: .reviewFingerprint,
                details: message
            )
        case "ssh_host_key_unverified":
            return ClientSetupFailure(
                explanation: "This server's fingerprint has not been confirmed yet.",
                action: .reviewFingerprint,
                details: message
            )
        case "ssh_auth_refused":
            return ClientSetupFailure(
                explanation: "The server refused the key or password. Check the credential "
                    + "and the user name you are connecting as.",
                action: .checkCredential,
                details: message
            )
        case "setup_pending":
            return ClientSetupFailure(
                explanation: "This machine has not appeared on your account yet.",
                changed: "The installer may still be running on the server.",
                action: .checkServer,
                details: message
            )
        case "identity_mismatch":
            return ClientSetupFailure(
                explanation: "The machine answered with a different identity than the one "
                    + "this setup installed. Reconnect and verify the server.",
                action: .reviewFingerprint,
                details: message
            )
        case "access_required":
            return ClientSetupFailure(
                explanation: "This machine is on your account, but this device is not "
                    + "allowed on it yet.",
                changed: "The server is installed and signed in.",
                action: .checkServer,
                details: message
            )
        case "pairing_expired", "code_expired":
            return ClientSetupFailure(
                explanation: "This pairing code has expired.",
                action: .newCode,
                details: message
            )
        case "identity_required":
            return ClientSetupFailure(
                explanation: "Paste the full machine key the installer printed, so setup "
                    + "finishes on the machine you installed rather than one with the "
                    + "same name.",
                action: .retry,
                details: message
            )
        case "account_changed", "signed_out", "auth":
            return ClientSetupFailure(
                explanation: "This device is signed out of the account that started this "
                    + "setup. Sign in again, then continue.",
                action: .signInToAccount,
                details: message
            )
        case "unknown_method":
            return ClientSetupFailure(
                explanation: "This machine is running an older tokenstat, which does not "
                    + "know how to finish setup. Update it there to continue.",
                action: .updateMachine,
                details: message
            )
        default:
            // No code this app knows. Two shapes are still worth naming,
            // because both used to arrive as a sentence nobody could act on.
            let lower = message.lowercased()
            if lower.contains("unknown method") {
                return ClientSetupFailure(
                    explanation: "This app is running against an older helper, which does not "
                        + "know how to do that yet. Reinstall tokenstat and try again.",
                    action: .updateMachine,
                    details: message
                )
            }
            if lower.contains("not logged in") {
                // The wizard is behind the sign-in, so this is only reachable
                // when a token was revoked mid-flow. The shared message tells
                // somebody to run a CLI command, which is not an answer a
                // person holding an iPhone or iPad can act on.
                return ClientSetupFailure(
                    explanation: "This device is signed out. Sign in again, then set the "
                        + "machine up.",
                    action: .signInToAccount,
                    details: message
                )
            }
            return ClientSetupFailure(explanation: message, action: .retry, details: nil)
        }
    }
}

/// Wizard destinations, shared with failure recovery on every build target.
///
/// A step per screen rather than one long form, because each of them can fail
/// on its own and each failure has its own thing to say. Trusting a host key
/// in particular is the one place where a mistake is permanent, so it is not a
/// row inside somebody else's screen.
enum SetupStep: Hashable {
    case `where`
    case credential
    case fingerprint
    case check
    case install
    case finish
    /// The project, which is what all of it was for.
    case project
    /// For somebody who has no machine at all yet.
    case needServer
    /// The install line, for somebody who would rather run it themselves.
    case byHand
    /// Door three, which ends by handing over to `where` with the addresses
    /// already known.
    case cloud
    /// Door one, which is a screen that watches rather than one that acts.
    case mac
}
