// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// References contain identifiers only. Labels, prompts and paths belong in
/// separate stores; none are needed to remember which conversation was open.
struct WorkReference: Codable, Hashable, Sendable {
    struct Scope: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable { case account, local }
        let kind: Kind
        let origin: String
        let identity: String

        /// Whose account this names. What this device already files the account
        /// under (see `AccountIdentityPins`), else the claimed handle, else the
        /// server's own id. A new account has no handle, and every function
        /// must still work for it, so the id is a full identity here rather
        /// than a lesser fallback. Nil only when neither answers, which is the
        /// unknown-account state.
        static func accountIdentity(handle: String?, id: String?) -> String? {
            let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let id = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty else { return handle.isEmpty ? nil : handle }
            return AccountIdentityPins.shared.identity(handle: handle.isEmpty ? nil : handle, id: id)
        }

        /// The identity a host can check against the account it is signed in
        /// to. What this device files under can be a handle the account has
        /// since left, and the id never moves.
        var wireIdentity: String {
            AccountIdentityPins.shared.accountID(for: identity) ?? identity
        }

        /// An account scope. The handle parameter carries the stable
        /// identity, which is the claimed handle when there is one and the
        /// server's id otherwise (see `accountIdentity`). Either one
        /// round-trips through validation unchanged: only the origin's
        /// shape is checked, and the identity only has to be non-empty.
        static func account(origin: String, handle: String) -> Self? {
            guard !handle.isEmpty,
                  var url = URLComponents(string: origin),
                  let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  let host = url.host?.lowercased(), !host.isEmpty,
                  url.user == nil, url.password == nil else { return nil }
            url.scheme = scheme
            url.host = host
            url.query = nil
            url.fragment = nil
            if (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80) {
                url.port = nil
            }
            while url.path.hasSuffix("/") { url.path.removeLast() }
            guard let canonical = url.string else { return nil }
            return Self(kind: .account, origin: canonical, identity: handle)
        }

        static func local(installationID: String) -> Self {
            Self(kind: .local, origin: "", identity: installationID)
        }
    }

    enum Kind: String, Codable, Sendable { case workspace, conversation, terminal, commit, savedDiff }
    let scope: Scope
    /// Verified machine public identity, never a display name or address.
    let hostIdentity: String
    let workspaceID: String
    let kind: Kind
    let itemID: String?
    var anchor: String? = nil

    enum CodingKeys: String, CodingKey {
        case scope, hostIdentity, kind, anchor
        case workspaceID = "workspaceId"
        case itemID = "itemId"
    }
}

/// One conversation on one machine under one account, as a storage key.
///
/// Shared by every device-local store that keeps something per conversation,
/// so a draft and the place it was being read from are filed under the same
/// name. Every part is an identifier, percent-encoded so the separator cannot
/// occur inside one.
enum WorkReferenceKey {
    static func conversation(_ reference: WorkReference) -> String? {
        guard reference.kind == .conversation, let item = reference.itemID, !item.isEmpty,
              !reference.hostIdentity.isEmpty, !reference.workspaceID.isEmpty
        else { return nil }
        return folder(scope: reference.scope, hostIdentity: reference.hostIdentity,
                      workspaceID: reference.workspaceID) + encode(item)
    }

    /// Everything above the conversation, ending in the separator, so one
    /// folder's keys are exactly the keys carrying this prefix.
    static func folder(scope: WorkReference.Scope, hostIdentity: String,
                       workspaceID: String) -> String {
        [scope.kind.rawValue, scope.origin, scope.identity, hostIdentity, workspaceID]
            .map(encode).joined(separator: "|") + "|"
    }

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}

/// What this device files each account's work under, kept from the first time
/// it saw the account.
///
/// Drafts, pins, reading places and saved work are keyed by an identity that
/// used to be recomputed from the handle. Claiming a handle moved it from the
/// server's id to the name, and changing one moved it again, and each time
/// everything filed under the old one was left behind. The account's id does
/// not move, so it is what finds the identity, and the identity stays put.
///
/// Off until `activate`, which the app does before anything asks. A process
/// that never activates it keeps the plain rule.
final class AccountIdentityPins: @unchecked Sendable {
    static let shared = AccountIdentityPins()
    private static let key = "account.identityPins.v1"

    private let lock = NSLock()
    private var defaults: UserDefaults?
    private var pins: [String: String] = [:]

    func activate(_ defaults: UserDefaults = .standard) {
        lock.lock()
        defer { lock.unlock() }
        self.defaults = defaults
        pins = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func identity(handle: String?, id: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let defaults else { return handle ?? id }
        if let pinned = pins[id] { return pinned }
        // A handle can be released and claimed by somebody else. Whoever was
        // filed under it here first keeps it, and the newcomer gets their id,
        // so one person's work never opens for another.
        let identity = handle.flatMap { name in pins.values.contains(name) ? nil : name } ?? id
        pins[id] = identity
        defaults.set(pins, forKey: Self.key)
        return identity
    }

    func accountID(for identity: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pins.first { $0.value == identity }?.key
    }
}
