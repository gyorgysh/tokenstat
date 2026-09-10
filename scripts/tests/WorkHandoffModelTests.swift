// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkHandoffModel.swift, WorkHandoff.swift and WorkReference.swift.
import Foundation

@main struct WorkHandoffModelTests {
    enum Failure: Error { case lostReply }

    @MainActor static func main() async {
        let reference = WorkReference(scope: .local(installationID: "test"),
            hostIdentity: "host", workspaceID: "folder", kind: .conversation, itemID: "chat")
        let mine = WorkSharedDraft(text: "My unsent words", attachmentIDs: ["attachment-one"])
        let theirs = WorkSharedDraft(text: "Their unsent words", attachmentIDs: [])
        func record(_ revision: UInt64, _ draft: WorkSharedDraft?) -> WorkHandoff {
            WorkHandoff(revision: revision, requestID: "other-share", deviceID: "other",
                deviceName: "Studio", updatedAtMs: 1000, draft: draft, anchor: nil)
        }

        var requests: [WorkHandoffRequest] = []
        var reads = 0
        let retry = WorkHandoffModel(reference: reference, ownsDestination: { true }, fetch: {
            reads += 1
            return nil
        }, put: { request in
            requests.append(request)
            if requests.count == 1 { throw Failure.lostReply }
            return .saved(WorkHandoff(revision: 1, requestID: request.requestID,
                deviceID: "phone", deviceName: request.deviceName, updatedAtMs: 1000,
                draft: request.draft, anchor: request.anchor))
        })
        await retry.share(deviceName: "Phone", draft: mine, anchor: nil)
        assert(requests.isEmpty) // Never assume an unread slot is revision zero.
        await retry.load()
        await retry.share(deviceName: "Phone", draft: mine, anchor: nil)
        assert(retry.canRetryShare && retry.pending?.draft == mine)
        await retry.load()
        await retry.share(deviceName: "Phone", draft: theirs, anchor: nil)
        assert(reads == 1 && requests.count == 1) // Uncertain write cannot be rebased or changed.
        await retry.retryShare()
        assert(requests.count == 2 && requests[0] == requests[1])
        assert(retry.phase == .shared && retry.pending == nil && retry.shared?.draft == mine)

        requests = []
        let conflict = WorkHandoffModel(reference: reference, ownsDestination: { true },
            fetch: { record(4, theirs) }, put: { request in
                requests.append(request)
                return .conflict(record(UInt64(4 + requests.count), theirs))
            })
        await conflict.load()
        await conflict.share(deviceName: "Phone", draft: mine, anchor: nil)
        assert(conflict.phase == .conflict && conflict.shared?.draft == theirs)
        assert(conflict.pending?.draft == mine && !conflict.canRetryShare)
        await conflict.retryShare()
        assert(requests.count == 1)
        await conflict.shareMyVersion()
        assert(requests.count == 2 && requests[0].requestID != requests[1].requestID)
        assert(requests[0].expectedRevision == 4 && requests[1].expectedRevision == 5)
        assert(requests[1].draft == mine && conflict.phase == .conflict)
        conflict.keepMine()
        assert(conflict.pending == nil && conflict.shared?.draft == theirs && conflict.canShare)

        var owns = true
        let stale = WorkHandoffModel(reference: reference, ownsDestination: { owns }, fetch: {
            owns = false // Account/selection changes while the host answers.
            return record(9, theirs)
        }, put: { _ in fatalError("An invalidated destination must never write") })
        await stale.load()
        assert(stale.phase == .invalidated && stale.shared == nil)
        owns = true
        await stale.load()
        await stale.share(deviceName: "Phone", draft: mine, anchor: nil)
        assert(stale.phase == .invalidated)

        var resume: CheckedContinuation<WorkHandoffResult, Never>?
        let delayed = WorkHandoffModel(reference: reference, ownsDestination: { true },
            fetch: { nil }, put: { _ in
                await withCheckedContinuation { resume = $0 }
            })
        await delayed.load()
        let task = Task { await delayed.share(deviceName: "Phone", draft: mine, anchor: nil) }
        while resume == nil { await Task.yield() }
        assert(delayed.isBusy)
        await delayed.share(deviceName: "Phone", draft: theirs, anchor: nil)
        assert(delayed.pending?.draft == mine)
        delayed.invalidate()
        resume?.resume(returning: .saved(record(1, mine)))
        await task.value
        assert(delayed.phase == .invalidated && delayed.shared == nil && delayed.pending == nil)
        print("Handoff model: exact retries, conflict preservation/rebase, ownership and late replies passed")
    }
}
