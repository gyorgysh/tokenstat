#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production pull-detail read model against controlled responses."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'apps/mac/Sources/Features/Workspaces/Pulls/PullDetailView.swift').read_text()
start = source.index('@MainActor @Observable\nfinal class PullDetailModel')
end = source.index('    func beginReview(', start)
action_start = source.index('    private func perform(', end)
action_end = source.index('\n}', action_start)
# Expose only this production action helper to the fixture so a delayed write
# can be completed after the account changes.
action = source[action_start:action_end].replace('    private func perform(', '    func perform(', 1)
draft_actions = source[end:source.index('    func ready(', end)]
checkout = source[source.index('    func checkout(', end):action_start]
model = source[start:end] + draft_actions + checkout + action + '\n}\n'
harness = r'''
import Foundation
import Observation
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var generation: UInt64 = 1
}
struct PullDetail { var body = ""; var headRef = "branch"; var title: String }
struct PullTimelineEvent { var body: String? }
struct PullTimelinePage { var events: [PullTimelineEvent]; var nextCursor: String? }
struct FileDiff { var path: String }
enum PullDetailTab { case conversation, changes }
enum PullReviewVerdict { case approve, requestChanges, comment }
enum PullMergeMethod { case squash }
struct CheckoutResult { var ok: Bool; var message: String }
enum Failure: LocalizedError {
    case offline, revoked
    var errorDescription: String? {
        self == .revoked ? "GitHub rejected the request: access was not granted" : "Offline"
    }
}
enum L10n { static func text(_ key: String, _ args: String...) -> String { key + args.joined() } }
enum MarkdownText { static func warm(_ text: [String]) {} }
@MainActor enum Bridge {
    static var details: [CheckedContinuation<PullDetail, Error>] = []
    static var timelines: [CheckedContinuation<PullTimelinePage, Error>] = []
    static var diffs: [CheckedContinuation<[FileDiff], Error>] = []
    static var writes: [CheckedContinuation<Void, Error>] = []
    static var checkouts: [CheckedContinuation<CheckoutResult, Error>] = []
    static var checkoutBranch: String?
    static func pullView(workspaceID: String, peer: String?, number: UInt32, refresh: Bool) async throws -> PullDetail {
        try await withCheckedThrowingContinuation { details.append($0) }
    }
    static func pullTimeline(workspaceID: String, peer: String?, number: UInt32, cursor: String? = nil, refresh: Bool = false) async throws -> PullTimelinePage {
        try await withCheckedThrowingContinuation { timelines.append($0) }
    }
    static func pullDiff(workspaceID: String, peer: String?, number: UInt32, refresh: Bool) async throws -> [FileDiff] {
        try await withCheckedThrowingContinuation { diffs.append($0) }
    }
    static func pullComment(workspaceID: String, peer: String?, number: UInt32, body: String) async throws {
        try await withCheckedThrowingContinuation { writes.append($0) }
    }
    static func pullReview(workspaceID: String, peer: String?, number: UInt32, verdict: PullReviewVerdict, body: String) async throws {
        try await withCheckedThrowingContinuation { writes.append($0) }
    }
    static func pullCheckout(workspaceID: String, peer: String?, number: UInt32, branch: String) async throws -> CheckoutResult {
        checkoutBranch = branch
        return try await withCheckedThrowingContinuation { checkouts.append($0) }
    }
}
@MainActor enum PendingAction { static var reply: CheckedContinuation<Void, Error>? }
'''
checks = r'''
@main struct Check {
    @MainActor static func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<10000 { if condition() { return }; await Task.yield() }
        fatalError("Timed out waiting for request")
    }
    static func page(_ body: String, _ cursor: String? = nil) -> PullTimelinePage {
        PullTimelinePage(events: [.init(body: body)], nextCursor: cursor)
    }
    @MainActor static func main() async {
        let model = PullDetailModel()
        let first = Task { await model.load(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 1 }
        Bridge.details.removeFirst().resume(returning: .init(title: "First"))
        Bridge.timelines.removeFirst().resume(throwing: Failure.offline)
        await first.value
        precondition(model.detail?.title == "First" && model.error == nil && model.timelineError != nil)

        let retry = Task { await model.load(workspaceID: "repo", peer: "host", number: 1, refresh: true) }
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 1 }
        Bridge.details.removeFirst().resume(throwing: Failure.offline)
        Bridge.timelines.removeFirst().resume(returning: page("new", "older"))
        await retry.value
        precondition(model.detail?.title == "First" && model.error != nil && model.events.first?.body == "new" && model.timelineError == nil)

        let older = Task { await model.load(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 1 }
        let newer = Task { await model.load(workspaceID: "repo", peer: "host", number: 1, refresh: true) }
        await waitFor { Bridge.details.count == 2 && Bridge.timelines.count == 2 }
        Bridge.details.removeLast().resume(returning: .init(title: "Newest"))
        Bridge.timelines.removeLast().resume(returning: page("newest", "older"))
        await newer.value
        Bridge.details.removeFirst().resume(returning: .init(title: "Obsolete"))
        Bridge.timelines.removeFirst().resume(returning: page("obsolete"))
        await older.value
        precondition(model.detail?.title == "Newest" && model.events.first?.body == "newest" && !model.loading)
        precondition(model.canReuseDetails)
        await model.open(workspaceID: "repo", peer: "host", number: 1)
        precondition(Bridge.details.isEmpty && Bridge.timelines.isEmpty)
        model.timelineError = "Offline"
        precondition(!model.canReuseDetails)
        model.timelineError = nil

        let pageBeforeLeave = Task { await model.moreTimeline(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.timelines.count == 1 }
        Bridge.timelines.removeFirst().resume(returning: page("later", "another"))
        await pageBeforeLeave.value
        precondition(model.events.count == 2 && model.nextCursor == "another")
        let repeatedPage = Task { await model.moreTimeline(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.timelines.count == 1 }
        Bridge.timelines.removeFirst().resume(returning: page("duplicate", "another"))
        await repeatedPage.value
        precondition(model.events.count == 2 && model.nextCursor == "another" && model.timelineError != nil,
                     "a repeated cursor must not duplicate events or loop")
        model.commentDraft = "keep draft"
        model.prepareForCache()
        precondition(model.events.count == 1 && model.nextCursor == "older" && model.commentDraft == "keep draft")

        let more = Task { await model.moreTimeline(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.timelines.count == 1 }
        let refresh = Task { await model.load(workspaceID: "repo", peer: "host", number: 1, refresh: true) }
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 2 }
        Bridge.details.removeFirst().resume(returning: .init(title: "Refreshed"))
        Bridge.timelines.removeLast().resume(returning: page("refreshed"))
        await refresh.value
        Bridge.timelines.removeFirst().resume(returning: page("stale page"))
        await more.value
        precondition(model.events.count == 1 && model.events.first?.body == "refreshed" && !model.loadingTimeline)

        let oldDiff = Task { await model.loadDiff(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.diffs.count == 1 }
        let newDiff = Task { await model.loadDiff(workspaceID: "repo", peer: "host", number: 1, refresh: true) }
        await waitFor { Bridge.diffs.count == 2 }
        Bridge.diffs.removeLast().resume(returning: [.init(path: "new")])
        await newDiff.value
        Bridge.diffs.removeFirst().resume(returning: [.init(path: "old")])
        await oldDiff.value
        precondition(model.diffs.first?.path == "new" && model.selectedPath == "new" && !model.loadingDiff)
        let failedDiff = Task { await model.loadDiff(workspaceID: "repo", peer: "host", number: 1, refresh: true) }
        await waitFor { Bridge.diffs.count == 1 }
        Bridge.diffs.removeFirst().resume(throwing: Failure.offline)
        await failedDiff.value
        precondition(model.diffs.first?.path == "new" && model.diffError != nil)
        model.diffError = "GitHub rejected the request: HTTP 406: {\"field\":\"diff\",\"code\":\"too_large\"}"
        precondition(model.displayDiffError == "apple.pulldetailview.diff_too_large")
        model.diffError = "Network unavailable"
        precondition(model.displayDiffError == "Network unavailable")
        model.prepareForCache()
        precondition(model.diffs.isEmpty && !model.didLoadDiff && model.selectedPath == "new")
        let emptyDiff = Task { await model.loadDiff(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.diffs.count == 1 }
        Bridge.diffs.removeFirst().resume(returning: [])
        await emptyDiff.value
        await model.loadDiff(workspaceID: "repo", peer: "host", number: 1)
        precondition(model.didLoadDiff && Bridge.diffs.isEmpty)
        let detached = Task { await model.load(workspaceID: "repo", peer: "host", number: 1, refresh: true) }
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 1 }
        model.prepareForCache()
        precondition(!model.canReuseDetails)
        Bridge.details.removeFirst().resume(returning: .init(title: "Late response"))
        Bridge.timelines.removeFirst().resume(returning: page("late"))
        await detached.value
        precondition(model.detail?.title == "Refreshed" && model.events.first?.body == "refreshed" && !model.loading)
        let revoked = Task { await model.load(workspaceID: "repo", peer: "host", number: 1, refresh: true) }
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 1 }
        Bridge.details.removeFirst().resume(throwing: Failure.revoked)
        Bridge.timelines.removeFirst().resume(returning: page("must not return"))
        await revoked.value
        precondition(model.accessLost && model.detail == nil && model.events.isEmpty && model.error != nil && !model.loading)
        let old = PullDetailModel()
        let oldRead = Task { await old.load(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 1 }
        WorkSessionContext.shared.generation += 1
        Bridge.details.removeFirst().resume(returning: .init(title: "Other account"))
        Bridge.timelines.removeFirst().resume(returning: page("other account"))
        await oldRead.value
        precondition(old.detail == nil && old.events.isEmpty && !old.loading && !old.canReuseDetails)
        await old.open(workspaceID: "repo", peer: "host", number: 1)
        precondition(Bridge.details.isEmpty && Bridge.timelines.isEmpty)
        let paged = PullDetailModel()
        let initial = Task { await paged.load(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 1 }
        Bridge.details.removeFirst().resume(returning: .init(title: "Original"))
        Bridge.timelines.removeFirst().resume(returning: page("original", "older"))
        await initial.value
        let oldPage = Task { await paged.moreTimeline(workspaceID: "repo", peer: "host", number: 1) }
        let oldDiffAfterSwitch = Task { await paged.loadDiff(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.timelines.count == 1 && Bridge.diffs.count == 1 }
        WorkSessionContext.shared.generation += 1
        Bridge.timelines.removeFirst().resume(returning: page("wrong account"))
        Bridge.diffs.removeFirst().resume(throwing: Failure.revoked)
        await oldPage.value; await oldDiffAfterSwitch.value
        precondition(paged.events.count == 1 && paged.events[0].body == "original"
            && paged.diffs.isEmpty && !paged.accessLost && !paged.loadingTimeline && !paged.loadingDiff)
        let writer = PullDetailModel()
        let write = Task {
            await writer.perform("Done", refresh: true, workspaceID: "repo", peer: "host", number: 1) {
                try await withCheckedThrowingContinuation { PendingAction.reply = $0 }
            }
        }
        await waitFor { PendingAction.reply != nil }
        WorkSessionContext.shared.generation += 1
        PendingAction.reply?.resume(); PendingAction.reply = nil
        let succeeded = await write.value
        precondition(!succeeded && writer.actionNotice == nil && !writer.actionBusy)
        precondition(Bridge.details.isEmpty && Bridge.timelines.isEmpty,
                     "a retired action must not launch a refresh in the next account")
        let refreshingWriter = PullDetailModel()
        let refreshingWrite = Task {
            await refreshingWriter.perform("Done", refresh: true, workspaceID: "repo", peer: "host", number: 1) {}
        }
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 1 }
        WorkSessionContext.shared.generation += 1
        Bridge.details.removeFirst().resume(returning: .init(title: "Retired"))
        Bridge.timelines.removeFirst().resume(returning: page("retired"))
        let refreshedInCurrentSession = await refreshingWrite.value
        precondition(!refreshedInCurrentSession && refreshingWriter.detail == nil && refreshingWriter.events.isEmpty)
        let leaving = PullDetailModel()
        let ready = Task { await leaving.load(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 1 }
        Bridge.details.removeFirst().resume(returning: .init(title: "Before write"))
        Bridge.timelines.removeFirst().resume(returning: page("before write"))
        await ready.value
        precondition(leaving.canReuseDetails)
        let leavingWrite = Task {
            await leaving.perform("Done", refresh: true, workspaceID: "repo", peer: "host", number: 1) {
                try await withCheckedThrowingContinuation { PendingAction.reply = $0 }
            }
        }
        await waitFor { PendingAction.reply != nil }
        leaving.prepareForCache()
        let reopened = Task { await leaving.open(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 1 }
        Bridge.details.removeFirst().resume(returning: .init(title: "While writing"))
        Bridge.timelines.removeFirst().resume(returning: page("while writing"))
        await reopened.value
        PendingAction.reply?.resume(); PendingAction.reply = nil
        let finishedAfterLeaving = await leavingWrite.value
        precondition(finishedAfterLeaving && leaving.actionNotice == "Done" && !leaving.actionBusy && !leaving.canReuseDetails,
                     "a confirmed write keeps its outcome after returning to the same account")
        precondition(Bridge.details.isEmpty && Bridge.timelines.isEmpty,
                     "a retired view does not refresh until it is opened again")
        let losingAccess = PullDetailModel()
        let pendingWrite = Task {
            await losingAccess.perform("Done", refresh: true, workspaceID: "repo", peer: "host", number: 1) {
                try await withCheckedThrowingContinuation { PendingAction.reply = $0 }
            }
        }
        await waitFor { PendingAction.reply != nil }
        let accessRead = Task { await losingAccess.load(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 1 }
        Bridge.details.removeFirst().resume(throwing: Failure.revoked)
        Bridge.timelines.removeFirst().resume(returning: page("inaccessible"))
        await accessRead.value
        PendingAction.reply?.resume(); PendingAction.reply = nil
        let doneAfterRevocation = await pendingWrite.value
        precondition(doneAfterRevocation && losingAccess.accessLost && losingAccess.detail == nil)
        precondition(Bridge.details.isEmpty && Bridge.timelines.isEmpty,
                     "a write finishing after access loss cannot restart reads")
        let drafts = PullDetailModel()
        drafts.commentDraft = "sent comment"
        let comment = Task { await drafts.comment(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.writes.count == 1 }
        drafts.commentDraft = "new comment"
        Bridge.writes.removeFirst().resume()
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 1 }
        Bridge.details.removeFirst().resume(returning: .init(title: "After comment"))
        Bridge.timelines.removeFirst().resume(returning: page("after comment"))
        await comment.value
        precondition(drafts.commentDraft == "new comment", "a late post cannot erase a newer draft")
        let unchanged = Task { await drafts.comment(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.writes.count == 1 }
        Bridge.writes.removeFirst().resume()
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 1 }
        Bridge.details.removeFirst().resume(returning: .init(title: "Posted"))
        Bridge.timelines.removeFirst().resume(returning: page("posted"))
        await unchanged.value
        precondition(drafts.commentDraft.isEmpty, "the submitted draft clears when it is unchanged")
        drafts.beginReview(.comment); drafts.reviewDraft = "sent review"
        let review = Task { await drafts.review(.comment, workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.writes.count == 1 }
        drafts.reviewDraft = "new review"
        Bridge.writes.removeFirst().resume()
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 1 }
        Bridge.details.removeFirst().resume(returning: .init(title: "After review"))
        Bridge.timelines.removeFirst().resume(returning: page("after review"))
        await review.value
        precondition(drafts.reviewMode == .comment && drafts.reviewDraft == "new review")
        let approve = Task { await drafts.review(.approve, workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.writes.count == 1 }
        Bridge.writes.removeFirst().resume()
        await waitFor { Bridge.details.count == 1 && Bridge.timelines.count == 1 }
        Bridge.details.removeFirst().resume(returning: .init(title: "Approved"))
        Bridge.timelines.removeFirst().resume(returning: page("approved"))
        await approve.value
        precondition(drafts.reviewMode == .comment && drafts.reviewDraft == "new review",
                     "approving does not discard an unrelated review draft")
        drafts.checkoutBranch = "original-branch"
        let checkout = Task { await drafts.checkout(workspaceID: "repo", peer: "host", number: 1) }
        await waitFor { Bridge.checkouts.count == 1 }
        drafts.checkoutBranch = "new-branch"
        Bridge.checkouts.removeFirst().resume(returning: .init(ok: true, message: ""))
        await checkout.value
        precondition(Bridge.checkoutBranch == "original-branch" && drafts.checkoutBranch == "new-branch"
            && drafts.actionNotice?.contains("original-branch") == true,
            "checkout feedback names the branch actually submitted")
        print("Pull detail: partial failures, overlapping refresh, pagination and diff retention passed")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(harness + model + checks)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
