// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Give the first send time to populate the retained reader before revealing
/// it. This is a ceiling on waiting, never a minimum animation duration.
@MainActor enum ChatStartPreparation {
    static let budget: Duration = .milliseconds(1600)
    private final class Completion { var finished = false }

    static func preload(until deadline: ContinuousClock.Instant,
                        send: @escaping @MainActor () async -> Void) async {
        let completion = Completion()
        // A presentation timeout or navigation away must not cancel an
        // authorized send, lose its receipt or start another copy of it.
        Task {
            await send()
            completion.finished = true
        }
        await Task.yield()
        let clock = ContinuousClock()
        while !completion.finished, clock.now < deadline {
            do {
                try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(16))))
            } catch { return }
        }
    }
}
