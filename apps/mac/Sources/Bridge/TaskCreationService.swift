// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

struct TaskCreationSubmission: Codable, Equatable, Sendable {
    let operationID: String
    let column: String
    let fields: TaskEditorDraft
    enum CodingKeys: String, CodingKey { case operationID = "operationId", column, fields }
}

struct TaskCreationOutcome: Codable, Equatable, Sendable {
    let operationID: String
    let cardID: String
    let createdAtMs: Int64
    let card: TodoCard?
    enum CodingKeys: String, CodingKey { case operationID = "operationId", cardID = "cardId", createdAtMs, card }
}

protocol TaskCreationService: Sendable {
    func supportsCreation() async throws -> Bool
    func creationDefaults() async throws -> UInt64
    func creationBackends() async throws -> [AgentBackend]
    func creationFolders() async throws -> [WorkspaceFolder]
    func createTask(_ submission: TaskCreationSubmission) async throws -> TaskCreationOutcome
    func taskCreationReceipt(operationID: String) async throws -> TaskCreationOutcome?
}

extension TaskEditorTarget: TaskCreationService {
    func supportsCreation() async throws -> Bool {
        guard let peer, !peer.isEmpty else { return true }
        return try await Bridge.peerProtocolVersion(peer) >= RemoteHostFeature.taskCreation.minimumProtocol
    }
    func creationDefaults() async throws -> UInt64 {
        let queue = try await call("automation.queue", [:], as: AutomationQueue.self)
        return queue.defaultBudgetSeconds
    }
    func creationBackends() async throws -> [AgentBackend] { try await taskBackends() }
    func creationFolders() async throws -> [WorkspaceFolder] { try await taskFolders() }
    func createTask(_ submission: TaskCreationSubmission) async throws -> TaskCreationOutcome {
        guard try await supportsCreation() else { throw TaskEditorDraft.Invalid.fields("Update this computer's tokenstat to create tasks from here.") }
        var params = try submission.fields.parameters(id: "", revision: 0)
        params.removeValue(forKey: "id"); params.removeValue(forKey: "expectedRevision")
        params["operationId"] = submission.operationID
        params["column"] = submission.column
        params["kind"] = "task"
        return try await call("todo.createOnce", params, as: TaskCreationOutcome.self)
    }
    func taskCreationReceipt(operationID: String) async throws -> TaskCreationOutcome? {
        guard try await supportsCreation() else { throw TaskEditorDraft.Invalid.fields("Update this computer's tokenstat to check task creation from here.") }
        return try await call("todo.creationReceipt", ["operationId": operationID], as: TaskCreationOutcome?.self)
    }
}
