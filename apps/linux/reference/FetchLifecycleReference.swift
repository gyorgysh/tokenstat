// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Original InsightsModel.fetchRemotes is inserted into controlled async stubs.
import Foundation
struct FetchReport { let message: String? }
struct FakeError: LocalizedError { let message: String; var errorDescription: String? { message } }
enum L10n { static func text(_ key: String, _ args: String...) -> String { "Remote fetch complete." } }
extension Notification.Name { static let archiveDidChange = Notification.Name("fixture.archiveDidChange") }
@MainActor enum Bridge {
    static var continuation: CheckedContinuation<[FetchReport], Error>?
    static func fetchRemotes() async throws -> [FetchReport] {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}
@MainActor final class Model {
    var isFetching = false
    var fetchCooldownUntil: Date?
    var actionMessage: String? = "old"
    var errorMessage: String?
    var refreshContinuation: CheckedContinuation<Void, Never>?
    var refreshFailure = false
    var cooldownSeconds: Double?
    func showAction(_ message: String) { actionMessage = message }
    func startCooldown(seconds: TimeInterval, clearing: ReferenceWritableKeyPath<Model, Date?>) {
        cooldownSeconds = seconds
        self[keyPath: clearing] = Date().addingTimeInterval(seconds)
    }
    func refresh() async {
        await withCheckedContinuation { refreshContinuation = $0 }
        if refreshFailure { errorMessage = "refresh offline" }
    }
    // ORIGINAL_FETCH_METHOD
}
final class NoticeBox: @unchecked Sendable { var count = 0; var fetching = false; var error: String? }
@main struct Reference {
    @MainActor static func main() async throws {
        var cases = [[String: Any]]()
        for scenario in ["empty", "messages", "refresh_error", "fetch_error"] {
            let model = Model()
            model.refreshFailure = scenario == "refresh_error"
            let notices = NoticeBox()
            let observer = NotificationCenter.default.addObserver(forName: .archiveDidChange, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { notices.count += 1; notices.fetching = model.isFetching; notices.error = model.errorMessage }
            }
            func point(_ label: String, fetching: Bool? = nil, error: String? = nil) -> [String: Any] {
                ["label":label,"fetching":fetching ?? model.isFetching,"cooldown":model.fetchCooldownUntil != nil,
                 "cooldownSeconds":model.cooldownSeconds as Any? ?? NSNull(), "action":model.actionMessage as Any? ?? NSNull(),
                 "error":error as Any? ?? model.errorMessage as Any? ?? NSNull(),"notifications":notices.count]
            }
            let task = Task { await model.fetchRemotes() }
            while Bridge.continuation == nil { await Task.yield() }
            var points = [point("fetch held")]
            await model.fetchRemotes()
            let continuation = Bridge.continuation!
            Bridge.continuation = nil
            if scenario == "fetch_error" {
                continuation.resume(throwing: FakeError(message:"fetch offline"))
                await task.value
                points.append(point("finished"))
            } else {
                let reports = scenario == "messages" ? [FetchReport(message:"one"), FetchReport(message:nil), FetchReport(message:"two")] : []
                continuation.resume(returning: reports)
                while model.refreshContinuation == nil { await Task.yield() }
                points.append(point("refresh held"))
                model.refreshContinuation!.resume()
                await task.value
                points.append(point("notification", fetching:notices.fetching, error:notices.error))
                points.append(point("finished"))
            }
            NotificationCenter.default.removeObserver(observer)
            cases.append(["scenario":scenario,"points":points])
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: cases, options: [.sortedKeys]), as: UTF8.self))
    }
}
