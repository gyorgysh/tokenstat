// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with PushRegistrationQueue.swift.
import Foundation

@main struct PushRegistrationQueueTests {
    @MainActor static func main() async {
        let queue = PushRegistrationQueue()
        var registrationStarted = false
        var finishRegistration: CheckedContinuation<Void, Never>?
        var calls: [String] = []
        queue.enqueue {
            calls.append("register-start")
            registrationStarted = true
            await withCheckedContinuation { finishRegistration = $0 }
            calls.append("register-finish")
        }
        while !registrationStarted { await Task.yield() }
        let removed = queue.enqueue { calls.append("unregister") }
        for _ in 0..<20 { await Task.yield() }
        assert(calls == ["register-start"], "Removal must wait for the in-flight registration")
        finishRegistration?.resume()
        await removed.value
        assert(calls == ["register-start", "register-finish", "unregister"])

        // A later enable waits behind removal and can register again.
        await queue.enqueue { calls.append("register-again") }.value
        assert(calls.last == "register-again")
        print("Push registration queue: delayed registration, disable and re-enable ordering passed")
    }
}
