// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TeamAskRecovery.swift TeamAskModel.swift TeamCommentDraftStore.swift TeamModels.swift WorkReference.swift JSONValue.swift.
import Foundation

@MainActor private final class AskFixture {
    let root: URL
    let target = TeamCommentTarget(origin: "https://accounts.example.test", person: "fixture-person", organization: "org_fixture", repository: "repo_fixture", checkout: "checkout_fixture", share: "share_fixture", host: String(repeating: "a", count: 64))
    let running = JSONValue.object(["runId": .string("run_" + String(repeating: "a", count: 32)), "incarnation": .string(String(repeating: "b", count: 64))])
    var first: [String: JSONValue]?
    var reviews = 0, sends = 0, stops = 0
    var status: JSONValue = .object(["running": .bool(true)])
    var loseReply = true, stopFails = true, current = true, invalidReply = false, refuse = false
    init(_ root: URL) { self.root = root }
    func model() -> TeamAskModel {
        TeamAskModel(target: target, storage: TeamAskRecoveryStore(directory: root), current: { self.current }, call: { try await self.call($0, $1) })
    }
    func call(_ method: String, _ input: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "team.chat.ask.review":
            reviews += 1
            return .object(["review": .string(String(repeating: "c", count: 64)), "agentRuns": .bool(true)])
        case "team.chat.ask":
            sends += 1
            let disk = try await TeamAskRecoveryStore(directory: root).load(target)
            precondition(disk?.record.input == input, "An Ask was sent before the exact attempt was durable")
            if let first { precondition(first == input, "A retry changed the original Ask") } else { first = input }
            if refuse { first = nil; throw TeamAskNotAccepted(message: "Fictional stale review refused") }
            if loseReply { throw TeamAskRecoveryFailure.unconfirmed }
            if invalidReply { return .object(["state": .string("running"), "fence": .object(["runId": .string("wrong")])]) }
            return .object(["state": .string("running"), "fence": running])
        case "team.chat.ask.status":
            precondition(input["fence"] == running, "Status changed the original fence")
            return status
        case "team.chat.ask.stop":
            precondition(input["fence"] == running, "Stop changed the original fence")
            stops += 1
            if stopFails { throw TeamAskRecoveryFailure.unconfirmed }
            return .object(["stopping": .bool(false)])
        default: preconditionFailure("Unexpected Ask call")
        }
    }
}

@main struct TeamAskRecoveryTests {
    static func expect(_ value: Bool, _ message: String) { precondition(value, message) }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("team-ask-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let api = AskFixture(root)
        let first = api.model(); await first.restore(); first.text = "Fictional original Ask"
        await first.ask(computer: "Example computer")
        expect(first.pending && api.sends == 1 && api.reviews == 1, "Lost delivery was forgotten")

        let reopened = api.model(); await reopened.restore()
        expect(reopened.pending && reopened.text == "Fictional original Ask" && api.sends == 1, "Restore sent work or lost the saved text")
        api.loseReply = false; await reopened.ask(computer: "Example computer")
        expect(api.reviews == 1 && api.sends == 2 && reopened.fence == api.running, "Recovery reviewed again or lost the same run")

        let running = api.model(); await running.restore()
        expect(running.fence == api.running && api.sends == 2, "Reopening failed to restore Stop without sending work")
        api.status = .object(["running": .string("false")]); await running.check()
        expect(running.fence == api.running, "Malformed status erased Stop")
        api.status = .object([:]); await running.check()
        expect(running.fence == api.running, "Missing status erased Stop")
        api.status = .object(["running": .bool(true)]); await running.check()
        expect(running.error == nil && running.fence != nil, "Healthy status kept the stale warning")
        await running.stop()
        expect(!running.stopping && running.fence != nil, "Failed Stop could not be retried")
        api.stopFails = false; await running.stop()
        expect(running.stopping && running.fence != nil && api.stops == 2, "Stop acknowledgement was mistaken for completion")
        api.status = .object(["running": .bool(false)]); await running.check()
        expect(running.fence == nil, "Confirmed completion did not retire the fence")
        expect(try await TeamAskRecoveryStore(directory: root).load(api.target) == nil, "Completed Ask stayed active on disk")

        let next = api.model(); await next.restore(); next.text = "A different fictional Ask"
        api.first = nil; api.loseReply = true; await next.ask(computer: "Example computer")
        await reopened.check() // A late old window must not remove the new request.
        expect(try await TeamAskRecoveryStore(directory: root).load(api.target)?.record.text == "A different fictional Ask", "Late status erased a newer Ask")
        let differentPerson = TeamCommentTarget(origin: api.target.origin, person: "other-person", organization: api.target.organization, repository: api.target.repository, checkout: api.target.checkout, share: api.target.share, host: api.target.host)
        expect(try await TeamAskRecoveryStore(directory: root).load(differentPerson) == nil, "A different person recovered someone else's Ask")
        let oldSends = api.sends; api.current = false
        await next.ask(computer: "Example computer"); await next.stop()
        expect(api.sends == oldSends, "An old login sent saved work")

        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        expect(files.count == 1, "Expected one pending recovery file")
        try Data("broken".utf8).write(to: files[0])
        api.current = true
        let corrupt = api.model(); await corrupt.restore(); corrupt.text = "Must not overwrite saved work"
        await corrupt.ask(computer: "Example computer")
        expect(!corrupt.loaded && api.sends == oldSends, "Corrupt recovery silently became a fresh Ask")
        expect(try String(contentsOf: files[0], encoding: .utf8) == "broken", "Corrupt recovery was removed")
        let refusedAPI = AskFixture(root.appendingPathComponent("refused"))
        refusedAPI.refuse = true
        let refused = refusedAPI.model(); await refused.restore(); refused.text = "Keep the words after a stale review"
        await refused.ask(computer: "Example computer")
        expect(!refused.pending && refused.text == "Keep the words after a stale review", "A definite host validation refusal trapped the Ask")
        refusedAPI.refuse = false; refusedAPI.loseReply = false
        await refused.ask(computer: "Example computer")
        expect(refused.fence != nil && refusedAPI.reviews == 2, "The explicitly refused Ask could not be reviewed again")
        let unavailableRoot = root.appendingPathComponent("unavailable")
        let unavailableAPI = AskFixture(unavailableRoot)
        let blocked = unavailableAPI.model(); await blocked.restore(); blocked.text = "Never send before saving"
        let backup = root.appendingPathComponent("backup")
        try FileManager.default.moveItem(at: unavailableRoot, to: backup)
        try Data("not a directory".utf8).write(to: unavailableRoot)
        await blocked.ask(computer: "Example computer")
        expect(unavailableAPI.sends == 0, "A failed durable save still sent paid work")
        let record = try TeamAskRecord(input: refusedAPI.first!)
        let otherReceipt = JSONValue.object(["receipt": .object(["shareId": .string("other-share"), "clientMessageId": record.input["clientMessageId"]!, "state": .string("succeeded"), "runId": .string("run_" + String(repeating: "a", count: 32))])])
        expect(!record.terminal(otherReceipt, share: refusedAPI.target.share), "A different chat's receipt retired the Ask")
        let discoveryRoot = root.appendingPathComponent("discovery")
        let discovery = TeamAskRecoveryStore(directory: discoveryRoot)
        func discoveryTarget(_ share: String, person: String? = nil, origin: String? = nil) -> TeamCommentTarget {
            .init(origin: origin ?? api.target.origin, person: person ?? api.target.person, organization: api.target.organization,
                  repository: api.target.repository, checkout: api.target.checkout, share: share, host: api.target.host)
        }
        let runningRecord = try TeamAskRecord(input: record.input, fence: api.running)
        for n in 0..<45 {
            _ = try await discovery.replace(discoveryTarget("share-\(n)"), record: runningRecord, expected: nil,
                location: TeamCommentLocation(organization: "Example team", repository: "Example project", chat: "Fictional request \(n)", computer: "Example computer"))
        }
        _ = try await discovery.replace(discoveryTarget("foreign", person: "foreign-person"), record: runningRecord, expected: nil)
        _ = try await discovery.replace(discoveryTarget("foreign", origin: "https://another.example.test"), record: runningRecord, expected: nil)
        let malformed = discoveryTarget("malformed"), discoveryFiles = TeamCommentDraftStore(directory: discoveryRoot)
        _ = try await discoveryFiles.save(malformed, text: "{}", expected: nil)
        var entries: [TeamAskRecoveryStore.Entry] = [], cursor: String?, unreadable = false
        repeat {
            let page = try await discovery.list(origin: api.target.origin, person: api.target.person, after: cursor)
            expect(page.entries.count <= 40, "Ask discovery opened an unbounded page")
            entries += page.entries; cursor = page.next; unreadable = unreadable || page.unreadable
        } while cursor != nil
        expect(entries.count == 45 && Set(entries.map(\.target)).count == 45, "Ask discovery skipped or duplicated a page")
        expect(entries.allSatisfy { $0.target.origin == api.target.origin && $0.target.person == api.target.person && $0.snapshot.record.fence == api.running }, "Ask discovery crossed accounts or lost Stop")
        let retainedMalformed = try await discoveryFiles.load(malformed)
        expect(unreadable && retainedMalformed?.text == "{}", "Malformed discovery removed saved work")
        expect(try await discovery.list(origin: api.target.origin, person: "foreign-person").entries.count == 1, "Foreign recovery was removed")
        print("Team Ask durable recovery and bounded account-local discovery tests passed")
    }
}
