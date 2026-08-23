// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import AppKit
import SwiftUI

/// Reports stable, read-only window geometry to SwiftUI.
///
/// AppKit owns the titlebar, toolbar, split-view hierarchy, traffic lights,
/// masks, and constraint lifecycle. This observer must never mutate those
/// objects during a full-screen transition.
struct WindowScreenObserver: NSViewRepresentable {
    @Binding var contentWidth: CGFloat
    @Binding var isFullScreen: Bool
    @Binding var titlebarInset: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            Task { @MainActor in
                coordinator?.attach(
                    to: window,
                    contentWidth: $contentWidth,
                    isFullScreen: $isFullScreen,
                    titlebarInset: $titlebarInset
                )
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        MainActor.assumeIsolated {
            context.coordinator.contentWidth = $contentWidth
            context.coordinator.isFullScreen = $isFullScreen
            context.coordinator.titlebarInset = $titlebarInset
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var pendingPublish: Task<Void, Never>?
        var attachedWindow: NSWindow? { window }
        var contentWidth: Binding<CGFloat>?
        var isFullScreen: Binding<Bool>?
        var titlebarInset: Binding<CGFloat>?

        func attach(
            to window: NSWindow?,
            contentWidth: Binding<CGFloat>,
            isFullScreen: Binding<Bool>,
            titlebarInset: Binding<CGFloat>
        ) {
            self.contentWidth = contentWidth
            self.isFullScreen = isFullScreen
            self.titlebarInset = titlebarInset
            guard self.window !== window else {
                schedulePublish()
                return
            }
            detach()
            guard let window else { return }
            self.window = window
            observe(window)
            updateDisplayAndClamp(window)
            schedulePublish()
        }

        private func observe(_ window: NSWindow) {
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didChangeScreenNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    Task { @MainActor in
                        guard let self, let window, self.window === window else { return }
                        if name == NSWindow.didChangeScreenNotification {
                            self.updateDisplayAndClamp(window)
                        }
                        self.schedulePublish()
                    }
                })
            }
            observers.append(center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self, weak window] _ in
                Task { @MainActor in
                    guard let self, let window, self.window === window else { return }
                    self.updateDisplayAndClamp(window)
                    self.schedulePublish()
                }
            })
        }

        /// Publish on the next actor turn, after AppKit's current layout pass.
        private func schedulePublish() {
            pendingPublish?.cancel()
            pendingPublish = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, let window = self.window else { return }
                self.publish(from: window)
            }
        }

        private func publish(from window: NSWindow) {
            let width = quantised(window.contentLayoutRect.width, step: 4)
            if contentWidth?.wrappedValue != width { contentWidth?.wrappedValue = width }

            let fullScreen = window.styleMask.contains(.fullScreen)
            if isFullScreen?.wrappedValue != fullScreen { isFullScreen?.wrappedValue = fullScreen }

            let inset: CGFloat
            if let contentView = window.contentView {
                let layout = contentView.convert(window.contentLayoutRect, from: nil)
                inset = max(0, contentView.bounds.maxY - layout.maxY)
            } else {
                inset = 0
            }
            let stableInset = (inset * 2).rounded() / 2
            if titlebarInset?.wrappedValue != stableInset { titlebarInset?.wrappedValue = stableInset }
        }

        private func updateDisplayAndClamp(_ window: NSWindow) {
            DisplayFit.update(screen: window.screen)
            guard !window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
            let visible = screen.visibleFrame
            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            if frame != window.frame { window.setFrame(frame, display: false) }
        }

        private func quantised(_ value: CGFloat, step: CGFloat) -> CGFloat {
            (value / step).rounded() * step
        }

        private func detach() {
            pendingPublish?.cancel()
            pendingPublish = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            window = nil
        }

        deinit {
            pendingPublish?.cancel()
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

final class WindowReportingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
#endif
