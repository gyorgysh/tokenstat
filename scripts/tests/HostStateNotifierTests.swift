// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with HostStateNotifier.swift.
import Foundation

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

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
        // A late timeout can follow unrelated successful calls. An explicit
        // helper answer must clear it even if no more user calls occur.
        let probed = DispatchSemaphore(value: 0)
        let probeLock = NSLock()
        var probeEvents: [Notification.Name] = []
        let checked = HostStateNotifier { name in
            probeLock.lock(); probeEvents.append(name); probeLock.unlock()
            if name == healthy { probed.signal() }
        }
        checked.post(failure, troubled: true, silent: true)
        checked.monitorSilence(healthy: healthy) { true }
        assert(probed.wait(timeout: .now() + 2) == .success)
        probeLock.lock(); let recovered = probeEvents; probeLock.unlock()
        assert(recovered == [failure, healthy])

        // An old probe may not hide a newer unreachable/recovery state.
        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        let newFailure = Notification.Name("newFailure")
        let oldProbeDone = DispatchSemaphore(value: 0)
        let fenced = HostStateNotifier { name in
            if name == healthy { oldProbeDone.signal() }
        }
        fenced.post(failure, troubled: true, silent: true)
        fenced.monitorSilence(healthy: healthy) {
            probeStarted.signal(); releaseProbe.wait(); return true
        }
        assert(probeStarted.wait(timeout: .now() + 2) == .success)
        fenced.post(newFailure, troubled: true)
        releaseProbe.signal()
        assert(oldProbeDone.wait(timeout: .now() + 0.2) == .timedOut)
        fenced.post(healthy, troubled: false)
        assert(oldProbeDone.wait(timeout: .now() + 2) == .success)
        // A second timeout while a probe is in flight must be checked again,
        // and multiple monitor requests must not spawn competing probes.
        let firstProbe = DispatchSemaphore(value: 0)
        let resumeProbe = DispatchSemaphore(value: 0)
        let secondProbe = DispatchSemaphore(value: 0)
        let resumeSecond = DispatchSemaphore(value: 0)
        let latestHealthy = DispatchSemaphore(value: 0)
        let count = Counter()
        let latest = HostStateNotifier { name in
            if name == healthy { latestHealthy.signal() }
        }
        latest.post(failure, troubled: true, silent: true)
        let probe: @Sendable () -> Bool = {
            let current = count.increment()
            if current == 1 { firstProbe.signal(); resumeProbe.wait() }
            else { secondProbe.signal(); resumeSecond.wait() }
            return true
        }
        latest.monitorSilence(healthy: healthy, probe: probe)
        assert(firstProbe.wait(timeout: .now() + 2) == .success)
        latest.post(failure, troubled: true, silent: true)
        latest.monitorSilence(healthy: healthy, probe: probe)
        resumeProbe.signal()
        assert(secondProbe.wait(timeout: .now() + 2) == .success)
        assert(latestHealthy.wait(timeout: .now() + 0.1) == .timedOut)
        resumeSecond.signal()
        assert(latestHealthy.wait(timeout: .now() + 2) == .success)
        assert(count.read() == 2)
        print("Host state: ordered delivery, independent recovery, coalescing and stale probe fencing passed")
    }
}
