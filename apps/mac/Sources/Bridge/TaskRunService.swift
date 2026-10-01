// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

protocol TaskRunService: Sendable {
    func supportsTaskExecution() async -> Bool
    func runTask(id: String, revision: UInt64, operationID: String, placement: TaskRunPlacement) async throws -> TaskRunOutcome
    func taskRunReceipt(operationID: String) async throws -> TaskRunOutcome?
    func stopTask(id: String, revision: UInt64, runID: String) async throws -> TodoCard
    func taskTerminal(ptyID: String) async throws -> PtySessionInfo
}

extension TaskEditorTarget: TaskRunService {
    func supportsTaskExecution() async -> Bool {
        await RemoteHostFeature.taskExecution.isSupported(peer: peer)
    }

    func runTask(id: String, revision: UInt64, operationID: String, placement: TaskRunPlacement) async throws -> TaskRunOutcome {
        guard await supportsTaskExecution() else {
            throw TaskEditorDraft.Invalid.fields(L10n.text("apple.taskrunservice.update_this_computer_s_tokenstat_to_run_ta.626d0e60"))
        }
        return try await call(
            "todo.runTask",
            ["id": id, "expectedRevision": revision, "operationId": operationID, "placement": placement.rawValue],
            as: TaskRunOutcome.self
        )
    }

    func taskRunReceipt(operationID: String) async throws -> TaskRunOutcome? {
        guard await supportsTaskExecution() else { return nil }
        return try await call("todo.runReceipt", ["operationId": operationID], as: TaskRunOutcome?.self)
    }

    func stopTask(id: String, revision: UInt64, runID: String) async throws -> TodoCard {
        guard await supportsTaskExecution() else {
            throw TaskEditorDraft.Invalid.fields(L10n.text("apple.taskrunservice.update_this_computer_s_tokenstat_to_stop_t.0ab49a08"))
        }
        return try await call(
            "todo.stopTask",
            ["id": id, "expectedRevision": revision, "runId": runID],
            as: TodoCard.self
        )
    }

    func taskTerminal(ptyID: String) async throws -> PtySessionInfo {
        guard !ptyID.isEmpty else {
            throw TaskEditorDraft.Invalid.fields(L10n.text("apple.taskrunservice.the_interactive_terminal_is_not_ready_yet.995670b6"))
        }
        #if os(macOS)
        return try await Bridge.ptyInfo(id: ptyID)
        #else
        guard let peer else { throw CocoaError(.fileReadNoSuchFile) }
        return try await ClientRemote.ptyInfo(peer: peer, id: ptyID)
        #endif
    }
}
