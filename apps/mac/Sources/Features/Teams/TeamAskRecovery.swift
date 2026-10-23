// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// The original Ask stays immutable even after its running reply arrives.
/// Replaying it is the host's idempotent recovery path, never a fresh review.
struct TeamAskRecord: Codable, Equatable, Sendable {
    let version: Int
    let input: [String: JSONValue]
    let fence: JSONValue?

    init(input: [String: JSONValue], fence: JSONValue? = nil) throws {
        version = 1; self.input = input; self.fence = fence
        try validate()
    }
    var text: String { if case let .string(value)? = input["text"] { return value }; return "" }
    private static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validFence(_ fence: JSONValue) -> Bool {
        guard case let .object(fields) = fence, fields.count == 2,
              case let .string(id)? = fields["runId"], id.hasPrefix("run_"), hex(String(id.dropFirst(4)), count: 32),
              case let .string(incarnation)? = fields["incarnation"], hex(incarnation, count: 64) else { return false }
        return true
    }
    func validate() throws {
        guard version == 1, Set(input.keys) == ["text", "review", "clientMessageId", "clientMessageCreatedAtMs"],
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 8192,
              case let .string(review)? = input["review"], Self.hex(review, count: 64),
              case let .string(id)? = input["clientMessageId"], UUID(uuidString: id) != nil,
              case let .int(time)? = input["clientMessageCreatedAtMs"], time > 0,
              try JSONEncoder().encode(input).count <= 14 * 1024,
              fence.map(Self.validFence) ?? true else { throw TeamAskRecoveryFailure.unconfirmed }
    }
    /// Only a bound, terminal receipt can retire an Ask without a run fence.
    func terminal(_ response: JSONValue, share: String) -> Bool {
        guard case let .object(body) = response, case let .object(receipt)? = body["receipt"],
              receipt["shareId"] == .string(share), receipt["clientMessageId"] == input["clientMessageId"],
              case let .string(state)? = receipt["state"], ["notStarted", "succeeded", "failed", "stopped", "recovered"].contains(state),
              case let .string(run)? = receipt["runId"], run.hasPrefix("run_"), Self.hex(String(run.dropFirst(4)), count: 32) else { return false }
        return true
    }
}

struct TeamAskNotAccepted: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum TeamAskRecoveryFailure: LocalizedError {
    case unavailable, unconfirmed
    var errorDescription: String? { L10n.text(self == .unavailable ? "common.teams.ask_save_failed" : "common.teams.ask_unconfirmed") }
}

/// Reuse the local draft store's locked, atomic CAS files, in a separate
/// directory. These envelopes are never Comment attempts or send payloads.
actor TeamAskRecoveryStore {
    static let shared = TeamAskRecoveryStore()
    struct Snapshot: Sendable { let saved: TeamCommentDraft; let record: TeamAskRecord }
    private let files: TeamCommentDraftStore
    init(directory: URL? = nil) {
        files = TeamCommentDraftStore(directory: directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tokenstat-team-asks", isDirectory: true))
    }
    func load(_ target: TeamCommentTarget) async throws -> Snapshot? {
        guard let saved = try await files.load(target) else { return nil }
        guard saved.attempt == nil else { throw TeamAskRecoveryFailure.unavailable }
        let record = try JSONDecoder().decode(TeamAskRecord.self, from: Data(saved.text.utf8))
        try record.validate()
        return Snapshot(saved: saved, record: record)
    }
    func replace(_ target: TeamCommentTarget, record: TeamAskRecord?, expected: Snapshot?, location: TeamCommentLocation? = nil) async throws -> Snapshot? {
        try record?.validate()
        let value = try record.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? ""
        do {
            let saved = try await files.save(target, text: value, expected: expected?.saved, location: location)
            guard let saved, let record else { return nil }
            return Snapshot(saved: saved, record: record)
        } catch TeamCommentDraftFailure.changed {
            // Another window may have persisted this same reply, or a prior
            // delete may have succeeded before its fsync reported failure.
            let current = try await load(target)
            if current?.record == record { return current }
            throw TeamCommentDraftFailure.changed
        }
    }
}
