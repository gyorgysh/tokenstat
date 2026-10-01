// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// A suggested setup on the Automations screen, pre-filling the sheet.
struct AutomationTemplate: Identifiable, Hashable, Sendable {
    var id: String { title }
    var title: String
    var subtitle: String
    var symbol: String
    var name: String
    var prompt: String
    var backendID: String
    var schedule: AutomationSchedule
    var budgetSeconds: UInt64
}

extension AutomationTemplate {
    static let suggested: [AutomationTemplate] = [
        AutomationTemplate(
            title: "Daily brief",
            subtitle: "Every morning at 8:00",
            symbol: "sunrise",
            name: "Daily brief",
            prompt: "Summarise yesterday's usage and flag anything that needs attention.",
            backendID: "claude",
            schedule: AutomationSchedule(kind: .daily, everySeconds: 0, hour: 8, minute: 0, weekday: 0),
            budgetSeconds: 600
        ),
        AutomationTemplate(
            title: "System health check",
            subtitle: "Every hour",
            symbol: "heart.text.square",
            name: "System health check",
            prompt: "Check disk, memory and CPU, and confirm the tokenstat daemon is running. Report anything abnormal.",
            backendID: "sh",
            schedule: AutomationSchedule(kind: .interval, everySeconds: 3600, hour: 0, minute: 0, weekday: 0),
            budgetSeconds: 120
        ),
        AutomationTemplate(
            title: "Dependency check",
            subtitle: "Every week",
            symbol: "shippingbox",
            name: "Dependency check",
            prompt: "Check for outdated or vulnerable dependencies (npm audit and the package managers this project uses) and summarise what needs a bump.",
            backendID: "sh",
            schedule: AutomationSchedule(kind: .weekly, hour: 9, minute: 0, weekday: 0),
            budgetSeconds: 900
        ),
        AutomationTemplate(
            title: "Weekday standup",
            subtitle: "Weekdays at 9:00",
            symbol: "person.3",
            name: "Weekday standup",
            prompt: "Summarise open work and anything that blocked progress yesterday. Keep it short.",
            backendID: "claude",
            schedule: AutomationSchedule(
                kind: .weekdays, hour: 9, minute: 0,
                weekdays: AutomationSchedule.weekdaysMask
            ),
            budgetSeconds: 600
        ),
        AutomationTemplate(
            title: "Release",
            subtitle: "Once, when you run it",
            symbol: "tag",
            name: "Release",
            prompt: releasePrompt,
            backendID: "claude",
            schedule: AutomationSchedule(kind: .once),
            budgetSeconds: 1800
        ),
    ]

    static let releasePrompt = """
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
