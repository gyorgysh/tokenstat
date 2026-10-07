// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// One CPU projection at a time per reader, away from the UI executor.
/// Callers publish only after checking their selection and window revision.
actor ChatTranscriptProjector {
    func project(_ events: [ChatTimelineEvent], backend: String?, running: Bool) throws -> [ChatDisplayItem] {
        try Task.checkCancellation()
        let rows = ChatDisplayItem.coalesce(events, defaultBackend: backend, running: running)
        try Task.checkCancellation()
        return rows
    }
}
