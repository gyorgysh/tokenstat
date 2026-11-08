// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct ChatControlsSwipeIntent {
    var upward: Bool
    var maximumStartY: CGFloat? = nil

    func acceptsStart(_ point: CGPoint, direction: CGPoint) -> Bool {
        if let maximumStartY, point.y < 0 || point.y > maximumStartY { return false }
        return (upward ? -direction.y : direction.y) > 0 && abs(direction.y) > abs(direction.x) * 1.2
    }

    func completes(_ translation: CGPoint) -> Bool {
        (upward ? -translation.y : translation.y) > 28 && abs(translation.y) > abs(translation.x) * 1.2
    }
}

struct ChatBackSwipeIntent {
    var rightToLeft = false

    func accepts(_ direction: CGPoint) -> Bool {
        (rightToLeft ? -direction.x : direction.x) > 0 && abs(direction.x) > abs(direction.y) * 1.2
    }

    func completes(_ translation: CGPoint, velocity: CGPoint) -> Bool {
        guard accepts(translation) else { return false }
        let distance = rightToLeft ? -translation.x : translation.x
        let speed = rightToLeft ? -velocity.x : velocity.x
        // A deliberate reversal cancels a swipe that already crossed the
        // distance threshold. Ignore small velocity noise at finger lift.
        guard speed > -150 else { return false }
        return distance > 64 || distance > 24 && speed > 500
    }
}

#if os(iOS)
import SwiftUI
import UIKit

/// Observe only swipes beginning inside this view, without covering its controls.
struct ClientChatControlsSwipe: ViewModifier {
    var upward: Bool
    var enabled = true
    var maximumStartY: CGFloat? = nil
    var action: () -> Void

    func body(content: Content) -> some View {
        content.background(ControlsPanAnchor(intent: .controls(.init(upward: upward, maximumStartY: maximumStartY)),
                                             enabled: enabled, action: action)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
    }
}

/// In-place readers use the same action as Back. Pushed readers keep the
/// system gesture while chrome is visible and use dismiss when it is hidden.
struct ClientChatBackSwipe: ViewModifier {
    var enabled = true
    var action: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        content.background {
            if enabled {
                ControlsPanAnchor(intent: .back(.init(rightToLeft: layoutDirection == .rightToLeft)),
                                  enabled: true, action: { if let action { action() } else { dismiss() } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private enum ChatPanIntent {
    case controls(ChatControlsSwipeIntent)
    case back(ChatBackSwipeIntent)

    var edge: UIRectEdge? {
        guard case .back(let intent) = self else { return nil }
        return intent.rightToLeft ? .right : .left
    }

    func acceptsStart(_ point: CGPoint, direction: CGPoint) -> Bool {
        switch self {
        case .controls(let intent): return intent.acceptsStart(point, direction: direction)
        case .back(let intent): return intent.accepts(direction)
        }
    }

    func completes(_ translation: CGPoint, velocity: CGPoint) -> Bool {
        switch self {
        case .controls(let intent): return intent.completes(translation)
        case .back(let intent): return intent.completes(translation, velocity: velocity)
        }
    }
}

private struct ControlsPanAnchor: UIViewRepresentable {
    var intent: ChatPanIntent
    var enabled: Bool
    var action: () -> Void

    func makeUIView(context: Context) -> Anchor { Anchor() }

    func updateUIView(_ view: Anchor, context: Context) {
        view.intent = intent
        view.action = action
        view.enabled = enabled
    }

    static func dismantleUIView(_ view: Anchor, coordinator: ()) {
        view.detach()
        view.action = nil
    }

    final class Anchor: UIView, UIGestureRecognizerDelegate {
        var intent = ChatPanIntent.controls(.init(upward: false)) {
            didSet { if intent.edge != oldValue.edge { install() } }
        }
        var action: (() -> Void)?
        var enabled = false { didSet { if oldValue != enabled { pan?.isEnabled = enabled } } }
        private var pan: UIPanGestureRecognizer?

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            install()
        }

        private func install() {
            detach()
            guard window != nil, let owner = hostingView else { return }
            let pan: UIPanGestureRecognizer
            if let edge = intent.edge {
                let edgePan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handlePan))
                edgePan.edges = edge
                pan = edgePan
            } else {
                pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            }
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = true
            pan.isEnabled = enabled
            pan.delegate = self
            self.pan = pan
            owner.addGestureRecognizer(pan)
        }

        // Stay in this presentation's view tree; a sheet above it owns its touches.
        private var hostingView: UIView? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController { return controller.viewIfLoaded }
                responder = current.next
            }
            return superview
        }

        func detach() {
            if let pan {
                pan.view?.removeGestureRecognizer(pan)
                pan.removeTarget(self, action: nil)
            }
            pan = nil
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard enabled, window != nil, bounds.contains(touch.location(in: self)) else { return false }
            var ancestor: UIView? = self
            while let view = ancestor {
                guard !view.isHidden, view.alpha > 0.01 else { return false }
                ancestor = view.superview
            }
            return true
        }

        override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer else { return false }
            let delta = pan.translation(in: self)
            let point = pan.location(in: self)
            let start = CGPoint(x: point.x - delta.x, y: point.y - delta.y)
            return intent.acceptsStart(start, direction: pan.velocity(in: self))
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            intent.edge == nil && other is UIPanGestureRecognizer
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // Reserve a recognized edge swipe for Back instead of horizontal
            // content scrolling. The system pop is inactive with hidden chrome.
            enabled && intent.edge != nil && other is UIPanGestureRecognizer
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard enabled, pan.state == .ended,
                  intent.completes(pan.translation(in: self), velocity: pan.velocity(in: self)) else { return }
            action?()
        }
    }
}
#endif
