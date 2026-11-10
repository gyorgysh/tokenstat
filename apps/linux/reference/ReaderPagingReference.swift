// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

// The original complete newest/earlier/tail methods run below. Selection setup
// and publication are inert adapters; no projector, outgoing, cache or GUI owner
// is claimed by this harness.
enum BridgeError: Error, LocalizedError {
    case core(String, String)
    var errorDescription: String? { switch self { case let .core(_, message): message } }
}
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var readingScope = "fixture-account"
}
struct FixtureReadingMark {}
@MainActor final class ChatReadingStore {
    static let shared = ChatReadingStore()
    func mark(for reference: WorkReference) -> FixtureReadingMark? { nil }
    func request(_ mark: FixtureReadingMark, for reference: WorkReference) {}
}
@MainActor enum Bridge {
    static var model: PagingModel!
    static var responses: [[String: Any]] = []
    static var calls: [[String: Any]] = []
    static func reply<T: Decodable>(_ method: String, _ params: [String: Any], as: T.Type) throws -> T {
        calls.append(["method": method, "params": params])
        guard !responses.isEmpty else { fatalError("unplanned request \(method)") }
        let response = responses.removeFirst()
        if let select = response["select"] as? String { model.selectFixture(select, fresh: false) }
        if let revision = response["revision"] as? NSNumber { model.selected?.sendRevision = revision.uint64Value }
        if response["epoch"] as? Bool == true { model.eventsEpoch &+= 1 }
        if response["retire"] as? Bool == true { model.continuityScope = "retired" }
        if response["ownerChanged"] as? Bool == true { throw CancellationError() }
        if let error = response["error"] as? String { throw BridgeError.core(response["unknown"] as? Bool == true ? "unknown_method" : "fixture", error) }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: response["value"]!))
    }
    /* SOURCE_PAGE_BRIDGE */
    /* SOURCE_CHUNK_BRIDGE */
    static func chatInvoke<T: Decodable>(peer: String?, _ method: String, _ params: [String: Any], as: T.Type) async throws -> T {
        try reply(method, params, as: T.self)
    }
}
@MainActor final class PagingModel {
    var selected: ChatConversation?
    var selectionGeneration: UInt64 = 0
    var continuityScope = "fixture-account"
    var eventsEpoch: UInt64 = 0
    var windowReplacementTicket: UUID?
    var liveWindowLoaded = false
    var contextRevision: UInt64?
    var events: [ChatTimelineEvent] = []
    var offset: UInt64 = 0
    var tailCursor: String?
    var earlierCursor: String?
    var hasEarlier = false
    var historyTrimmed = false
    var reachedStart = false
    var loadingEarlier = false
    var earlierInFlight = false
    var conversationUsage: ChatUsageTotals?
    var usageThrough: UInt64?
    var pagingUnavailable = false
    var openingConversation = false
    var savedCopy: String?
    var peer: String?
    var error: String?
    var readingRestorationPulse: UInt64 = 0
    var currentReference: WorkReference? { nil }
    func warmMarkdown() {}
    func settleNotifications() {}
    func reconcileOutgoing() {}
    func keepOfflineCopy(id: String, title: String?, page: ChatEventPage, sendRevision: UInt64?) {}
    func scheduleResponseAttachments(id: String, generation: UInt64) {}
    func publishEvents(id: String, generation: UInt64, canPublish: () -> Bool = { true }, rebasesWindow: Bool = true,
                       transform: ([ChatTimelineEvent]) -> [ChatTimelineEvent]) async -> Bool {
        guard selectionMatches(id: id, generation: generation), canPublish() else { return false }
        events = transform(events)
        return true
    }
    func openEvents(id: String, generation: UInt64, quiet: Bool = false) async -> Bool {
        await readOpeningEvents(id: id, generation: generation, quiet: quiet)
    }
    func selectFixture(_ id: String, fresh: Bool) {
        selectionGeneration &+= 1
        selected = try! JSONDecoder().decode(ChatConversation.self, from: JSONSerialization.data(withJSONObject:
            ["id": id, "workspaceId": "folder", "title": "Synthetic", "backend": "fixture", "sendRevision": 3]))
        events = []
        forgetWindow()
        openingConversation = !fresh
        if fresh { liveWindowLoaded = true; contextRevision = selected?.sendRevision; openingConversation = false }
    }
    /* SOURCE_WINDOW_METHODS */
    func action(_ action: [String: Any]) async {
        switch action["op"] as! String {
        case "select": selectFixture(action["id"] as! String, fresh: action["fresh"] as? Bool ?? false)
        case "revision": selected?.sendRevision = (action["value"] as! NSNumber).uint64Value
        default:
            Bridge.responses = action["responses"] as? [[String: Any]] ?? []
            guard let id = selected?.id else { fatalError("missing selection") }
            let generation = selectionGeneration
            let quiet = action["quiet"] as? Bool ?? false
            switch action["op"] as! String {
            case "open":
                openingConversation = true
                _ = await openEvents(id: id, generation: generation, quiet: quiet)
                if generation == selectionGeneration { openingConversation = false }
            case "tail": _ = await loadEvents(id: id, reset: false, generation: generation, quiet: quiet)
            case "earlier": await loadEarlier(id: id, generation: generation, quiet: quiet)
            default: fatalError("unknown action")
            }
            precondition(Bridge.responses.isEmpty, "unused responses")
        }
    }
    func snapshot() -> [String: Any] {
        func json<T: Encodable>(_ value: T?) -> Any {
            guard let value else { return NSNull() }
            return try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
        }
        return ["selected": selected?.id as Any? ?? NSNull(), "events": json(events), "opening": openingConversation,
                "liveLoaded": liveWindowLoaded, "pagingUnavailable": pagingUnavailable, "offset": offset,
                "tailCursor": tailCursor as Any? ?? NSNull(), "earlierCursor": earlierCursor as Any? ?? NSNull(),
                "hasEarlier": hasEarlier, "loadingEarlier": loadingEarlier, "reachedStart": reachedStart,
                "historyTrimmed": historyTrimmed, "usage": json(conversationUsage), "usageThrough": json(usageThrough),
                "contextRevision": json(contextRevision), "error": error as Any? ?? NSNull(), "calls": Bridge.calls]
    }
}
@MainActor func pagingReference(_ traces: [[String: Any]]) async -> [[[String: Any]]] {
    var output: [[[String: Any]]] = []
    for trace in traces {
        let model = PagingModel()
        Bridge.model = model
        Bridge.calls = []
        var checkpoints: [[String: Any]] = []
        for action in trace["actions"] as! [[String: Any]] {
            await model.action(action)
            checkpoints.append(model.snapshot())
        }
        output.append(checkpoints)
    }
    return output
}
