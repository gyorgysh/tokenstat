// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum ChatReadingAnchor {
    static func resolve(_ eventID: String, items: [ChatDisplayItem], events: [ChatTimelineEvent]) -> String? {
        let eventID = eventID.hasPrefix("g:") ? String(eventID.dropFirst(2)) : eventID
        if items.contains(where: { $0.id == eventID }) { return eventID }
        for (prefix, kind) in [("text-s", "text"), ("think-s", "thinking")] where eventID.hasPrefix(prefix) {
            guard let position = UInt64(eventID.dropFirst(prefix.count)),
                  events.contains(where: { $0.seq == position && $0.event?.kind == kind }) else { return nil }
            return items.first { row in
                guard row.id.hasPrefix(prefix),
                      let start = row.firstSequence ?? UInt64(row.id.dropFirst(prefix.count)),
                      let end = row.lastSequence else { return false }
                return start <= position && position <= end
            }?.id
        }
        return nil
    }
}
