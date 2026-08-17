// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftTerm
import SwiftUI

/// Every terminal in a workspace, stacked, with one or two of them visible.
///
/// One `NSViewRepresentable` holding all of the session views, rather than one
/// per session in a SwiftUI stack. Two reasons, both learned the hard way:
///
/// - **Sizing.** A `TerminalView` has no useful intrinsic width, so a SwiftUI
///   stack asked to size itself around several of them settles on something
///   tiny and the terminal renders one character per line. Here the frames are
///   set from `bounds` and there is nothing to infer.
/// - **Switching.** Showing a terminal must not mean adding it to the view
///   hierarchy, because that lays it out again, which resizes the pty, which
///   raises SIGWINCH, which makes a full screen program repaint from scratch.
///   Every view stays mounted and switching is `isHidden`. A split shows two
///   frames. Hidden views keep the last size they had, so bringing one back
///   to a half it already filled does not SIGWINCH.
struct TerminalStack: NSViewRepresentable {
    let sessions: [TerminalSession]
    /// Left / top session when split, or the only visible session when not.
    let leading: TerminalSession?
    /// Right / bottom session when split.
    var trailing: TerminalSession? = nil
    /// The half that should own the keyboard.
    var focused: TerminalSession? = nil
    /// `nil` is a single pane. Horizontal is side by side, vertical is stacked.
    var splitAxis: Axis? = nil
    /// Leading (left / top) share of the column, 0.2...0.8.
    var fraction: CGFloat = 0.5
    /// Whether this stack may claim first responder. False while the workspace
    /// surface is kept mounted under another destination (Home, Insights, …).
    var claimsFocus: Bool = true
    /// Which visible half last took a click, so first responder follows it.
    var onActivate: ((TerminalSession) -> Void)? = nil

    func makeNSView(context: Context) -> TerminalStackView {
        let view = TerminalStackView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: TerminalStackView, context: Context) {
        context.coordinator.parent = self
        // Only sessions that already have an emulator. Pending ones have no
        // view on purpose: the pane draws a starting state over them instead.
        let loaded = sessions.compactMap(\.terminalViewIfLoaded)
        nsView.sync(
            views: loaded,
            leading: leading.flatMap(\.terminalViewIfLoaded),
            trailing: trailing.flatMap(\.terminalViewIfLoaded),
            focused: focused.flatMap(\.terminalViewIfLoaded),
            axis: splitAxis,
            fraction: fraction,
            claimsFocus: claimsFocus
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator {
        var parent: TerminalStack

        init(_ parent: TerminalStack) {
            self.parent = parent
        }

        func activate(view: TerminalView) {
            // The click monitor is not actor-isolated. Sessions live on the
            // main actor. A mouse-down is already on the main thread, so this
            // hop is a hop in name only.
            Task { @MainActor in
                if let session = self.parent.sessions.first(where: {
                    $0.terminalViewIfLoaded === view
                }) {
                    self.parent.onActivate?(session)
                }
            }
        }
    }
}

final class TerminalStackView: NSView {
    /// The view that was in front last time, so focus is claimed on a change
    /// rather than on every update. Claiming it every time would pull the
    /// keyboard out of whatever else the user was typing in.
    private weak var shown: NSView?
    /// Last value of `claimsFocus` seen by `sync`. Falling edge clears
    /// `shown` so rising edge reclaims the keyboard when the surface returns.
    private var lastClaimsFocus = false
    /// Full buffer paint waiting for a non-zero layout. Re-parent can run
    /// while the stack still has a zero frame (fresh `makeNSView`); painting
    /// then marks an empty rect and the buffer never appears.
    private var needsFullPaint = false
    weak var coordinator: TerminalStack.Coordinator?
    private weak var leadingView: TerminalView?
    private weak var trailingView: TerminalView?
    private var splitAxis: Axis?
    private var fraction: CGFloat = 0.5
    private var clickMonitor: Any?

    func sync(
        views: [TerminalView],
        leading: TerminalView?,
        trailing: TerminalView?,
        focused: TerminalView?,
        axis: Axis?,
        fraction: CGFloat,
        claimsFocus: Bool
    ) {
        leadingView = leading
        trailingView = trailing
        splitAxis = axis
        self.fraction = fraction
        // Views just re-parented into this stack need a repaint even when they
        // stay visible: a fresh TerminalStackView after a folder switch hands
        // the same emulator instance into a new hierarchy, and without a
        // display the screen shows only a caret until the process prints.
        var reparented = Set<ObjectIdentifier>()
        for view in views where view.superview !== self {
            // No autoresizing: split frames are set in `layout`.
            view.autoresizingMask = []
            addSubview(view)
            reparented.insert(ObjectIdentifier(view))
        }
        // A session closed elsewhere leaves a view here with nothing behind it.
        for sub in subviews where !views.contains(where: { $0 === sub }) {
            sub.removeFromSuperview()
        }

        var requestPaint = !reparented.isEmpty
        for view in views {
            let visible = view === leading || view === trailing
            let needsFlip = view.isHidden == visible
            if needsFlip {
                view.isHidden = !visible
                if visible { requestPaint = true }
            }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if requestPaint {
            scheduleFullPaint()
        }

        if !claimsFocus {
            if lastClaimsFocus {
                shown = nil
            }
            lastClaimsFocus = false
            return
        }

        let focusReturning = !lastClaimsFocus
        lastClaimsFocus = true
        installClickMonitor()

        let key = focused ?? leading
        if let key, focusReturning || shown !== key {
            shown = key
            DispatchQueue.main.async { [weak self, weak key] in
                guard let self, let key, key.superview === self else { return }
                guard self.lastClaimsFocus else { return }
                self.window?.makeFirstResponder(key)
            }
        } else if key == nil {
            shown = nil
        }
    }

    /// Mark every visible terminal for a full redraw once bounds are real.
    private func scheduleFullPaint() {
        needsFullPaint = true
        if bounds.width > 1, bounds.height > 1 {
            paintVisibleTerminals()
        }
    }

    private func paintVisibleTerminals() {
        needsFullPaint = false
        for sub in subviews where !sub.isHidden {
            sub.setNeedsDisplay(sub.bounds)
        }
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 1
        if let axis = splitAxis, bounds.width > 1, bounds.height > 1 {
            let (lead, trail) = splitFrames(axis: axis, fraction: fraction, gap: gap)
            if let view = leadingView, view.frame != lead { view.frame = lead }
            if let view = trailingView, view.frame != trail { view.frame = trail }
            // Hidden views keep the last frame they were shown at. Resizing
            // them here would SIGWINCH a session nobody can see.
        } else {
            for sub in subviews {
                if sub.frame != bounds { sub.frame = bounds }
            }
        }
        if needsFullPaint, bounds.width > 1, bounds.height > 1 {
            paintVisibleTerminals()
        }
    }

    private func splitFrames(axis: Axis, fraction: CGFloat, gap: CGFloat) -> (CGRect, CGRect) {
        let clamped = min(0.8, max(0.2, fraction))
        switch axis {
        case .horizontal:
            let leadW = max(1, (bounds.width - gap) * clamped)
            let trailX = leadW + gap
            return (
                CGRect(x: 0, y: 0, width: leadW, height: bounds.height),
                CGRect(x: trailX, y: 0, width: max(1, bounds.width - trailX), height: bounds.height)
            )
        case .vertical:
            // AppKit y is up. Leading (focused) is the top half in UI terms,
            // which is the higher y origin.
            let leadH = max(1, (bounds.height - gap) * clamped)
            let trailH = max(1, bounds.height - leadH - gap)
            return (
                CGRect(x: 0, y: bounds.height - leadH, width: bounds.width, height: leadH),
                CGRect(x: 0, y: 0, width: bounds.width, height: trailH)
            )
        }
    }

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.noteClick(event)
            return event
        }
    }

    private func noteClick(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let leading = leadingView, !leading.isHidden, leading.frame.contains(point) {
            coordinator?.activate(view: leading)
        } else if let trailing = trailingView, !trailing.isHidden, trailing.frame.contains(point) {
            coordinator?.activate(view: trailing)
        }
    }

    deinit {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
    }
}
#endif
