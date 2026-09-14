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

        /// Whose account this names. The claimed handle when there is one,
        /// else the server's own id for it. A new account has no handle,
        /// and every function must still work for it, so the id is a full
        /// identity here rather than a lesser fallback. Nil only when
        /// neither answers, which is the unknown-account state.
        static func accountIdentity(handle: String?, id: String?) -> String? {
            if let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty {
                return handle
            }
            if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                return id
            }
            return nil
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
