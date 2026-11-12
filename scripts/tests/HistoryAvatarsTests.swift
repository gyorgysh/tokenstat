// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with HistoryAvatars.swift.
import Foundation

@main
struct HistoryAvatarsTests {
    @MainActor static func main() {
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
        }

        let faces = HistoryAvatarIndex(
            byCommit: [
                "aaaa": "https://avatars.example/ada",
                "BBBB": "https://avatars.example/grace",
            ],
            byEmail: [
                "ada@example.com": "https://avatars.example/ada",
                "grace@example.com": "javascript:alert(1)",
            ]
        )

        check(
            faces.url(commitID: "aaaa", email: "ada@example.com", mine: true, accountAvatar: "https://tokenstat.example/me")
                == "https://tokenstat.example/me",
            "a commit of yours keeps the account picture"
        )
        check(
            faces.url(commitID: "aaaa", email: "ada@example.com", mine: true, accountAvatar: "  ")
                == "https://avatars.example/ada",
            "yours with no account picture uses the forge picture"
        )
        check(
            faces.url(commitID: "bbbb", email: "grace@example.com", mine: false, accountAvatar: "https://tokenstat.example/me")
                == "https://avatars.example/grace",
            "a teammate uses the forge picture for that commit"
        )
        check(
            faces.url(commitID: "cccc", email: " Ada@Example.com ", mine: false, accountAvatar: nil)
                == "https://avatars.example/ada",
            "an unpushed commit reuses the author's picture by email"
        )
        check(
            faces.url(commitID: "dddd", email: "grace@example.com", mine: false, accountAvatar: nil) == nil,
            "a picture that is not https is not shown"
        )
        check(
            faces.url(commitID: "eeee", email: "nobody@example.com", mine: false, accountAvatar: nil) == nil,
            "an author with no picture stays a letter"
        )

        let folded = HistoryAvatarIndex(
            byCommit: ["AbC": "http://avatars.example/insecure", "def": " https://avatars.example/ok "],
            byEmail: ["x@example.com": "javascript:alert(1)"]
        ).normalized()
        check(folded.byCommit["abc"] == nil, "an http picture is dropped")
        check(folded.byCommit["def"] == "https://avatars.example/ok", "a padded https picture is kept")
        check(folded.byEmail.isEmpty, "a script URL is dropped")
        check(
            folded.url(commitID: "DEF", email: nil, mine: false, accountAvatar: nil) == "https://avatars.example/ok",
            "lookup uses the folded commit id"
        )
        let cache = HistoryAvatarCache()
        let key = HistoryAvatarCache.Key(owner: 1, peer: "host-a", workspace: "repo", from: "old")
        let time = Date(timeIntervalSince1970: 1000)
        cache.store(faces, for: key, now: time)
        check(cache.exact(key, now: time)?.byCommit["aaaa"] == "https://avatars.example/ada", "reopening uses the cached mapping")
        var next = key; next.from = "new"
        check(cache.exact(next, now: time) == nil && cache.recent(next, now: time) != nil, "new commits retain known authors while refreshing")
        next.peer = "host-b"
        check(cache.recent(next, now: time) == nil, "different hosts cannot share mappings")
        next = key; next.owner = 2
        check(cache.recent(next, now: time) == nil, "account changes cannot reuse mappings")
        check(cache.exact(key, now: time.addingTimeInterval(301)) == nil, "old mappings expire")
    }
}
