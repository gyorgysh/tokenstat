// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TeamCommentModel.swift TeamCommentDraftStore.swift TeamStore.swift TeamModels.swift WorkReference.swift JSONValue.swift.
import Foundation

private actor CommentAPI {
    var sends: [JSONValue] = []
    var accepted: [String: JSONValue] = [:]
    var loseReply = false
    var wrongShare = false
    var delay = false
    var waiter: CheckedContinuation<JSONValue, Error>?
    func api() -> TeamAPI { TeamAPI { method, params, _ in try await self.call(method, params) } }
    func configure(loseReply: Bool = false, wrongShare: Bool = false, delay: Bool = false) { self.loseReply = loseReply; self.wrongShare = wrongShare; self.delay = delay }
    func waiting() -> Bool { waiter != nil }
    func release() { waiter?.resume(returning: accepted.values.first!); waiter = nil }
    func count() -> Int { sends.count }
    func call(_ method: TeamHostMethod, _ params: JSONValue) async throws -> JSONValue {
        guard case let .object(body) = params else { fatalError("Fixture request must be an object") }
        switch method {
        case .capabilities: return .object(["enabled":.bool(true),"ready":.bool(true),"authorizationRequired":.bool(false),"version":.int(1),"actorId":.string("fixture-person")])
        case .directory:
            if body["operation"] == .string("inbox.list") { return .object(["invitations":.array([]),"nextOffset":.null]) }
            return .object(["organizations":.array([.object(["id":.string("org_fixture"),"slug":.string("fixture"),"name":.string("Fixture studio"),"ownerId":.string("fixture-person"),"role":.string("owner"),"revision":.int(1),"epoch":.int(1),"state":.string("active"),"eligible":.bool(true),"membershipRevision":.int(1),"createdAt":.string("2026-01-01T00:00:00Z")])]),"nextOffset":.null])
        case .commentSend:
            sends.append(params)
            guard case let .object(input)? = body["input"], case let .string(id)? = input["clientMessageId"], case let .object(target)? = body["target"], let share = target["share"] else { fatalError("Missing exact comment attempt") }
            let receipt = accepted[id] ?? .object(["receipt":.object(["shareId":share,"clientMessageId":.string(id),"state":.string("accepted"),"sequence":.int(42),"acceptedAtMs":.int(1792500000100)])])
            accepted[id] = receipt
            if delay { return try await withCheckedThrowingContinuation { waiter = $0 } }
            if loseReply { throw TeamRequestFailure(code: "delivery_unknown", message: "Fictional reply interrupted") }
            return receipt
        case .connectionCall:
            guard body["method"] == .string("team.chat.receipt"), case let .object(query)? = body["params"], case let .string(id)? = query["clientMessageId"], let receipt = accepted[id] else { fatalError("Receipt check did not use the saved attempt") }
            if wrongShare { return .object(["receipt":.object(["shareId":.string("share_other"),"clientMessageId":.string(id),"state":.string("accepted"),"sequence":.int(42),"acceptedAtMs":.int(1792500000100)])]) }
            return receipt
        default: fatalError("Unexpected fixture method")
        }
    }
}
@main struct TeamCommentModelTests {
    static func expect(_ value: Bool, _ message: String) { precondition(value, message) }
    @MainActor private static func session(_ fixture: CommentAPI, _ storage: TeamCommentDraftStore) async -> (TeamStore, TeamCommentModel) {
        let owner = TeamAccountOwner(scope: .account(origin: "https://accounts.example.test", handle: "fixture-person")!, generation: 1, session: "fixture")
        let store = TeamStore(api: await fixture.api()); await store.bind(to: owner); store.select(store.organizations[0])
        let target = TeamCommentTarget(origin: owner.scope.origin, person: "fixture-person", organization: "org_fixture", repository: "repo_fixture", checkout: "checkout_fixture", share: "share_fixture", host: String(repeating: "ab", count: 32))
        let model = TeamCommentModel(target: target, store: store, context: store.mutationContext!, storage: storage)
        await model.restore()
        return (store, model)
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("team-comment-model-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = CommentAPI(), storage = TeamCommentDraftStore(directory: root)
        let (store, model) = await session(fixture, storage)
        let mismatched = TeamCommentTarget(origin: model.target.origin, person: model.target.person, organization: "org_other", repository: model.target.repository, checkout: model.target.checkout, share: model.target.share, host: model.target.host)
        let wrongScope = TeamCommentModel(target: mismatched, store: store, context: store.mutationContext!, storage: storage)
        await wrongScope.restore(); wrongScope.edit("Wrong organization"); await wrongScope.send()
        expect(!wrongScope.loaded && !wrongScope.current, "A mismatched repository escaped its captured organization form")
        expect(await fixture.count() == 0, "A mismatched organization reached the comment API")
        model.edit("A fictional comment")
        await fixture.configure(loseReply: true)
        await model.send()
        expect(model.pending && model.text == "A fictional comment", "Unknown delivery discarded the original draft")
        expect(await fixture.count() == 1, "The mutation was automatically replayed")
        let original = model.draft!
        model.edit("Do not replace uncertain content")
        expect(model.draft == original && model.text == original.text, "An uncertain attempt was edited")
        let restored = TeamCommentModel(target: model.target, store: store, context: store.mutationContext!, storage: TeamCommentDraftStore(directory: root))
        await restored.restore()
        expect(restored.draft == original && restored.pending, "Relaunch did not restore the exact attempt")
        expect(await fixture.count() == 1, "Restoring a draft sent it")
        await fixture.configure(wrongShare: true)
        await restored.checkDelivery()
        expect(restored.pending && restored.text == original.text, "A different share's receipt cleared the draft")
        await fixture.configure()
        await restored.checkDelivery()
        expect(restored.text.isEmpty && !restored.pending && restored.acceptedRevision == 1, "Own accepted receipt did not settle the draft")
        expect(try await storage.load(model.target) == nil, "Accepted writing stayed on disk")
        // The first window still owns an old receipt. A late check must not
        // remove words a second window started after acceptance.
        restored.edit("Later writing"); try await restored.flush()
        await model.checkDelivery()
        expect(model.pending, "A stale window silently discarded its unresolved local state")
        expect(try await storage.load(model.target)?.text == "Later writing", "Late acknowledgement removed a newer draft")
        do { _ = try await storage.save(model.target, text: "Unposted words from another window", expected: original); preconditionFailure("Stale edit replaced the saved draft") } catch TeamCommentDraftFailure.changed {}
        let recovered = TeamCommentModel(target: model.target, store: store, context: store.mutationContext!, storage: storage)
        await recovered.restore()
        expect(recovered.text == "Later writing" && recovered.copyText == "Unposted words from another window", "Conflicting writing was merged into another window's saved attempt")
        expect(!recovered.canSend && recovered.hasUnsavedWriting, "An unreconciled draft conflict could be sent")
        await recovered.reloadSavedDraft()
        expect(recovered.text == "Later writing" && recovered.recoveredText == nil, "Explicit saved-version review did not settle the local conflict")
        let callsBefore = await fixture.count()
        store.select(nil)
        await model.send(); await model.checkDelivery()
        expect(await fixture.count() == callsBefore, "An old organization view sent a request")
        // A successful late network response still belongs to its old form.
        let otherRoot = root.appendingPathComponent("late"), otherStorage = TeamCommentDraftStore(directory: otherRoot), delayed = CommentAPI()
        let (otherStore, other) = await session(delayed, otherStorage)
        other.edit("Original organization")
        await delayed.configure(delay: true)
        let sending = Task { await other.send() }
        let deadline = Date().addingTimeInterval(3)
        while !(await delayed.waiting()) { precondition(Date() < deadline); await Task.yield() }
        let pending = other.draft!
        otherStore.select(nil); await delayed.release(); await sending.value
        expect(other.acceptedRevision == 0 && other.draft == pending, "Late response changed a retired view")
        expect(try await otherStorage.load(other.target) == pending, "Late response erased the original scoped attempt")
        print("Team comments keep uncertain attempts, validate receipts and fence late organization responses")
    }
}
