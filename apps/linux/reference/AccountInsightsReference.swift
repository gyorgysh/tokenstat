// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

// The original ClientInsightsModel is inserted into this inert async harness.
// All identities, reports and suspended host responses are synthetic.
import Foundation
import Observation

struct WorkReference { struct Scope: Hashable, Sendable { let name: String } }
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope?
}
struct Bucket: Sendable { let key: String }
struct AccountReport: Sendable { let rows: [Bucket]; let group: String; let stale: Bool; let fetchedAt: Date }
enum L10n { static func text(_ key: String, _ args: String...) -> String { key } }
enum InsightDayAxis { static func title(_ key: String) -> String { key } }
func harnessName(_ key: String) -> String { key }
struct FakeError: LocalizedError { var errorDescription: String? { "Please sign in" } }

@MainActor enum Bridge {
    static var pending: [(String, CheckedContinuation<AccountReport, Error>)] = []
    static func accountReport(group: String) async throws -> AccountReport {
        try await withCheckedThrowingContinuation { pending.append((group, $0)) }
    }
    static func take() async -> (String, CheckedContinuation<AccountReport, Error>) {
        while pending.isEmpty { await Task.yield() }
        return pending.removeFirst()
    }
}

// ORIGINAL_MODEL

@main struct Reference {
    @MainActor static func main() async throws {
        let a=WorkReference.Scope(name:"a"), b=WorkReference.Scope(name:"b")
        WorkSessionContext.shared.scope=a
        let model=ClientInsightsModel()
        func report(_ group: String, _ key: String) -> AccountReport {
            AccountReport(rows:[Bucket(key:key)],group:group,stale:false,fetchedAt:Date(timeIntervalSince1970:0))
        }
        func point(_ label: String) -> [String: Any] {
            func keys(_ cut: ClientInsightsModel.Cut) -> Any { model.rows(for:cut).map { $0.map(\.key) } as Any? ?? NSNull() }
            return ["label":label,"cut":model.cut.rawValue,"loading":model.isLoading,
                    "model":keys(.model),"source":keys(.source),"day":keys(.day),
                    "error":model.errorMessage as Any? ?? NSNull(),"needsSignIn":model.needsSignIn]
        }
        var out=[[String: Any]]()
        let first=Task { await model.load() }; let old=await Bridge.take(); out.append(point("first"))
        let second=Task { await model.load() }; let new=await Bridge.take()
        old.1.resume(returning:report(old.0,"old")); await first.value; out.append(point("old reply"))
        new.1.resume(returning:report(new.0,"one")); await second.value; out.append(point("model loaded"))
        await model.load(); precondition(Bridge.pending.isEmpty)
        model.cut = .day; let dayTask=Task { await model.load() }; let day=await Bridge.take()
        model.cut = .source; let refreshTask=Task { await model.refresh() }; let fresh=await Bridge.take(); out.append(point("refresh"))
        day.1.resume(returning:report(day.0,"stale")); await dayTask.value; out.append(point("stale day"))
        fresh.1.resume(returning:report(fresh.0,"tool")); await refreshTask.value; out.append(point("source loaded"))
        let priorTask=Task { await model.refresh() }; let prior=await Bridge.take()
        WorkSessionContext.shared.scope=b; out.append(point("scope changed"))
        let nextTask=Task { await model.load() }; let next=await Bridge.take()
        prior.1.resume(returning:report(prior.0,"private")); await priorTask.value; out.append(point("old account"))
        next.1.resume(throwing:FakeError()); await nextTask.value; out.append(point("failure"))
        let cancelledTask=Task { await model.load() }; let cancelled=await Bridge.take(); cancelledTask.cancel()
        cancelled.1.resume(returning:report(cancelled.0,"cancelled")); await cancelledTask.value; out.append(point("cancelled"))
        let retryTask=Task { await model.load() }; let retry=await Bridge.take()
        retry.1.resume(returning:report(retry.0,"new")); await retryTask.value; out.append(point("retry"))
        print(String(decoding:try JSONSerialization.data(withJSONObject:out,options:[.sortedKeys]),as:UTF8.self))
    }
}
