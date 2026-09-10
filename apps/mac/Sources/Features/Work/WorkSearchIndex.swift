// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// A disposable index. The caller supplies current access, never a filter
/// inferred from previously cached records. No text is written to disk.
actor WorkSearchIndex {
    struct Folder: Hashable, Sendable {
        let hostIdentity: String
        let workspaceID: String
    }

    struct Document: Sendable {
        let reference: WorkReference
        let revision: String
        let title: String
        let text: String
        let folderName: String
        let machineName: String
        let updatedAt: Date
        let partial: Bool
    }

    enum Source: String, Sendable { case saved = "Saved", live = "Live" }

    struct Hit: Sendable {
        var source: Source = .saved
        let reference: WorkReference
        let revision: String
        let title: WorkSearchText.Excerpt
        let excerpt: WorkSearchText.Excerpt
        let folderName: String
        let machineName: String
        let updatedAt: Date
        let partial: Bool
        let score: Int
    }

    struct Results: Sendable {
        let hits: [Hit]
        let total: Int
        let generation: UUID
        let nextCursor: Cursor?
    }

    /// Local cursors cannot be forged from a row offset or reused for a
    /// different query, filter, index instance or content generation.
    struct Cursor: Sendable {
        fileprivate let generation: UUID
        fileprivate let query: WorkSearchQuery
        fileprivate let kinds: Set<WorkReference.Kind>
        fileprivate let hosts: Set<String>
        fileprivate let offset: Int
    }

    enum PageError: Error { case staleCursor }

    /// Capture before decrypting a cache record. Removal, replacement or an
    /// access change invalidates an in-flight load, including a late success.
    struct Load: Sendable {
        fileprivate let reference: WorkReference
        fileprivate let token: UUID
    }

    private struct Entry: Sendable {
        let document: Document
        let title: WorkSearchText
        let text: WorkSearchText
        let folder: WorkSearchText
        let machine: WorkSearchText
        let key: String
    }

    private let scope: WorkReference.Scope
    private var folders: Set<Folder>
    private var entries: [WorkReference: [Entry]] = [:]
    private var loads: [WorkReference: UUID] = [:]
    private var generation = UUID()

    init(scope: WorkReference.Scope, folders: Set<Folder>) {
        self.scope = scope
        self.folders = folders
    }

    func isCurrent(generation candidate: UUID) -> Bool { generation == candidate }

    func revokeHost(_ host: String) {
        setAccess(folders.filter { $0.hostIdentity != host })
    }

    func setAccess(_ allowed: Set<Folder>) {
        folders = allowed
        entries = entries.filter { permits($0.key) }
        loads.removeAll()
        generation = UUID()
    }

    func beginLoad(_ reference: WorkReference) -> Load? {
        let reference = container(reference)
        guard permits(reference) else { return nil }
        let token = UUID()
        loads[reference] = token
        return Load(reference: reference, token: token)
    }

    @discardableResult
    func replace(_ load: Load, documents: [Document]) -> Bool {
        guard loads[load.reference] == load.token, permits(load.reference),
              documents.allSatisfy({ container($0.reference) == load.reference }) else { return false }
        var seen = Set<WorkReference>()
        let prepared = documents.filter { seen.insert($0.reference).inserted }.map { document in
            Entry(document: document, title: WorkSearchText(document.title),
                  text: WorkSearchText(document.text), folder: WorkSearchText(document.folderName),
                  machine: WorkSearchText(document.machineName), key: stableKey(document.reference))
        }
        entries[load.reference] = prepared
        loads.removeValue(forKey: load.reference)
        generation = UUID()
        return true
    }

    func remove(_ reference: WorkReference) {
        let reference = container(reference)
        entries.removeValue(forKey: reference)
        loads.removeValue(forKey: reference)
        generation = UUID()
    }

    func retainSavedWork(_ references: Set<WorkReference>) {
        entries = entries.filter { $0.key.kind == .workspace || references.contains($0.key) }
        loads = loads.filter { $0.key.kind == .workspace || references.contains($0.key) }
        generation = UUID()
    }

    func invalidateLoads() {
        loads.removeAll()
    }

    func clear() {
        entries.removeAll()
        loads.removeAll()
        generation = UUID()
    }

    func search(_ query: WorkSearchQuery, kinds: Set<WorkReference.Kind> = [],
                hosts: Set<String> = [], limit: Int = 50, cursor: Cursor? = nil) throws -> Results {
        if let cursor {
            guard cursor.generation == generation, cursor.query == query,
                  cursor.kinds == kinds, cursor.hosts == hosts else { throw PageError.staleCursor }
        }
        guard !query.terms.isEmpty else {
            return Results(hits: [], total: 0, generation: generation, nextCursor: nil)
        }
        var matches: [(entry: Entry, score: Int)] = []
        for (reference, records) in entries where permits(reference) {
            guard (kinds.isEmpty || kinds.contains(reference.kind)),
                  (hosts.isEmpty || hosts.contains(reference.hostIdentity)) else { continue }
            for entry in records {
                var score = 0
                var matchesAll = true
                for term in query.terms {
                    let titleMatch = entry.title.contains(term)
                    let textMatch = entry.text.contains(term)
                    if titleMatch || textMatch {
                        score += (titleMatch ? 8 : 0) + (textMatch ? 4 : 0)
                    } else if entry.folder.contains(term) || entry.machine.contains(term) { score += 1 }
                    else { matchesAll = false; break }
                }
                if matchesAll { matches.append((entry, score)) }
            }
        }
        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.entry.document.updatedAt != $1.entry.document.updatedAt {
                return $0.entry.document.updatedAt > $1.entry.document.updatedAt
            }
            return $0.entry.key < $1.entry.key
        }
        // One destination per conversation. A body match wins over a title
        // alone and keeps its exact message anchor. Title-only ties prefer
        // the unanchored metadata document, which sorts before message IDs.
        var destinations = Set<WorkReference>()
        matches = matches.filter { destinations.insert(container($0.entry.document.reference)).inserted }
        let offset = cursor?.offset ?? 0
        let end = min(matches.count, 200, offset + max(1, min(50, limit)))
        let hits = matches[offset..<end].map { match in
            let entry = match.entry
            let document = entry.document
            return Hit(reference: document.reference, revision: document.revision,
                       title: entry.title.excerpt(for: query), excerpt: entry.text.excerpt(for: query),
                       folderName: document.folderName, machineName: document.machineName,
                       updatedAt: document.updatedAt, partial: document.partial, score: match.score)
        }
        let next = end < min(200, matches.count)
            ? Cursor(generation: generation, query: query, kinds: kinds, hosts: hosts, offset: end) : nil
        return Results(hits: hits, total: matches.count, generation: generation, nextCursor: next)
    }

    private func permits(_ reference: WorkReference) -> Bool {
        reference.scope == scope && folders.contains(Folder(hostIdentity: reference.hostIdentity,
                                                           workspaceID: reference.workspaceID))
            && reference.kind != .terminal
    }

    private func container(_ reference: WorkReference) -> WorkReference {
        var reference = reference
        reference.anchor = nil
        return reference
    }

    private func stableKey(_ reference: WorkReference) -> String {
        [reference.hostIdentity, reference.workspaceID, reference.kind.rawValue,
         reference.itemID ?? "", reference.anchor ?? ""]
            .map(WorkReferenceKey.encode).joined(separator: "|")
    }
}
