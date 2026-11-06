// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import AppKit

/// Nested SwiftUI/AppKit targets do not all receive the accepted drop.
/// End their hover states together, including when the source cancels outside
/// the app and no destination callback arrives.
@MainActor final class ChatDragSession {
    static let shared = ChatDragSession()
    static let ended = Notification.Name("ai.tokenstat.chatDragEnded")
    private let buttonIsDown: () -> Bool
    private let notifications: NotificationCenter
    private var timer: Timer?
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    var isWatching: Bool { timer != nil }

    init(buttonIsDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons != 0 },
         notifications: NotificationCenter = .default) {
        self.buttonIsDown = buttonIsDown; self.notifications = notifications
    }

    func begin() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForEnd() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consume = MainActor.assumeIsolated {
                guard event.keyCode == 53, let self else { return false }
                let hasSheet = event.window?.attachedSheet != nil || event.window?.sheetParent != nil
                    || NSApp.modalWindow != nil
                return self.escape(hasSheet: hasSheet)
            }
            return consume ? nil : event
        }
        activationObserver = notifications.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
    }

    func checkForEnd() {
        if !buttonIsDown() { finish() }
    }

    /// Let AppKit cancel a live drag. A later Escape clears stale hover
    /// without reaching the composer's Stop action or dismissing a sheet.
    func escape(hasSheet: Bool) -> Bool {
        guard isWatching else { return false }
        let consume = !buttonIsDown() && !hasSheet
        finish()
        return consume
    }

    func finish() {
        guard let timer else { return }
        timer.invalidate(); self.timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let activationObserver { notifications.removeObserver(activationObserver); self.activationObserver = nil }
        notifications.post(name: Self.ended, object: nil)
    }

    deinit {
        timer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let activationObserver { notifications.removeObserver(activationObserver) }
    }
}
#endif
