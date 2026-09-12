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
        withMobileFlag(url("\(host)/privacy"))
    }

    static func terms(host: String = host) -> URL {
        withMobileFlag(url("\(host)/terms"))
    }

    static func publicProfile(host: String, handle: String) -> URL {
        withMobileFlag(url("\(host)/\(handle)"))
    }

    static func accountDeletion(host: String = host) -> URL {
        guard var parts = URLComponents(string: "\(host)/settings/data") else {
            return withMobileFlag(url(host))
        }
        parts.queryItems = [
            URLQueryItem(name: "mobile", value: "1"),
            URLQueryItem(name: "focus", value: "delete"),
        ]
        parts.fragment = "delete"
        return parts.url ?? withMobileFlag(url(host))
    }

    /// A URL built from account data, or the site itself when the pieces do
    /// not form one. `host` and `handle` are not constants, and a phone must
    /// not trap because one of them arrived odd.
    private static func url(_ string: String) -> URL {
        URL(string: string) ?? fallback
    }

    /// The site root, and a non-failing last resort beside it. A file URL is
    /// a URL, and the browser sheet refuses anything that is not http/https.
    private static var fallback: URL {
        URL(string: host) ?? URL(fileURLWithPath: "/")
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
