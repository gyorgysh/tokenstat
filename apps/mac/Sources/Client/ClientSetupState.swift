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
