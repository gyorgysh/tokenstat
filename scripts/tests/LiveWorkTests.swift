// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with LiveWorkActivity.swift and EcosystemSnapshot.swift.
import Foundation

@main struct LiveWorkTests {
    static func main() throws {
        // These exact keys match the host's APNs registrations; chat and PTY
        // identifiers must never collide or disclose their raw IDs.
        assert(LiveWorkAttributes.key(kind: .chat, id: "chat-1") == "daeb6878280f4b0c33f4989eef9481119981cc99f3ac0ffab46decea50696570")
        assert(LiveWorkAttributes.key(kind: .terminal, id: "pty-1") == "8c1c2ef5da443ed42597c6c901e5fa9f42c52e5f6edde31be3e62f8009626d53")
        assert(LiveWorkAttributes.key(kind: .chat, id: "same") != LiveWorkAttributes.key(kind: .terminal, id: "same"))

        for kind in [LiveWorkKind.chat, .terminal] {
            let route = LiveWorkAttributes.destination(kind: kind, id: "item /?#🧪", peer: "host", workspaceID: "project", owner: "owner")
            assert(route.projectID == "remote:host:project")
            assert(EcosystemRoute(url: route.url) == route)
            assert(route == LiveWorkAttributes.destination(kind: kind, id: "item /?#🧪", peer: "host", workspaceID: "remote:host:project", owner: "owner"))
            assert(route.chatID == (kind == .chat ? "item /?#🧪" : nil))
            assert(route.terminalID == (kind == .terminal ? "item /?#🧪" : nil))
        }
        for invalid in ["tokenstat://open/workspaces?project=p&owner=o&terminal=x",
                        "tokenstat://open/workspaces?project=p&owner=o&section=chat&terminal=x",
                        "tokenstat://open/workspaces?project=p&owner=o&section=sessions&terminal=",
                        "tokenstat://open/workspaces?project=p&owner=o&section=sessions&terminal=x&chat=y"] {
            assert(EcosystemRoute(url: URL(string: invalid)!) == nil)
        }
        assert(LiveWorkPhase.terminal(alive: true, exitCode: nil, activity: "working", attention: nil) == .working)
        assert(LiveWorkPhase.terminal(alive: true, exitCode: nil, activity: "idle", attention: nil) == .waiting)
        assert(LiveWorkPhase.terminal(alive: true, exitCode: nil, activity: "working", attention: "permission") == .waiting)
        assert(LiveWorkPhase.terminal(alive: false, exitCode: 0, activity: "idle", attention: nil) == .done)
        assert(LiveWorkPhase.terminal(alive: false, exitCode: 1, activity: "idle", attention: nil) == .failed)
        assert(LiveWorkPhase.terminal(alive: false, exitCode: nil, activity: "working", attention: nil) == .stopped)
        print("Live work: host key compatibility, exact chat/terminal routes and lifecycle phases passed")
    }
}
