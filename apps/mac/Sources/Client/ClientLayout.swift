// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import GameController
import SwiftUI
import UIKit

enum ClientLayoutMode: Equatable {
    case tabs
    case sidebar
}

enum ClientLayoutPreference: String, CaseIterable, Identifiable {
    case automatic
    case sidebar
    case tabs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return L10n.text("apple.clientlayout.automatic.d461a493")
        case .sidebar: return L10n.text("apple.clientlayout.sidebar.f7efa7bc")
        case .tabs: return L10n.text("apple.clientlayout.tabs.8e5ea509")
        }
    }

    var detail: String {
        switch self {
        case .automatic: return L10n.text("apple.clientlayout.sidebar_when_a_keyboard_or_trackpad_is_att.936c310e")
        case .sidebar: return L10n.text("apple.clientlayout.always_the_sidebar_on_this_ipad.b8da017a")
        case .tabs: return L10n.text("apple.clientlayout.always_the_tab_bar.4c8a527c")
        }
    }
}

enum ClientLayout {
    static let minimumSidebarWidth: CGFloat = 820

    static func hasRoom(
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?
    ) -> Bool {
        horizontal == .regular && vertical == .regular
    }

    static func mode(
        preference: ClientLayoutPreference,
        hasDesktopInput: Bool,
        sizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        width: CGFloat
    ) -> ClientLayoutMode {
        guard hasRoom(horizontal: sizeClass, vertical: verticalSizeClass) else { return .tabs }
        switch preference {
        case .tabs:
            return .tabs
        case .sidebar:
            return width >= minimumSidebarWidth ? .sidebar : .tabs
        case .automatic:
            guard hasDesktopInput else { return .tabs }
            return width >= minimumSidebarWidth ? .sidebar : .tabs
        }
    }
}

@MainActor
@Observable
final class PointerKeyboardModel {
    private(set) var hasKeyboard = false
    private(set) var hasPointer = false

    var hasDesktopInput: Bool { hasKeyboard || hasPointer }

    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var publishTask: Task<Void, Never>?
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

    static func dismantleUIView(_ view: UIView, coordinator: ()) {
        (view as? ProbeView)?.removeProbe()
    }

    final class ProbeView: UIView {
        var onHover: (() -> Void)?
        private var installed: UIHoverGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if installed?.view !== window { removeProbe() }
            guard let window, installed == nil else { return }
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
            window.addGestureRecognizer(hover)
            installed = hover
        }

        func removeProbe() {
            if let installed { installed.view?.removeGestureRecognizer(installed) }
            installed = nil
        }

        @objc func hovered(_ recognizer: UIHoverGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            onHover?()
        }
    }
}

extension View {
    func clientPointerProbe(_ input: PointerKeyboardModel) -> some View {
        background(
            PointerProbe { input.noteHover() }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}

#endif
