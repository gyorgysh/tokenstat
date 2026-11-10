// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

// The generated companion file inserts the original InsightsModel.scan body.
// Timers and refresh transport are controllable stubs; no host or window opens.
import Foundation

struct ScanReport { let eventsNew: UInt64; let filesRead: UInt64 }
struct FakeError: LocalizedError { let message: String; var errorDescription: String? { message } }
enum L10n { static func text(_ key: String, _ args: String...) -> String { key } }
extension Notification.Name { static let archiveDidChange = Notification.Name("fixture.archiveDidChange") }

@MainActor enum Bridge {
    static var continuation: CheckedContinuation<ScanReport, Error>?
    static func scan() async throws -> ScanReport {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

@MainActor final class Model {
    var isScanning = false
    var scanCooldownUntil: Date?
    var actionMessage: String?
    var errorMessage: String?
    var refreshContinuation: CheckedContinuation<Void, Never>?
    var refreshFailure = false
    func showAction(_ message: String) { actionMessage = message }
    func startCooldown(seconds: TimeInterval, clearing: ReferenceWritableKeyPath<Model, Date?>) {
        self[keyPath: clearing] = Date().addingTimeInterval(seconds)
    }
    func refresh() async {
        await withCheckedContinuation { refreshContinuation = $0 }
        if refreshFailure { errorMessage = "refresh offline" }
    }
    // ORIGINAL_SCAN_METHOD
}

final class NoticeBox: @unchecked Sendable {
    var count = 0
    var scanning = false
    var error: String?
}

@main struct Reference {
    @MainActor static func main() async throws {
        var cases = [[String: Any]]()
        for scenario in ["success", "refresh_error", "scan_error"] {
            let model = Model()
            model.refreshFailure = scenario == "refresh_error"
            let notices = NoticeBox()
            let observer = NotificationCenter.default.addObserver(forName: .archiveDidChange, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated {
                    notices.count += 1
                    notices.scanning = model.isScanning
                    notices.error = model.errorMessage
                }
            }
            func point(_ label: String, scanning: Bool? = nil, error: String? = nil) -> [String: Any] {
                ["label":label,"scanning":scanning ?? model.isScanning,
                 "cooldown":model.scanCooldownUntil != nil,"action":model.actionMessage != nil,
                 "error":error as Any? ?? model.errorMessage as Any? ?? NSNull(),"notifications":notices.count]
            }
            let task = Task { await model.scan() }
            while Bridge.continuation == nil { await Task.yield() }
            var points = [point("scan held")]
            await model.scan() // Must return without issuing another scan.
            let continuation = Bridge.continuation!
            Bridge.continuation = nil
            if scenario == "scan_error" {
                continuation.resume(throwing: FakeError(message:"scan offline"))
                await task.value
                points.append(point("finished"))
            } else {
                continuation.resume(returning: ScanReport(eventsNew:2, filesRead:1))
                while model.refreshContinuation == nil { await Task.yield() }
                points.append(point("refresh held"))
                model.refreshContinuation!.resume()
                await task.value
                points.append(point("notification", scanning:notices.scanning, error:notices.error))
                points.append(point("finished"))
            }
            NotificationCenter.default.removeObserver(observer)
            cases.append(["scenario":scenario,"points":points])
        }
        let output = try JSONSerialization.data(withJSONObject: cases, options: [.sortedKeys])
        print(String(decoding: output, as: UTF8.self))
    }
}
