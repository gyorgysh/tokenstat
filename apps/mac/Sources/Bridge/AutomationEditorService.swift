// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

protocol AutomationEditorService: Sendable {
    func createAutomation(_ job: Automation) async throws -> Automation
    func updateAutomation(_ job: Automation) async throws -> Automation
    func removeAutomation(id: String) async throws
    func automation(id: String) async throws -> Automation?
    func automations() async throws -> [Automation]
    func automationBackends() async throws -> [AgentBackend]
    func automationQueue() async throws -> AutomationQueue
}

/// One computer. Mobile always has a peer. Mac local uses the daemon.
struct AutomationEditorTarget: Hashable, Sendable, AutomationEditorService {
    let peer: String?

    func createAutomation(_ job: Automation) async throws -> Automation {
        try await call("automation.create", ["job": job.payload], as: Automation.self)
    }

    func updateAutomation(_ job: Automation) async throws -> Automation {
        try await call("automation.update", ["job": job.payload], as: Automation.self)
    }

    func removeAutomation(id: String) async throws {
        struct Removed: Codable, Sendable { let removed: Bool? }
        _ = try await call("automation.remove", ["id": id], as: Removed.self)
    }

    func automation(id: String) async throws -> Automation? {
        try await automations().first { $0.id == id }
    }

    func automations() async throws -> [Automation] {
        try await call("automation.list", [:], as: [Automation].self)
    }

    func automationBackends() async throws -> [AgentBackend] {
        try await call("automation.backends", [:], as: [AgentBackend].self)
    }

    func automationQueue() async throws -> AutomationQueue {
        try await call("automation.queue", [:], as: AutomationQueue.self)
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
