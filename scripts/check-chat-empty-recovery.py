#!/usr/bin/env python3
"""Exercise the actual mobile empty-history retry and offline-copy guards."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
def member(file, signature):
    source = (root / file).read_text()
    start = source.index(signature)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func')
retry = member('apps/mac/Sources/Client/ClientChatView.swift', '    private func foregroundRefresh() async {')
# The second foreground refresh belongs to the transcript, the first to its list.
source = (root / 'apps/mac/Sources/Client/ClientChatView.swift').read_text()
first = source.index('    private func foregroundRefresh() async {')
second = source.index('    private func foregroundRefresh() async {', first + 1)
brace = source.index('{', second); end, depth = brace + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}'); end += 1
retry = source[second:end].replace('private func', 'func')
cache = member('apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift', '    private func keepOfflineCopy(')
code = '''import Foundation
struct Reference { let itemID: String }
struct Conversation { let lastMessageAtMs: Int64?; let backend = "codex" }
struct ChatEventPage { let events: [Int] }
enum L10n { static func text(_ key: String) -> String { key } }
@MainActor final class WorkCacheStore {
    static let shared = WorkCacheStore(); var pages: [ChatEventPage] = []
    func saveConversation(reference: Reference, title: String, page: ChatEventPage, backend: String?, sendRevision: UInt64?) async { pages.append(page) }
}
@MainActor final class Model {
    var currentReference: Reference? = .init(itemID: "chat")
    var selected: Conversation? = .init(lastMessageAtMs: 123)
    var events: [Int] = [], error: String?, selects = 0, polls = 0
    func select(_ chat: Conversation) async { selects += 1; events = [1, 2, 3] }
    func poll() async { polls += 1 }
''' + cache + '''
}
@MainActor final class Reader {
    var refreshing = false; let model = Model()
''' + retry + '''
}
@main struct Check {
    @MainActor static func main() async {
        let reader = Reader()
        await reader.foregroundRefresh()
        precondition(reader.model.selects == 1 && reader.model.events == [1, 2, 3])
        await reader.foregroundRefresh()
        precondition(reader.model.polls == 1 && reader.model.selects == 1)
        reader.model.keepOfflineCopy(id: "chat", title: nil, page: .init(events: []), sendRevision: nil)
        for _ in 0..<100 { await Task.yield() }
        precondition(WorkCacheStore.shared.pages.isEmpty)
        reader.model.keepOfflineCopy(id: "chat", title: nil, page: .init(events: [1]), sendRevision: nil)
        for _ in 0..<100 { await Task.yield() }
        precondition(WorkCacheStore.shared.pages.count == 1)
        reader.model.selected = .init(lastMessageAtMs: nil)
        reader.model.keepOfflineCopy(id: "chat", title: nil, page: .init(events: []), sendRevision: nil)
        for _ in 0..<100 { await Task.yield() }
        precondition(WorkCacheStore.shared.pages.count == 2)
        print("Mobile history recovery: empty reader reopens; loaded reader tails; known history cache survives empty reads")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-empty-history-') as directory:
    source = Path(directory) / 'checks.swift'; binary = Path(directory) / 'checks'
    source.write_text(code)
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
