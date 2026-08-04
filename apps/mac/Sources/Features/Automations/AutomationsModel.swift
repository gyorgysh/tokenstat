// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import Foundation
import Observation

/// The agent automations this machine runs, and the runs they have produced.
///
/// Everything lives in the daemon, so a job keeps its schedule with the window
/// closed. The app is a viewer and a form: it lists jobs and runs, edits a
/// job, starts a run, and tails the transcript of whichever run is live.
@MainActor
@Observable
final class AutomationsModel {
    private(set) var jobs: [Automation] = []
    private(set) var runs: [RunRecord] = []
    private(set) var backends: [AgentBackend] = []
    var errorMessage: String?
    var noticeMessage: String?

    /// The run whose transcript is on screen, if any.
    private(set) var watchingRunID: String?
    private(set) var selectedRunID: String?
    /// Transcript text assembled so far for the watched run.
    private(set) var transcriptText: String = ""
    private var transcriptOffset: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var noticeGeneration = 0

    func load() async {
        do {
            async let j = Bridge.automations()
            async let r = Bridge.automationRuns()
            async let b = Bridge.automationBackends()
            jobs = try await j
            runs = try await r
            backends = try await b
            errorMessage = nil
            syncWatching()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The newest running run, if any. This is what the screen tails live.
    var liveRun: RunRecord? {
        runs.first(where: \.isRunning) ?? runs.first
    }

    var selectedRun: RunRecord? {
        guard let selectedRunID else { return liveRun }
        return runs.first { $0.id == selectedRunID }
    }

    func create(
        name: String,
        backend: String,
        workspaceID: String,
        prompt: String,
        schedule: AutomationSchedule,
        budget: UInt64
    ) async {
        let job = Automation(
            id: "", name: name, backend: backend, workspaceID: workspaceID, prompt: prompt,
            schedule: schedule, budgetSeconds: budget, enabled: true,
            lastRunAtMs: nil, nextRunAtMs: nil, lastRunID: nil
        )
        do {
            _ = try await Bridge.createAutomation(job)
            showNotice("\(name) will run \(scheduleSummary(schedule)).")
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggle(_ job: Automation) async {
        do {
            _ = try await Bridge.setAutomation(job.id, enabled: !job.enabled)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func run(_ job: Automation) async {
        do {
            _ = try await Bridge.runAutomation(job.id)
            showNotice("Started \(job.name).")
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ job: Automation) async {
        do {
            try await Bridge.removeAutomation(job.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func watch(_ run: RunRecord) {
        selectedRunID = run.id
        watchingRunID = run.id
        transcriptText = ""
        transcriptOffset = 0
        syncWatching()
    }

    /// Start or stop the transcript poll to match what is on screen.
    func syncWatching() {
        guard let live = selectedRun ?? liveRun else {
            stopPolling()
            return
        }
        if watchingRunID == nil || watchingRunID != live.id {
            watchingRunID = live.id
            transcriptText = ""
            transcriptOffset = 0
        }
        if live.isRunning {
            startPolling(live.id)
        } else {
            stopPolling()
            // The run ended; show whatever the transcript has, once.
            Task { await self.fetchTranscript(id: live.id, resetIfNeeded: false) }
        }
    }

    private func startPolling(_ id: String) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetchTranscript(id: id, resetIfNeeded: true)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func fetchTranscript(id: String, resetIfNeeded: Bool) async {
        // The run being watched may have changed between ticks.
        if resetIfNeeded, watchingRunID != id {
            stopPolling()
            return
        }
        do {
            let chunk = try await Bridge.automationTranscript(id: id, offset: transcriptOffset)
            if !chunk.text.isEmpty {
                transcriptText += chunk.text
            }
            transcriptOffset = chunk.nextOffset
        } catch {
            // A just-finished run may still have its file in flight; the next
            // load() refreshes runs and the poll stops then.
        }
    }

    private func showNotice(_ message: String) {
        noticeGeneration += 1
        let generation = noticeGeneration
        noticeMessage = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.noticeGeneration == generation else { return }
            self.noticeMessage = nil
        }
    }

    func scheduleSummary(_ s: AutomationSchedule) -> String {
        switch s.kind {
        case .once: return "once, when you run it"
        case .interval:
            let minutes = Int(s.everySeconds) / 60
            return "every \(minutes) minute\(minutes == 1 ? "" : "s")"
        case .daily: return "daily at \(s.hour):\(String(format: "%02d", s.minute))"
        case .weekly:
            let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
            let day = s.weekday >= 0 && s.weekday < 7 ? names[s.weekday] : "?"
            return "\(day) at \(s.hour):\(String(format: "%02d", s.minute))"
        }
    }
}
