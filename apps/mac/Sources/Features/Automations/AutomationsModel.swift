// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import Foundation
import Observation

@MainActor
@Observable
final class AutomationsModel {
    private(set) var jobs: [Automation] = []
    private(set) var folders: [WorkspaceFolder] = []
    var errorMessage: String?
    var noticeMessage: String?

    func load() async {
        do {
            async let jobs = Bridge.automations()
            async let folders = Bridge.workspaces()
            self.jobs = try await jobs
            self.folders = try await folders
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func create(name: String, workspaceID: String, command: String, interval: UInt64, budget: UInt64) async {
        let job = Automation(
            id: "", name: name, workspaceID: workspaceID, command: command, args: [],
            intervalSeconds: interval, budgetSeconds: budget, enabled: false,
            lastRunAtMs: nil, nextRunAtMs: nil, lastRunID: nil
        )
        do {
            _ = try await Bridge.createAutomation(job)
            noticeMessage = "Automation created."
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    func toggle(_ job: Automation) async {
        do {
            _ = try await Bridge.setAutomation(job.id, enabled: !job.enabled)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    func run(_ job: Automation) async {
        do {
            _ = try await Bridge.runAutomation(job.id)
            noticeMessage = "Started \(job.name)."
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    func remove(_ job: Automation) async {
        do {
            try await Bridge.removeAutomation(job.id)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}
