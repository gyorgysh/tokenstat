// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

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

struct ClientSetupScope: Codable, Equatable {
    var origin: String
    var account: String
    var deviceKey: String

    static func accountIdentity(handle: String?, id: String?) -> String {
        WorkReference.Scope.accountIdentity(handle: handle, id: id) ?? ""
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

    var summary: String {
        switch self {
        case .trusted:
            L10n.text("apple.clientsetupstate.its_fingerprint_is_verified_setup_carries.85d90f26")
        case .checked:
            L10n.text("apple.clientsetupstate.it_is_checked_and_ready_to_install.8f2e0902")
        case .installRequested:
            L10n.text("apple.clientsetupstate.the_installer_was_started_setup_asks_the_s.2ca3a719")
        case .verifying:
            L10n.text("apple.clientsetupstate.the_server_is_installed_setup_is_waiting_f.fe7267cd")
        case .hostReady:
            L10n.text("apple.clientsetupstate.the_server_answered_one_last_check_finishe.a9101f9b")
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
        case .invalid: L10n.text("apple.clientsetupstate.saved_setup_is_incomplete_or_belongs_to_an.5a0fc6b6")
        case .unsupportedVersion: L10n.text("apple.clientsetupstate.saved_setup_was_created_by_a_different_ver.d909f4bf")
        }
    }
}

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
            case .checkAddress: L10n.text("apple.clientsetupstate.check_the_address.b092b174")
            case .reviewFingerprint: L10n.text("apple.clientsetupstate.review_the_fingerprint.377df466")
            case .checkCredential: L10n.text("apple.clientsetupstate.check_the_credential.5f42f1c7")
            case .checkServer: L10n.text("apple.clientsetupstate.check_the_server.eb259223")
            case .newCode: L10n.text("apple.clientsetupstate.get_a_new_code.42cc251c")
            case .signInToAgent: L10n.text("common.sign_in")
            case .signInToAccount: L10n.text("common.sign_in")
            case .updateMachine: L10n.text("apple.clientsetupstate.how_to_update.d97d76cb")
            case .retry: L10n.text("apple.clientsetupstate.try_again.d8b8392e")
            }
        }

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
    var changed: String?
    var action: Action
    var details: String?

    static func from(_ error: Error) -> ClientSetupFailure {
        guard case let BridgeError.core(code, message) = error else {
            return ClientSetupFailure(
                explanation: error.localizedDescription, action: .retry, details: nil
            )
        }
        switch code {
        case "ssh_unreachable":
            return ClientSetupFailure(
                explanation: L10n.text("apple.clientsetupstate.we_couldn_t_reach_this_server_check_its_ad.13dd9877"),
                action: .checkAddress,
                details: message
            )
        case "ssh_host_key_changed":
            return ClientSetupFailure(
                explanation: L10n.text("apple.clientsetupstate.this_server_s_identity_has_changed_since_i.e7f60705"),
                changed: L10n.text("apple.clientsetupstate.nothing_was_sent_to_it.80689dc8"),
                action: .reviewFingerprint,
                details: message
            )
        case "ssh_host_key_unverified":
            return ClientSetupFailure(
                explanation: L10n.text("apple.clientsetupstate.this_server_s_fingerprint_has_not_been_con.98cbb3d1"),
                action: .reviewFingerprint,
                details: message
            )
        case "ssh_auth_refused":
            return ClientSetupFailure(
                explanation: L10n.text("apple.clientsetupstate.the_server_refused_the_key_or_password_che.7f44f231"),
                action: .checkCredential,
                details: message
            )
        case "setup_pending":
            return ClientSetupFailure(
                explanation: L10n.text("apple.clientsetupstate.this_machine_has_not_appeared_on_your_acco.54a9c2b8"),
                changed: L10n.text("apple.clientsetupstate.the_installer_may_still_be_running_on_the.9ccd1cf6"),
                action: .checkServer,
                details: message
            )
        case "identity_mismatch":
            return ClientSetupFailure(
                explanation: L10n.text("apple.clientsetupstate.the_machine_answered_with_a_different_iden.b027025e"),
                action: .reviewFingerprint,
                details: message
            )
        case "access_required":
            return ClientSetupFailure(
                explanation: L10n.text("apple.clientsetupstate.this_machine_is_on_your_account_but_this_d.876ba315"),
                changed: L10n.text("apple.clientsetupstate.the_server_is_installed_and_signed_in.092d7364"),
                action: .checkServer,
                details: message
            )
        case "pairing_expired", "code_expired":
            return ClientSetupFailure(
                explanation: L10n.text("apple.clientsetupstate.this_pairing_code_has_expired.dc34ec3b"),
                action: .newCode,
                details: message
            )
        case "identity_required":
            return ClientSetupFailure(
                explanation: L10n.text("apple.clientsetupstate.paste_the_full_machine_key_the_installer_p.95ca62ac"),
                action: .retry,
                details: message
            )
        case "account_changed", "signed_out", "auth":
            return ClientSetupFailure(
                explanation: L10n.text("apple.clientsetupstate.this_device_is_signed_out_of_the_account_t.cd22fc68"),
                action: .signInToAccount,
                details: message
            )
        case "unknown_method":
            return ClientSetupFailure(
                explanation: L10n.text("apple.clientsetupstate.this_machine_is_running_an_older_tokenstat.e8972de3"),
                action: .updateMachine,
                details: message
            )
        default:
            let lower = message.lowercased()
            if lower.contains("unknown method") {
                return ClientSetupFailure(
                    explanation: L10n.text("apple.clientsetupstate.this_app_is_running_against_an_older_helpe.66cf1f69"),
                    action: .updateMachine,
                    details: message
                )
            }
            if lower.contains("not logged in") {
                return ClientSetupFailure(
                    explanation: L10n.text("apple.clientsetupstate.this_device_is_signed_out_sign_in_again_th.868697cc"),
                    action: .signInToAccount,
                    details: message
                )
            }
            return ClientSetupFailure(explanation: message, action: .retry, details: nil)
        }
    }
}

enum SetupStep: Hashable {
    case `where`
    case credential
    case fingerprint
    case check
    case install
    case finish
    case project
    case needServer
    case byHand
    case cloud
    case mac
}
