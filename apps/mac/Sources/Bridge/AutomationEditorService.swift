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
    func supportsReceipts() async -> Bool
    func editAutomation(_ job: Automation, revision: UInt64) async throws -> Automation
    func createAutomationOnce(_ job: Automation, operationID: String) async throws -> AutomationCreationOutcome
    func automationCreationReceipt(operationID: String) async throws -> AutomationCreationOutcome?
    func runningJobIDs() async throws -> [String]
}

extension AutomationEditorService {
    func supportsReceipts() async -> Bool { false }
    func editAutomation(_ job: Automation, revision: UInt64) async throws -> Automation {
        try await updateAutomation(job)
    }
    func createAutomationOnce(_ job: Automation, operationID: String) async throws -> AutomationCreationOutcome {
        let created = try await createAutomation(job)
        return AutomationCreationOutcome(operationID: operationID, jobID: created.id, createdAtMs: 0, job: created)
    }
    func automationCreationReceipt(operationID: String) async throws -> AutomationCreationOutcome? { nil }
    func runningJobIDs() async throws -> [String] { [] }
}

/// One computer. Mobile always has a peer. Mac local uses the daemon.
struct AutomationEditorTarget: Hashable, Sendable, AutomationEditorService {
    let peer: String?

    func supportsReceipts() async -> Bool {
        await RemoteHostFeature.automationReceipts.isSupported(peer: peer)
    }

    func createAutomation(_ job: Automation) async throws -> Automation {
        try await call("automation.create", ["job": job.payload], as: Automation.self)
    }

    func createAutomationOnce(_ job: Automation, operationID: String) async throws -> AutomationCreationOutcome {
        try await call(
            "automation.createOnce",
            ["job": job.payload, "operationId": operationID],
            as: AutomationCreationOutcome.self
        )
    }

    func automationCreationReceipt(operationID: String) async throws -> AutomationCreationOutcome? {
        try await call(
            "automation.creationReceipt",
            ["operationId": operationID],
            as: AutomationCreationOutcome?.self
        )
    }

    func updateAutomation(_ job: Automation) async throws -> Automation {
        try await call("automation.update", ["job": job.payload], as: Automation.self)
    }

    func editAutomation(_ job: Automation, revision: UInt64) async throws -> Automation {
        try await call(
            "automation.edit",
            ["job": job.payload, "expectedRevision": revision],
            as: Automation.self
        )
    }

    func runningJobIDs() async throws -> [String] {
        let runs: [RunRecord] = try await call("automation.runs", [:], as: [RunRecord].self)
        return Array(Set(runs.filter(\.isRunning).map(\.jobId)))
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
