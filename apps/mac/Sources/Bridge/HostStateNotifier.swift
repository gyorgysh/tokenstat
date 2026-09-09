// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// State transitions and their delivery must have the same order. Scheduling
/// stays inside the lock; the supplied scheduler must enqueue without reentry.
final class HostStateNotifier: @unchecked Sendable {
    private let lock = NSLock()
    private var troubled = false
    private let schedule: (Notification.Name) -> Void

    init(schedule: @escaping (Notification.Name) -> Void = { name in
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }) {
        self.schedule = schedule
    }

    func post(_ name: Notification.Name, troubled next: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let changed = troubled != next
        troubled = next
        guard next || changed else { return }
        schedule(name)
    }
}
