#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run production sheet actions with file work paused across dismissal."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Features/Work/WorkHandoffSheet.swift').read_text()
def member(signature):
    start = source.index(signature)
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end].replace('private func ', 'func ')
methods = '\n'.join(member(name) for name in ['    private func share(', '    private func importDraft(', '    private func importAnchor('])
if '    private func invalidate()' in source:
    methods += '\n' + member('    private func invalidate()')
disappear = re.search(r'\.onDisappear \{ ([^\n]+) \}', source).group(1)
harness = r'''import Foundation
struct WorkSharedDraft { let text: String }
struct WorkHandoffAnchor {
    init() {}
    init(eventID: String, fraction: UInt16, followsLatest: Bool) {}
}
struct ChatReadingMark {
    let eventID: String
    let within: Double
    static func isStable(eventID: String) -> Bool { true }
}
@MainActor final class ChatReadingStore {
    static let shared = ChatReadingStore()
    func mark(for reference: String) -> ChatReadingMark? { nil }
}
struct DisplayItem { let id: String }
enum L10n { static func text(_ value: String) -> String { value } }
@MainActor final class WorkHandoffModel {
    enum Phase { case ready, invalidated }
    var phase = Phase.ready
    let reference = "chat"
    var shares = 0
    func share(deviceName: String, draft: WorkSharedDraft?, anchor: WorkHandoffAnchor?) async {
        if phase != .invalidated { shares += 1 }
    }
    func invalidate() { phase = .invalidated }
}
@MainActor final class Connection {
    var isCurrent = true
    var pending: CheckedContinuation<Void, Never>?
    var observedCancellation = false
    func attachments(for draft: WorkSharedDraft) async throws -> [String] {
        await withCheckedContinuation { pending = $0 }
        observedCancellation = Task.isCancelled
        return ["file"]
    }
    func verifyForImport() async throws { _ = try await attachments(for: .init(text: "")) }
}
@MainActor final class Chat {
    var stagingAttachments = 0
    var handoffDraft = WorkSharedDraft(text: "local")
    var attachments: [String] = []
    var displayItems: [DisplayItem] = []
    var preparation: CheckedContinuation<Void, Never>?
    var cancelledPreparation = false
    var failPreparation = false
    func saveDraftNow() {}
    func prepareHandoffDraft(_ draft: WorkSharedDraft) async throws -> WorkSharedDraft {
        await withCheckedContinuation { preparation = $0 }
        cancelledPreparation = Task.isCancelled
        try Task.checkCancellation()
        if failPreparation { throw CocoaError(.fileReadUnknown) }
        return draft
    }
    var downloads = 0, imports = 0
    var pauseFiles = false
    var pending: CheckedContinuation<Void, Never>?
    func keepImportedDraftFiles(_ files: [String], reference: String, expected: WorkSharedDraft) async throws {
        downloads += 1
        if pauseFiles { await withCheckedContinuation { pending = $0 } }
    }
    func importHandoffDraft(_ draft: WorkSharedDraft, files: [String], replacing: WorkSharedDraft, reference: String) -> Bool { imports += 1; return true }
    func importHandoffAnchor(_ anchor: WorkHandoffAnchor, reference: String) -> Bool { imports += 1; return true }
}
@MainActor final class Sheet {
    let chat = Chat()
    var connection: Connection? = Connection()
    var model: WorkHandoffModel? = WorkHandoffModel()
    var importing = false
    var notice: String?
    var importTask: Task<Void, Never>?
    var shareTask: Task<Void, Never>?
    var preparingDraft = false
    var includeDraft = true
    var dismissed = 0
    func dismiss() { dismissed += 1 }
''' + methods + '\n    func disappear() { ' + disappear + r''' }
}
@main struct Check {
    @MainActor static func main() async {
        let queued = Sheet()
        queued.share(queued.model!)
        queued.disappear()
        while queued.preparingDraft { await Task.yield() }
        precondition(queued.chat.preparation == nil && queued.model!.shares == 0 && queued.notice == nil,
            "A share closed before its task starts must not prepare files")
        for close in [true, false] {
            for failure in [true, false] {
                let sheet = Sheet()
                sheet.chat.failPreparation = failure
                sheet.share(sheet.model!)
                while sheet.chat.preparation == nil { await Task.yield() }
                if close { sheet.disappear() }
                sheet.chat.preparation!.resume()
                while sheet.preparingDraft { await Task.yield() }
                precondition(sheet.chat.cancelledPreparation == close,
                    "dismissal did not cancel shared-draft preparation")
                precondition(sheet.model!.shares == ((!close && !failure) ? 1 : 0))
                precondition((sheet.notice != nil) == (!close && failure),
                    "closed sheet published a preparation error")
            }
        }
        for anchor in [false, true] {
            for close in [true, false] {
                let sheet = Sheet()
                if anchor { sheet.importAnchor(.init(), model: sheet.model!) }
                else { sheet.importDraft(.init(text: "shared"), model: sheet.model!) }
                while sheet.connection!.pending == nil { await Task.yield() }
                if close { sheet.disappear() }
                sheet.connection!.pending!.resume()
                while sheet.importing { await Task.yield() }
                precondition(sheet.chat.downloads == ((!close && !anchor) ? 1 : 0), "closed sheet still downloads files")
                precondition(sheet.chat.imports == (close ? 0 : 1))
                precondition(sheet.dismissed == (close ? 0 : 1))
                precondition(sheet.notice == nil, "cancelled import published an error")
                if close { precondition(sheet.connection!.observedCancellation, "dismissal did not cancel the import task") }
            }
        }
        let loading = Sheet()
        loading.chat.pauseFiles = true
        loading.importDraft(.init(text: "shared"), model: loading.model!)
        while loading.connection!.pending == nil { await Task.yield() }
        loading.connection!.pending!.resume()
        while loading.chat.pending == nil { await Task.yield() }
        loading.disappear()
        loading.chat.pending!.resume()
        while loading.importing { await Task.yield() }
        precondition(loading.chat.imports == 0 && loading.notice == nil, "late file completion published after dismissal")
        print("Handoff sheet: dismissal cancels draft preparation and draft/anchor imports; late work cannot publish; open-sheet actions still finish")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-handoff-sheet-') as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(harness)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True, timeout=20)
