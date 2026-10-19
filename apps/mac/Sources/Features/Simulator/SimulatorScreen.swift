// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import SwiftUI
import QuartzCore
import IOSurface

struct SimulatorScreen: NSViewRepresentable {
    let session: SimulatorSession
    var interactive = true
    var cornerRadius: CGFloat = 0
    var visible = true
    func makeNSView(context: Context) -> SimulatorScreenNSView {
        let view = SimulatorScreenNSView()
        view.session = session
        session.register(view)
        return view
    }
    func updateNSView(_ view: SimulatorScreenNSView, context: Context) {
        view.interactive = interactive
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        view.isHidden = !visible
        if visible { view.redraw() }
    }
    static func dismantleNSView(_ view: SimulatorScreenNSView, coordinator: ()) {
        view.cancelGestures()
        view.session?.connection?.releaseInputs()
    }
}

/// Frames update a native Metal view without publishing every frame
/// through SwiftUI. Each screen owns input only while it is first responder.
final class SimulatorScreenNSView: NSView {
    weak var session: SimulatorSession?
    var interactive = true {
        didSet {
            if oldValue && !interactive { cancelGestures(); session?.connection?.releaseInputs() }
        }
    }
    private var pixels = CGSize.zero
    private var orientation = 1
    private let renderer = SimulatorMetalRenderer()
    private var down = false
    private var lastPoint = CGPoint.zero
    private var modifiers: NSEvent.ModifierFlags = []
    private var wheelPoint: CGPoint?
    private var wheelRelease: Task<Void, Never>?
    private var windowObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { interactive }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        renderer.view.frame = bounds
        renderer.view.autoresizingMask = [.width, .height]
        addSubview(renderer.view)
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.text("apple.simulator.screen"))
        setAccessibilityHelp(L10n.text("apple.simulator.screen_help"))
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }
    func present(_ surface: Any, pixels: CGSize, orientation: Int, backing: Any? = nil) {
        self.pixels = pixels
        self.orientation = orientation
        if !renderer.isAvailable { session?.error = L10n.text("apple.simulator.metal_unavailable"); return }
        guard let surface = surface as? IOSurface else { return }
        renderer.present(surface, orientation: orientation, backing: backing)
    }
    override func layout() { super.layout(); renderer.view.frame = bounds; renderer.redraw() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        if let window {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelGestures(); self?.session?.connection?.releaseInputs() }
            }
        }
        // A cached frame may arrive before the view has a window or drawable.
        // Redraw after mounting even when the guest screen is completely still.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderer.redraw()
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        interactive && !isHidden && bounds.contains(convert(point, from: superview)) ? self : nil
    }
    func clear() { cancelGestures(); renderer.clear() }
    func redraw() { renderer.redraw() }
    func cancelGestures() {
        wheelRelease?.cancel(); wheelRelease = nil
        if let wheelPoint { _ = session?.touch(SimulatorGeometry.devicePoint(wheelPoint, orientation: orientation), phase: 2) }
        self.wheelPoint = nil
        if down { _ = session?.touch(lastPoint, phase: 2); down = false }
        updateModifiers([])
    }
    private func point(_ event: NSEvent) -> CGPoint? {
        guard let point = SimulatorGeometry.normalized(point: convert(event.locationInWindow, from: nil), bounds: bounds.size,
            pixels: SimulatorGeometry.displaySize(pixels: pixels, orientation: orientation)) else { return nil }
        return SimulatorGeometry.devicePoint(point, orientation: orientation)
    }
    override func mouseDown(with event: NSEvent) {
        guard interactive, let point = point(event), let session else { return }
        cancelGestures()
        window?.makeFirstResponder(self)
        updateModifiers(event.modifierFlags)
        lastPoint = point
        down = session.touch(point, phase: 0)
        if !down { session.error = L10n.text("apple.simulator.control_unavailable") }
    }
    override func mouseDragged(with event: NSEvent) {
        guard down, let point = point(event) else { return }
        lastPoint = point
        _ = session?.touch(point, phase: 1)
    }
    override func mouseUp(with event: NSEvent) {
        guard down else { return }
        _ = session?.touch(point(event) ?? lastPoint, phase: 2)
        down = false
    }
    override func resignFirstResponder() -> Bool {
        cancelGestures(); session?.connection?.releaseInputs()
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        guard interactive else { super.keyDown(with: event); return }
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 9: paste(nil)
            case 8: copy(nil)
            case 7: cut(nil)
            case 0: selectAll(nil)
            default:
                updateModifiers(event.modifierFlags)
                if session?.key(event, pressed: true) != true { super.keyDown(with: event) }
            }
            return
        }
        updateModifiers(event.modifierFlags)
        if session?.key(event, pressed: true) != true { NSSound.beep() }
    }
    override func flagsChanged(with event: NSEvent) { if interactive { updateModifiers(event.modifierFlags) } }
    private func updateModifiers(_ flags: NSEvent.ModifierFlags) {
        let pairs: [(NSEvent.ModifierFlags, UInt)] = [(.shift,0xe1),(.control,0xe0),(.option,0xe2),(.command,0xe3)]
        for (flag, usage) in pairs where flags.contains(flag) != modifiers.contains(flag) {
            _ = session?.connection?.sendKeyUsage(usage, pressed: flags.contains(flag))
        }
        modifiers = flags
    }
    @objc func paste(_ sender: Any?) {
        if interactive { session?.pasteClipboard(isCurrent: { [weak self] in
            guard let self else { return false }
            return self.window?.firstResponder === self
        }) }
    }
    @objc func copy(_ sender: Any?) { if interactive { session?.copyDeviceClipboard() } }
    @objc func cut(_ sender: Any?) { if interactive { session?.copyDeviceClipboard(cut: true) } }
    override func selectAll(_ sender: Any?) { if interactive { session?.keyboardChord(4, keepCommand: modifiers.contains(.command)) } }
    override func keyUp(with event: NSEvent) {
        guard interactive else { return }
        _ = session?.key(event, pressed: false)
    }
    override func scrollWheel(with event: NSEvent) {
        guard interactive, let session, let point = SimulatorGeometry.normalized(point: convert(event.locationInWindow, from: nil),
            bounds: bounds.size, pixels: SimulatorGeometry.displaySize(pixels: pixels, orientation: orientation)) else { return }
        if wheelPoint == nil {
            wheelPoint = point
            _ = session.touch(SimulatorGeometry.devicePoint(point, orientation: orientation), phase: 0)
        }
        let p = wheelPoint ?? point
        let destination = CGPoint(x: min(0.98, max(0.02, p.x - event.scrollingDeltaX / 600)),
                                  y: min(0.98, max(0.02, p.y - event.scrollingDeltaY / 600)))
        wheelPoint = destination
        _ = session.touch(SimulatorGeometry.devicePoint(destination, orientation: orientation), phase: 1)
        wheelRelease?.cancel()
        wheelRelease = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, let point = self.wheelPoint else { return }
            _ = self.session?.touch(SimulatorGeometry.devicePoint(point, orientation: self.orientation), phase: 2)
            self.wheelPoint = nil
        }
    }
}
#endif
