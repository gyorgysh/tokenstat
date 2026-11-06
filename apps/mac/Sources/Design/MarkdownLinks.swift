// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

enum MarkdownLinks {
    private static let schemes: Set<String> = ["http", "https", "mailto"]

    private static func allows(_ url: URL) -> Bool {
        if schemes.contains(url.scheme?.lowercased() ?? "") { return true }
        #if os(macOS)
        return SimulatorAttachRequest(url: url) != nil || DesktopOpenRequest(url: url) != nil
        #else
        return false
        #endif
    }

    /// Styling and URL filtering share one pass: an unsafe URL becomes plain
    /// text, while a safe link keeps emphasis and gains a visible affordance.
    static func styled(_ attributed: AttributedString, color: Color) -> AttributedString {
        guard attributed.runs.contains(where: { $0.link != nil }) else { return attributed }
        var result = attributed
        for run in attributed.runs {
            guard let url = run.link else { continue }
            if !allows(url) {
                result[run.range].link = nil
            } else {
                // Explicit attributes survive an enclosing foreground style,
                // selection and mixed inline formatting on supported OSes.
                result[run.range].foregroundColor = color
                result[run.range].underlineStyle = Text.LineStyle(pattern: .solid, color: color)
            }
        }
        return result
    }
}

struct MarkdownLinkAttribute: TextAttribute {
    let url: URL
}

/// Bound native text views without reparsing fragments of Markdown syntax.
enum MarkdownTextChunks {
    static let maximumLineBreaks = 64

    /// Keep code lines intact so a wide fence can still scroll horizontally.
    static func splitLines(_ value: AttributedString) -> [AttributedString] {
        let characters = value.characters
        var pieces: [AttributedString] = []
        var start = characters.startIndex
        var end = start
        var lineBreaks = 0
        while end < characters.endIndex {
            if characters[end].isNewline { lineBreaks += 1 }
            end = characters.index(after: end)
            if lineBreaks == maximumLineBreaks, end < characters.endIndex {
                pieces.append(AttributedString(value[start..<end]))
                start = end
                lineBreaks = 0
            }
        }
        pieces.append(AttributedString(value[start..<end]))
        return pieces
    }

    static func split(_ value: AttributedString, maximum: Int) -> [AttributedString] {
        precondition(maximum > 0)
        let characters = value.characters
        var pieces: [AttributedString] = []
        var start = characters.startIndex
        while start < characters.endIndex {
            var end = start
            var count = 0
            var lineBreaks = 0
            while end < characters.endIndex, count < maximum {
                if characters[end].isNewline { lineBreaks += 1 }
                end = characters.index(after: end)
                count += 1
                if lineBreaks == maximumLineBreaks { break }
            }
            if end < characters.endIndex {
                // Prefer a word boundary, retaining the whitespace itself.
                let halfway = characters.index(start, offsetBy: count / 2)
                var boundary = end
                while boundary > halfway {
                    let previous = characters.index(before: boundary)
                    if characters[previous].isWhitespace { end = boundary; break }
                    boundary = previous
                }
            }
            pieces.append(AttributedString(value[start..<end]))
            start = end
        }
        return pieces
    }
}

extension MarkdownLinks {
    /// Keep native link handling and one selectable Text, while giving each
    /// wrapped link run an identity the hover renderer can recognize.
    static func text(_ attributed: AttributedString) -> Text {
        guard attributed.runs.contains(where: { $0.link != nil }) else { return Text(attributed) }
        let parts = attributed.runs.map { run -> Text in
            let piece = Text(AttributedString(attributed[run.range]))
            guard let url = run.link, allows(url) else { return piece }
            return piece.customAttribute(MarkdownLinkAttribute(url: url))
        }
        return joined(parts[...])
    }

    /// SwiftUI resolves concatenation recursively. Balance the tree so a
    /// long streamed paragraph or many link runs cannot exhaust the stack.
    static func joined(_ parts: ArraySlice<Text>) -> Text {
        guard parts.count > 1 else { return parts.first ?? Text("") }
        let middle = parts.index(parts.startIndex, offsetBy: parts.count / 2)
        return joined(parts[..<middle]) + joined(parts[middle...])
    }
}

#if os(macOS)
import AppKit

/// Drawing may happen off the main thread. No observable state is mutated
/// during layout, and only link rectangles (never the whole paragraph) hit.
final class MarkdownLinkHitMap: @unchecked Sendable {
    struct Region { let url: URL; let rect: CGRect }
    private let lock = NSLock()
    private var regions: [Region] = []

    func replace(_ regions: [Region]) {
        lock.lock(); defer { lock.unlock() }
        self.regions = regions
    }
    func url(at point: CGPoint) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return regions.first { $0.rect.contains(point) }?.url
    }
}

@available(macOS 15.0, *)
struct MarkdownLinkRenderer: TextRenderer {
    let hovered: URL?
    let map: MarkdownLinkHitMap

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var regions: [MarkdownLinkHitMap.Region] = []
        for line in layout {
            for run in line {
                if let link = run[MarkdownLinkAttribute.self] {
                    let bounds = run.typographicBounds.rect
                    regions.append(.init(url: link.url, rect: bounds))
                    if link.url == hovered {
                        // Recolor the glyphs and their underline, preserving
                        // bold/italic and native selection/link interaction.
                        context.drawLayer { layer in
                            layer.draw(run)
                            layer.blendMode = .sourceIn
                            layer.fill(Path(bounds.insetBy(dx: -1, dy: -2)), with: .color(Theme.secondary))
                        }
                        continue
                    }
                }
                context.draw(run)
            }
        }
        map.replace(regions)
    }
}
/// AppKit tracking remains active above native text-selection overlays. The
/// view never takes clicks, drags or selection away from the underlying Text.
private struct MarkdownLinkTracking: NSViewRepresentable {
    let map: MarkdownLinkHitMap
    @Binding var hovered: URL?

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    static func dismantleNSView(_ view: TrackingView, coordinator: ()) { view.stop() }
    func updateNSView(_ view: TrackingView, context: Context) {
        view.map = map
        view.changed = { hovered = $0 }
    }

    final class TrackingView: NSView {
        var map: MarkdownLinkHitMap?
        var changed: ((URL?) -> Void)?
        private var current: URL?
        private var tracking: NSTrackingArea?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() }
        }
        func stop() { LinkHoverMonitor.leave(self) }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                                     options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .enabledDuringMouseDrag],
                                     owner: self)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseEntered(with event: NSEvent) { note(event) }
        override func mouseMoved(with event: NSEvent) { note(event) }
        override func cursorUpdate(with event: NSEvent) { note(event) }
        override func mouseExited(with event: NSEvent) {
            LinkHoverMonitor.leave(self)
            if current != nil { current = nil; changed?(nil); toolTip = nil }
            NSCursor.arrow.set()
        }
        fileprivate func note(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else {
                LinkHoverMonitor.leave(self)
                if current != nil { current = nil; changed?(nil); toolTip = nil; NSCursor.arrow.set() }
                return
            }
            LinkHoverMonitor.enter(self)
            let url = map?.url(at: point)
            if current != url { current = url; changed?(url); toolTip = url?.absoluteString }
            (url == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
        }
    }
}

/// One window-wide monitor for every paragraph with a link, not one each.
///
/// Selection overlays can own mouse-move delivery, so tracking areas alone
/// miss moves over selectable text. The monitor fills that gap, but it only
/// reaches the paragraphs the pointer is inside, which the tracking areas
/// report on entry and exit. A long transcript then costs the same per mouse
/// move as a short one. It always returns the event unchanged.
@MainActor
private enum LinkHoverMonitor {
    private static var monitor: Any?
    private static let inside = NSHashTable<MarkdownLinkTracking.TrackingView>.weakObjects()

    static func enter(_ view: MarkdownLinkTracking.TrackingView) {
        inside.add(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged]) { event in
            MainActor.assumeIsolated {
                for view in inside.allObjects where view.window === event.window {
                    view.note(event)
                }
            }
            return event
        }
    }

    static func leave(_ view: MarkdownLinkTracking.TrackingView) {
        inside.remove(view)
        guard inside.count == 0, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}

#endif

struct MarkdownLinkHover: ViewModifier {
    var enabled = true
    #if os(macOS)
    @State private var map = MarkdownLinkHitMap()
    @State private var hovered: URL?
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *), enabled {
            content
                .textRenderer(MarkdownLinkRenderer(hovered: hovered, map: map))
                .background {
                    MarkdownLinkTracking(map: map, hovered: $hovered)
                        .accessibilityHidden(true)
                }
        } else { content }
        #else
        content
        #endif
    }
}
