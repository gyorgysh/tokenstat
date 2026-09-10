// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import AppKit
import SwiftUI

/// Arrow navigation belongs only to the visible chat in this window. Text
/// editors keep their cursor keys, and sheets keep their own key handling.
struct ChatNavigationKeys: NSViewRepresentable {
    var isActive: Bool
    var move: (Int) -> Bool

    func makeNSView(context: Context) -> KeyView { KeyView() }

    func updateNSView(_ view: KeyView, context: Context) {
        view.isActive = isActive
        view.move = move
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }

    final class KeyView: NSView {
        var isActive = false
        var move: ((Int) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isActive, let window = self.window,
                      window.isKeyWindow, event.window === window,
                      window.attachedSheet == nil,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      !(window.firstResponder is NSTextView),
                      !(window.firstResponder is NSControl) else { return event }
                let step: Int
                switch event.keyCode {
                case 126: step = -1 // Up arrow
                case 125: step = 1  // Down arrow
                default: return event
                }
                return self.move?(step) == true ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
#endif
