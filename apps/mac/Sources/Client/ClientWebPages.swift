// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

/// Website URLs the iOS client opens inside the app.
///
/// Always add `mobile=1` so tokenstat.ai hides the site chrome. The same
/// flag the sign-in sheet already sends. A query, not a user agent.
enum ClientWebPages {
    static let host = "https://tokenstat.ai"

    static func privacy(host: String = host) -> URL {
        withMobileFlag(url("\(host)/privacy"))
    }

    static func contact(host: String = host) -> URL {
        withMobileFlag(url("\(host)/contact"))
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

    private static func url(_ string: String) -> URL {
        URL(string: string) ?? fallback
    }

    private static var fallback: URL {
        URL(string: host) ?? URL(fileURLWithPath: "/")
    }

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
