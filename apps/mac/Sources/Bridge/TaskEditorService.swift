// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

protocol TaskEditorService: Sendable {
    func supportsEditing() async -> Bool
    func task(id: String) async throws -> TodoCard?
    func taskBackends() async throws -> [AgentBackend]
    func taskFolders() async throws -> [WorkspaceFolder]
    func edit(id: String, revision: UInt64, draft: TaskEditorDraft) async throws -> TodoCard
}

/// Task identity is host-wide and survives moving the task to another folder.
struct TaskEditorTarget: Hashable, Sendable, TaskEditorService {
    let peer: String?

    func supportsEditing() async -> Bool { await RemoteHostFeature.taskEditing.isSupported(peer: peer) }
    func task(id: String) async throws -> TodoCard? { try await call("todo.get", ["id": id], as: TodoCard?.self) }
    func taskBackends() async throws -> [AgentBackend] { try await call("automation.backends", [:], as: [AgentBackend].self) }
    func taskFolders() async throws -> [WorkspaceFolder] { try await call("workspace.list", [:], as: [WorkspaceFolder].self) }
    func edit(id: String, revision: UInt64, draft: TaskEditorDraft) async throws -> TodoCard {
        try await call("todo.edit", draft.parameters(id: id, revision: revision), as: TodoCard.self)
    }

    func call<T: Decodable & Sendable>(_ method: String, _ params: [String: Any], as type: T.Type) async throws -> T {
        if let peer { return try await Bridge.onPeer(peer, method, params, as: type) }
        #if os(macOS)
        return try await Bridge.localTaskEditor(method, params, as: type)
        #else
        throw CocoaError(.fileReadNoSuchFile)
        #endif
    }
}
