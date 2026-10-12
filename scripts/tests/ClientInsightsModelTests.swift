// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientInsightsModel.swift; deterministic delayed bridge responses.
import Foundation
struct Bucket { var key: String }
struct AccountReport { var rows: [Bucket]; var fetchedAt = Date(); var stale = false }
enum WorkReference { typealias Scope = String }
@MainActor final class WorkSessionContext { static let shared = WorkSessionContext(); var scope: String? = "first" }
enum InsightDayAxis { static func title(_ key: String) -> String { key } }
func harnessName(_ key: String) -> String { key }
@MainActor enum Bridge {
    static var pending: [CheckedContinuation<AccountReport, Error>] = []
    static func accountReport(group: String) async throws -> AccountReport {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
}
@main struct ClientInsightsModelTests {
    @MainActor static func waitFor(_ count: Int) async { while Bridge.pending.count < count { await Task.yield() } }
    @MainActor static func main() async {
        let model = ClientInsightsModel()
        let first = Task { await model.load() }
        await waitFor(1)
        let refresh = Task { await model.refresh() }
        await waitFor(2)
        Bridge.pending[1].resume(returning: .init(rows: [.init(key: "new")]))
        await refresh.value
        Bridge.pending[0].resume(returning: .init(rows: [.init(key: "old")], stale: true))
        await first.value
        assert(model.rows(for: .model)?.first?.key == "new" && model.ageDescription == nil)
        Bridge.pending = []
        model.cut = .source
        let source = Task { await model.load() }
        await waitFor(1)
        model.cut = .day
        let day = Task { await model.load() }
        await waitFor(2)
        Bridge.pending[0].resume(returning: .init(rows: [.init(key: "source")], stale: true))
        await source.value
        assert(model.isLoading && model.ageDescription == nil)
        Bridge.pending[1].resume(returning: .init(rows: [.init(key: "day")]))
        await day.value
        model.cut = .source
        assert(model.ageDescription != nil && !model.isLoading)
        WorkSessionContext.shared.scope = "second"
        assert(model.rows(for: .source) == nil)
        Bridge.pending = []
        let second = Task { await model.load() }
        await waitFor(1)
        WorkSessionContext.shared.scope = "third"
        let third = Task { await model.load() }
        await waitFor(2)
        Bridge.pending[0].resume(throwing: NSError(domain: "old", code: 1))
        await second.value
        assert(model.errorMessage == nil && model.isLoading)
        Bridge.pending[1].resume(returning: .init(rows: [.init(key: "third")]))
        await third.value
        assert(model.rows(for: .source)?.first?.key == "third" && !model.isLoading)
        print("ClientInsightsModel: refresh ordering, cut metadata/spinner, account switch passed")
    }
}
