// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatViewportContinuity.swift ChatReadingPosition.swift ChatReadingStore.swift WorkReference.swift.
import Foundation

@main
struct ChatViewportContinuityTests {
    @MainActor static func main() {
        let viewport = ChatViewportContinuity()
        let mark = ChatReadingMark(eventID: "text-s12", offset: 0.2, updatedAt: Date(), within: 0.4)
        var owner = UUID()
        precondition(viewport.claim(generation: 1, owner: owner) == nil)
        viewport.record(.away(mark), generation: 1, owner: owner)
        for _ in 0..<30 {
            let next = UUID()
            precondition(viewport.claim(generation: 1, owner: next) == mark)
            // The outgoing layout can disappear after its successor claims.
            viewport.record(.latest, generation: 1, owner: owner)
            precondition(viewport.mark(generation: 1) == mark)
            viewport.record(.unknown, generation: 1, owner: next)
            precondition(viewport.mark(generation: 1) == mark)
            owner = next
        }
        viewport.record(.latest, generation: 1, owner: owner)
        // Explicit Jump/Send intent wins even before the scroll chase settles.
        precondition(viewport.claim(generation: 1, owner: UUID()) == nil)
        owner = UUID()
        viewport.claim(generation: 1, owner: owner)
        precondition(viewport.mark(generation: 1) == nil)
        viewport.record(.away(mark), generation: 1, owner: owner)
        let requested = ChatReadingMark(eventID: "text-s99", offset: 0, updatedAt: Date())
        viewport.record(.away(requested), generation: 1, owner: owner)
        let replacement = UUID()
        precondition(viewport.claim(generation: 1, owner: replacement) == requested,
            "explicit reading intent must survive remount before first placement")
        viewport.record(.away(mark), generation: 1, owner: owner)
        precondition(viewport.mark(generation: 1) == requested)
        owner = replacement
        precondition(viewport.claim(generation: 2, owner: owner) == nil)
        viewport.record(.away(mark), generation: 1, owner: owner)
        precondition(viewport.mark(generation: 2) == nil)
        precondition(viewport.mark(generation: 1) == nil)
        let anotherReader = ChatViewportContinuity()
        precondition(anotherReader.claim(generation: 1, owner: UUID()) == nil)
        print("Chat viewport continuity: 30 layout handoffs, late teardown, unknown geometry, latest, new selections and reader isolation passed")
    }
}
