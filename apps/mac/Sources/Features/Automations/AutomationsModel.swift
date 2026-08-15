// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import Foundation
import Observation

/// Renders a run transcript readably, caching the parsed result so a live
/// tail that polls every 400ms does not re-parse the whole stream on every
/// tick.
///
/// Claude's `--output-format stream-json` writes one JSON object per line:
/// system hooks, tool uses, assistant messages, and a final result. The
/// readable form keeps the assistant text and the result, and drops the
/// machinery. Non-JSON output (shell runs) passes through whole.
struct TranscriptRenderer {
    private var rawKey = ""
    private var cached = ""

    /// The readable form of `raw`, re-parsed only when the text changed.
    mutating func render(_ raw: String) -> String {
        if rawKey != raw {
            rawKey = raw
            cached = Self.readableTranscript(raw)
        }
        return cached
    }

    mutating func reset() {
        rawKey = ""
        cached = ""
    }

    static func readableTranscript(_ raw: String) -> String {
        guard !raw.isEmpty else { return "Waiting for output…" }
        var out: [String] = []
        // Split on the *string* separator, not the Character one: the pty
        // writes CRLF, and Swift treats CRLF as one grapheme cluster, so
        // splitting on Character("\n") finds nothing and the whole file is one
        // "line" that then fails to parse and passes through raw.
        for line in raw.components(separatedBy: "\n") {
            // `\r` ends pty lines and `.whitespaces` alone does not strip it;
            // ANSI show/hide-cursor escapes can also prefix a line.
            let cleaned = stripANSI(line)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.hasPrefix("{"),
                  let data = cleaned.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                // An occasional truncated or escape-polluted JSON line should
                // not dump raw machine JSON into the readable view.
                if !cleaned.contains("\"type\":") {
                    out.append(cleaned)
                }
                continue
            }

            let type = object["type"] as? String
            switch type {
            case "assistant":
                // `message.content` on newer SDKs, top-level `content` on
                // older ones. Text blocks are the words; tool blocks are not.
                let content = (object["message"] as? [String: Any])?["content"]
                    ?? object["content"]
                let texts = (content as? [[String: Any]])?
                    .compactMap { $0["text"] as? String } ?? []
                if !texts.isEmpty {
                    let block = texts.joined(separator: "\n")
                    // Claude re-emits the same final message across turns; the
                    // user and tool lines between the copies are filtered out,
                    // so without this the conclusion prints once per turn.
                    if out.last != block {
                        out.append(block)
                    }
                }
            case "result":
                if let result = object["result"] as? String, !result.isEmpty {
                    // Claude's final result repeats the last assistant
                    // message; do not print the conclusion twice.
                    if out.last != result {
                        out.append(result)
                    }
                }
            default:
                // System hooks, tool uses, and the prompt echo are the
                // machinery around the answer, not the answer.
                break
            }
        }
        let joined = out.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "(No readable output)" : joined
    }

    /// Removes ANSI escape sequences (e.g. `\u{1B}[?25h`) that the pty can
    /// interleave with the JSON stream.
    static func stripANSI(_ text: String) -> String {
        // Not a raw string: `\u{1B}` must become the ESC character in the
        // pattern, and `\\[` the regex's literal-bracket.
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
    }
}

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
    private(set) var runs: [RunRecord] = []
    private(set) var backends: [AgentBackend] = []

    /// True once the daemon has been read at least once. "No automations yet"
    /// and "not asked yet" are different answers and must not look the same.
    private(set) var hasLoaded = false

    var errorMessage: String?
    var noticeMessage: String?

    /// The readable form of the watched transcript, parsed once per change
    /// rather than on every poll.
    var readableTranscript: String {
        transcriptRenderer.render(transcriptText)
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
    private var noticeGeneration = 0
    private var transcriptRenderer = TranscriptRenderer()

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

    func load() async {
        do {
            async let j = Bridge.automations()
            async let r = Bridge.automationRuns()
            async let b = Bridge.automationBackends()
            jobs = try await j
            runs = try await r
            backends = try await b
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
        let job = Automation(
            id: "", name: name, backend: backend, model: model, effort: effort,
            workspaceID: workspaceID, prompt: prompt,
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

    func update(_ job: Automation) async {
        do {
            _ = try await Bridge.updateAutomation(job)
            errorMessage = nil
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
        let name = "Auto commit"
        let prompt = Self.autoCommitPrompt(workspaceName: workspaceName)
        let schedule = AutomationSchedule(kind: .once)
        if var existing = jobs.first(where: {
            $0.name == name && $0.workspaceID == workspaceID
        }) {
            existing.backend = backend
            existing.model = model
            existing.prompt = prompt
            existing.enabled = true
            await update(existing)
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
        transcriptRenderer.reset()
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
        guard isVisible, pollTask == nil else { return }
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

    private static func dayList(_ mask: Int) -> String {
        let short = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return (0..<7).compactMap { bit -> String? in
            (mask & (1 << bit)) != 0 ? short[bit] : nil
        }.joined(separator: ", ")
    }
}
