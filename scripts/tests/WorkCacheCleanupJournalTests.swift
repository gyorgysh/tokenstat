// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkCacheCleanupJournal.swift.
import Foundation
import Darwin
@main struct WorkCacheCleanupJournalTests {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--crash-cleanup" {
            let journal = WorkCacheCleanupJournal(file: URL(fileURLWithPath: CommandLine.arguments[2]))
            try journal.prepare(scope: "owner-a")
            try journal.confirm(scope: "owner-a")
            await journal.recover(verifiedScope: nil, accountKnown: true,
                deleteKey: { _ in true }, clear: { _ in Darwin._exit(23) })
            assertionFailure("Crash helper unexpectedly returned")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cleanup/journal.json")
        let journal = WorkCacheCleanupJournal(file: file)
        var events: [String] = []
        try journal.prepare(scope: "owner-a")
        assert(WorkCacheCleanupJournal.blocks("owner-a", file: file))
        assert(!WorkCacheCleanupJournal.blocks("owner-b", file: file))
        let reopened = WorkCacheCleanupJournal(file: file)
        await reopened.recover(verifiedScope: nil, accountKnown: false,
            deleteKey: { _ in events.append("key"); return true }, clear: { _ in events.append("clear") })
        assert(events.isEmpty, "An offline unknown account does not prove sign-out")
        await reopened.recover(verifiedScope: "owner-a", accountKnown: true,
            deleteKey: { _ in events.append("key"); return true }, clear: { _ in events.append("clear") })
        assert(events.isEmpty, "Fresh original account preserves a failed sign-out's cache")
        assert(!WorkCacheCleanupJournal.blocks("owner-a", file: file))
        try journal.prepare(scope: "owner-a")
        enum Interrupted: Error { case localTransport }
        await reopened.recover(verifiedScope: nil, accountKnown: true,
            deleteKey: { _ in events.append("key"); return true }, clear: { _ in
                assert(events == ["key"], "Key is destroyed before awaiting record deletion")
                events.append("interrupted")
                throw Interrupted.localTransport
            })
        assert(WorkCacheCleanupJournal.blocks("owner-a", file: file))
        let relaunched = WorkCacheCleanupJournal(file: file)
        await relaunched.recover(verifiedScope: nil, accountKnown: true,
            deleteKey: { _ in events.append("key retry"); return true }, clear: { _ in events.append("clear retry") })
        assert(events == ["key", "interrupted", "key retry", "clear retry"])
        assert(!WorkCacheCleanupJournal.blocks("owner-a", file: file))
        try journal.prepare(scope: "owner-a")
        try journal.confirm(scope: "owner-a")
        events = []
        await relaunched.recover(verifiedScope: "owner-a", accountKnown: true,
            deleteKey: { _ in events.append("locked key"); return false }, clear: { _ in assertionFailure("Cleared despite inaccessible keychain") })
        assert(WorkCacheCleanupJournal.blocks("owner-a", file: file))
        await relaunched.recover(verifiedScope: "owner-a", accountKnown: true,
            deleteKey: { _ in true }, clear: { _ in events.append("confirmed cleanup") })
        assert(events == ["locked key", "confirmed cleanup"], "Confirmed cleanup survives reauthentication to same account")
        try journal.prepare(scope: "owner-a")
        await relaunched.recover(verifiedScope: "owner-a", accountKnown: true, stillValid: { false },
            deleteKey: { _ in assertionFailure(); return true }, clear: { _ in assertionFailure() })
        assert(WorkCacheCleanupJournal.blocks("owner-a", file: file), "Stale account load cannot cancel current intent")
        try journal.confirm(scope: "owner-a")
        await relaunched.recover(verifiedScope: nil, accountKnown: true,
            deleteKey: { _ in true }, clear: { _ in try journal.prepare(scope: "owner-a") })
        assert(WorkCacheCleanupJournal.blocks("owner-a", file: file), "Old completion cannot remove a new cleanup intent")
        // A separate process exits abruptly after key deletion but before
        // record cleanup, so this checks disk recovery beyond object re-init.
        let crashFile = root.appendingPathComponent("crash/journal.json")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--crash-cleanup", crashFile.path]
        try child.run()
        child.waitUntilExit()
        assert(child.terminationStatus == 23)
        assert(WorkCacheCleanupJournal.blocks("owner-a", file: crashFile))
        var resumedAfterExit = false
        await WorkCacheCleanupJournal(file: crashFile).recover(verifiedScope: nil, accountKnown: true,
            deleteKey: { _ in true }, clear: { _ in resumedAfterExit = true })
        assert(resumedAfterExit && !WorkCacheCleanupJournal.blocks("owner-a", file: crashFile))
        let original = root.appendingPathComponent("original.txt")
        try Data("Unsent original".utf8).write(to: original)
        let broken = Data("broken journal".utf8)
        try broken.write(to: file)
        do { try journal.prepare(scope: "owner-b"); assertionFailure("Overwrote unreadable intent") } catch {}
        let preservedJournal = try Data(contentsOf: file)
        assert(preservedJournal == broken)
        assert(WorkCacheCleanupJournal.blocks("owner-b", file: file))
        let preservedOriginal = try Data(contentsOf: original)
        assert(preservedOriginal == Data("Unsent original".utf8))
        print("Cleanup journal: relaunch, failed sign-out, key-first retry, inaccessible keychain, stale proof and new-intent preservation passed")
    }
}
