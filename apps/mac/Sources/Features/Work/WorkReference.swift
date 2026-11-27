// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct WorkReference: Codable, Hashable, Sendable {
    struct Scope: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable { case account, local }
        let kind: Kind
        let origin: String
        let identity: String

        static func accountIdentity(handle: String?, id: String?) -> String? {
            let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let id = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty else { return handle.isEmpty ? nil : handle }
            return AccountIdentityPins.shared.identity(handle: handle.isEmpty ? nil : handle, id: id)
        }

        var wireIdentity: String {
            AccountIdentityPins.shared.accountID(for: identity) ?? identity
        }

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

enum WorkReferenceKey {
    static func conversation(_ reference: WorkReference) -> String? {
        guard reference.kind == .conversation, let item = reference.itemID, !item.isEmpty,
              !reference.hostIdentity.isEmpty, !reference.workspaceID.isEmpty
        else { return nil }
        return folder(scope: reference.scope, hostIdentity: reference.hostIdentity,
                      workspaceID: reference.workspaceID) + encode(item)
    }

    static func folder(scope: WorkReference.Scope, hostIdentity: String,
                       workspaceID: String) -> String {
        [scope.kind.rawValue, scope.origin, scope.identity, hostIdentity, workspaceID]
            .map(encode).joined(separator: "|") + "|"
    }

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}

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
