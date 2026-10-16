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
        var reportedCount = 0
        if var records = try? c.nestedUnkeyedContainer(forKey: .entries) {
            reportedCount = records.count ?? 0
            while !records.isAtEnd, entries.count < 256 {
                entries.append(try records.decode(Record.self))
            }
        }
        total = (try? c.decode(UInt64.self, forKey: .total)) ?? UInt64(max(reportedCount, entries.count))
        truncated = ((try? c.decode(Bool.self, forKey: .truncated)) ?? false)
            || reportedCount > 256 || total > UInt64(min(entries.count, 64))
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
        if let localID, validReference(localID), !localID.hasPrefix("pending-") {
            result.append(.init(kind: kind, value: localID))
        }
        var recorded: [String: SessionIdentities.Record] = [:]
        for entry in (sessions?.entries ?? []).prefix(256) where validNativeID(backend: entry.backend, id: entry.id) {
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
        for entry in ordered.prefix(64) {
            let role: SessionIdentityEntry.Kind = entry.status == "current" ? .current : entry.status == "saved" ? .saved : .historical
            result.append(.init(kind: role, value: entry.id, backend: entry.backend))
        }
        var sources: Set<String> = []
        for entry in (sessions?.entries ?? []).prefix(256) where validNativeID(backend: entry.backend, id: entry.id) {
            if let source = entry.sourceConversationId, validReference(source), source != localID, sources.count < 64, sources.insert(source).inserted {
                result.append(.init(kind: .sourceConversation, value: source))
            }
        }
        return result
    }
    private static func rank(_ status: String) -> Int { status == "current" ? 0 : status == "saved" ? 1 : 2 }
    /// Match the host's verified native-ID projection. Arbitrary resume or
    /// authorization objects cannot become copyable IDs through optional data.
    static func validNativeID(backend: String, id: String) -> Bool {
        if backend == "opencode" || backend == "opencode2" {
            let bytes = Array(id.utf8)
            guard bytes.count == 30, bytes.starts(with: Array("ses_".utf8)) else { return false }
            let hexadecimal = Set("0123456789abcdefABCDEF".utf8)
            let base62 = Set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
            return bytes[4..<16].allSatisfy(hexadecimal.contains) && bytes[16...].allSatisfy(base62.contains)
        }
        guard ["claude", "codex", "cursor", "muse", "grok", "agy"].contains(backend),
              id.utf8.count == 36, let uuid = UUID(uuidString: id),
              uuid.uuidString.lowercased() == id.lowercased() else { return false }
        return uuid.uuidString != "00000000-0000-0000-0000-000000000000"
    }
    private static func validReference(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.contains(where: { $0.isWhitespace })
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !value.contains(where: { "/\\{[".contains($0) })
    }
}
