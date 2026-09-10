// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Native acceptance against the disposable host in tests/native_continuity.rs.
import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor enum NativeContinuityRuntimeTests {
    struct Fixture: Decodable {
        let socket: String
        let workspaceId: String
        let conversationId: String
    }
    struct Failure: Error { let message: String }
    static func run(chat: ChatModel, fixture: Fixture, output: URL) async throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(message: message) }
        }
        func signal(_ name: String) throws {
            try Data("ready".utf8).write(to: output.appendingPathComponent(name), options: .atomic)
        }
        func recordViewport(_ name: String) throws {
            #if canImport(UIKit)
            func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            let scrolls = windows.flatMap(descendants).compactMap { $0 as? UIScrollView }.filter { $0.bounds.height > 300 && $0.contentSize.height > $0.bounds.height * 2 }
            let values = scrolls.map { scroll in
                ["offsetX": scroll.contentOffset.x, "offsetY": scroll.contentOffset.y,
                 "width": scroll.bounds.width, "contentWidth": scroll.contentSize.width,
                 "leftInset": scroll.adjustedContentInset.left, "rightInset": scroll.adjustedContentInset.right]
            }
            try JSONSerialization.data(withJSONObject: values).write(to: output.appendingPathComponent(name))
            try check(!scrolls.isEmpty, "native viewport is available for reading-position acceptance")
            try check(scrolls.allSatisfy { abs($0.contentOffset.x + $0.adjustedContentInset.left) < 0.5 },
                      "vertical reading restoration must preserve horizontal gutters")
            #endif
        }
        func waitFor(_ name: String) async throws {
            for _ in 0..<600 {
                if FileManager.default.fileExists(atPath: output.appendingPathComponent(name).path) { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw Failure(message: "Timed out awaiting \(name)")
        }
        try check(RemoteHostFeature.handoff.minimumProtocol >= 12, "handoff requires durable transcript positions")
        let account = try JSONDecoder().decode(Account.self, from: Data(#"{"signedIn":false,"host":"https://example.invalid","machines":[]}"#.utf8))
        WorkSessionContext.shared.update(account: account)
        await chat.load(workspaceID: fixture.workspaceId)
        try check(chat.selected?.id == fixture.conversationId, "open the host-owned conversation")
        try check(chat.savedCopy == nil && !chat.events.isEmpty, "live native open")
        try check(chat.turnUsage?.input == 3500, "opening usage counted once across the full archive")
        guard let reference = chat.currentReference else { throw Failure(message: "missing owned reference") }
        let savedPage = try await Bridge.chatEventPage(id: fixture.conversationId, cursor: nil, limit: 300)
        let savingWasEnabled = WorkCacheSettings.shared.enabled
        WorkCacheSettings.shared.enabled = true
        await WorkCacheStore.shared.saveConversation(reference: reference, title: "Continuity test", page: savedPage)
        WorkCacheSettings.shared.enabled = savingWasEnabled
        let savedChat = ChatModel()
        let openedSaved = await savedChat.loadSavedConversation(reference)
        try check(openedSaved && savedChat.savedCopy != nil, "cold model opens the encrypted saved conversation")
        try check(savedChat.turnUsage?.input == 3500, "saved page preserves full conversation usage without counting resident rows twice")
        try check(savedChat.turnUsage == chat.turnUsage, "offline and live meters agree on all counters and cost for the same saved revision")
        try check(savedChat.savedCopy?.hasEarlier == true && !savedChat.hasEarlier, "saved copy remains explicit about unavailable earlier pages")
        chat.draft = "Keep this local draft through reading and sharing."
        let originalDraft = chat.handoffDraft
        let originalGeneration = chat.selectionGeneration
        let earlierReset = ProcessInfo.processInfo.environment["QA_RESET_EARLIER"] == "1"
        let response = try await Bridge.workSearch(query: earlierReset ? "Note 250" : "Note 50", kinds: [.conversation], workspaceIDs: [fixture.workspaceId])
        let page = try WorkSearchLive.decode(JSONEncoder().encode(response), expectedHost: reference.hostIdentity, scope: reference.scope)
        guard let hit = page.hits.first, let anchor = hit.reference.anchor else { throw Failure(message: "missing exact live search anchor") }
        if !earlierReset {
            try check(!chat.displayItems.contains { $0.id == anchor }, "search fixture starts outside the loaded window")
        }
        try check(chat.restoreSearchReadingPosition(hit.reference), "same-conversation search requests reading restoration")
        try signal("reading.requested")
        for _ in 0..<200 {
            if chat.displayItems.contains(where: { $0.id == anchor }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if ProcessInfo.processInfo.environment["QA_REVIEW_READING"] == "1" { try await waitFor("reading.continue") }
        try check(chat.displayItems.contains { $0.id == anchor }, "native restoration fetched the matching older page")
        try check(chat.selectionGeneration == originalGeneration && chat.handoffDraft == originalDraft, "reading preserves selection and draft")

        guard let connection = WorkHandoffConnection(chat: chat, hostIsLinked: { true }) else {
            throw Failure(message: "cannot open an owned handoff connection")
        }
        let first = connection.makeModel(), second = connection.makeModel()
        await first.load(); await second.load()
        try check(first.phase == .ready && second.phase == .ready, "two handoff snapshots loaded from host")
        await first.share(deviceName: "Studio", draft: originalDraft, anchor: nil)
        let other = WorkSharedDraft(text: "A separate version to review.", attachmentIDs: [])
        await second.share(deviceName: "Tablet", draft: other, anchor: nil)
        try check(first.phase == .shared && second.phase == .conflict, "host CAS detects the competing share")
        try check(second.pending?.draft == other && second.shared?.draft == originalDraft, "both drafts remain available")
        try check(chat.handoffDraft == originalDraft, "fetch and conflict never import automatically")
        await second.shareMyVersion()
        try check(second.phase == .shared && second.shared?.draft == other, "explicit conflict resolution writes the chosen draft")
        let files = try await connection.attachments(for: other)
        try await connection.verifyForImport()
        try check(chat.importHandoffDraft(other, files: files, replacing: originalDraft, reference: reference), "explicit import after live verification")
        try check(chat.draft == other.text && chat.queued.isEmpty && !chat.sending, "import stays an unsent local draft")

        if ProcessInfo.processInfo.environment["QA_REVIEW_SURVIVING"] == "1" {
            let response = try await Bridge.workSearch(query: earlierReset ? "Note 250" : "Note 150", kinds: [.conversation], workspaceIDs: [fixture.workspaceId])
            let hits = try WorkSearchLive.decode(JSONEncoder().encode(response), expectedHost: reference.hostIdentity, scope: reference.scope)
            guard let target = hits.hits.first else { throw Failure(message: "missing surviving reading target") }
            try check(chat.restoreSearchReadingPosition(target.reference), "restore a still-retained older message before trim")
            try await Task.sleep(for: .seconds(2))
            try recordViewport("viewport-before.json")
            try signal("surviving.before")
            try await waitFor("surviving.trim")
        }
        if earlierReset { try check(chat.hasEarlier, "older-page fixture retains a pre-trim cursor") }
        try signal("trim"); try await waitFor("trim.done")
        if earlierReset { await chat.loadEarlier() } else { await chat.poll() }
        if ProcessInfo.processInfo.environment["QA_REVIEW_SURVIVING"] == "1" {
            try await Task.sleep(for: .seconds(2))
            if earlierReset {
                try check(FileManager.default.fileExists(atPath: output.appendingPathComponent("older-reset-observed").path), "host returned reset to the outstanding older-page request")
            }
            try recordViewport("viewport-after.json")
            try signal("surviving.after")
            try await waitFor("surviving.continue")
        }
        let afterTrim = try await Bridge.chatEventPage(id: fixture.conversationId, cursor: nil, limit: 300)
        try check(afterTrim.usage?.input == 4000, "history retention preserves the full conversation total")
        try check(chat.turnUsage?.input == afterTrim.usage?.input, "trim reset adopts the host total without double counting")
        var retainedIDs = Set(afterTrim.events.compactMap(\.seq))
        var cursor = afterTrim.cursor
        while let before = cursor {
            let older = try await Bridge.chatEventPage(id:fixture.conversationId,cursor:before,limit:300)
            retainedIDs.formUnion(older.events.compactMap(\.seq)); cursor = older.cursor
        }
        try check(chat.events.last?.seq == afterTrim.events.last?.seq, "live poll reaches the new retained end")
        let residentIDs = chat.events.compactMap(\.seq)
        try check(Set(residentIDs).count == residentIDs.count && residentIDs.allSatisfy(retainedIDs.contains), "reset holds only retained records without duplicates")
        if chat.hasEarlier { try check(!chat.reachedStart, "reset reopens older paging after the previous window reached its start") }
        for _ in 0..<100 {
            if !chat.hasEarlier { break }
            await chat.loadEarlier()
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(!chat.hasEarlier, "retained older pages remain reachable")
        try check(chat.historyTrimmed && chat.reachedStart, "retained history is distinguished from the true start")
        try check(chat.turnUsage?.input == 4000, "loading retained older pages does not change the total")
        let retainedSearch = try await Bridge.workSearch(query:"layout",kinds:[.conversation],workspaceIDs:[fixture.workspaceId])
        try check(retainedSearch.hits.first?.partial == true && retainedSearch.coverage.partial, "search reports retained history as partial coverage")
        let retainedTotal = chat.turnUsage?.input ?? 0
        if ProcessInfo.processInfo.environment["QA_REVIEW_RETAINED"] == "1" {
            try signal("trim.checked")
            try await waitFor("trim.continue")
        }
        try signal("append"); try await waitFor("append.done")
        await chat.poll()
        try check(chat.turnUsage?.input == retainedTotal + 250, "new usage is counted once after compaction")
        await chat.poll()
        try check(chat.turnUsage?.input == retainedTotal + 250, "idle poll does not count usage again")
        try check(chat.draft == other.text && chat.selectionGeneration == originalGeneration, "poll reset preserves unsent work and selection")
        try await Bridge.removeChat(id: fixture.conversationId)
        do {
            try await connection.verifyForImport()
            throw Failure(message: "deleted conversation accepted handoff verification")
        } catch let error as Failure { throw error } catch {}
        try check(chat.draft == other.text, "deletion refusal preserves the composer")
    }
}
