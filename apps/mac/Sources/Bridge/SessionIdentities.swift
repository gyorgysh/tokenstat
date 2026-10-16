// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Verified native identifiers are metadata, never opaque authentication or
/// resume blobs. Hosts omit this object when they cannot report identifiers.
struct SessionIdentities: Codable, Sendable, Hashable {
    struct Record: Codable, Sendable, Hashable {
        var backend = ""
        var id = ""
        var status = "historical"
        var sourceConversationId: String?
        var firstSeenAtMs: Int64?
        var lastSeenAtMs: Int64?

        private enum CodingKeys: String, CodingKey {
            case backend, id, status, sourceConversationId, firstSeenAtMs, lastSeenAtMs
        }
        init(from decoder: Decoder) throws {
            // Optional decoration must not break the surrounding chat/terminal
            // if a newer host adds an unfamiliar record shape.
            guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
            backend = (try? c.decode(String.self, forKey: .backend)) ?? ""
            id = (try? c.decode(String.self, forKey: .id)) ?? ""
            status = (try? c.decode(String.self, forKey: .status)) ?? "historical"
            sourceConversationId = try? c.decode(String.self, forKey: .sourceConversationId)
            firstSeenAtMs = try? c.decode(Int64.self, forKey: .firstSeenAtMs)
            lastSeenAtMs = try? c.decode(Int64.self, forKey: .lastSeenAtMs)
        }
    }
    var entries: [Record] = []
    var total: UInt64 = 0
    var truncated = false
    var archivePath: String?
    var transcriptPath: String?

    private enum CodingKeys: String, CodingKey { case entries, total, truncated, archivePath, transcriptPath }
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        entries = (try? c.decode([Record].self, forKey: .entries)) ?? []
        total = (try? c.decode(UInt64.self, forKey: .total)) ?? UInt64(entries.count)
        truncated = (try? c.decode(Bool.self, forKey: .truncated)) ?? false
        archivePath = try? c.decode(String.self, forKey: .archivePath)
        transcriptPath = try? c.decode(String.self, forKey: .transcriptPath)
    }
}

/// Presentation preserves the host's current/saved/historical distinction.
/// Local UI UUIDs and pending PTY placeholders are never offered as host IDs.
struct SessionIdentityEntry: Identifiable, Equatable {
    enum Kind: String { case conversation, terminal, current, saved, historical, sourceConversation }
    let kind: Kind
    let value: String
    var backend: String? = nil
    var id: String { kind.rawValue + "|" + (backend ?? "") + "|" + value }
    var isHistorical: Bool { kind == .saved || kind == .historical || kind == .sourceConversation }
    var isNative: Bool { kind == .current || kind == .saved || kind == .historical }
}

enum SessionIdentityPresentation {
    static func entries(localID: String?, kind: SessionIdentityEntry.Kind, sessions: SessionIdentities?) -> [SessionIdentityEntry] {
        var result: [SessionIdentityEntry] = []
        if let localID, usable(localID), !localID.hasPrefix("pending-") {
            result.append(.init(kind: kind, value: localID))
        }
        var recorded: [String: SessionIdentities.Record] = [:]
        for entry in sessions?.entries ?? [] where usable(entry.id) && usable(entry.backend) {
            let key = entry.backend + "|" + entry.id
            if let previous = recorded[key], rank(previous.status) <= rank(entry.status) { continue }
            recorded[key] = entry
        }
        let ordered = recorded.values.sorted {
            let a = rank($0.status), b = rank($1.status)
            if a != b { return a < b }
            if $0.lastSeenAtMs != $1.lastSeenAtMs { return ($0.lastSeenAtMs ?? 0) > ($1.lastSeenAtMs ?? 0) }
            if $0.backend != $1.backend { return $0.backend < $1.backend }
            return $0.id < $1.id
        }
        for entry in ordered {
            let role: SessionIdentityEntry.Kind = entry.status == "current" ? .current : entry.status == "saved" ? .saved : .historical
            result.append(.init(kind: role, value: entry.id, backend: entry.backend))
        }
        var sources: Set<String> = []
        for entry in sessions?.entries ?? [] where usable(entry.id) && usable(entry.backend) {
            if let source = entry.sourceConversationId, usable(source), source != localID, sources.insert(source).inserted {
                result.append(.init(kind: .sourceConversation, value: source))
            }
        }
        return result
    }
    private static func rank(_ status: String) -> Int { status == "current" ? 0 : status == "saved" ? 1 : 2 }
    private static func usable(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 4096
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
