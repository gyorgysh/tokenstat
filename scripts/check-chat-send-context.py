#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run ChatModel's real setup-update method against controlled host replies."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift').read_text()
start = source.index('    func update(\n')
brace = source.index(') async {', start) + len(') async ')
end, depth = brace + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
update = source[start:end]
stub = '''import Foundation
struct Conversation { let id: String; let sendRevision: UInt64? }
@MainActor enum Bridge {
    static var reply = Conversation(id: "chat", sendRevision: 8)
    static var beforeReply: (() -> Void)?
    static func updateChat(id: String, title: String?, backend: String?, model: String?,
        effort: String?, fastMode: Bool?, expectedRevision: UInt64?, mode: String?,
        autonomy: String?, personaID: String?, systemPrompt: String?, allowedTools: [String]?,
        allowedShellPrefixes: [String]?, peer: String?) async throws -> Conversation {
        beforeReply?()
        return reply
    }
}
@MainActor final class Model {
    var savedCopy: Bool? = nil
    var selected: Conversation? = Conversation(id: "chat", sendRevision: 7)
    var selectionGeneration: UInt64 = 0
    var contextRevision: UInt64? = 7
    var peer: String? = nil
    var error: String? = nil
    func selectionMatches(id: String, generation: UInt64) -> Bool {
        selected?.id == id && selectionGeneration == generation
    }
    func replace(_ chat: Conversation) { selected = chat }
    func loadInstructions(id: String, generation: UInt64) async {}
'''
tests = '''
}
@main struct Tests {
    @MainActor static func main() async {
        let model = Model()
        await model.update(model: "different-model")
        assert(model.contextRevision == 8, "Own model edit must not cause a false conversation_changed on the next send")
        model.selected = Conversation(id: "chat", sendRevision: 8)
        model.contextRevision = 8
        Bridge.reply = Conversation(id: "chat", sendRevision: 9)
        await model.update(fastMode: true)
        assert(model.contextRevision == 9, "Own speed edit must retain a sendable composer")
        model.selected = Conversation(id: "chat", sendRevision: 9)
        model.contextRevision = 9
        Bridge.reply = Conversation(id: "chat", sendRevision: 11)
        await model.update(model: "third-model")
        assert(model.contextRevision == 9, "Other accepted work requires review")
        Bridge.beforeReply = { model.selected = Conversation(id: "other-chat", sendRevision: 20) }
        await model.update(model: "fourth-model")
        assert(model.contextRevision == 9 && model.selected?.id == "other-chat", "Late setup response cannot change another chat")
        print("ChatModel send context: own model/speed edits, concurrent work and changed selection passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-chat-context-') as work:
    work = Path(work)
    swift = work / 'Tests.swift'
    swift.write_text(stub + update + tests)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5',
                    '-module-cache-path', str(work / 'cache'), '-o', str(work / 'test'),
                    str(swift), str(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatSendContext.swift')], check=True)
    subprocess.run([str(work / 'test')], check=True)
