// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import AppKit
typealias ChartViewportContent = NSView
#else
import UIKit
typealias ChartViewportContent = UIView
#endif

/// Keep the chart's measured seat in the document, but only retain an
/// expensive browser while that seat intersects its native scroll viewport.
/// A message's plain VStack may contain any number of chart seats.
final class ChartViewportView: ChartViewportContent {
    var makeContent: (() -> ChartViewportContent?)?
    var releaseContent: ((ChartViewportContent) -> Void)?
    private(set) var content: ChartViewportContent?
    private var notifications: [NSObjectProtocol] = []
    private var ancestors: [ObjectIdentifier] = []
    private var observedWindow: ObjectIdentifier?
    private var queued = false
    private var stopped = false
    private var observations: [NSKeyValueObservation] = []

    init() { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attachmentChanged() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attachmentChanged() }
    override func viewDidHide() { super.viewDidHide(); updateVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); scheduleVisibilityUpdate() }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); scheduleVisibilityUpdate() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); scheduleVisibilityUpdate() }
    override var alphaValue: CGFloat { didSet { scheduleVisibilityUpdate() } }
    override func layout() { super.layout(); scheduleVisibilityUpdate() }
    #else
    override func didMoveToSuperview() { super.didMoveToSuperview(); attachmentChanged() }
    override func didMoveToWindow() { super.didMoveToWindow(); attachmentChanged() }
    override var frame: CGRect { didSet { scheduleVisibilityUpdate() } }
    override var bounds: CGRect { didSet { scheduleVisibilityUpdate() } }
    override var isHidden: Bool { didSet { scheduleVisibilityUpdate() } }
    override var alpha: CGFloat { didSet { scheduleVisibilityUpdate() } }
    override func layoutSubviews() { super.layoutSubviews(); scheduleVisibilityUpdate() }
    #endif

    private func attachmentChanged() {
        stopObserving()
        if window == nil { unmount() }
        scheduleVisibilityUpdate()
    }

    func scheduleVisibilityUpdate() {
        guard !queued, !stopped else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queued = false
            self.updateVisibility()
        }
    }

    func updateVisibility() {
        guard !stopped else { return }
        observeAncestors()
        guard isInViewport else { unmount(); return }
        guard content == nil, let child = makeContent?() else { return }
        content = child
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor), child.trailingAnchor.constraint(equalTo: trailingAnchor),
            child.topAnchor.constraint(equalTo: topAnchor), child.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private var isInViewport: Bool {
        #if os(macOS)
        guard let window, window.isVisible, !window.isMiniaturized, !isHiddenOrHasHiddenAncestor else { return false }
        var ancestor: NSView? = self
        while let view = ancestor {
            guard view.alphaValue > 0.01 else { return false }
            ancestor = view.superview
        }
        let visible = bounds.intersection(visibleRect)
        #else
        guard let window, !window.isHidden else { return false }
        var visible = convert(bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = self
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01 else { return false }
            if view.clipsToBounds { visible = visible.intersection(view.convert(view.bounds, to: window)) }
            ancestor = view.superview
        }
        #endif
        return !visible.isNull && visible.width > 0 && visible.height > 0
    }

    private func observeAncestors() {
        var views: [ChartViewportContent] = []
        var ancestor = superview
        while let view = ancestor { views.append(view); ancestor = view.superview }
        let identity = views.map(ObjectIdentifier.init)
        let windowIdentity = window.map(ObjectIdentifier.init)
        guard identity != ancestors || windowIdentity != observedWindow else { return }
        stopObserving()
        ancestors = identity; observedWindow = windowIdentity
        guard window != nil else { return }
        #if os(macOS)
        for view in views {
            observations.append(view.observe(\.alphaValue) { [weak self] _, _ in self?.scheduleVisibilityUpdate() })
            view.postsBoundsChangedNotifications = true
            view.postsFrameChangedNotifications = true
            observe(NSView.boundsDidChangeNotification, object: view)
            observe(NSView.frameDidChangeNotification, object: view)
        }
        observe(NSWindow.didChangeOcclusionStateNotification, object: window)
        observe(NSWindow.didMiniaturizeNotification, object: window)
        observe(NSWindow.didDeminiaturizeNotification, object: window)
        observe(NSWindow.willCloseNotification, object: window)
        if let window {
            observations.append(window.observe(\.isVisible) { [weak self] _, _ in self?.scheduleVisibilityUpdate() })
        }
        #else
        for view in views {
            observations.append(view.observe(\.isHidden) { [weak self] _, _ in self?.scheduleVisibilityUpdate() })
            observations.append(view.observe(\.alpha) { [weak self] _, _ in self?.scheduleVisibilityUpdate() })
            observations.append(view.observe(\.frame) { [weak self] _, _ in self?.scheduleVisibilityUpdate() })
            observations.append(view.observe(\.bounds) { [weak self] _, _ in self?.scheduleVisibilityUpdate() })
            if let scroll = view as? UIScrollView {
                observations.append(scroll.observe(\.contentOffset) { [weak self] _, _ in self?.scheduleVisibilityUpdate() })
            }
        }
        observe(UIWindow.didBecomeVisibleNotification, object: window)
        observe(UIWindow.didBecomeHiddenNotification, object: window)
        #endif
    }

    private func observe(_ name: Notification.Name, object: Any?) {
        notifications.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            self?.scheduleVisibilityUpdate()
        })
    }

    private func stopObserving() {
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications = []; ancestors = []; observedWindow = nil
        observations = []
    }

    private func unmount() {
        guard let child = content else { return }
        content = nil
        releaseContent?(child)
        child.removeFromSuperview()
    }

    func shutdown() {
        stopped = true
        stopObserving(); unmount()
        makeContent = nil; releaseContent = nil
    }
    deinit { notifications.forEach(NotificationCenter.default.removeObserver) }
}
