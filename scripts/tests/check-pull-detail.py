#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production pull-detail read model against controlled responses."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'apps/mac/Sources/Features/Workspaces/Pulls/PullDetailView.swift').read_text()
start = source.index('@MainActor @Observable\nprivate final class PullDetailModel')
end = source.index('    func beginReview(', start)
model = source[start:end] + '}\n'
harness = r'''
import Foundation
import Observation
struct PullDetail { var body = ""; var headRef = "branch"; var title: String }
struct PullTimelineEvent { var body: String? }
struct PullTimelinePage { var events: [PullTimelineEvent]; var nextCursor: String? }
struct FileDiff { var path: String }
enum PullDetailTab { case conversation, changes }
enum PullReviewVerdict { case approve }
enum PullMergeMethod { case squash }
enum Failure: Error { case offline }
enum MarkdownText { static func warm(_ text: [String]) {} }
@MainActor enum Bridge {
    static var details: [CheckedContinuation<PullDetail, Error>] = []
    static var timelines: [CheckedContinuation<PullTimelinePage, Error>] = []
    static var diffs: [CheckedContinuation<[FileDiff], Error>] = []
    static func pullView(workspaceID: String, peer: String?, number: UInt32, refresh: Bool) async throws -> PullDetail {
        try await withCheckedThrowingContinuation { details.append($0) }
    }
    static func pullTimeline(workspaceID: String, peer: String?, number: UInt32, cursor: String? = nil, refresh: Bool = false) async throws -> PullTimelinePage {
        try await withCheckedThrowingContinuation { timelines.append($0) }
    }
    static func pullDiff(workspaceID: String, peer: String?, number: UInt32, refresh: Bool) async throws -> [FileDiff] {
        try await withCheckedThrowingContinuation { diffs.append($0) }
    }
}
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
        print("Pull detail: partial failures, overlapping refresh, pagination and diff retention passed")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(harness + model + checks)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
