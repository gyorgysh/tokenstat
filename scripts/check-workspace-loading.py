#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production workspace loader with delayed and failed host replies."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Features/Workspaces/WorkspacesModel.swift').read_text()
start = source.index('    var folders: [WorkspaceFolder]')
fields = source[start:source.index('    /// Which inspector tab', start)]
start = source.index('    func loadLocal() async -> Bool {')
end, depth = source.index('{', start) + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method = source[start:end]
swift = r'''import Foundation
struct WorkspaceFolder { let id: String; var name = "Fixture"; var exists = true }
struct WorkspaceSummary { let id: String }
struct EcosystemProject { let id: String; let name: String; let host: String }
@MainActor final class WorkSessionContext { static let shared = WorkSessionContext(); var scope: String? = "A" }
@MainActor enum EcosystemPublisher {
    static var lease: Int? = 1
    enum Place { case local }
    static func publish(projects: [EcosystemProject], lease: Int?, replacing: Place) {}
}
enum ReadFailure: Error { case unavailable }
@MainActor enum Bridge {
    static var replies: [CheckedContinuation<[WorkspaceFolder], Error>?] = []
    static func workspaces() async throws -> [WorkspaceFolder] {
        try await withCheckedThrowingContinuation { replies.append($0) }
    }
    static func workspaceSummaries() async throws -> [WorkspaceSummary] { [] }
    static func answer(_ index: Int, _ folders: [WorkspaceFolder]?) {
        let reply = replies[index]; replies[index] = nil
        if let folders { reply?.resume(returning: folders) }
        else { reply?.resume(throwing: ReadFailure.unavailable) }
    }
}
@MainActor final class Model {
''' + fields + r'''
    var localFolders: [WorkspaceFolder] = []
    var summaries: [String: WorkspaceSummary] = [:]
    func publishFolders() { folders = localFolders }
''' + method + r'''
}
@MainActor func pending(_ count: Int) async {
    for _ in 0..<10000 { if Bridge.replies.count == count { return }; await Task.yield() }
    preconditionFailure("The host read did not start")
}
@main struct LoadingTests {
    static func check(_ value: Bool) { precondition(value) }
    @MainActor static func main() async {
        let model = Model()
        precondition(model.directoryPresentation == .loading, "Before the first read, empty storage is unknown")
        let first = Task { await model.loadLocal() }; await pending(1)
        precondition(model.directoryPresentation == .loading, "A delayed host must show a placeholder")
        Bridge.answer(0, nil)
        check(await first.value == false)
        precondition(model.directoryPresentation == .failed, "A failed read is not a first-project prompt")
        let retry = Task { await model.loadLocal() }; await pending(2)
        precondition(model.directoryPresentation == .loading)
        Bridge.answer(1, [.init(id: "existing")])
        check(await retry.value)
        precondition(model.directoryPresentation == .content)
        let refresh = Task { await model.loadLocal() }; await pending(3)
        precondition(model.directoryPresentation == .content, "Keep usable folders during a refresh")
        Bridge.answer(2, nil)
        check(await refresh.value == false)
        precondition(model.directoryPresentation == .content)
        let empty = Task { await model.loadLocal() }; await pending(4)
        Bridge.answer(3, [])
        check(await empty.value)
        precondition(model.directoryPresentation == .empty, "Only a successful empty read confirms first use")
        let stale = Model()
        let oldRead = Task { await stale.loadLocal() }; await pending(5)
        WorkSessionContext.shared.scope = "B"
        Bridge.answer(4, nil)
        check(await oldRead.value == false)
        precondition(stale.directoryError == nil && !stale.hasLoadedDirectory)
        precondition(stale.directoryPresentation == .loading, "An old account's failure cannot finish the new account's load")
        print("PASS: startup, delay, failure/retry, retained content, confirmed empty and stale-owner reads")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-workspace-loading-') as temporary:
    path = Path(temporary)
    (path / 'main.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5',
                    str(root / 'apps/mac/Sources/Features/Workspaces/WorkspaceDirectoryPresentation.swift'),
                    str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
