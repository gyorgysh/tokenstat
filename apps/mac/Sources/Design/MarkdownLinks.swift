// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

enum MarkdownLinks {
    private static let schemes: Set<String> = ["http", "https", "mailto"]

    /// Styling and URL filtering share one pass: an unsafe URL becomes plain
    /// text, while a safe link keeps emphasis and gains a visible affordance.
    static func styled(_ attributed: AttributedString, color: Color) -> AttributedString {
        guard attributed.runs.contains(where: { $0.link != nil }) else { return attributed }
        var result = attributed
        for run in attributed.runs {
            guard let url = run.link else { continue }
            if !schemes.contains(url.scheme?.lowercased() ?? "") {
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

extension MarkdownLinks {
    /// Keep native link handling and one selectable Text, while giving each
    /// wrapped link run an identity the hover renderer can recognize.
    static func text(_ attributed: AttributedString) -> Text {
        guard attributed.runs.contains(where: { $0.link != nil }) else { return Text(attributed) }
        return attributed.runs.reduce(Text("")) { result, run in
            let piece = Text(AttributedString(attributed[run.range]))
            guard let url = run.link, schemes.contains(url.scheme?.lowercased() ?? "") else { return result + piece }
            return result + piece.customAttribute(MarkdownLinkAttribute(url: url))
        }
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
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            // Selection overlays can own mouse-move delivery. Observe only
            // this window and always return the original event unchanged.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                self.note(event)
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
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
            if current != nil { current = nil; changed?(nil); toolTip = nil }
            NSCursor.arrow.set()
        }
        private func note(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else {
                if current != nil { current = nil; changed?(nil); toolTip = nil; NSCursor.arrow.set() }
                return
            }
            let url = map?.url(at: point)
            if current != url { current = url; changed?(url); toolTip = url?.absoluteString }
            (url == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
        }
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
