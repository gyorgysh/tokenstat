// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if DEBUG && os(macOS)
import AppKit

/// Lets a script look at the window and steer it, in Debug builds only.
///
/// Layout work needs pictures, and a picture of another app's window needs a
/// Screen Recording grant the terminal usually does not have. An app may
/// always capture its own windows, so the app takes the picture itself when
/// asked. The same channel moves between screens, sizes the window and flips
/// the appearance, so a screen can be checked at several widths in both
/// themes without anybody clicking.
///
/// Every hook is a distributed notification whose object is a plain string:
///
/// - `ai.tokenstat.debug.snapshot`: a PNG path to write the main window to.
/// - `ai.tokenstat.debug.route`: `home`, `insights`, `machines`, `todo`,
///   `notes`, `workflows`, `automations`, `account`, `overview`, `ssh`, or
///   `workspace:<folder name or index>:<section>`.
/// - `ai.tokenstat.debug.window`: the content size, as `1440x900`.
/// - `ai.tokenstat.debug.appearance`: `dark`, `light` or `system`.
/// - `ai.tokenstat.debug.key`: a named action, such as `sidebar` or
///   `inspector`, for the toggles the menu would otherwise post. Any other
///   name is relayed in process for the screen on show to act on.
///
/// Release builds compile none of it.
enum DebugUIHooks {
    static let snapshot = Notification.Name("ai.tokenstat.debug.snapshot")
    static let route = Notification.Name("ai.tokenstat.debug.route")
    static let window = Notification.Name("ai.tokenstat.debug.window")
    static let appearance = Notification.Name("ai.tokenstat.debug.appearance")
    static let key = Notification.Name("ai.tokenstat.debug.key")
    /// The route hook, relayed in process. The shell owns navigation, so it
    /// is the one that listens.
    static let routeRequested = Notification.Name("ai.tokenstat.debug.routeRequested")
    /// Any other key, relayed in process for a screen to act on.
    static let keyRequested = Notification.Name("ai.tokenstat.debug.keyRequested")

    /// Set by `TOKENSTAT_PRINT_CHANGES`: views that opt in print what made
    /// their body run again.
    static let printsChanges = ProcessInfo.processInfo.environment["TOKENSTAT_PRINT_CHANGES"] != nil

    @MainActor
    static func install() {
        // Redirected to a file, stdout is block-buffered and the lines only
        // arrive when the app quits. Line by line is what a measurement wants.
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
            case "sidebar": NotificationCenter.default.post(name: .toggleLeftSidebar, object: nil)
            case "inspector": NotificationCenter.default.post(name: .toggleRightSidebar, object: nil)
            case let other?: NotificationCenter.default.post(name: keyRequested, object: other)
            default: break
            }
        }
    }

    /// The shell's window: the largest visible one that can be main. The
    /// About window and a remote screen viewer are both smaller.
    @MainActor
    private static var shellWindow: NSWindow? {
        NSApp.windows
            .filter { $0.isVisible && $0.canBecomeMain }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// `CGWindowListCreateImage`, looked up at run time.
    ///
    /// It is the one call that returns the window exactly as the window server
    /// composites it, glass included, and it is marked unavailable in newer
    /// SDKs. The symbol is still exported, and a Debug hook has no business
    /// holding the deployment target or the warning count hostage.
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    @MainActor
    private static func capture(to path: String) {
        guard let window = shellWindow,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
        else { return }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // .optionIncludingWindow, then .boundsIgnoreFraming | .bestResolution.
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
