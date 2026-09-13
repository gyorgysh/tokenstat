// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// The reusable once-job Changes starts. One folder has one Auto commit job.
/// The scheduler never calls gitwrite. The agent commits because a person
/// pressed the button.
enum AutoCommitJob {
    static let name = "Auto commit"
    static let budgetSeconds: UInt64 = 900

    static func isName(_ name: String) -> Bool {
        name.compare(Self.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    static func prompt(workspaceName: String) -> String {
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

    /// Agents that can write a commit. Shell stays out even if it was stored.
    static func commitBackends(_ backends: [AgentBackend], keeping id: String? = nil) -> [AgentBackend] {
        var out = backends.filter { $0.id != "sh" && !$0.models.isEmpty }
        if let id, !id.isEmpty, id != "sh", !out.contains(where: { $0.id == id }),
           let extra = backends.first(where: { $0.id == id })
        {
            out.append(extra)
        }
        return out
    }

    static func preferredModel(in backend: AgentBackend?, stored: String) -> String {
        guard let backend else { return "" }
        if backend.models.contains(stored) { return stored }
        if backend.models.contains("haiku") { return "haiku" }
        return backend.models.first ?? ""
    }

    static func job(
        in workspaceID: String,
        workspaceName: String,
        backend: String,
        model: String?,
        existing: Automation? = nil
    ) -> Automation {
        var job = existing ?? Automation(
            id: "",
            name: name,
            backend: backend,
            model: model,
            effort: nil,
            workspaceID: workspaceID,
            prompt: prompt(workspaceName: workspaceName),
            schedule: AutomationSchedule(kind: .once),
            budgetSeconds: budgetSeconds,
            enabled: true
        )
        job.name = name
        job.backend = backend
        job.model = model
        job.prompt = prompt(workspaceName: workspaceName)
        job.schedule = AutomationSchedule(kind: .once)
        job.budgetSeconds = budgetSeconds
        job.enabled = true
        job.workspaceID = workspaceID
        return job
    }

    static func match(in jobs: [Automation], workspaceID: String) -> Automation? {
        jobs.first { $0.workspaceID == workspaceID && isName($0.name) }
    }
}
