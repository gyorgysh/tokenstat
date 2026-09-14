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
            assert(condition, message)
        }
        // The first run asks.
        do {
            let probe = RemoteHostFeatureProbe()
            check(probe.state == .checking, "starts checking")
            check(probe.beginRun(key: "peer-0"), "first run asks")
            check(probe.state == .checking, "new question clears")
            probe.didAnswer(key: "peer-0", state: .available)
            check(probe.state == .available, "answer lands")
        }
        // A restart for the answered key resumes it. Pushing a screen cancels
        // the gate's task and popping restarts it, and clearing there unmounted
        // the content: Back from workspace tools landed on the chat list
        // instead of the open thread.
        do {
            let probe = RemoteHostFeatureProbe()
            check(probe.beginRun(key: "peer-0"), "first run asks")
            probe.didAnswer(key: "peer-0", state: .available)
            check(!probe.beginRun(key: "peer-0"), "restart resumes")
            check(probe.state == .available, "answer stays mounted")
            probe.didAnswer(key: "peer-0", state: .needsUpdate(3))
            check(!probe.beginRun(key: "peer-0"), "restart resumes a refusal")
            check(probe.state == .needsUpdate(3), "refusal stays")
        }
        // A new peer is a new question: the old host's answer must not cover
        // the next host while it is still being checked.
        do {
            let probe = RemoteHostFeatureProbe()
            check(probe.beginRun(key: "a-0"), "first peer asks")
            probe.didAnswer(key: "a-0", state: .available)
            check(probe.beginRun(key: "b-0"), "new peer asks")
            check(probe.state == .checking, "new peer clears the old answer")
        }
        // An explicit retry asks again.
        do {
            let probe = RemoteHostFeatureProbe()
            check(probe.beginRun(key: "peer-0"), "first run asks")
            probe.didAnswer(key: "peer-0", state: .needsUpdate(3))
            check(probe.beginRun(key: "peer-1"), "retry asks")
            check(probe.state == .checking, "retry clears")
        }
        // Cancelled before answering: no key is recorded, so the restart asks
        // instead of resuming a check that never finished.
        do {
            let probe = RemoteHostFeatureProbe()
            check(probe.beginRun(key: "peer-0"), "first run asks")
            check(probe.beginRun(key: "peer-0"), "unanswered restart asks again")
            check(probe.state == .checking, "still checking")
        }
        print("RemoteHostFeatureProbeTests passed")
    }
}
