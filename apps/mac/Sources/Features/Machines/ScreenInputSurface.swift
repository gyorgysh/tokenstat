// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What a screen input surface can ask the session to do.
///
/// One struct rather than a delegate protocol, because both platform surfaces
/// are leaves: they translate a gesture or an event into an intent and forget
/// it. Coordinates are normalized to the video rect, so neither surface has to
/// know the remote display's size and a zoomed view sends the same numbers as
/// an unzoomed one.
struct ScreenInputActions {
    /// Put the pointer at this normalized point.
    var move: (CGPoint) -> Void
    /// Move the pointer by a distance measured on this surface. Trackpad mode:
    /// the finger is not where the pointer is.
    var nudge: (CGSize, CGSize) -> Void
    /// Press and release, with a button and a click count in one message.
    var click: (Int, Int) -> Void
    /// Hold or release the left button, for a drag that outlives one gesture.
    var press: (Bool) -> Void
    /// Wheel movement in pixels.
    var scroll: (CGSize) -> Void
    /// Move a locally zoomed picture without sending anything to the host.
    var panView: (CGSize, CGSize) -> Void
    /// Typed characters, with modifier flags already folded in.
    var text: (String, UInt64) -> Void
    /// A key that has no character: escape, tab, the arrows.
    var key: (UInt16, Bool, UInt64) -> Void
    /// Pinch. The surface reports the factor, the view decides what to do.
    var magnify: (CGFloat, CGSize) -> Void
}

/// Virtual key codes the accessory bar and the special keys send.
///
/// macOS numbers, because the host synthesises `CGEvent`s with them. They are
/// stable and are not going to be looked up from a table at runtime.
enum ScreenKey {
    static let escape: UInt16 = 53
    static let tab: UInt16 = 48
    static let delete: UInt16 = 51
    static let ret: UInt16 = 36
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}

/// Modifier bits shared with `EventModifiers.screenFlags` and with
/// `CGEventFlags` on the host.
enum ScreenFlag {
    static let shift: UInt64 = 1 << 17
    static let control: UInt64 = 1 << 18
    static let option: UInt64 = 1 << 19
    static let command: UInt64 = 1 << 20
}

/// How a finger or a pointer maps onto the remote pointer.
enum ScreenPointerMode: String, CaseIterable, Identifiable {
    /// The finger drags the pointer from wherever it already is. What a laptop
    /// trackpad does, and the only thing that works on a phone.
    case trackpad
    /// The pointer goes where the finger touched.
    case direct

    var id: String { rawValue }
    var title: String { self == .trackpad ? "Trackpad" : "Direct" }
    var symbol: String { self == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.tap" }
}

#if os(macOS)

/// Mouse and keyboard over the shared screen.
///
/// An `NSView` rather than SwiftUI gestures because a remote screen needs the
/// events SwiftUI does not offer: the scroll wheel, the right button, and key
/// presses that arrive while no text field is focused.
struct ScreenInputSurface: NSViewRepresentable {
    let actions: ScreenInputActions
    let enabled: Bool
    let mode: ScreenPointerMode
    let zoomed: Bool

    func makeNSView(context: Context) -> NSView {
        let view = InputView()
        view.actions = actions
        view.enabled = enabled
        view.mode = mode
        view.zoomed = zoomed
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? InputView else { return }
        view.actions = actions
        view.enabled = enabled
        view.mode = mode
        view.zoomed = zoomed
    }

    private final class InputView: NSView {
        var actions: ScreenInputActions?
        var enabled = false
        var mode: ScreenPointerMode = .direct
        var zoomed = false

        override var acceptsFirstResponder: Bool { enabled }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func normalized(_ event: NSEvent) -> CGPoint {
            let local = convert(event.locationInWindow, from: nil)
            // AppKit's origin is bottom left and the remote screen's is top
            // left. Flipping here rather than at the host keeps one convention
            // on the wire for both platforms.
            return CGPoint(
                x: min(max(local.x / max(1, bounds.width), 0), 1),
                y: min(max(1 - local.y / max(1, bounds.height), 0), 1)
            )
        }

        override func mouseDown(with event: NSEvent) {
            guard enabled, let actions else { return }
            window?.makeFirstResponder(self)
            actions.move(normalized(event))
            if event.clickCount > 1 {
                actions.click(0, min(3, event.clickCount))
            } else {
                actions.press(true)
            }
        }

        override func mouseUp(with event: NSEvent) {
            guard enabled, let actions, event.clickCount <= 1 else { return }
            actions.move(normalized(event))
            actions.press(false)
        }

        override func mouseDragged(with event: NSEvent) {
            guard enabled, let actions else { return }
            if mode == .trackpad {
                actions.nudge(CGSize(width: event.deltaX, height: event.deltaY), bounds.size)
            } else {
                actions.move(normalized(event))
            }
        }

        override func mouseMoved(with event: NSEvent) {
            guard enabled, let actions, mode == .direct else { return }
            actions.move(normalized(event))
        }

        override func rightMouseDown(with event: NSEvent) {
            guard enabled, let actions else { return }
            actions.move(normalized(event))
            actions.click(1, 1)
        }

        override func scrollWheel(with event: NSEvent) {
            guard let actions else { return super.scrollWheel(with: event) }
            if enabled {
                actions.move(normalized(event))
                actions.scroll(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            } else if zoomed {
                actions.panView(
                    CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
                    bounds.size
                )
            } else {
                super.scrollWheel(with: event)
            }
        }

        override func magnify(with event: NSEvent) {
            // Zoom changes only this viewer. It is useful while watching and
            // must not require permission to send mouse or keyboard input to
            // the far end.
            guard let actions else { return }
            actions.magnify(1 + event.magnification, bounds.size)
        }

        override func keyDown(with event: NSEvent) {
            guard enabled, let actions else { return super.keyDown(with: event) }
            let flags = event.modifierFlags.screenFlags
            if let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
               !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
               let scalar = characters.unicodeScalars.first, scalar.value >= 32, scalar.value != 127
            {
                actions.text(characters, flags)
            } else {
                actions.key(event.keyCode, true, flags)
                actions.key(event.keyCode, false, flags)
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                owner: self
            ))
        }
    }
}

private extension NSEvent.ModifierFlags {
    var screenFlags: UInt64 {
        var value: UInt64 = 0
        if contains(.shift) { value |= ScreenFlag.shift }
        if contains(.control) { value |= ScreenFlag.control }
        if contains(.option) { value |= ScreenFlag.option }
        if contains(.command) { value |= ScreenFlag.command }
        return value
    }
}

#else

/// Touch and keyboard over the shared screen.
///
/// The gesture vocabulary is the one people already know from remote desktop
/// apps, because a screen that needs a legend is a screen nobody controls:
/// one finger moves the pointer, tap clicks, two-finger tap is a right click,
/// two fingers drag to scroll, long press then drag holds the button down, and
/// pinch zooms the view rather than the remote display.
///
/// A `UIView` and not SwiftUI gestures for two reasons: several recognizers
/// have to fail relative to each other, and iOS will not raise a keyboard for
/// anything that is not a first responder adopting `UIKeyInput`.
struct ScreenInputSurface: UIViewRepresentable {
    let actions: ScreenInputActions
    let enabled: Bool
    let mode: ScreenPointerMode
    let zoomed: Bool
    /// Raised so the accessory bar can show which modifiers are held.
    @Binding var heldModifiers: UInt64
    /// Set by the view when the keyboard should be up.
    @Binding var keyboardWanted: Bool

    func makeUIView(context: Context) -> UIView {
        let view = TouchInputView()
        view.configure(actions: actions, enabled: enabled, mode: mode, zoomed: zoomed)
        view.onModifiersChanged = { heldModifiers = $0 }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard let view = view as? TouchInputView else { return }
        view.configure(actions: actions, enabled: enabled, mode: mode, zoomed: zoomed)
        view.onModifiersChanged = { heldModifiers = $0 }
        view.apply(modifiers: heldModifiers)
        if keyboardWanted, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !keyboardWanted, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    final class TouchInputView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
        private var actions: ScreenInputActions?
        private var enabled = false
        private var mode: ScreenPointerMode = .trackpad
        private var zoomed = false
        private var modifiers: UInt64 = 0
        private var dragging = false
        private var lastPan: CGPoint = .zero
        private weak var moveRecognizer: UIPanGestureRecognizer?
        private weak var pinchRecognizer: UIPinchGestureRecognizer?
        var onModifiersChanged: ((UInt64) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            addRecognizers()
        }

        required init?(coder: NSCoder) { nil }

        func configure(
            actions: ScreenInputActions,
            enabled: Bool,
            mode: ScreenPointerMode,
            zoomed: Bool
        ) {
            self.actions = actions
            self.enabled = enabled
            self.mode = mode
            self.zoomed = zoomed
            // Pinch is local viewing, not remote control. Keep the surface in
            // the gesture chain in view mode and let every input-sending
            // handler enforce `enabled` itself.
            isUserInteractionEnabled = true
            for recognizer in gestureRecognizers ?? [] {
                let shouldEnable: Bool
                if recognizer === pinchRecognizer {
                    shouldEnable = true
                } else if recognizer === moveRecognizer {
                    shouldEnable = enabled || zoomed
                } else {
                    shouldEnable = enabled
                }
                // Setting a recognizer false cancels an in-flight gesture.
                // SwiftUI updates after every pinch step, so only touch the
                // property when its desired state actually changed.
                if recognizer.isEnabled != shouldEnable {
                    recognizer.isEnabled = shouldEnable
                    if recognizer === moveRecognizer, !shouldEnable { lastPan = .zero }
                }
            }
        }

        func apply(modifiers value: UInt64) { modifiers = value }

        private func addRecognizers() {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            tap.require(toFail: doubleTap)
            let secondary = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryTap))
            secondary.numberOfTouchesRequired = 2
            let move = UIPanGestureRecognizer(target: self, action: #selector(handleMove))
            move.maximumNumberOfTouches = 1
            moveRecognizer = move
            let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
            scroll.minimumNumberOfTouches = 2
            scroll.maximumNumberOfTouches = 2
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold))
            hold.minimumPressDuration = 0.35
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
            pinch.delegate = self
            pinchRecognizer = pinch
            for recognizer in [tap, doubleTap, secondary, move, scroll, hold, pinch] as [UIGestureRecognizer] {
                addGestureRecognizer(recognizer)
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Pinch and the two-finger scroll share their touches: a pinch that
            // drifted should still zoom rather than being eaten by the pan.
            gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
        }

        private func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: min(max(point.x / max(1, bounds.width), 0), 1),
                y: min(max(point.y / max(1, bounds.height), 0), 1)
            )
        }

        /// Everything a tap does starts by putting the pointer somewhere.
        /// Direct mode uses the touch, trackpad mode leaves the pointer where
        /// the last drag left it.
        private func positionForTap(_ recognizer: UIGestureRecognizer) {
            guard mode == .direct, let actions else { return }
            actions.move(normalized(recognizer.location(in: self)))
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard enabled, let actions else { return }
            positionForTap(recognizer)
            actions.click(0, 1)
            consumeModifiers()
        }

        @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard enabled, let actions else { return }
            positionForTap(recognizer)
            actions.click(0, 2)
            consumeModifiers()
        }

        @objc private func handleSecondaryTap(_ recognizer: UITapGestureRecognizer) {
            guard enabled, let actions else { return }
            positionForTap(recognizer)
            actions.click(1, 1)
            consumeModifiers()
        }

        @objc private func handleMove(_ recognizer: UIPanGestureRecognizer) {
            guard let actions else { return }
            if !enabled {
                guard zoomed else { return }
                let translation = recognizer.translation(in: self)
                actions.panView(
                    CGSize(width: translation.x - lastPan.x, height: translation.y - lastPan.y),
                    bounds.size
                )
                lastPan = translation
                if recognizer.state == .ended || recognizer.state == .cancelled { lastPan = .zero }
                return
            }
            switch mode {
            case .trackpad:
                let translation = recognizer.translation(in: self)
                actions.nudge(
                    CGSize(width: translation.x - lastPan.x, height: translation.y - lastPan.y),
                    bounds.size
                )
                lastPan = recognizer.state == .ended ? .zero : translation
                if recognizer.state == .ended || recognizer.state == .cancelled { lastPan = .zero }
            case .direct:
                actions.move(normalized(recognizer.location(in: self)))
            }
        }

        @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
            guard enabled, let actions else { return }
            let translation = recognizer.translation(in: self)
            let delta = CGSize(width: translation.x - lastPan.x, height: translation.y - lastPan.y)
            lastPan = translation
            if recognizer.state == .ended || recognizer.state == .cancelled { lastPan = .zero }
            actions.scroll(delta)
        }

        /// Long press, then move: the button stays down until the finger
        /// leaves. This is how a window gets dragged or a file gets selected.
        @objc private func handleHold(_ recognizer: UILongPressGestureRecognizer) {
            guard enabled, let actions else { return }
            switch recognizer.state {
            case .began:
                positionForTap(recognizer)
                dragging = true
                actions.press(true)
            case .changed:
                if mode == .direct {
                    actions.move(normalized(recognizer.location(in: self)))
                }
            case .ended, .cancelled, .failed:
                guard dragging else { return }
                dragging = false
                actions.press(false)
                consumeModifiers()
            default:
                break
            }
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let actions else { return }
            guard recognizer.state == .changed else {
                recognizer.scale = 1
                return
            }
            actions.magnify(recognizer.scale, bounds.size)
            recognizer.scale = 1
        }

        // MARK: Keyboard

        override var canBecomeFirstResponder: Bool { enabled }
        var hasText: Bool { false }

        func insertText(_ text: String) {
            guard let actions else { return }
            if text == "\n" {
                actions.key(ScreenKey.ret, true, modifiers)
                actions.key(ScreenKey.ret, false, modifiers)
            } else {
                actions.text(text, modifiers)
            }
            consumeModifiers()
        }

        func deleteBackward() {
            guard let actions else { return }
            actions.key(ScreenKey.delete, true, modifiers)
            actions.key(ScreenKey.delete, false, modifiers)
            consumeModifiers()
        }

        /// A hardware keyboard on an iPad reaches this instead of `insertText`
        /// for anything with a modifier, which is exactly the set that matters
        /// here: cmd+tab, ctrl+c, the arrows.
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard enabled, let actions else { return super.pressesBegan(presses, with: event) }
            var handled = false
            for press in presses {
                guard let key = press.key else { continue }
                let flags = modifiers | key.modifierFlags.screenFlags
                if let code = ScreenKey.code(for: key.keyCode) {
                    actions.key(code, true, flags)
                    actions.key(code, false, flags)
                    handled = true
                } else if !key.characters.isEmpty, flags & (ScreenFlag.command | ScreenFlag.control) == 0 {
                    actions.text(key.characters, flags)
                    handled = true
                } else if let scalar = key.charactersIgnoringModifiers.unicodeScalars.first,
                          let code = ScreenKey.code(forCharacter: scalar)
                {
                    actions.key(code, true, flags)
                    actions.key(code, false, flags)
                    handled = true
                }
            }
            if handled { consumeModifiers() } else { super.pressesBegan(presses, with: event) }
        }

        /// Modifiers are sticky for one keystroke, the way an on-screen
        /// modifier has to be when there is only one finger to press it with.
        private func consumeModifiers() {
            guard modifiers != 0 else { return }
            modifiers = 0
            onModifiersChanged?(0)
        }
    }
}

private extension ScreenKey {
    static func code(for keyCode: UIKeyboardHIDUsage) -> UInt16? {
        switch keyCode {
        case .keyboardEscape: escape
        case .keyboardTab: tab
        case .keyboardLeftArrow: left
        case .keyboardRightArrow: right
        case .keyboardUpArrow: up
        case .keyboardDownArrow: down
        case .keyboardReturnOrEnter: ret
        case .keyboardDeleteOrBackspace: delete
        default: nil
        }
    }

    /// A character typed with command or control still has to reach the host
    /// as a key code, because the host synthesises a key event and not text.
    static func code(forCharacter scalar: Unicode.Scalar) -> UInt16? {
        let letters: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        ]
        return letters[Character(scalar).lowercased().first ?? " "]
    }
}

private extension UIKeyModifierFlags {
    var screenFlags: UInt64 {
        var value: UInt64 = 0
        if contains(.shift) { value |= ScreenFlag.shift }
        if contains(.control) { value |= ScreenFlag.control }
        if contains(.alternate) { value |= ScreenFlag.option }
        if contains(.command) { value |= ScreenFlag.command }
        return value
    }
}

/// The row of keys a touch screen has no other way to send.
///
/// Sticky rather than held, because holding control with one thumb and typing
/// with the other is not a thing on a phone. A modifier stays lit until the
/// next keystroke spends it.
struct ScreenKeyBar: View {
    @Binding var modifiers: UInt64
    let send: (UInt16, UInt64) -> Void
    /// Pointer controls, when this bar is drawn over a screen somebody is
    /// controlling with a finger.
    ///
    /// Buttons and not more gestures. A remote desktop needs a click, a double
    /// click, a right click and a held button, and a phone was asking somebody
    /// to guess four gestures for them with nothing on screen to say so.
    var pointer: ScreenPointerControls?

    private struct Special: Identifiable {
        let id: String
        let code: UInt16
        let symbol: String?
    }

    private let specials: [Special] = [
        Special(id: "esc", code: ScreenKey.escape, symbol: nil),
        Special(id: "tab", code: ScreenKey.tab, symbol: nil),
        Special(id: "up", code: ScreenKey.up, symbol: "arrow.up"),
        Special(id: "down", code: ScreenKey.down, symbol: "arrow.down"),
        Special(id: "left", code: ScreenKey.left, symbol: "arrow.left"),
        Special(id: "right", code: ScreenKey.right, symbol: "arrow.right"),
    ]

    private let sticky: [(String, UInt64)] = [
        ("ctrl", ScreenFlag.control),
        ("opt", ScreenFlag.option),
        ("cmd", ScreenFlag.command),
        ("shift", ScreenFlag.shift),
    ]

    var body: some View {
        HStack(spacing: 0) {
            if let pointer {
                // A held mouse button cannot scroll off screen: releasing it
                // is the one pointer action that always has to be reachable.
                Button(action: pointer.toggleDrag) {
                    ActionIcon.move.label(pointer.dragLatched ? "Release" : "Hold")
                }
                // One width for both words. "Release" is wider than "Hold",
                // so the pinned button used to grow the moment it was pressed
                // and shove the whole scrolling row sideways under the
                // thumb that had just pressed it.
                .buttonStyle(ScreenKeyStyle(active: pointer.dragLatched, width: 104))
                .padding(.leading, Theme.Space.m)
                .padding(.trailing, Theme.Space.s)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.s) {
                    if let pointer {
                        Button("click") { pointer.click(0, 1) }
                            .buttonStyle(ScreenKeyStyle(active: false))
                        Button("double") { pointer.click(0, 2) }
                            .buttonStyle(ScreenKeyStyle(active: false))
                        Button("right") { pointer.click(1, 1) }
                            .buttonStyle(ScreenKeyStyle(active: false))
                        Button("fine") { pointer.toggleFine() }
                            .buttonStyle(ScreenKeyStyle(active: pointer.fine))
                        if pointer.zoom > 1.01 {
                            Button(String(format: "%.1fx", pointer.zoom)) { pointer.resetZoom() }
                                .buttonStyle(ScreenKeyStyle(active: true))
                        }
                        Divider().frame(height: 20)
                    }
                    ForEach(sticky, id: \.0) { name, flag in
                        Button(name) { modifiers ^= flag }
                            .buttonStyle(ScreenKeyStyle(active: modifiers & flag != 0))
                    }
                    Divider().frame(height: 20)
                    ForEach(specials) { special in
                        Button {
                            send(special.code, modifiers)
                            modifiers = 0
                        } label: {
                            if let symbol = special.symbol {
                                Image(systemName: symbol)
                            } else {
                                Text(special.id)
                            }
                        }
                        .buttonStyle(ScreenKeyStyle(active: false))
                    }
                }
                .padding(.trailing, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
            }
            // A keycap cut in half at the edge reads as a broken row rather
            // than as one that scrolls. Fading the last few points says the
            // same thing and says it on purpose.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.94),
                        .init(color: .black.opacity(0), location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .background(.ultraThinMaterial)
    }
}

/// What the bar can do to the pointer. A value rather than a pile of bindings,
/// so the bar takes one parameter and the viewer keeps the state.
struct ScreenPointerControls {
    var fine: Bool
    var dragLatched: Bool
    var zoom: CGFloat
    var click: (Int, Int) -> Void
    var toggleDrag: () -> Void
    var toggleFine: () -> Void
    var resetZoom: () -> Void
}

private struct ScreenKeyStyle: ButtonStyle {
    let active: Bool
    /// A fixed width, for a key whose label changes while it is on screen.
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(active ? Color.white : Color.primary)
            .lineLimit(1)
            .frame(width: width)
            .frame(minWidth: 44, minHeight: Theme.Control.height)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Theme.accent : Theme.panel.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(active ? Color.clear : Theme.border, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

#endif
