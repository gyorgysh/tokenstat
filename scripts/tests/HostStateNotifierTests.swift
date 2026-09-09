// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with HostStateNotifier.swift.
import Foundation

@main struct HostStateNotifierTests {
    static func main() {
        let failure = Notification.Name("failure")
        let healthy = Notification.Name("healthy")
        let schedulingFailure = DispatchSemaphore(value: 0)
        let releaseFailure = DispatchSemaphore(value: 0)
        let recoveryReturned = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        let resultLock = NSLock()
        var delivered: [Notification.Name] = []
        let notifier = HostStateNotifier { name in
            if name == failure {
                schedulingFailure.signal()
                releaseFailure.wait()
            }
            resultLock.lock()
            delivered.append(name)
            resultLock.unlock()
        }
        notifier.post(healthy, troubled: false)
        done.enter()
        DispatchQueue.global().async {
            notifier.post(failure, troubled: true)
            done.leave()
        }
        schedulingFailure.wait()
        done.enter()
        DispatchQueue.global().async {
            notifier.post(healthy, troubled: false)
            recoveryReturned.signal()
            done.leave()
        }
        // A recovery must not overtake a failure whose delivery is scheduling.
        assert(recoveryReturned.wait(timeout: .now() + 0.1) == .timedOut)
        releaseFailure.signal()
        done.wait()
        notifier.post(healthy, troubled: false)
        assert(delivered == [failure, healthy])
        print("Host state: ordered concurrent delivery and quiet healthy calls passed")
    }
}
