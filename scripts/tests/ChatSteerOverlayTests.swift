// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatSteerOverlay.swift.

struct ChatConversation: Equatable {
    let id: String
    var pendingSteer: String?
}

@main enum ChatSteerOverlayTests {
    static func main() {
        var overlay = ChatSteerOverlay()
        let owner = "account|host|project"
        func rows(_ note: String?) -> [ChatConversation] { [.init(id: "chat", pendingSteer: note)] }
        var current = rows(nil)

        let beforeSend = overlay.beginRead(owner: owner)
        overlay.remember(owner: owner, conversationID: "chat", note: "accepted note")
        current = overlay.apply(rows(nil), read: beforeSend, current: current)
        precondition(current == rows("accepted note"), "a delayed list cannot erase an accepted note")

        let afterSend = overlay.beginRead(owner: owner)
        current = overlay.apply(rows(nil), read: afterSend, current: current)
        precondition(current == rows(nil), "fresh host state can report tool consumption")
        current = overlay.apply(rows("old note"), read: beforeSend, current: current)
        precondition(current == rows(nil), "out-of-order lists cannot resurrect consumed notes")

        let beforeClear = overlay.beginRead(owner: owner)
        overlay.remember(owner: owner, conversationID: "chat", note: nil)
        current = overlay.apply(rows("removed note"), read: beforeClear, current: current)
        precondition(current == rows(nil), "delayed lists cannot resurrect removed or delivered notes")
        let afterClear = overlay.beginRead(owner: owner)
        current = overlay.apply(rows("another client's note"), read: afterClear, current: current)
        precondition(current == rows("another client's note"), "new host notes survive a completed removal")

        let beforeReplacement = overlay.beginRead(owner: owner)
        overlay.remember(owner: owner, conversationID: "chat", note: "first note")
        let betweenReplacements = overlay.beginRead(owner: owner)
        overlay.remember(owner: owner, conversationID: "chat", note: "replacement note")
        current = overlay.apply(rows("first note"), read: betweenReplacements, current: current)
        precondition(current == rows("replacement note"))
        current = overlay.apply(rows(nil), read: beforeReplacement, current: current)
        precondition(current == rows("replacement note"))

        // Warming another project cannot make this project's read stale or
        // apply its note to a same-named chat on another account or host.
        let otherOwner = "other-account|other-host|project"
        let other = overlay.beginRead(owner: otherOwner)
        let otherRows = overlay.apply(rows(nil), read: other, current: [])
        precondition(otherRows == rows(nil))
        let independent = overlay.beginRead(owner: "account|host|other-project")
        let independentRows = overlay.apply(rows("independent note"), read: independent, current: [])
        precondition(independentRows == rows("independent note"))

        // Delivery starts the old note's turn before its reply reaches the
        // client. A running poll lets the composer accept a newer note first.
        let delivering = overlay.mutation(owner: owner, conversationID: "chat")
        let duringDelivery = overlay.beginRead(owner: owner)
        overlay.remember(owner: owner, conversationID: "chat", note: "new turn's note")
        precondition(!overlay.remember(owner: owner, conversationID: "chat", note: nil,
            ifUnchangedSince: delivering), "an old delivery reply cannot remove a newer accepted note")
        current = overlay.apply(rows(nil), read: duringDelivery, current: current)
        precondition(current == rows("new turn's note"))

        let sameWords = overlay.mutation(owner: owner, conversationID: "chat")
        overlay.remember(owner: owner, conversationID: "chat", note: "new turn's note")
        precondition(!overlay.remember(owner: owner, conversationID: "chat", note: nil,
            ifUnchangedSince: sameWords), "identical words still belong to a newer acceptance")
        let freshNote = overlay.beginRead(owner: owner)
        current = overlay.apply(rows("new turn's note"), read: freshNote, current: current)
        precondition(!overlay.remember(owner: owner, conversationID: "chat", note: nil,
            ifUnchangedSince: delivering), "retiring the list overlay must retain mutation ownership")

        let clearing = overlay.mutation(owner: owner, conversationID: "chat")
        let duringClear = overlay.beginRead(owner: owner)
        precondition(overlay.remember(owner: owner, conversationID: "chat", note: nil,
            ifUnchangedSince: clearing), "the matching clear acknowledgment removes its note")
        current = overlay.apply(rows("new turn's note"), read: duringClear, current: current)
        precondition(current == rows(nil))
        precondition(!overlay.remember(owner: otherOwner, conversationID: "chat", note: nil,
            ifUnchangedSince: clearing), "removal snapshots cannot cross accounts or hosts")

        let record = ChatConversation(id: "chat", pendingSteer: nil)
        let renamed = ChatSteerOverlay.preservingNote(in: record, from: rows("still executable").first)
        precondition(renamed.pendingSteer == "still executable", "renaming and setup replies must preserve ephemeral notes")
        let otherRecord = ChatConversation(id: "another-chat", pendingSteer: nil)
        precondition(ChatSteerOverlay.preservingNote(in: otherRecord,
            from: rows("still executable").first).pendingSteer == nil)

        let deletion = overlay.beginRead(owner: owner)
        current = overlay.apply([], read: deletion, current: current)
        precondition(current.isEmpty)
        current = overlay.apply(rows("replacement note"), read: betweenReplacements, current: current)
        precondition(current.isEmpty, "a deleted conversation cannot return through a delayed list")
        overlay.removeAll()
        let nextAccount = overlay.beginRead(owner: owner)
        precondition(overlay.apply(rows(nil), read: nextAccount, current: []) == rows(nil))
        print("Steer overlays: delayed reads, newer acceptances, consumption, removal and owner isolation passed")
    }
}
