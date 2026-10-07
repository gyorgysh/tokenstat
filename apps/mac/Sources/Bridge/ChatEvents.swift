// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct ChatTimelineEvent: Codable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey {
        case kind, text, seq, atMs, backend, event, approval, to, brief
        case recordID = "id"
        case question, options, multiple, blocking, delivery
        case defaultAnswer = "default"
        case questionID = "questionId"
        /// The spelling the archive itself holds. A host new enough writes
        /// both; one that is not writes only this. Read, never written.
        case atMsLegacy = "at_ms"
    }

    var kind: String
    var text: String?
    /// Where this record starts in the conversation's archive.
    ///
    /// A name for the row that does not change when an older page is loaded
    /// in front of it, which is what lets the transcript hold its place and
    /// VoiceOver hold its focus across a prepend. Absent from a host older
    /// than paging, and then the old positional identity is used instead.
    var seq: UInt64?
    var atMs: Int64?
    var backend: String?
    var event: ChatAgentEvent?
    var approval: ChatApproval?
    /// Handoff only: the agent picking the conversation up, and the summary it
    /// was given. Recorded in the timeline rather than hidden, because it is
    /// text tokenstat put in front of somebody's agent on their behalf.
    var to: String?
    var brief: String?
    /// Question only: the agent's question, its choices, and what it goes
    /// with if nobody answers. `recordID` names the question.
    var recordID: String?
    var question: String?
    var options: [String]?
    var multiple: Bool?
    var defaultAnswer: String?
    var blocking: Bool?
    /// Answer only: which question, and how the answer was sent on.
    var questionID: String?
    var delivery: String?
    var id: String {
        "\(kind)-\(atMs ?? 0)-\(text ?? event?.delta ?? event?.verb ?? event?.status ?? approval?.id ?? to ?? "event")"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        seq = try c.decodeIfPresent(UInt64.self, forKey: .seq)
        atMs = try c.decodeIfPresent(Int64.self, forKey: .atMs)
            ?? c.decodeIfPresent(Int64.self, forKey: .atMsLegacy)
        backend = try c.decodeIfPresent(String.self, forKey: .backend)
        event = try c.decodeIfPresent(ChatAgentEvent.self, forKey: .event)
        approval = try c.decodeIfPresent(ChatApproval.self, forKey: .approval)
        to = try c.decodeIfPresent(String.self, forKey: .to)
        brief = try c.decodeIfPresent(String.self, forKey: .brief)
        recordID = try c.decodeIfPresent(String.self, forKey: .recordID)
        question = try c.decodeIfPresent(String.self, forKey: .question)
        options = try c.decodeIfPresent([String].self, forKey: .options)
        multiple = try c.decodeIfPresent(Bool.self, forKey: .multiple)
        defaultAnswer = try c.decodeIfPresent(String.self, forKey: .defaultAnswer)
        blocking = try c.decodeIfPresent(Bool.self, forKey: .blocking)
        questionID = try c.decodeIfPresent(String.self, forKey: .questionID)
        delivery = try c.decodeIfPresent(String.self, forKey: .delivery)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(seq, forKey: .seq)
        try c.encodeIfPresent(atMs, forKey: .atMs)
        try c.encodeIfPresent(backend, forKey: .backend)
        try c.encodeIfPresent(event, forKey: .event)
        try c.encodeIfPresent(approval, forKey: .approval)
        try c.encodeIfPresent(to, forKey: .to)
        try c.encodeIfPresent(brief, forKey: .brief)
        try c.encodeIfPresent(recordID, forKey: .recordID)
        try c.encodeIfPresent(question, forKey: .question)
        try c.encodeIfPresent(options, forKey: .options)
        try c.encodeIfPresent(multiple, forKey: .multiple)
        try c.encodeIfPresent(defaultAnswer, forKey: .defaultAnswer)
        try c.encodeIfPresent(blocking, forKey: .blocking)
        try c.encodeIfPresent(questionID, forKey: .questionID)
        try c.encodeIfPresent(delivery, forKey: .delivery)
    }
}


struct ChatAgentEvent: Codable, Sendable {
    var kind: String
    var delta: String?
    var verb: String?
    var target: String?
    var path: String?
    var added: UInt32?
    var removed: UInt32?
    var patch: String?
    var status: String?
    var text: String?
    /// Token count on `usage`. Tool calls send `input` as an object, which
    /// this field ignores so the row can still decode.
    var input: UInt64?
    var output: UInt64?
    var costUsd: Double?
    var callId: String?
    var ok: Bool?
    var detail: String?
    var cacheRead: UInt64?
    var cacheWrite: UInt64?
    var exitCode: Int32?
    var id: String?
    var name: String?
    var mediaType: String?
    var size: UInt64?

    enum CodingKeys: String, CodingKey {
        case kind, delta, verb, target, path, added, removed, patch, status, text
        case input, output, costUsd, callId, ok, detail, cacheRead, cacheWrite, exitCode
        case id, name, mediaType, size
        // The spellings the archive itself holds. A host new enough writes
        // both, and one that is not writes only these. Read, never written.
        case callIdLegacy = "call_id"
        case cacheReadLegacy = "cache_read"
        case cacheWriteLegacy = "cache_write"
        case costUsdLegacy = "cost_usd"
        case exitCodeLegacy = "exit_code"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        delta = try c.decodeIfPresent(String.self, forKey: .delta)
        verb = try c.decodeIfPresent(String.self, forKey: .verb)
        target = try c.decodeIfPresent(String.self, forKey: .target)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        added = try c.decodeIfPresent(UInt32.self, forKey: .added)
        removed = try c.decodeIfPresent(UInt32.self, forKey: .removed)
        patch = try c.decodeIfPresent(String.self, forKey: .patch)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        input = c.decodeCount(forKey: .input)
        output = c.decodeCount(forKey: .output)
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd)
            ?? c.decodeIfPresent(Double.self, forKey: .costUsdLegacy)
        callId = try c.decodeIfPresent(String.self, forKey: .callId)
            ?? c.decodeIfPresent(String.self, forKey: .callIdLegacy)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        cacheRead = c.decodeCount(forKey: .cacheRead) ?? c.decodeCount(forKey: .cacheReadLegacy)
        cacheWrite = c.decodeCount(forKey: .cacheWrite) ?? c.decodeCount(forKey: .cacheWriteLegacy)
        exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
            ?? c.decodeIfPresent(Int32.self, forKey: .exitCodeLegacy)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        mediaType = try c.decodeIfPresent(String.self, forKey: .mediaType)
        size = c.decodeCount(forKey: .size)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(delta, forKey: .delta)
        try c.encodeIfPresent(verb, forKey: .verb)
        try c.encodeIfPresent(target, forKey: .target)
        try c.encodeIfPresent(path, forKey: .path)
        try c.encodeIfPresent(added, forKey: .added)
        try c.encodeIfPresent(removed, forKey: .removed)
        try c.encodeIfPresent(patch, forKey: .patch)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(input, forKey: .input)
        try c.encodeIfPresent(output, forKey: .output)
        try c.encodeIfPresent(costUsd, forKey: .costUsd)
        try c.encodeIfPresent(callId, forKey: .callId)
        try c.encodeIfPresent(ok, forKey: .ok)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(cacheRead, forKey: .cacheRead)
        try c.encodeIfPresent(cacheWrite, forKey: .cacheWrite)
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(mediaType, forKey: .mediaType)
        try c.encodeIfPresent(size, forKey: .size)
    }
}

private extension KeyedDecodingContainer where K == ChatAgentEvent.CodingKeys {
    /// Usage counters are numbers. Tool `input` is an object. Never throw.
    func decodeCount(forKey key: K) -> UInt64? {
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key), value >= 0 {
            return UInt64(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value >= 0 {
            return UInt64(value)
        }
        return nil
    }
}
