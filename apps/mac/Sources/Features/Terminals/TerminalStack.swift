// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
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
struct TerminalStack<Session: TerminalPresentable>: NSViewRepresentable {
    let sessions: [Session]
    let leading: Session?
    var trailing: Session? = nil
    var focused: Session? = nil
    var splitAxis: Axis? = nil
    var fraction: CGFloat = 0.5
    var claimsFocus: Bool = true
    /// Whether the terminal layer is what the person should see.
    ///
    /// SwiftUI `.opacity(0)` does **not** hide an `NSViewRepresentable`: the
    /// AppKit host keeps painting and eats the SwiftUI cover above it (Launch
    /// becomes a black hole with tile gears clipped on the left edge). The
    /// stack view itself is `isHidden` when this is false. Sessions stay
    /// parented at their last frames, so bringing the layer back does not
    /// SIGWINCH.
    var isSurfaceVisible: Bool = true
    var onActivate: ((Session) -> Void)? = nil

    func makeNSView(context: Context) -> TerminalStackView {
        let view = TerminalStackView()
        // A closure rather than a reference to the coordinator, because the
        // coordinator is generic over the session type and this AppKit view is
        // not. Nothing below this line has ever needed to know what a session
        // is, and now nothing below it names one.
        view.onViewClicked = { [weak coordinator = context.coordinator] clicked in
            coordinator?.activate(view: clicked)
        }
        return view
    }

    func updateNSView(_ nsView: TerminalStackView, context: Context) {
        context.coordinator.parent = self
        let loaded = sessions.compactMap(\.terminalViewIfLoaded)
        nsView.onReturnToFront = { [sessions] view in
            sessions.first(where: { $0.terminalViewIfLoaded === view })?
                .terminalReturnedToFront()
        }
        nsView.sync(
            views: loaded,
            leading: leading.flatMap(\.terminalViewIfLoaded),
            trailing: trailing.flatMap(\.terminalViewIfLoaded),
            focused: focused.flatMap(\.terminalViewIfLoaded),
            axis: splitAxis,
            fraction: fraction,
            claimsFocus: claimsFocus,
            surfaceVisible: isSurfaceVisible
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
    private weak var shown: NSView?
    private var lastClaimsFocus = false
    /// Full buffer paint waiting for a non-zero layout. Re-parent can run
    /// while the stack still has a zero frame (fresh `makeNSView`); painting
    /// then marks an empty rect and the buffer never appears.
    private var needsFullPaint = false
    var onViewClicked: ((TerminalView) -> Void)?
    var onReturnToFront: ((TerminalView) -> Void)?
    private weak var leadingView: TerminalView?
    private weak var trailingView: TerminalView?
    private var splitAxis: Axis?
    private var fraction: CGFloat = 0.5
    private var clickMonitor: Any?

    /// No intrinsic size: SwiftUI must assign the frame. An intrinsic built
    /// from hidden terminal subviews was collapsing the GeometryReader above
    /// this stack after a Sessions/Launch flip.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func sync(
        views: [TerminalView],
        leading: TerminalView?,
        trailing: TerminalView?,
        focused: TerminalView?,
        axis: Axis?,
        fraction: CGFloat,
        claimsFocus: Bool,
        surfaceVisible: Bool
    ) {
        leadingView = leading
        trailingView = trailing
        splitAxis = axis
        self.fraction = fraction

        // Hide the whole AppKit host while Launch/Files/… is in front. SwiftUI
        // opacity does not reach NSViewRepresentable; without this the black
        // terminal layer covers the cover and only clipped tile gears show.
        let wasHidden = isHidden
        if isHidden != !surfaceVisible {
            isHidden = !surfaceVisible
        }
        if !surfaceVisible {
            leadingView = nil
            trailingView = nil
            splitAxis = nil
            for sub in subviews where !views.contains(where: { $0 === sub }) {
                sub.removeFromSuperview()
            }
            shown = nil
            lastClaimsFocus = false
            return
        }

        var reparented = Set<ObjectIdentifier>()
        for view in views where view.superview !== self {
            view.autoresizingMask = []
            addSubview(view)
            reparented.insert(ObjectIdentifier(view))
        }
        if bounds.width > 1, bounds.height > 1 {
            for view in views where reparented.contains(ObjectIdentifier(view)) {
                if let frame = targetFrame(
                    for: view, leading: leading, trailing: trailing,
                    axis: axis, fraction: fraction
                ) {
                    view.frame = frame
                }
            }
        }
        for sub in subviews where !views.contains(where: { $0 === sub }) {
            sub.removeFromSuperview()
        }

        var requestPaint = !reparented.isEmpty || (wasHidden && surfaceVisible)
        var flippedVisible = Set<ObjectIdentifier>()
        for view in views {
            let visible = view === leading || view === trailing
            let needsFlip = view.isHidden == visible
            if needsFlip {
                view.isHidden = !visible
                if visible {
                    flippedVisible.insert(ObjectIdentifier(view))
                    requestPaint = true
                    onReturnToFront?(view)
                }
            }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if requestPaint {
            scheduleFullPaint()
        }

        if !surfaceVisible || !claimsFocus {
            if lastClaimsFocus {
                shown = nil
            }
            lastClaimsFocus = false
            return
        }

        let focusReturning = !lastClaimsFocus
        lastClaimsFocus = true
        installClickMonitor()

        if focusReturning {
            for view in views where !view.isHidden {
                if !flippedVisible.contains(ObjectIdentifier(view)) {
                    onReturnToFront?(view)
                }
            }
            scheduleFullPaint()
        }

        let key = focused ?? leading
        if let key, focusReturning || shown !== key {
            shown = key
            DispatchQueue.main.async { [weak self, weak key] in
                guard let self, let key, key.superview === self else { return }
                guard self.lastClaimsFocus, self.shown === key, !key.isHiddenOrHasHiddenAncestor,
                      self.window?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
                self.window?.makeFirstResponder(key)
            }
        } else if key == nil {
            shown = nil
        }
    }

    private func scheduleFullPaint() {
        needsFullPaint = true
        if bounds.width > 1, bounds.height > 1 {
            paintVisibleTerminals()
        }
    }

    private func paintVisibleTerminals() {
        needsFullPaint = false
        for sub in subviews where !sub.isHidden {
            // `setNeedsDisplay` alone only asks AppKit to composite whatever
            // Request a fresh frame after reparenting, including GPU-backed
            // surfaces. The copied terminal state and the pty size stay intact.
            guard let terminalView = sub as? TerminalView else { continue }
            terminalView.requestRedraw()
        }
    }

    private static let splitGap: CGFloat = 1

    override func layout() {
        super.layout()
        guard !isHidden else { return }
        guard bounds.width > 1, bounds.height > 1 else {
            return
        }
        let gap = Self.splitGap
        if let axis = splitAxis {
            let (lead, trail) = splitFrames(axis: axis, fraction: fraction, gap: gap)
            if let view = leadingView, view.frame != lead { view.frame = lead }
            if let view = trailingView, view.frame != trail { view.frame = trail }
        } else {
            for sub in subviews where !sub.isHidden {
                if sub.frame != bounds { sub.frame = bounds }
            }
        }
        if needsFullPaint {
            paintVisibleTerminals()
        }
    }

    private func targetFrame(
        for view: TerminalView,
        leading: TerminalView?,
        trailing: TerminalView?,
        axis: Axis?,
        fraction: CGFloat
    ) -> CGRect? {
        if let axis {
            let (lead, trail) = splitFrames(axis: axis, fraction: fraction, gap: Self.splitGap)
            if view === leading { return lead }
            if view === trailing { return trail }
            return nil
        }
        if view === leading || view === trailing { return bounds }
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        needsLayout = true
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
        guard lastClaimsFocus, !isHiddenOrHasHiddenAncestor, let window, event.window === window,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let leading = leadingView, !leading.isHidden, leading.frame.contains(point) {
            onViewClicked?(leading)
        } else if let trailing = trailingView, !trailing.isHidden, trailing.frame.contains(point) {
            onViewClicked?(trailing)
        }
    }

    deinit {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
    }
}
#endif
