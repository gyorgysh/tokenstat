// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import GameController
import SwiftUI
import UIKit

/// Which shape the client draws itself in.
///
/// An iPad in a Magic Keyboard is a laptop running the phone build: landscape,
/// a thousand points wide, a trackpad, and a floating tab bar sized for a thumb
/// that is nowhere near the screen. With a keyboard attached, navigation
/// belongs down the left side, where the pointer already is.
enum ClientLayoutMode: Equatable {
    /// The phone's floating tab bar. Every iPhone, and an iPad held in a hand.
    case tabs
    /// A left sidebar, the way the Mac app is laid out.
    case sidebar
}

/// What the person chose, which always beats what the app worked out.
///
/// Stage Manager, an external display, a keyboard used only for typing, and
/// somebody who simply prefers the tab bar all end here, and none of them
/// need a new heuristic.
enum ClientLayoutPreference: String, CaseIterable, Identifiable {
    case automatic
    case sidebar
    case tabs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .sidebar: return "Sidebar"
        case .tabs: return "Tabs"
        }
    }

    var detail: String {
        switch self {
        case .automatic: return "Sidebar when a keyboard or trackpad is attached and there is room."
        case .sidebar: return "Always the sidebar, on this iPad."
        case .tabs: return "Always the tab bar."
        }
    }
}

/// The decision itself, kept out of the view so it can be reasoned about.
///
/// Three inputs in order, and all three have to agree before the layout
/// changes: a wrong guess moves the whole interface under somebody.
enum ClientLayout {
    /// Below this the sidebar is not a desktop, it is a squeeze. A third-width
    /// Split View is regular horizontally on a 13 inch iPad, so size class
    /// alone would put a sidebar into 375 points.
    static let minimumSidebarWidth: CGFloat = 820

    static func mode(
        preference: ClientLayoutPreference,
        hasDesktopInput: Bool,
        sizeClass: UserInterfaceSizeClass?,
        width: CGFloat
    ) -> ClientLayoutMode {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return .tabs }
        switch preference {
        case .tabs:
            return .tabs
        case .sidebar:
            // Still not into a squeeze. The setting says "prefer", and half a
            // Split View cannot hold a sidebar and a screen.
            return width >= minimumSidebarWidth ? .sidebar : .tabs
        case .automatic:
            guard hasDesktopInput else { return .tabs }
            guard sizeClass == .regular else { return .tabs }
            return width >= minimumSidebarWidth ? .sidebar : .tabs
        }
    }
}

/// Whether this iPad has a keyboard or a pointer attached right now.
///
/// Two sources, because neither alone is enough:
/// - **GameController** answers for keyboards outright. `GCKeyboard.coalesced`
///   is the state now and the two notifications are the changes, and it covers
///   the Magic Keyboard, the Folio and any Bluetooth keyboard.
/// - **A hover probe** answers for pointers. A trackpad is not guaranteed to
///   publish a `GCMouse`, but a hover event cannot happen without a pointer, so
///   one crossing proves one exists. See `PointerProbe`.
///
/// Attaching a Magic Keyboard fires several notifications inside a few hundred
/// milliseconds, so what this publishes is debounced. The interface swapping
/// twice would be worse than swapping late.
@MainActor
@Observable
final class PointerKeyboardModel {
    private(set) var hasKeyboard = false
    private(set) var hasPointer = false

    /// Either one is enough. A keyboard with no trackpad still wants the
    /// sidebar, and a mouse with no keyboard is still a desk.
    var hasDesktopInput: Bool { hasKeyboard || hasPointer }

    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var publishTask: Task<Void, Never>?
    /// Latched by the probe. Cleared when the last mouse disconnects, which is
    /// the only disconnect signal a trackpad reliably gives.
    private var sawHover = false

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        for name in [
            NSNotification.Name.GCKeyboardDidConnect,
            NSNotification.Name.GCKeyboardDidDisconnect,
            NSNotification.Name.GCMouseDidConnect,
            NSNotification.Name.GCMouseDidDisconnect,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let disconnectedMouse = note.name == NSNotification.Name.GCMouseDidDisconnect
                    Task { @MainActor [weak self] in
                        if disconnectedMouse { self?.sawHover = false }
                        self?.schedulePublish()
                    }
                }
            )
        }
        schedulePublish()
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        publishTask?.cancel()
        started = false
    }

    /// A pointer crossed the app. Only a pointer can do that.
    func noteHover() {
        guard !sawHover else { return }
        sawHover = true
        schedulePublish()
    }

    private func schedulePublish() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }

    private func publish() {
        let keyboard = GCKeyboard.coalesced != nil
        let mouse = !GCMouse.mice().isEmpty
        let pointer = mouse || sawHover
        if keyboard != hasKeyboard { hasKeyboard = keyboard }
        if pointer != hasPointer { hasPointer = pointer }
    }
}

/// A zero-size view that reports the first pointer crossing.
///
/// `UIHoverGestureRecognizer` fires only where a pointer exists, so this is a
/// yes-only answer and it never has to guess.
///
/// The recognizer goes on the **window**, not on this view. A view that has to
/// be hit-tested to see a hover is a view that also swallows taps, and a view
/// that refuses hit testing never sees the hover either. A hover recognizer on
/// the window sees the pointer wherever it enters and consumes nothing: it is
/// not a touch gesture, so no control below it loses an event.
struct PointerProbe: UIViewRepresentable {
    let onHover: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = ProbeView()
        view.onHover = onHover
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        (view as? ProbeView)?.onHover = onHover
    }

    final class ProbeView: UIView {
        var onHover: (() -> Void)?
        private var installed: UIHoverGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, installed == nil else { return }
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
            window.addGestureRecognizer(hover)
            installed = hover
        }

        @objc func hovered(_ recognizer: UIHoverGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            onHover?()
        }
    }
}

extension View {
    /// Install the pointer probe behind this view.
    func clientPointerProbe(_ input: PointerKeyboardModel) -> some View {
        background(
            PointerProbe { input.noteHover() }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}

#endif
