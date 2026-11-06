#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production relay approval wait across cancellation and replacement."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatFileTransferControls.swift').read_text()
methods = source[source.index('extension ChatModel {'):source.index('\nstruct ChatFileTransferControls:')]
harness = r'''import Foundation
struct WorkReference: Equatable { let id: String }
enum WorkCacheAccess { static func canSave(_ reference: WorkReference) -> Bool { true } }
@MainActor final class ChatModel {
    var selectionGeneration: UInt64 = 0
    var savedCopy: Bool?
    var currentReference = WorkReference(id: "chat")
    var fileRelayName: String?
    var fileRelaySize: UInt64?
    var fileRelayRemaining: UInt64?
    var fileRelayAnswer: CheckedContinuation<Bool, Never>?
    var fileRelayTicket: UUID?
    var fileTransferCancelled = false
    var fileTransferProgress: Double = 0
    var fileTransferName: String?
}
''' + methods + r'''
@main struct Check {
    @MainActor static func waitForPrompt(_ model: ChatModel) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fileRelayAnswer == nil {
            precondition(ContinuousClock.now < deadline, "Relay prompt must appear")
            await Task.yield()
        }
    }
    @MainActor static func main() async {
        let model = ChatModel()
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await model.confirmFileRelay(name: "cancelled", size: 123)
        }
        let preCancelledAnswer = await preCancelled.value
        precondition(!preCancelledAnswer && model.fileRelayName == nil && model.fileRelayAnswer == nil)
        let cancelled = Task { await model.confirmFileRelay(name: "old", size: 123) }
        await waitForPrompt(model)
        let oldTicket = model.fileRelayTicket!
        cancelled.cancel()
        let cancelledAnswer = await cancelled.value
        precondition(!cancelledAnswer && model.fileRelayAnswer == nil && model.fileRelayName == nil)
        let current = Task { await model.confirmFileRelay(name: "current", size: 456, remaining: 789) }
        await waitForPrompt(model)
        model.answerFileRelay(false, request: oldTicket)
        precondition(model.fileRelayName == "current" && model.fileRelayAnswer != nil,
            "An old cancellation must not close a newer relay prompt")
        precondition(model.fileRelaySize == 456 && model.fileRelayRemaining == 789)
        let duplicate = await model.confirmFileRelay(name: "duplicate", size: 1)
        precondition(!duplicate && model.fileRelayName == "current")
        model.answerFileRelay(true)
        let approved = await current.value
        precondition(approved && model.fileRelayName == nil && model.fileRelayTicket == nil)
        for change in ["selection", "saved", "none", "decline"] {
            model.savedCopy = nil
            let stale = Task { await model.confirmFileRelay(name: "stale", size: nil) }
            await waitForPrompt(model)
            if change == "selection" { model.selectionGeneration += 1 }
            if change == "saved" { model.savedCopy = true }
            model.answerFileRelay(change != "decline")
            let answer = await stale.value
            precondition(answer == (change == "none"))
        }
        print("Relay approval: cancellation resumes the waiter, old tickets preserve newer prompts, approval and selection guards remain intact")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-relay-cancellation-') as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(harness)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True, timeout=15)
