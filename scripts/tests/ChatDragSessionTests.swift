// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatDragSession.swift.
import AppKit

@MainActor private final class Hover {
    var pane = true, transcript = true, composer = true
    var endings = 0
    func clear() { pane = false; transcript = false; composer = false; endings += 1 }
}

@main enum ChatDragSessionTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var held = true
        var checks = 0
        let center = NotificationCenter(), hover = Hover()
        let session = ChatDragSession(buttonIsDown: { checks += 1; return held }, notifications: center)
        let observer = center.addObserver(forName: ChatDragSession.ended, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { hover.clear() }
        }
        defer { center.removeObserver(observer) }
        for _ in 0..<20 { session.begin() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        precondition(session.isWatching && hover.endings == 0 && checks <= 3,
            "A held drag must stay visible without multiplying its timer")
        held = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(!session.isWatching && hover.endings == 1,
            "A missing drop/exit callback must not leave hover behind after mouse release")
        precondition(!hover.pane && !hover.transcript && !hover.composer,
            "A completed child drop must clear every ancestor")
        let stopped = checks
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(checks == stopped, "Drag monitoring must stop when the drag ends")

        held = true; session.begin()
        precondition(!session.escape(hasSheet: false) && !session.isWatching,
            "AppKit must receive Escape to cancel a live drag")
        precondition(!session.escape(hasSheet: false), "A normal Escape must keep its existing action")
        held = false; session.begin()
        precondition(session.escape(hasSheet: false), "Escape must clear stale hover before stopping a turn")
        session.begin()
        precondition(!session.escape(hasSheet: true), "A sheet keeps its own Escape handling")
        held = true; session.begin()
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        precondition(!session.isWatching, "Switching applications must clear the drag")
        session.begin(); session.finish(); session.finish()
        precondition(!session.isWatching && hover.endings == 6,
            "A drop ends once, and the next drag can start normally")
        weak var discarded: ChatDragSession?
        do {
            let temporary = ChatDragSession(buttonIsDown: { held }, notifications: center)
            discarded = temporary; temporary.begin()
        }
        precondition(discarded == nil, "Event monitoring must not retain a retired drag session")
        print("Chat drag release, nested targets, cancellation, Escape and monitor cleanup passed")
    }
}
