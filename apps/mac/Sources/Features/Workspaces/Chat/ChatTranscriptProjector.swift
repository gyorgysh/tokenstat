// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

actor ChatTranscriptProjector {
    func project(_ events: [ChatTimelineEvent], backend: String?, running: Bool) throws -> [ChatDisplayItem] {
        try Task.checkCancellation()
        let rows = ChatDisplayItem.coalesce(events, defaultBackend: backend, running: running)
        try Task.checkCancellation()
        return rows
    }
}
