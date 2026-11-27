// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if DEBUG && os(macOS)
import AppKit

enum DebugUIHooks {
    static let snapshot = Notification.Name("ai.tokenstat.debug.snapshot")
    static let route = Notification.Name("ai.tokenstat.debug.route")
    static let window = Notification.Name("ai.tokenstat.debug.window")
    static let appearance = Notification.Name("ai.tokenstat.debug.appearance")
    static let key = Notification.Name("ai.tokenstat.debug.key")
    static let routeRequested = Notification.Name("ai.tokenstat.debug.routeRequested")
    static let keyRequested = Notification.Name("ai.tokenstat.debug.keyRequested")

    static let printsChanges = ProcessInfo.processInfo.environment["TOKENSTAT_PRINT_CHANGES"] != nil

    @MainActor
    static func install() {
        if printsChanges { setvbuf(stdout, nil, _IOLBF, 0) }
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: snapshot, object: nil, queue: .main) { note in
            guard let path = note.object as? String else { return }
            MainActor.assumeIsolated { capture(to: path) }
        }
        center.addObserver(forName: route, object: nil, queue: .main) { note in
            guard let target = note.object as? String else { return }
            NotificationCenter.default.post(name: routeRequested, object: target)
        }
        center.addObserver(forName: window, object: nil, queue: .main) { note in
            guard let size = note.object as? String else { return }
            MainActor.assumeIsolated { resize(to: size) }
        }
        center.addObserver(forName: appearance, object: nil, queue: .main) { note in
            guard let name = note.object as? String else { return }
            MainActor.assumeIsolated {
                switch name {
                case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                case "light": NSApp.appearance = NSAppearance(named: .aqua)
                default: NSApp.appearance = nil
                }
            }
        }
        center.addObserver(forName: key, object: nil, queue: .main) { note in
            switch note.object as? String {
            case "performance-start": MainActor.assumeIsolated { TranscriptProbe.shared.startRecording() }
            case "performance-stop": MainActor.assumeIsolated { TranscriptProbe.shared.finishRecording() }
            case "backdrop": MainActor.assumeIsolated { toggleBackdropProbe() }
            case "sidebar": NotificationCenter.default.post(name: .toggleLeftSidebar, object: nil)
            case "inspector": NotificationCenter.default.post(name: .toggleRightSidebar, object: nil)
            case let wheel? where wheel.hasPrefix("wheel:"):
                let parts = wheel.split(separator: ":")
                let points = Int32(parts.count > 1 ? parts[1] : "") ?? 0
                let steps = Int(parts.count > 2 ? parts[2] : "") ?? 1
                let momentum = Int(parts.count > 3 ? parts[3] : "") ?? 0
                MainActor.assumeIsolated { DebugTranscriptWheel.gesture(points: points, steps: steps, momentum: momentum) }
            case let other?: NotificationCenter.default.post(name: keyRequested, object: other)
            default: break
            }
        }
    }

    @MainActor private static var backdropProbe: NSWindow?

    @MainActor private static func toggleBackdropProbe() {
        if let probe = backdropProbe {
            probe.parent?.removeChildWindow(probe)
            probe.close()
            backdropProbe = nil
            return
        }
        guard let shell = shellWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        shell.makeKeyAndOrderFront(nil)
        let probe = NSWindow(contentRect: shell.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        probe.ignoresMouseEvents = true
        let surface = NSView(frame: NSRect(origin: .zero, size: shell.frame.size))
        surface.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.frame = surface.bounds
        gradient.colors = [NSColor.systemPink.cgColor, NSColor.systemBlue.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 0, y: 1)
        surface.layer = gradient
        probe.contentView = surface
        shell.addChildWindow(probe, ordered: .below)
        probe.order(.below, relativeTo: shell.windowNumber)
        backdropProbe = probe
    }

    @MainActor
    private static var shellWindow: NSWindow? {
        NSApp.windows
            .filter { $0.isVisible && $0.canBecomeMain }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    @MainActor
    private static func capture(to path: String) {
        guard let window = shellWindow else { return }
        write(window, to: path)
        let url = URL(fileURLWithPath: path)
        func beside(_ suffix: String) -> String {
            url.deletingLastPathComponent()
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + suffix + ".png").path
        }
        if let sheet = window.attachedSheet { write(sheet, to: beside("-sheet")) }
        let others = NSApp.windows.filter { $0 !== window && $0 !== window.attachedSheet && $0.isVisible }
        for (index, other) in others.enumerated() { write(other, to: beside("-window-\(index + 1)")) }
    }

    @MainActor
    private static func write(_ window: NSWindow, to path: String) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
        else { return }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?
            .takeRetainedValue()
        else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    @MainActor
    private static func resize(to spec: String) {
        let parts = spec.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let window = shellWindow else { return }
        TranscriptProbe.shared.noteResize()
        var frame = window.frame
        let content = window.contentRect(forFrameRect: frame)
        let chrome = frame.height - content.height
        let top = frame.maxY
        frame.size = NSSize(width: parts[0], height: parts[1] + chrome)
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true, animate: false)
    }
}
#endif
