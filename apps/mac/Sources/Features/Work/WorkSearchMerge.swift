// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// One row per destination across saved/live sources. A confirmed live match
/// replaces the saved copy of the same destination, including its message anchor.
/// The presentation separately retains selected row order while offering updates.
enum WorkSearchMerge {
    static func live(_ page: WorkSearchLive.Page, query: WorkSearchQuery,
                     machineName: String) -> [WorkSearchIndex.Hit] {
        page.hits.map { hit in
            WorkSearchIndex.Hit(source: .live, reference: hit.reference, revision: hit.revision,
                title: WorkSearchText(hit.title).excerpt(for: query), excerpt: hit.excerpt,
                folderName: hit.folderName,
                machineName: machineName, updatedAt: hit.updatedAt, partial: hit.partial, score: hit.score)
        }
    }

    static func combine(saved: [WorkSearchIndex.Hit], live: [WorkSearchIndex.Hit]) -> [WorkSearchIndex.Hit] {
        var destinations: [WorkReference: WorkSearchIndex.Hit] = [:]
        for hit in saved + live {
            let key = WorkSearchResultOrder.destination(hit.reference)
            if let previous = destinations[key] {
                if previous.source == .live && hit.source == .saved { continue }
                if previous.source == hit.source {
                    if previous.score > hit.score { continue }
                    if previous.score == hit.score && previous.updatedAt > hit.updatedAt { continue }
                    if previous.score == hit.score && previous.updatedAt == hit.updatedAt && stableKey(previous.reference) <= stableKey(hit.reference) { continue }
                }
            }
            destinations[key] = hit
        }
        return Array(destinations.values.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
            return stableKey(left.reference) < stableKey(right.reference)
        }.prefix(200))
    }

    private static func stableKey(_ reference: WorkReference) -> String {
        [reference.scope.kind.rawValue, reference.scope.origin, reference.scope.identity,
         reference.hostIdentity, reference.workspaceID, reference.kind.rawValue,
         reference.itemID ?? "", reference.anchor ?? ""].map(WorkReferenceKey.encode).joined(separator: "|")
    }
}
