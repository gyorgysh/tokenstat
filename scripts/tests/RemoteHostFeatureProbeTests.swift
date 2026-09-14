// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientRemoteFeatureGate.swift.
import SwiftUI

enum Bridge {
    static func peerProtocolVersion(_ peer: String) async throws -> Int { 99 }
}

enum Theme {
    enum Space {
        static let m: CGFloat = 16
        static let xl: CGFloat = 32
    }
    static let callout = Font.callout
    static let title3 = Font.title3
    static let caption = Font.caption
    static let accent = Color.purple
    static let background = Color.white
    static let panel = Color.gray
    static let border = Color.gray
    static func fixed(_ size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight)
    }
}

func personaSeed(for identifier: String) -> UInt64 { 0 }

struct PersonaPastime: View {
    enum Repertoire { case thought }
    init(seed: UInt64, size: CGFloat, doing: Repertoire) {}
    var body: some View { EmptyView() }
}

enum ActionIcon { case refresh }

extension Button where Label == Text {
    init(_ title: String, _ icon: ActionIcon, action: @escaping () -> Void) {
        self.init(action: action) { Text(title) }
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

@main
struct RemoteHostFeatureProbeTests {
    @MainActor static func main() {
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
        }
        func key(_ peer: String, _ feature: RemoteHostFeature = .chat, _ retry: Int = 0) -> RemoteHostFeatureProbeKey {
            RemoteHostFeatureProbeKey(peer: peer, feature: feature, retry: retry)
        }
        // The first run asks.
        do {
            let probe = RemoteHostFeatureProbe()
            check(probe.state == .checking, "starts checking")
            check(probe.beginRun(key: key("peer")), "first run asks")
            check(probe.state == .checking, "new question clears")
            probe.didAnswer(key: key("peer"), state: .available)
            check(probe.state == .available, "answer lands")
        }
        // A restart for the answered key resumes it. Pushing a screen cancels
        // the gate's task and popping restarts it, and clearing there unmounted
        // the content: Back from workspace tools landed on the chat list
        // instead of the open thread.
        do {
            let probe = RemoteHostFeatureProbe()
            check(probe.beginRun(key: key("peer")), "first run asks")
            probe.didAnswer(key: key("peer"), state: .available)
            check(!probe.beginRun(key: key("peer")), "restart resumes")
            check(probe.state == .available, "answer stays mounted")
            probe.didAnswer(key: key("peer"), state: .needsUpdate(3))
            check(!probe.beginRun(key: key("peer")), "restart resumes a refusal")
            check(probe.state == .needsUpdate(3), "refusal stays")
        }
        // A new peer is a new question: the old host's answer must not cover
        // the next host while it is still being checked.
        do {
            let probe = RemoteHostFeatureProbe()
            check(probe.beginRun(key: key("a")), "first peer asks")
            probe.didAnswer(key: key("a"), state: .available)
            check(probe.beginRun(key: key("b")), "new peer asks")
            check(probe.state == .checking, "new peer clears the old answer")
        }
        // An explicit retry asks again.
        do {
            let probe = RemoteHostFeatureProbe()
            check(probe.beginRun(key: key("peer", .chat, 0)), "first run asks")
            probe.didAnswer(key: key("peer", .chat, 0), state: .needsUpdate(3))
            check(probe.beginRun(key: key("peer", .chat, 1)), "retry asks")
            check(probe.state == .checking, "retry clears")
        }
        // Cancelled before answering: no key is recorded, so the restart asks
        // instead of resuming a check that never finished.
        do {
            let probe = RemoteHostFeatureProbe()
            check(probe.beginRun(key: key("peer")), "first run asks")
            check(probe.beginRun(key: key("peer")), "unanswered restart asks again")
            check(probe.state == .checking, "still checking")
        }
        // A new feature is a new question, even for the same peer and retry:
        // a chat answer must not cover pulls while it is still being checked.
        // Folder picker and clone repository share minimum protocol 7 and must
        // still ask separately.
        do {
            let probe = RemoteHostFeatureProbe()
            check(probe.beginRun(key: key("peer", .chat)), "first feature asks")
            probe.didAnswer(key: key("peer", .chat), state: .available)
            check(probe.beginRun(key: key("peer", .pulls)), "new feature asks")
            check(probe.state == .checking, "new feature clears the old answer")
            probe.didAnswer(key: key("peer", .pulls), state: .available)
            check(!probe.beginRun(key: key("peer", .pulls)), "same feature resumes")
            check(probe.beginRun(key: key("peer", .folderPicker)), "third feature asks")
            probe.didAnswer(key: key("peer", .folderPicker), state: .available)
            check(probe.beginRun(key: key("peer", .cloneRepository)), "same-minimum feature still asks")
            check(probe.state == .checking, "same-minimum feature clears")
        }
        // A late answer for a superseded peer is dropped: switching computers
        // while the old host is still answering must not cover the new host.
        do {
            let probe = RemoteHostFeatureProbe()
            check(probe.beginRun(key: key("a")), "first peer asks")
            check(probe.beginRun(key: key("b")), "new peer supersedes")
            probe.didAnswer(key: key("a"), state: .available)
            check(probe.state == .checking, "stale answer is dropped")
            check(probe.checkedKey == nil, "stale answer records no key")
            probe.didAnswer(key: key("b"), state: .available)
            check(probe.state == .available, "current answer lands")
            check(!probe.beginRun(key: key("b")), "answered key resumes")
        }
        // A local interlude clears: remote needsUpdate, a local host, then
        // back to the same remote must re-check rather than resume the local
        // .available and hide the update prompt.
        do {
            let probe = RemoteHostFeatureProbe()
            check(probe.beginRun(key: key("peer")), "remote asks")
            probe.didAnswer(key: key("peer"), state: .needsUpdate(3))
            probe.noteLocal()
            check(probe.state == .available, "local shows content")
            check(probe.beginRun(key: key("peer")), "back to remote asks again")
            check(probe.state == .checking, "back to remote clears the local answer")
        }
        print("RemoteHostFeatureProbeTests passed")
    }
}
