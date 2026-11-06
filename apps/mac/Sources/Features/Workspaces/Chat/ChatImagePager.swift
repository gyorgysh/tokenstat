// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(iOS)
import SwiftUI
import UIKit

/// Native interactive paging around the current image. The data source
/// creates adjacent pages on demand; remote loading stays with the viewer.
struct ChatImagePager: UIViewControllerRepresentable {
    let resources: [ChatImageResource]
    let selection: Int
    @Binding var zoom: CGFloat
    let reduceMotion: Bool
    var onSelect: (Int) -> Void

    func makeUIViewController(context: Context) -> ChatImagePagingController { ChatImagePagingController() }
    func updateUIViewController(_ controller: ChatImagePagingController, context: Context) {
        controller.update(resources: resources, selection: selection, zoom: $zoom,
                          reduceMotion: reduceMotion, onSelect: onSelect)
    }
    static func dismantleUIViewController(_ controller: ChatImagePagingController, coordinator: ()) {
        controller.deactivate()
    }
}

@MainActor final class ChatImagePagingController: UIPageViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private final class Page: UIHostingController<AnyView> {
        let index: Int
        init(index: Int, content: AnyView) { self.index = index; super.init(rootView: content) }
        required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
    private var resources: [ChatImageResource] = []
    private var pages: [Int: Page] = [:]
    private var zoom: Binding<CGFloat> = .constant(1)
    private var lastInput: Int?
    private var pending: Int?
    private var transitioning = false
    private var active = true
    private var reduceMotion = false
    private var onSelect: ((Int) -> Void)?
    private var displayed: Int? { (viewControllers?.first as? Page)?.index }

    init() {
        super.init(transitionStyle: .scroll, navigationOrientation: .horizontal,
                   options: [.interPageSpacing: NSNumber(value: 16)])
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(resources: [ChatImageResource], selection: Int, zoom: Binding<CGFloat>,
                reduceMotion: Bool, onSelect: @escaping (Int) -> Void) {
        guard active, resources.indices.contains(selection) else { return }
        self.resources = resources; self.zoom = zoom
        self.reduceMotion = reduceMotion; self.onSelect = onSelect
        // Removing the data source during a pinch interrupts UIKit's gesture.
        // Keep the controller intact and disable only the outer page scroll.
        if dataSource == nil { dataSource = self }
        configurePaging()
        let changed = lastInput != selection
        lastInput = selection
        for (index, page) in pages where resources.indices.contains(index) { page.rootView = content(at: index) }
        if transitioning {
            if changed { pending = selection }
        } else if changed || displayed == nil {
            show(selection, animated: !reduceMotion && view.window != nil)
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        configurePaging()
    }
    private func configurePaging() {
        let enabled = zoom.wrappedValue <= 1.001 && resources.count > 1
        for case let scroll as UIScrollView in view.subviews {
            if scroll.panGestureRecognizer.maximumNumberOfTouches != 1 { scroll.panGestureRecognizer.maximumNumberOfTouches = 1 }
            if scroll.isScrollEnabled != enabled { scroll.isScrollEnabled = enabled }
        }
    }
    private func content(at index: Int) -> AnyView {
        AnyView(ChatImageSurface(resource: resources[index], zoom: index == lastInput ? zoom : .constant(1),
                                 pagesAtFit: true).id(resources[index].attachment.id))
    }
    private func page(at index: Int) -> Page? {
        guard resources.indices.contains(index) else { return nil }
        if let page = pages[index] { return page }
        let page = Page(index: index, content: content(at: index))
        page.view.backgroundColor = .clear
        pages[index] = page
        return page
    }
    private func show(_ index: Int, animated: Bool) {
        guard active, displayed != index, let page = page(at: index) else { return }
        let previous = displayed
        let animate = animated && view.window != nil && previous.map { abs($0 - index) == 1 } == true
        // UIKit's animated replacement cancels a child pinch when it finishes.
        // Button changes crossfade an immediate replacement; swipes still use
        // the native interactive slide. Gestures stay available during the fade.
        let replace = {
            self.setViewControllers([page], direction: previous.map { index < $0 ? .reverse : .forward } ?? .forward,
                                   animated: false)
        }
        if animate {
            UIView.transition(with: view, duration: 0.18,
                              options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
                              animations: replace)
        } else { replace() }
        settle()
    }
    private func settle() {
        if let pending {
            self.pending = nil
            show(pending, animated: !reduceMotion)
        } else if let lastInput, displayed != lastInput {
            show(lastInput, animated: false)
        }
        if let page = viewControllers?.first as? Page {
            // UIKit can retain an adjacent page after our own cache prunes it.
            pages[page.index] = page
            pages = pages.filter { abs($0.key - page.index) <= 1 }
        }
    }
    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard zoom.wrappedValue <= 1.001, let page = viewController as? Page else { return nil }
        return self.page(at: page.index - 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard zoom.wrappedValue <= 1.001, let page = viewController as? Page else { return nil }
        return self.page(at: page.index + 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        transitioning = true
    }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard active else { return }
        transitioning = false
        if pending == nil, completed, let displayed {
            lastInput = displayed
            onSelect?(displayed)
        }
        settle()
    }
    func deactivate() {
        active = false; onSelect = nil; pending = nil
        dataSource = nil; delegate = nil; pages = [:]; resources = []
    }
}

#endif
