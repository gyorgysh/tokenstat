// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

#if !os(macOS)

/// Website URLs the iOS client opens inside the app.
///
/// Always add `mobile=1` so tokenstat.ai hides the site chrome. The same
/// flag the sign-in sheet already sends. A query, not a user agent.
enum ClientWebPages {
    static let host = "https://tokenstat.ai"

    static func privacy(host: String = host) -> URL {
        withMobileFlag(URL(string: "\(host)/privacy")!)
    }

    static func terms(host: String = host) -> URL {
        withMobileFlag(URL(string: "\(host)/terms")!)
    }

    static func publicProfile(host: String, handle: String) -> URL {
        withMobileFlag(URL(string: "\(host)/\(handle)")!)
    }

    static func accountDeletion(host: String = host) -> URL {
        var parts = URLComponents(string: "\(host)/settings/data")!
        parts.queryItems = [
            URLQueryItem(name: "mobile", value: "1"),
            URLQueryItem(name: "focus", value: "delete"),
        ]
        parts.fragment = "delete"
        return parts.url!
    }

    /// Idempotent: a URL that already carries `mobile=1` is left alone.
    static func withMobileFlag(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = parts.queryItems ?? []
        if items.contains(where: { $0.name == "mobile" }) {
            return url
        }
        items.append(URLQueryItem(name: "mobile", value: "1"))
        parts.queryItems = items
        return parts.url ?? url
    }
}

#endif
