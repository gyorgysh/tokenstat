// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with RepositoryNextStep.swift.
import Foundation

@main enum RepositoryNextStepTests {
    static func main() {
        typealias Pull = RepositoryFacts.Pull
        func next(_ edit: (inout RepositoryFacts) -> Void) -> RepositoryNextStep {
            var facts = RepositoryFacts()
            edit(&facts)
            return RepositoryNextStep.next(facts)
        }

        precondition(next { _ in } == .clear, "nothing known is clear")
        precondition(next { $0.exists = false; $0.waitingChatIDs = ["a"] } == .missing, "a missing folder says only that")
        precondition(next { $0.unpushedCommits = 3 } == .unpushed(commits: 3))
        precondition(next { $0.behindCommits = 42 } == .behind(commits: 42))
        precondition(next { $0.behindCommits = 42; $0.unpushedCommits = 1 } == .unpushed(commits: 1), "own work before others'")
        precondition(next { $0.unpushedCommits = 3; $0.changedFiles = 9 } == .uncommitted(files: 9), "commit comes before push")
        precondition(next { $0.changedFiles = 9; $0.runningChats = 2 } == .working(count: 2))
        precondition(next { $0.runningChats = 1; $0.waitingChatIDs = ["a"] } == .waiting(chatID: "a"), "a person blocking work wins")
        precondition(next { $0.reachable = false; $0.changedFiles = 4 } == .asleep, "old counts are not a step on a sleeping computer")

        let failing = Pull(number: 7, mine: true, failing: true, review: "approved")
        precondition(next { $0.pulls = [failing]; $0.runningChats = 1 } == .checksFailed(pull: 7))
        precondition(next { $0.pulls = [Pull(number: 7, mine: false, failing: true)] } == .clear, "another person's checks are theirs")
        precondition(next { $0.pulls = [Pull(number: 7, mine: true, draft: true, failing: true)] } == .clear, "a draft owes nothing")
        precondition(next { $0.pulls = [Pull(number: 8, mine: true, passing: true, review: "approved")] } == .readyToMerge(pull: 8))
        precondition(next { $0.pulls = [Pull(number: 8, mine: true, review: "approved")] } == .clear, "checks still running are not ready")
        precondition(next { $0.pulls = [Pull(number: 8, mine: true, passing: true)] } == .clear, "nobody approved it")
        precondition(next { $0.pulls = [Pull(number: 9, mine: false, reviewRequested: true)] } == .reviewRequested(pull: 9))

        var many = RepositoryFacts()
        many.waitingChatIDs = ["a", "b"]
        many.pulls = [failing, Pull(number: 9, mine: false, reviewRequested: true)]
        precondition(RepositoryNextStep.owed(many) == [.waiting(chatID: "a"), .waiting(chatID: "b"), .checksFailed(pull: 7), .reviewRequested(pull: 9)])
        precondition(RepositoryNextStep.owed(many).map(\.rank) == RepositoryNextStep.owed(many).map(\.rank).sorted(), "owed steps are already ranked")
        precondition(RepositoryNextStep.owed(many).allSatisfy(\.needsPerson))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func quiet(_ edit: (inout RepositoryFacts) -> Void) -> Bool {
            var facts = RepositoryFacts()
            edit(&facts)
            return RepositoryNextStep.isQuiet(facts, now: now)
        }
        precondition(quiet { _ in })
        precondition(quiet { $0.lastActivity = now.addingTimeInterval(-15 * 86_400) })
        precondition(!quiet { $0.lastActivity = now.addingTimeInterval(-13 * 86_400) })
        precondition(quiet { $0.behindCommits = 5 }, "behind and unused is still quiet")
        precondition(!quiet { $0.hasRecentUsage = true })
        precondition(!quiet { $0.changedFiles = 1 }, "unfinished work is never quiet")
        precondition(!quiet { $0.exists = false }, "a missing folder has to be seen")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Budapest")!
        let spring = calendar.date(from: DateComponents(year: 2026, month: 4, day: 2, hour: 0, minute: 30))!
        let keys = RepositoryDays.keys(now: spring, calendar: calendar)
        precondition(keys.count == 14 && keys.last == "2026-04-02" && keys.first == "2026-03-20", "a clock change does not skip a day")
        precondition(Set(keys).count == 14)
        precondition(RepositoryDays.date("2026-04-02", calendar: calendar).map { RepositoryDays.key($0, calendar: calendar) } == "2026-04-02")
        precondition(RepositoryDays.date("nope") == nil)

        precondition(RepositoryOrder.merge(held: ["b", "gone", "a"], current: ["a", "b", "new"]) == ["b", "a", "new"])
        precondition(RepositoryOrder.move(from: 0, by: -1, count: 3) == nil)
        precondition(RepositoryOrder.move(from: 1, by: 2, count: 3) == nil)
        precondition(RepositoryOrder.move(from: 0, by: 2, count: 3) == 2)
        print("Repository next step: ranking, ownership, quiet, days and order passed")
    }
}
