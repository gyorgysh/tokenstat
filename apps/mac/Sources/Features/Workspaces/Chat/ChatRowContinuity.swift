// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

/// Keep a streamed block's identity when an older page brings its start.
///
/// A text or thinking block is named after its first delta. A conversation
/// opens on its newest records, so a long reply is often cut by the page
/// boundary, and the page that brings its earlier deltas renames it: the
/// same reply, a new id. SwiftUI then sees one row removed and another
/// inserted. Everything holding the old id loses it, the reader's anchor
/// included, and the transcript lands at the top of the page it just loaded.
/// That was most pages of a chat made of long replies.
///
/// A block's true start only ever moves earlier, so the block that now
/// covers where an old one started is that block. It keeps the old id.
enum ChatRowContinuity {
    static func carry(_ next: [ChatDisplayItem], from previous: [ChatDisplayItem]) -> [ChatDisplayItem] {
        carrying(next, from: previous).rows
    }

    /// The rows, and the ids of the blocks that grew at their start. A reader
    /// inside one of those keeps their place by its bottom edge, because the
    /// text before theirs grew and the text after did not.
    static func carrying(_ next: [ChatDisplayItem], from previous: [ChatDisplayItem])
        -> (rows: [ChatDisplayItem], extendedAtStart: Set<String>) {
        guard !previous.isEmpty, !next.isEmpty else { return (next, []) }
        // A block that already carries an older id and grew again keeps its
        // id without help, and still grew at its start.
        var previousStart: [String: UInt64] = [:]
        for row in previous where kind(row) != nil { previousStart[row.id] = row.firstSequence }
        var grown = Set<String>()
        for row in next where kind(row) != nil {
            if let was = previousStart[row.id] ?? nil, let now = row.firstSequence, now < was { grown.insert(row.id) }
        }
        // Fast path: nothing renamed. The common case on every streamed token.
        let previousIDs = Set(previous.map(\.id))
        guard next.contains(where: { (kind($0) != nil || call($0) != nil) && !previousIDs.contains($0.id) })
        else { return (next, grown) }

        var starts: [String: [(start: UInt64, id: String)]] = [:]
        for row in previous {
            guard let kind = kind(row), let start = row.firstSequence else { continue }
            starts[kind, default: []].append((start, row.id))
        }
        // A tool call cut by the page boundary arrives as its end alone and is
        // named after that. The page with its start names it after the start.
        var calls: [String: String] = [:]
        for row in previous { if let call = call(row) { calls[call] = calls[call] ?? row.id } }
        guard !starts.isEmpty || !calls.isEmpty else { return (next, grown) }
        let nextIDs = Set(next.map(\.id))
        var claimed = Set<String>()
        var carried = next
        for index in carried.indices {
            let row = carried[index]
            guard !previousIDs.contains(row.id), let call = call(row), let old = calls[call],
                  old != row.id, !nextIDs.contains(old), !claimed.contains(old) else { continue }
            claimed.insert(old)
            carried[index] = row.carrying(id: old)
        }
        let toolCarries = claimed
        for index in carried.indices {
            let row = carried[index]
            guard !previousIDs.contains(row.id), let kind = kind(row),
                  let first = row.firstSequence, let last = row.lastSequence,
                  let match = starts[kind]?.first(where: { candidate in
                      first <= candidate.start && candidate.start <= last
                          && candidate.id != row.id && !nextIDs.contains(candidate.id)
                          && !claimed.contains(candidate.id)
                  }) else { continue }
            claimed.insert(match.id)
            carried[index] = row.carrying(id: match.id)
        }
        return (carried, claimed.subtracting(toolCarries).union(grown))
    }

    /// A tool row's call, scoped by backend: two agents can reuse an id.
    private static func call(_ row: ChatDisplayItem) -> String? {
        guard case let .tool(tool) = row.kind, !tool.callId.isEmpty else { return nil }
        return (row.sourceBackend ?? "") + "|" + tool.callId
    }

    private static func kind(_ row: ChatDisplayItem) -> String? {
        switch row.kind {
        case .assistant: return "text"
        case .thinking: return "think"
        default: return nil
        }
    }
}
