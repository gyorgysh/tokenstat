// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// The host returns its own local scope. Only a verified response from the
/// expected machine may be adopted into the currently owned client session.
/// No account identifier is supplied as authority to the remote host.
enum WorkSearchLive {
    enum Invalid: Error { case response }

    struct Highlight: Codable, Sendable {
        let location: Int
        let length: Int
    }

    struct Hit: Codable, Sendable {
        let source: String
        let reference: WorkReference
        let revision: String
        let folderName: String
        let title: String
        let excerpt: String
        let highlights: [Highlight]
        let score: Int
        let updatedAtMs: Int64
        let partial: Bool
    }

    struct Coverage: Codable, Sendable {
        let searched: Int
        let unreadable: Int
        let partial: Bool
    }

    struct Response: Codable, Sendable {
        let hits: [Hit]
        let nextCursor: String?
        let coverage: Coverage
    }

    struct Result: Sendable {
        let reference: WorkReference
        let revision: String
        let folderName: String
        let title: String
        let excerpt: WorkSearchText.Excerpt
        let score: Int
        let updatedAt: Date
        let partial: Bool
    }

    struct Page: Sendable {
        let hits: [Result]
        let nextCursor: String?
        let coverage: Coverage
    }

    static func decode(_ data: Data, expectedHost: String, scope: WorkReference.Scope,
                       kinds: Set<WorkReference.Kind> = [], workspaceIDs: Set<String> = [],
                       limit: Int = 50) throws -> Page {
        guard data.count <= 2 * 1024 * 1024, !expectedHost.isEmpty, (1...50).contains(limit),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.hits.count <= limit, response.coverage.searched >= 0,
              response.coverage.unreadable >= 0,
              response.coverage.searched >= response.hits.count,
              response.coverage.unreadable == 0 || response.coverage.partial,
              response.nextCursor.map(validCursor) ?? true else { throw Invalid.response }
        var destinations = Set<WorkReference>()
        let hits = try response.hits.map { hit -> Result in
            let reference = hit.reference
            guard hit.source == "live", reference.hostIdentity == expectedHost,
                  reference.scope == .local(installationID: expectedHost),
                  reference.kind == .workspace || reference.kind == .conversation,
                  kinds.isEmpty || kinds.contains(reference.kind),
                  validID(reference.workspaceID),
                  workspaceIDs.isEmpty || workspaceIDs.contains(reference.workspaceID),
                  !hit.folderName.isEmpty, hit.folderName.utf8.count <= 16 * 1024,
                  hit.title.utf8.count <= 16 * 1024, hit.revision.utf8.count <= 256,
                  hit.excerpt.count <= WorkSearchText.maximumExcerptCharacters,
                  hit.excerpt.utf8.count <= 16 * 1024,
                  hit.score >= 0, hit.score <= Int(UInt32.max) else { throw Invalid.response }
            if reference.kind == .workspace {
                guard reference.itemID == nil, reference.anchor == nil else { throw Invalid.response }
            } else {
                guard reference.itemID.map(validID) == true,
                      reference.anchor.map(validAnchor) ?? true else { throw Invalid.response }
            }
            let adopted = WorkReference(scope: scope, hostIdentity: expectedHost,
                workspaceID: reference.workspaceID, kind: reference.kind,
                itemID: reference.itemID, anchor: reference.anchor)
            var destination = adopted
            destination.anchor = nil
            guard destinations.insert(destination).inserted else { throw Invalid.response }
            var previousEnd = 0
            let highlights = try hit.highlights.map { highlight -> NSRange in
                let count = hit.excerpt.utf16.count
                guard highlight.location >= previousEnd, highlight.length > 0,
                      highlight.location <= count, highlight.length <= count - highlight.location else {
                    throw Invalid.response
                }
                let range = NSRange(location: highlight.location, length: highlight.length)
                guard let indices = Range(range, in: hit.excerpt),
                      hit.excerpt.indices.contains(indices.lowerBound),
                      indices.upperBound == hit.excerpt.endIndex || hit.excerpt.indices.contains(indices.upperBound) else {
                    throw Invalid.response
                }
                previousEnd = highlight.location + highlight.length
                return range
            }
            return Result(reference: adopted, revision: hit.revision, folderName: hit.folderName, title: hit.title,
                excerpt: .init(text: hit.excerpt, highlights: highlights), score: hit.score,
                updatedAt: Date(timeIntervalSince1970: Double(hit.updatedAtMs) / 1000), partial: hit.partial)
        }
        return Page(hits: hits, nextCursor: response.nextCursor, coverage: response.coverage)
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validCursor(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func validAnchor(_ value: String) -> Bool {
        for prefix in ["user-s", "text-s", "think-s", "handoff-s"] where value.hasPrefix(prefix) {
            let suffix = value.dropFirst(prefix.count)
            return !suffix.isEmpty && suffix.utf8.allSatisfy { (48...57).contains($0) } && UInt64(suffix) != nil
        }
        return false
    }
}
