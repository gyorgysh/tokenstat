// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import Foundation
import Observation

/// How much readable transcript the inspector keeps. The host already caps
/// each reply and the on-disk readable file. This is the last line of defence
/// so a live tail cannot grow a SwiftUI `Text` without bound.
private let transcriptDisplayCap = 256 * 1024

/// Which side of the Automations inspector is showing.
enum AutomationFocus: Sendable {
    case none
    case job
    case run
}

/// The agent automations this machine runs, and the runs they have produced.
///
/// Everything lives in the daemon, so a job keeps its schedule with the window
/// closed. The app is a viewer and a form: it lists jobs and runs, edits a
/// job, starts a run, and tails the transcript of whichever run is live.
@MainActor
@Observable
final class AutomationsModel {
    private(set) var jobs: [Automation] = []
    /// Which workspace this screen is showing. Nil is every workspace.
    var scope: String?
    private(set) var runs: [RunRecord] = []
    private(set) var backends: [AgentBackend] = []

    /// True once the daemon has been read at least once. "No automations yet"
    /// and "not asked yet" are different answers and must not look the same.
    private(set) var hasLoaded = false

    var errorMessage: String?
    var noticeMessage: String?

    /// Scheduler settings, edited on the Automations screen.
    var queueBudgetMinutes = "180"
    var queueNoLimit = false
    var queueMaxConcurrent = "2"
    /// Last values the daemon accepted. The Save button is only live when
    /// the fields differ, so a tap that did nothing cannot look like a save.
    private(set) var savedQueueBudgetMinutes = "180"
    private(set) var savedQueueNoLimit = false
    private(set) var savedQueueMaxConcurrent = "2"

    var queueDirty: Bool {
        queueBudgetMinutes != savedQueueBudgetMinutes
            || queueNoLimit != savedQueueNoLimit
            || queueMaxConcurrent != savedQueueMaxConcurrent
    }

    /// The run whose transcript is on screen, if any.
    private(set) var watchingRunID: String?
    private(set) var selectedRunID: String?
    /// The job the inspector is showing. Separate from the run so picking a
    /// job does not have to invent a run for it.
    private(set) var selectedJobID: String?
    /// Which of the two the inspector should prefer when both are set.
    private(set) var selectedFocus: AutomationFocus = .none
    /// Transcript text assembled so far for the watched run.
    private(set) var transcriptText: String = ""
    private var transcriptOffset: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    /// The run id the poll task is actually tailing. Distinct from
    /// `watchingRunID` so switching runs restarts the loop.
    private var pollingID: String?
    private var noticeGeneration = 0

    /// True while the screen is on show.
    ///
    /// The transcript poll is a live tail, at four hundred milliseconds. Its
    /// only reader is a text view on this screen, so with the screen gone it is
    /// a bridge round trip twice a second producing text nobody will read. The
    /// model outlives the view, so this has to be said out loud.
    private var isVisible = false

    /// The screen appeared: load, and tail whatever is running.
    func appeared() async {
        isVisible = true
        await load()
        syncWatching()
    }

    /// The screen went away. The run carries on in the daemon, which is the
    /// whole point of it living there, so only the tail stops.
    func disappeared() {
        isVisible = false
        stopPolling()
    }

    /// Picker list: hidden workspace tiles stay out, except the current pick.
    func pickerBackends(keeping id: String? = nil) -> [AgentBackend] {
        backends.visibleForPicker(keeping: id)
    }

    func load() async {
        do {
            async let j = Bridge.automations()
            async let r = Bridge.automationRuns()
            async let b = Bridge.automationBackends()
            async let q = Bridge.automationQueue()
            jobs = try await j
            runs = try await r
            backends = try await b
            if let queue = try? await q {
                applyQueue(queue)
            }
            hasLoaded = true
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

    /// Display name of the once-job the Changes pane starts.
    static let autoCommitName = "Auto commit"

    /// The reusable Auto commit job for a folder, if one exists.
    ///
    /// Name plus workspace, not schedule: one folder gets one Auto commit
    /// job. A later start with a different agent edits that job.
    func autoCommitJobs(in workspaceID: String) -> [Automation] {
        jobs.filter {
            $0.workspaceID == workspaceID && Self.isAutoCommitName($0.name)
        }
    }

    func autoCommitJob(in workspaceID: String) -> Automation? {
        let matches = autoCommitJobs(in: workspaceID)
        if let live = matches.first(where: { lastRun(for: $0)?.isRunning == true }) {
            return live
        }
        return matches.first { lastRun(for: $0) != nil } ?? matches.first
    }

    static func isAutoCommitName(_ name: String) -> Bool {
        name.compare(autoCommitName, options: [.caseInsensitive, .diacriticInsensitive])
            == .orderedSame
    }

    /// True while this folder's Auto commit run is queued or live.
    func isAutoCommitRunning(in workspaceID: String) -> Bool {
        autoCommitJobs(in: workspaceID).contains { lastRun(for: $0)?.isRunning == true }
    }

    /// Jobs in this folder whose last run is still going. The workspace
    /// sidebar lists these so a hidden automation pty is still visible.
    /// The jobs of the current scope. Nil scope is every folder.
    var scoped: [Automation] {
        guard let scope else { return jobs }
        return jobs.filter { $0.workspaceID == scope }
    }

    /// The runs of the current scope.
    ///
    /// Recent runs sits under a scoped list of jobs, so it has to answer the
    /// same question they do. Unscoped it listed every folder's runs under a
    /// chip naming one folder, and the rows carry no folder of their own to
    /// correct the impression.
    var scopedRuns: [RunRecord] {
        guard let scope else { return runs }
        return runs.filter { $0.workspaceID == scope }
    }

    /// Jobs set up in a folder, running or not: the sidebar count.
    func count(in workspaceID: String) -> Int {
        jobs.filter { $0.workspaceID == workspaceID }.count
    }

    func liveJobs(in workspaceID: String) -> [Automation] {
        jobs.filter { job in
            job.workspaceID == workspaceID && lastRun(for: job)?.isRunning == true
        }
    }

    /// Reload jobs and runs without touching the transcript tail.
    ///
    /// The Automations screen is not the only reader: the workspace sidebar
    /// and the Auto commit button need a live status while that screen is off.
    func refreshList() async {
        do {
            async let j = Bridge.automations()
            async let r = Bridge.automationRuns()
            jobs = try await j
            runs = try await r
        } catch {
            // The next tick tries again.
        }
    }

    /// How a job last got on. The row carries this rather than the run list,
    /// because "did my nightly check pass" is a question about the automation
    /// and answering it should not mean reading a run history to find out which
    /// entry belonged to which job.
    func lastRun(for job: Automation) -> RunRecord? {
        if let id = job.lastRunID, let run = runs.first(where: { $0.id == id }) {
            return run
        }
        // A job whose last run predates the retained history still has an id
        // that resolves to nothing. Fall back to the newest run it owns.
        return runs.first { $0.jobId == job.id }
    }

    /// The runs a job produced, newest first.
    func runs(of job: Automation) -> [RunRecord] {
        runs.filter { $0.jobId == job.id }
    }

    var selectedRun: RunRecord? {
        guard let selectedRunID else { return nil }
        return runs.first { $0.id == selectedRunID }
    }

    /// Drop a job or run the new scope would hide.
    func dropOutOfScopeSelection() {
        if let scope, let id = selectedJobID,
           let job = jobs.first(where: { $0.id == id }),
           job.workspaceID != scope
        {
            selectedJobID = nil
            if selectedFocus == .job { selectedFocus = .none }
        }
        if let scope, let id = selectedRunID,
           let run = runs.first(where: { $0.id == id }),
           run.workspaceID != scope
        {
            selectedRunID = nil
            if selectedFocus == .run { selectedFocus = .none }
        }
    }

    var selectedJob: Automation? {
        guard let selectedJobID else { return nil }
        return jobs.first { $0.id == selectedJobID }
    }

    func selectJob(_ id: String) {
        selectedJobID = id
        selectedFocus = .job
        if let job = jobs.first(where: { $0.id == id }), let last = lastRun(for: job) {
            watch(last)
        }
    }

    func selectRun(_ run: RunRecord) {
        selectedJobID = run.jobId
        selectedFocus = .run
        watch(run)
    }

    func create(
        name: String,
        backend: String,
        model: String? = nil,
        effort: String? = nil,
        workspaceID: String,
        prompt: String,
        schedule: AutomationSchedule,
        budget: UInt64
    ) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // One Auto commit per folder. The Changes button and this form
        // share that job, so a second create is an edit.
        if Self.isAutoCommitName(trimmed), var existing = autoCommitJob(in: workspaceID) {
            existing.backend = backend
            existing.model = model
            existing.effort = effort
            existing.prompt = prompt
            existing.schedule = schedule
            existing.budgetSeconds = budget
            existing.enabled = true
            await update(existing, announce: false)
            showNotice("Updated Auto commit in this folder.")
            selectJob(existing.id)
            return
        }
        let job = Automation(
            id: "", name: trimmed, backend: backend, model: model, effort: effort,
            workspaceID: workspaceID, prompt: prompt,
            schedule: schedule, budgetSeconds: budget, enabled: true,
            lastRunAtMs: nil, nextRunAtMs: nil, lastRunID: nil
        )
        do {
            _ = try await Bridge.createAutomation(job)
            showNotice("\(trimmed) will run \(scheduleSummary(schedule)).")
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveQueue() async {
        let budget: UInt64
        if queueNoLimit {
            budget = 0
        } else {
            let trimmed = queueBudgetMinutes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let minutes = UInt64(trimmed), minutes > 0 else {
                errorMessage = "Time limit must be a whole number of minutes."
                return
            }
            budget = minutes * 60
        }
        let maxTrimmed = queueMaxConcurrent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let max = UInt32(maxTrimmed) else {
            errorMessage = "Max concurrent jobs must be a whole number."
            return
        }
        do {
            applyQueue(try await Bridge.setAutomationQueue(
                defaultBudgetSeconds: budget,
                maxConcurrent: max
            ))
            showNotice("Scheduler saved.")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyQueue(_ queue: AutomationQueue) {
        queueNoLimit = queue.defaultBudgetSeconds == 0
        if queue.defaultBudgetSeconds > 0 {
            queueBudgetMinutes = String(max(1, queue.defaultBudgetSeconds / 60))
        }
        queueMaxConcurrent = String(queue.maxConcurrent)
        savedQueueBudgetMinutes = queueBudgetMinutes
        savedQueueNoLimit = queueNoLimit
        savedQueueMaxConcurrent = queueMaxConcurrent
    }

    func toggle(_ job: Automation) async {
        do {
            _ = try await Bridge.setAutomation(job.id, enabled: !job.enabled)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(_ job: Automation, announce: Bool = true) async {
        do {
            _ = try await Bridge.updateAutomation(job)
            if announce {
                showNotice("Saved \(job.name).")
            }
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func run(_ job: Automation) async {
        do {
            let updated = try await Bridge.runAutomation(job.id)
            showNotice("Started \(job.name).")
            errorMessage = nil
            await load()
            if let id = updated.lastRunID, let run = runs.first(where: { $0.id == id }) {
                selectRun(run)
            } else if let last = lastRun(for: updated) ?? lastRun(for: job) {
                selectRun(last)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Kill a live run now. Same host path as a budget stop: the pty dies
    /// and the drain records the run as stopped.
    func stop(_ run: RunRecord) async {
        do {
            try await Bridge.automationKill(runID: run.id)
            showNotice("Stopped \(run.name).")
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Start a one-time Auto commit job in this folder and run it now.
    ///
    /// Reuses the existing automation runner: same backends, same pty, same
    /// budget. The scheduler never calls gitwrite. The agent commits with its
    /// own tools because the user pressed the button.
    func startAutoCommit(
        workspaceID: String,
        workspaceName: String,
        backend: String,
        model: String?
    ) async {
        let name = Self.autoCommitName
        let prompt = Self.autoCommitPrompt(workspaceName: workspaceName)
        let schedule = AutomationSchedule(kind: .once)
        if var existing = autoCommitJob(in: workspaceID) {
            if lastRun(for: existing)?.isRunning == true {
                selectJob(existing.id)
                if let last = lastRun(for: existing) {
                    selectRun(last)
                }
                return
            }
            existing.backend = backend
            existing.model = model
            existing.prompt = prompt
            existing.enabled = true
            await update(existing, announce: false)
            guard let job = jobs.first(where: { $0.id == existing.id }) else { return }
            selectJob(job.id)
            await run(job)
            return
        }
        let draft = Automation(
            id: "", name: name, backend: backend, model: model, effort: nil,
            workspaceID: workspaceID, prompt: prompt,
            schedule: schedule, budgetSeconds: 900, enabled: true,
            lastRunAtMs: nil, nextRunAtMs: nil, lastRunID: nil
        )
        do {
            let created = try await Bridge.createAutomation(draft)
            errorMessage = nil
            await load()
            selectJob(created.id)
            await run(created)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func autoCommitPrompt(workspaceName: String) -> String {
        """
        Commit the pending work in this git repository (\(workspaceName)).

        Inspect the working tree (git status and git diff). Group the changes \
        into one or more commits by concern. One concern per commit. A single \
        concern is one commit.

        Write messages that match this repository's existing style:
        1. Follow the most recent commit subjects.
        2. If CONTRIBUTING.md, a commitlint config, or .gitmessage exists, \
        follow those rules.
        3. Otherwise use Conventional Commits: lowercase type, optional scope, \
        imperative subject, English.

        Do not push. Do not force. Do not amend. Do not change files except to \
        commit them. If there is nothing to commit, say so and stop.

        After you finish, list the commits you made.
        """
    }

    /// Ship a version: bump, push, wait for CI, then tag. A once-job you run
    /// by hand, so the prompt can be long and the budget can cover the wait.
    static func releasePrompt() -> String {
        """
        Ship a release of this repository.

        1. Read how this repo versions itself (workspace manifests, lockfile, \
        app marketing version, changelog if one exists). Bump to the next \
        version the same way the last release did. Refresh the lockfile if \
        this project requires it.
        2. Commit the bump only. Match this repository's commit style \
        (CONTRIBUTING, commitlint, or recent subjects). Do not mix other \
        work into the bump.
        3. Push the branch to GitHub. Do not force. Do not amend published \
        history.
        4. Wait for CI on that commit. Poll until it finishes. If anything \
        fails, read the failing job, fix it, commit the fix, push, and wait \
        again. Repeat until CI is green.
        5. Only then create an annotated version tag on that commit and push \
        the tag. Do not tag a red commit. Do not move an existing tag.

        If the working tree is dirty with unrelated changes, stop and say so. \
        If you cannot see CI, say what you could not check and stop before \
        the tag.
        """
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
            // Each reply is 64 KiB. A finished run is not growing, so pull
            // until we have the display window or the host has no more.
            let id = live.id
            Task { await self.fetchTranscriptUntilCaughtUp(id: id) }
        }
    }

    private func startPolling(_ id: String) {
        guard isVisible else { return }
        if pollTask != nil, pollingID == id { return }
        stopPolling()
        pollingID = id
        pollTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetchTranscript(id: id, resetIfNeeded: true)
                ticks += 1
                // Status lives on the run list, not in the transcript. Refresh
                // it often enough that a finished job flips off Running
                // without switching screens.
                if ticks % 3 == 0 {
                    await self.refreshRuns()
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        pollingID = nil
    }

    /// Reload run rows so a live inspector sees ok / error / stopped.
    private func refreshRuns() async {
        do {
            let latest = try await Bridge.automationRuns()
            let before = runs.first { $0.id == watchingRunID }
            runs = latest
            let after = runs.first { $0.id == watchingRunID }
            if let before, let after, before.status != after.status, !after.isRunning {
                stopPolling()
                await fetchTranscriptUntilCaughtUp(id: after.id)
            }
        } catch {
            // The next tick tries again.
        }
    }

    private func fetchTranscriptUntilCaughtUp(id: String) async {
        var slices = 0
        while slices < 8 {
            slices += 1
            let before = transcriptOffset
            await fetchTranscript(id: id, resetIfNeeded: false)
            if watchingRunID != id { return }
            if transcriptOffset <= before { return }
            if transcriptText.utf8.count >= transcriptDisplayCap { return }
        }
    }

    private func fetchTranscript(id: String, resetIfNeeded: Bool) async {
        // The run being watched may have changed between ticks.
        if resetIfNeeded, watchingRunID != id {
            stopPolling()
            return
        }
        do {
            let chunk = try await Bridge.automationTranscript(id: id, offset: transcriptOffset)
            if chunk.nextOffset < transcriptOffset {
                // The host compacted the readable file. Start again from the
                // window it kept rather than appending onto dropped bytes.
                transcriptText = ""
                transcriptOffset = 0
                let again = try await Bridge.automationTranscript(id: id, offset: 0)
                transcriptText = Self.capped(again.text)
                transcriptOffset = again.nextOffset
                return
            }
            if !chunk.text.isEmpty {
                transcriptText = Self.capped(transcriptText + chunk.text)
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
        let time = String(format: "%d:%02d", s.hour, s.minute)
        switch s.kind {
        case .once: return "once, when you run it"
        case .interval:
            let minutes = Int(s.everySeconds) / 60
            if minutes >= 60, minutes % 60 == 0 {
                let hours = minutes / 60
                return "every \(hours) hour\(hours == 1 ? "" : "s")"
            }
            return "every \(minutes) minute\(minutes == 1 ? "" : "s")"
        case .daily: return "daily at \(time)"
        case .weekdays: return "weekdays at \(time)"
        case .weekly:
            // Prefer the multi-day bitset when present (host accepts both).
            if s.weekdays & 0b0111_1111 != 0 {
                return "\(Self.dayList(s.weekdays)) at \(time)"
            }
            let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
            let day = s.weekday >= 0 && s.weekday < 7 ? names[s.weekday] : "?"
            return "\(day) at \(time)"
        case .custom:
            let days = Self.dayList(s.weekdays)
            if days.isEmpty { return "custom at \(time)" }
            return "\(days) at \(time)"
        }
    }

    private static func capped(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > transcriptDisplayCap else { return text }
        var start = bytes.count - transcriptDisplayCap
        while start < bytes.count && bytes[start] & 0b1100_0000 == 0b1000_0000 {
            start += 1
        }
        if let newline = bytes[start...].firstIndex(of: UInt8(ascii: "\n")) {
            start = newline + 1
        }
        return String(decoding: bytes[start...], as: UTF8.self)
    }

    private static func dayList(_ mask: Int) -> String {
        let short = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return (0..<7).compactMap { bit -> String? in
            (mask & (1 << bit)) != 0 ? short[bit] : nil
        }.joined(separator: ", ")
    }
}
