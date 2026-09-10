// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift WorkSearchText.swift WorkSearchIndex.swift.
import Foundation

actor SearchCancellationGate {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; observer?.resume(); observer = nil
        await withCheckedContinuation { waiting = $0 }
    }
    func started() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func release() { waiting?.resume(); waiting = nil }
}

@main struct WorkSearchRankingTests {
    static func main() async throws {
        let scope = WorkReference.Scope.local(installationID: "ranking")
        let folder = WorkSearchIndex.Folder(hostIdentity: "host", workspaceID: "folder")
        let index = WorkSearchIndex(scope: scope, folders: [folder])
        var corpus: [WorkSearchIndex.Document] = []
        func root(_ reference: WorkReference) -> WorkReference { var copy = reference; copy.anchor = nil; return copy }
        func key(_ reference: WorkReference) -> String {
            [reference.hostIdentity, reference.workspaceID, reference.kind.rawValue, reference.itemID ?? "", reference.anchor ?? ""]
                .map(WorkReferenceKey.encode).joined(separator: "|")
        }
        for conversation in 0..<60 {
            let reference = WorkReference(scope: scope, hostIdentity: "host", workspaceID: "folder", kind: .conversation, itemID: "chat-\(conversation)")
            let documents = (0..<17).map { message -> WorkSearchIndex.Document in
                var reference = reference
                reference.anchor = message == 0 ? nil : "user-s\(message)"
                return .init(reference: reference, revision: "r1",
                    title: message % 3 == 0 ? "Needle title" : "Other title",
                    text: String(repeating: "Useful context. ", count: 20) + (message % 4 == 0 ? "needle café detail" : "ordinary text"),
                    folderName: conversation % 2 == 0 ? "Folder needle" : "Project",
                    machineName: "Machine", updatedAt: Date(timeIntervalSince1970: Double(message % 5)), partial: false)
            }
            corpus += documents
            let load = await index.beginLoad(reference)!
            let accepted = await index.replace(load, documents: documents.reversed())
            assert(accepted)
        }
        for raw in ["needle", "café", "needle café", "title", "detail needle", "machine", "folder", "missing"] {
            let query = try WorkSearchQuery(raw)
            // Exhaustive prior ranking: scan every record, sort, then dedupe.
            // This deliberately does not use the optimized matching helper.
            var expected: [(WorkSearchIndex.Document, Int)] = []
            for document in corpus {
                func contains(_ text: String, _ term: String) -> Bool {
                    WorkSearchText.normalize(text).range(of: term, options: .literal) != nil
                }
                var score = 0
                var matches = true
                for term in query.terms {
                    let title = contains(document.title, term)
                    let body = contains(document.text, term)
                    if title || body { score += (title ? 8 : 0) + (body ? 4 : 0) }
                    else if contains(document.folderName, term) || contains(document.machineName, term) { score += 1 }
                    else { matches = false; break }
                }
                if matches { expected.append((document, score)) }
            }
            expected.sort {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                if $0.0.updatedAt != $1.0.updatedAt { return $0.0.updatedAt > $1.0.updatedAt }
                return key($0.0.reference) < key($1.0.reference)
            }
            var seen = Set<WorkReference>()
            expected = expected.filter { seen.insert(root($0.0.reference)).inserted }
            let actual = try await index.search(query)
            assert(actual.total == expected.count)
            assert(actual.hits.map(\.reference) == expected.prefix(50).map { $0.0.reference })
            assert(actual.hits.map(\.score) == expected.prefix(50).map { $0.1 })
        }
        let reference = root(corpus[0].reference)
        let load = await index.beginLoad(reference)!
        let gate = SearchCancellationGate()
        let replacement = Task { await gate.pause(); return await index.replace(load, documents: []) }
        await gate.started()
        replacement.cancel()
        await gate.release()
        let accepted = await replacement.value
        assert(!accepted, "Canceled rebuild cannot replace existing searchable work")
        let remaining = try await index.search(try WorkSearchQuery("needle"))
        assert(remaining.total == 60)
        let searchGate = SearchCancellationGate()
        let searching = Task { await searchGate.pause(); return try await index.search(WorkSearchQuery("needle")) }
        await searchGate.started()
        searching.cancel()
        await searchGate.release()
        do { _ = try await searching.value; assertionFailure("Canceled search returned results") } catch is CancellationError {}
        print("Search ranking: exhaustive score/date/anchor equivalence, metadata fallback, Unicode and cancellation passed")
    }
}
