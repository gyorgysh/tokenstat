#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production activity reader across owner and refresh races."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatActivityView.swift').read_text()


def declaration(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


pieces = [r'''import Foundation
struct WorkReference: Hashable { var scope = "account"; var itemID: String? = "chat" }
struct Conversation { var backend = "codex"; var model: String? = "model"; var runRevision: UInt64? = 1; var running = true }
enum BridgeError: Error { case core(String, String) }
@MainActor enum WorkCacheAccess {
    static var readable = true
    static func canRead(_ reference: WorkReference) -> Bool { readable && reference.scope == "account" }
}
@MainActor enum Bridge {
    static var pending: CheckedContinuation<ChatInspection, Error>?
    static var calls = 0
    static func chatInspection(id: String, peer: String?) async throws -> ChatInspection {
        calls += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
}
@MainActor final class ChatModel {
    var currentReference: WorkReference? = WorkReference()
    var selected: Conversation? = Conversation()
    var selectionGeneration: UInt64 = 1
    var savedCopy: Bool?
    var peer: String? = "host"
    var activityRead: ChatActivityRead?
    var busy: Bool { selected?.running == true }
}
''']
pieces += [declaration(signature) for signature in [
    'struct ChatActivityOwner:', 'struct ChatActivityRead {', 'extension ChatModel {']]
pieces += [r'''
@main enum Tests {
    @MainActor static func settle() async { for _ in 0..<100 { await Task.yield() } }
    @MainActor static func request() async -> CheckedContinuation<ChatInspection, Error> {
        for _ in 0..<10000 { if Bridge.pending != nil { break }; await Task.yield() }
        guard let next = Bridge.pending else { preconditionFailure("Activity request did not start") }
        Bridge.pending = nil
        return next
    }
    @MainActor static func main() async throws {
        let wire = Data(#"{"backend":"codex","model":"model","tools":null,"usedTools":[],"mcpServers":[],"mcpReported":false,"currentRun":true,"activity":{"goal":null,"plan":[],"agents":[{"id":"worker","status":"running","source":"agent"}],"goalReported":false,"planReported":false,"agentsReported":true,"partial":false,"live":true}}"#.utf8)
        let report = try JSONDecoder().decode(ChatInspection.self, from: wire)
        for change in ["chat", "account", "backend", "model", "run", "selection", "running", "saved", "access"] {
            let model = ChatModel()
            let task = Task { await model.watchActivity() }
            let next = await request()
            switch change {
            case "chat": model.currentReference?.itemID = "other"
            case "account": model.currentReference?.scope = "other"
            case "backend": model.selected?.backend = "claude"
            case "model": model.selected?.model = "different"
            case "run": model.selected?.runRevision = 2
            case "selection": model.selectionGeneration += 1
            case "running": model.selected?.running = false
            case "saved": model.savedCopy = true
            default: WorkCacheAccess.readable = false
            }
            next.resume(returning: report)
            await task.value
            precondition(model.currentActivityRead?.inspection == nil, "Late activity escaped its captured \(change) owner")
            precondition(!model.activityIsLive)
            WorkCacheAccess.readable = true
        }
        let model = ChatModel()
        let retired = ChatModel()
        let retiredTask = Task { await retired.watchActivity() }
        let retiredReply = await request()
        retired.retireActivityRead()
        retiredReply.resume(returning: report)
        await retiredTask.value
        precondition(retired.currentActivityRead?.inspection == nil && !retired.activityIsLive,
                     "A response begun before backgrounding cannot reacquire live state")
        let task = Task { await model.watchActivity() }
        let next = await request()
        next.resume(returning: report)
        await settle()
        precondition(model.activityIsLive && model.inspectionIsLive && model.currentActivityRead?.inspection?.activity?.agents.count == 1)
        let olderHost = ChatModel()
        olderHost.selected?.runRevision = nil
        var oldReport = report
        oldReport.activity = nil
        olderHost.activityRead = ChatActivityRead(owner: olderHost.activityOwner, inspection: oldReport, loaded: true)
        precondition(olderHost.inspectionIsLive && !olderHost.activityIsLive,
                     "Older hosts can report live MCP connections without an activity payload")
        olderHost.retireActivityRead()
        precondition(!olderHost.inspectionIsLive && olderHost.currentActivityRead?.inspection != nil,
                     "A backgrounded MCP report must remain historical")
        olderHost.activityRead?.failed = false
        olderHost.selected?.running = false
        precondition(!olderHost.inspectionIsLive && olderHost.currentActivityRead == nil,
                     "Run transitions invalidate context even when older hosts omit runRevision")
        model.retireActivityRead()
        precondition(!model.activityIsLive && !model.inspectionIsLive, "Backgrounding must invalidate live state before an in-flight read returns")
        task.cancel(); await task.value
        precondition(!model.activityIsLive && model.currentActivityRead?.inspection != nil,
                     "Stopping visibility polling must revoke live state while retaining the report")
        model.selected?.running = false
        precondition(!model.activityIsLive, "A completed turn cannot keep subagents live")
        model.selected?.running = true
        model.activityRead?.failed = true
        precondition(!model.activityIsLive && !model.inspectionIsLive && model.currentActivityRead?.inspection != nil,
                     "A disconnected report stays readable without claiming live agents")
        let saved = ChatModel(); saved.savedCopy = true
        let before = Bridge.calls
        await saved.watchActivity()
        precondition(Bridge.calls == before && saved.currentActivityRead?.loaded == true,
                     "Saved chats must not fetch current backend state")
        print("Chat activity: late owner/account/backend/model/run rejection, saved copies and stale live status passed")
    }
}
''']
with tempfile.TemporaryDirectory(prefix='tokenstat-activity-owner-') as directory:
    directory = Path(directory)
    fixture = directory / 'Check.swift'
    fixture.write_text('\n'.join(pieces))
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(directory / 'cache'),
                    str(fixture), str(root / 'apps/mac/Sources/Bridge/ChatInspection.swift'), '-o', str(directory / 'check')], check=True)
    subprocess.run([str(directory / 'check')], check=True)
