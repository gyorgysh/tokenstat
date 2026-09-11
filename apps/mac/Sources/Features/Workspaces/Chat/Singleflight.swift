// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// One async operation at a time: concurrent callers share the in-flight
/// attempt instead of each starting their own.
///
/// The New chat button gives no feedback while the backend answers, so an
/// impatient second tap used to create a second conversation. Every create
/// path funnels through one of these, so the double tap awaits the same
/// answer rather than doubling the sidebar.
///
/// Main-actor confined, like its owners: the operation runs where the model
/// lives, and a second caller simply waits for the same task. A waiter that
/// is cancelled still gets the answer (waiting never throws), and the slot
/// clears exactly once, for the attempt that holds it.
@MainActor
final class Singleflight<Value: Sendable> {
    private var inFlight: Task<Value, Never>?

    /// True while an attempt is running. Views read this to disable the
    /// button that started it: the tap is answered, just not yet.
    var isRunning: Bool { inFlight != nil }

    func run(_ operation: @MainActor @Sendable @escaping () async -> Value) async -> Value {
        if let running = inFlight {
            return await running.value
        }
        let task = Task { await operation() }
        inFlight = task
        let value = await task.value
        // Unconditional: a contender can only arrive while this await is
        // suspended, and then it sees the slot as set and shares this task
        // instead of starting one. Nobody else can hold the slot, so nobody
        // else can have cleared or replaced it.
        inFlight = nil
        return value
    }
}
