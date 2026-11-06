// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Decoded pixels remain bounded by ChatImageDecodeCache; zoom never decodes again.
struct ChatImageViewport {
    let image: CGImage
    @Binding var zoom: CGFloat
    var move: (Int) -> Void
    var pagesAtFit = false
}

#if os(macOS)
extension ChatImageViewport: NSViewRepresentable {
    func makeNSView(context: Context) -> ChatImageScrollView { ChatImageScrollView() }
    func updateNSView(_ view: ChatImageScrollView, context: Context) {
        view.onZoom = { zoom = $0 }; view.onMove = move
        view.update(image: image, zoom: zoom)
    }
}

private final class ChatImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposed)
        if let documentView {
            if documentView.frame.width < result.width { result.origin.x = (documentView.frame.width - result.width) / 2 }
            if documentView.frame.height < result.height { result.origin.y = (documentView.frame.height - result.height) / 2 }
        }
        return result
    }
}

final class ChatImageScrollView: NSScrollView {
    private let picture = NSImageView()
    private var pixels: CGImage?
    private var fittedViewport = CGSize.zero
    private var applying = false
    private var dragStart = CGPoint.zero
    private var dragWasFitted = false
    private var wheelTravel = CGPoint.zero
    private var wheelWasFitted = false
    var onZoom: ((CGFloat) -> Void)?
    var onMove: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = ChatImageClipView()
        documentView = picture
        drawsBackground = false; contentView.drawsBackground = false
        hasHorizontalScroller = false; hasVerticalScroller = false
        allowsMagnification = true; minMagnification = 1; maxMagnification = 4
        picture.imageScaling = .scaleAxesIndependently
        let drag = NSPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        addGestureRecognizer(drag)
        let tap = NSClickGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        tap.numberOfClicksRequired = 2; addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func update(image: CGImage, zoom: CGFloat) {
        applying = true; defer { applying = false }
        if pixels !== image {
            pixels = image; picture.image = NSImage(cgImage: image, size: .zero)
            fittedViewport = .zero
        }
        fitIfNeeded()
        if abs(magnification - zoom) > 0.001 {
            setMagnification(min(4, max(1, zoom)), centeredAt: CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
        }
    }
    override func layout() { super.layout(); fitIfNeeded() }
    private func fitIfNeeded() {
        let viewport = bounds.size
        guard let pixels, viewport.width > 0, viewport.height > 0, viewport != fittedViewport else { return }
        let wasApplying = applying; applying = true; defer { applying = wasApplying }
        let scale = magnification
        magnification = 1
        picture.frame = CGRect(origin: .zero, size: ChatImageViewerGeometry.fit(image: CGSize(width: pixels.width, height: pixels.height), viewport: viewport))
        fittedViewport = viewport
        magnification = scale
        contentView.scroll(to: contentView.constrainBoundsRect(contentView.bounds).origin)
        reflectScrolledClipView(contentView)
    }
    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        if !applying { onZoom?(min(4, max(1, magnification))) }
    }
    @objc private func doubleTap(_ gesture: NSClickGestureRecognizer) {
        setMagnification(magnification <= 1.001 ? 2 : 1, centeredAt: gesture.location(in: contentView))
        onZoom?(magnification)
    }
    @objc private func pan(_ gesture: NSPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        if gesture.state == .began { dragStart = .zero; dragWasFitted = magnification <= 1.001 }
        if gesture.state == .began || gesture.state == .changed {
            if !dragWasFitted {
                var target = contentView.bounds
                target.origin.x -= (translation.x - dragStart.x) / magnification
                target.origin.y -= (translation.y - dragStart.y) / magnification
                contentView.scroll(to: contentView.constrainBoundsRect(target).origin)
                reflectScrolledClipView(contentView)
            }
            dragStart = translation
        } else if gesture.state == .ended, dragWasFitted {
            navigate(translation.x, translation.y)
        }
    }
    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.cancelled) {
            wheelTravel = .zero; wheelWasFitted = false
            super.scrollWheel(with: event); return
        }
        if event.phase.contains(.began) { wheelTravel = .zero; wheelWasFitted = magnification <= 1.001 }
        if magnification > 1.001 {
            wheelTravel = .zero; wheelWasFitted = false
            super.scrollWheel(with: event); return
        }
        // Momentum belongs to the image that was swiped, not its replacement.
        guard event.momentumPhase.isEmpty else { return }
        wheelTravel.x += event.scrollingDeltaX; wheelTravel.y += event.scrollingDeltaY
        if event.phase.contains(.ended) {
            if wheelWasFitted { navigate(wheelTravel.x, wheelTravel.y) }
            wheelTravel = .zero; wheelWasFitted = false
        }
    }
    private func navigate(_ x: CGFloat, _ y: CGFloat) {
        let direction = ChatImageViewerGeometry.swipe(x: x, y: y, width: bounds.width)
        if direction != 0 { onMove?(direction) }
    }
}
#else
extension ChatImageViewport: UIViewRepresentable {
    func makeUIView(context: Context) -> ChatImageScrollView { ChatImageScrollView() }
    func updateUIView(_ view: ChatImageScrollView, context: Context) {
        view.pagesAtFit = pagesAtFit
        view.onZoom = { zoom = $0 }; view.onMove = move
        view.update(image: image, zoom: zoom)
    }
}

final class ChatImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let picture = UIImageView()
    private var pixels: CGImage?
    private var fittedViewport = CGSize.zero
    private var applying = false
    private var panWasFitted = false
    private var panHadMultipleTouches = false
    var pagesAtFit = false
    var onZoom: ((CGFloat) -> Void)?
    var onMove: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; minimumZoomScale = 1; maximumZoomScale = 4
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        picture.contentMode = .scaleAspectFit; addSubview(picture)
        alwaysBounceHorizontal = true
        panGestureRecognizer.addTarget(self, action: #selector(pan(_:)))
        pinchGestureRecognizer?.addTarget(self, action: #selector(pinch(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        tap.numberOfTapsRequired = 2; addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        // Fitted images hand the drag to the native pager. Pinch and zoomed
        // image panning keep the scroll view's own gesture handling.
        if pagesAtFit && gesture === panGestureRecognizer && zoomScale <= 1.001 { return false }
        return super.gestureRecognizerShouldBegin(gesture)
    }
    func update(image: CGImage, zoom: CGFloat) {
        applying = true; defer { applying = false }
        if pixels !== image {
            pixels = image; picture.image = UIImage(cgImage: image); fittedViewport = .zero
        }
        fitIfNeeded()
        if abs(zoomScale - zoom) > 0.001 { zoomAt(min(4, max(1, zoom)), point: CGPoint(x: bounds.midX, y: bounds.midY)) }
    }
    override func layoutSubviews() { super.layoutSubviews(); fitIfNeeded(); centerImage() }
    private func fitIfNeeded() {
        let viewport = bounds.size
        guard let pixels, viewport.width > 0, viewport.height > 0, viewport != fittedViewport else { return }
        let wasApplying = applying; applying = true; defer { applying = wasApplying }
        let scale = zoomScale
        setZoomScale(1, animated: false)
        picture.frame = CGRect(origin: .zero, size: ChatImageViewerGeometry.fit(image: CGSize(width: pixels.width, height: pixels.height), viewport: viewport))
        contentSize = picture.bounds.size; fittedViewport = viewport
        setZoomScale(scale, animated: false); centerImage()
    }
    private func centerImage() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if contentInset != inset { contentInset = inset }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        if !applying { onZoom?(min(4, max(1, zoomScale))) }
    }
    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began || gesture.state == .changed { panHadMultipleTouches = true }
    }
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            panWasFitted = zoomScale <= 1.001
            panHadMultipleTouches = gesture.numberOfTouches > 1 || pinchGestureRecognizer?.state == .began || pinchGestureRecognizer?.state == .changed
        } else if gesture.state == .changed {
            panHadMultipleTouches = panHadMultipleTouches || gesture.numberOfTouches > 1
        } else if gesture.state == .ended, panWasFitted, !panHadMultipleTouches, zoomScale <= 1.001 {
            let translation = gesture.translation(in: self)
            let direction = ChatImageViewerGeometry.swipe(x: translation.x, y: translation.y, width: bounds.width)
            if direction != 0 { onMove?(direction) }
        }
    }
    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        zoomAt(zoomScale <= 1.001 ? 2 : 1, point: gesture.location(in: self))
    }
    private func zoomAt(_ scale: CGFloat, point: CGPoint) {
        let pixel = convert(point, to: picture)
        let anchor = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
        setZoomScale(scale, animated: false); centerImage()
        let x = min(max(-contentInset.left, pixel.x * zoomScale - anchor.x), max(-contentInset.left, contentSize.width - bounds.width + contentInset.right))
        let y = min(max(-contentInset.top, pixel.y * zoomScale - anchor.y), max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom))
        setContentOffset(CGPoint(x: x, y: y), animated: false)
    }
}
#endif
