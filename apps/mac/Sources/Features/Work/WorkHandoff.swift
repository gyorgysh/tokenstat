// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Explicitly shared text and host-owned attachments, never a local outbox.
struct WorkSharedDraft: Codable, Equatable, Sendable {
    var text: String
    var attachmentIDs: [String]
    enum CodingKeys: String, CodingKey {
        case text
        case attachmentIDs = "attachmentIds"
    }
}

struct WorkHandoffAnchor: Codable, Equatable, Sendable {
    var eventID: String
    /// Basis points within the row, 0...10,000.
    var fraction: UInt16
    var followsLatest: Bool
    enum CodingKeys: String, CodingKey {
        case eventID = "eventId"
        case fraction, followsLatest
    }
}

struct WorkHandoffRequest: Codable, Equatable, Sendable {
    var requestID: String
    var expectedRevision: UInt64
    var deviceName: String
    var draft: WorkSharedDraft?
    var anchor: WorkHandoffAnchor?
    enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case expectedRevision, deviceName, draft, anchor
    }
}

struct WorkHandoff: Codable, Equatable, Sendable {
    var revision: UInt64
    var requestID: String
    var deviceID: String
    var deviceName: String
    var updatedAtMs: Int64
    var draft: WorkSharedDraft?
    var anchor: WorkHandoffAnchor?
    enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case deviceID = "deviceId"
        case revision, deviceName, updatedAtMs, draft, anchor
    }
}

enum WorkHandoffResult: Decodable, Equatable, Sendable {
    case saved(WorkHandoff)
    case conflict(WorkHandoff?)

    private enum CodingKeys: String, CodingKey { case status, handoff, current }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .status) {
        case "saved": self = .saved(try values.decode(WorkHandoff.self, forKey: .handoff))
        case "conflict": self = .conflict(try values.decodeIfPresent(WorkHandoff.self, forKey: .current))
        default:
            throw DecodingError.dataCorruptedError(forKey: .status, in: values,
                debugDescription: "Unknown handoff result")
        }
    }
}
