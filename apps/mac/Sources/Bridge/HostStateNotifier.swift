// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// State transitions and their delivery must have the same order. Scheduling
/// stays inside the lock; the supplied scheduler must enqueue without reentry.
final class HostStateNotifier: @unchecked Sendable {
    private let lock = NSLock()
    private var troubled = false
    private var silent = false
    private var revision: UInt64 = 0
    private var monitoring = false
    private let schedule: (Notification.Name) -> Void

    init(schedule: @escaping (Notification.Name) -> Void = { name in
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }) {
        self.schedule = schedule
    }

    func post(_ name: Notification.Name, troubled next: Bool, silent isSilent: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let changed = troubled != next
        troubled = next
        silent = isSilent
        revision &+= 1
        guard next || changed else { return }
        schedule(name)
    }
    /// Check the helper independently of the slow request. Only the timeout
    /// being checked may be cleared; a later failure or recovery owns its own
    /// state. A single monitor retries while the helper stays silent.
    func monitorSilence(healthy: Notification.Name, probe: @escaping @Sendable () -> Bool) {
        lock.lock()
        guard silent, !monitoring else { lock.unlock(); return }
        monitoring = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            checkSilence(healthy: healthy, probe: probe)
        }
    }

    private func checkSilence(healthy: Notification.Name, probe: @escaping @Sendable () -> Bool) {
        lock.lock()
        guard silent else { monitoring = false; lock.unlock(); return }
        let ticket = revision
        lock.unlock()

        let answered = probe()
        lock.lock()
        if silent && revision == ticket && answered {
            troubled = false
            silent = false
            revision &+= 1
            monitoring = false
            schedule(healthy)
            lock.unlock()
            return
        }
        guard silent else { monitoring = false; lock.unlock(); return }
        let delay: TimeInterval = revision == ticket ? 5 : 0
        lock.unlock()
        // Do not occupy a worker thread while waiting for the next probe.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
            checkSilence(healthy: healthy, probe: probe)
        }
    }
}
