// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// A partial page can begin halfway through a streamed message. Once older
/// deltas are loaded its visible row uses an earlier start, but the marked
/// archive event still belongs to that same readable message.
enum ChatReadingAnchor {
    static func resolve(_ eventID: String, items: [ChatDisplayItem], events: [ChatTimelineEvent]) -> String? {
        if items.contains(where: { $0.id == eventID }) { return eventID }
        for (prefix, kind) in [("text-s", "text"), ("think-s", "thinking")] where eventID.hasPrefix(prefix) {
            guard let position = UInt64(eventID.dropFirst(prefix.count)),
                  events.contains(where: { $0.seq == position && $0.event?.kind == kind }) else { return nil }
            return items.first { row in
                guard row.id.hasPrefix(prefix), let start = UInt64(row.id.dropFirst(prefix.count)),
                      let end = row.lastSequence else { return false }
                return start <= position && position <= end
            }?.id
        }
        return nil
    }
}
