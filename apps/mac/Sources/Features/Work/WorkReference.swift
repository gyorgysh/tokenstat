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
