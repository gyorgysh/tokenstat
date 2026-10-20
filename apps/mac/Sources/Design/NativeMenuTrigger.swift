// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
#if os(macOS)
import AppKit

/// One entry in a menu popped by `NativeMenuTrigger`.
struct NativeMenuItem {
    enum Kind {
        case action
        case separator
        case heading
    }

    let kind: Kind
    let title: String
    let isEnabled: Bool
    let isSelected: Bool
    let symbol: String?
    let destructive: Bool
    let action: () -> Void

    init(_ title: String, icon: ActionIcon? = nil, isEnabled: Bool = true, isSelected: Bool = false,
         destructive: Bool = false, action: @escaping () -> Void) {
        self.kind = .action
        self.title = title
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.symbol = icon?.symbol
        self.destructive = destructive
        self.action = action
    }

    private init(kind: Kind = .separator, title: String = "") {
        self.kind = kind
        self.title = title
        isEnabled = false
        isSelected = false
        symbol = nil
        destructive = false
        action = {}
    }

    static let separator = NativeMenuItem()
    static func heading(_ title: String) -> NativeMenuItem { NativeMenuItem(kind: .heading, title: title) }
}

/// Pops a real `NSMenu` under whatever it is laid over.
///
/// For rows that must look exactly as designed. SwiftUI's `Menu` rebuilds a
/// custom label rather than hosting it (see `RootView.railAccount`), so a row
/// with a picture, a badge and a trailing chevron in it cannot survive being
/// that label. Here the row is drawn as an ordinary view and this sits on top
/// of it as the control: the menu is the system's own, with its keyboard
/// handling and its placement, and the row is untouched.
struct NativeMenuTrigger: NSViewRepresentable {
    /// Read at press time, not at build time, so item titles and enablement
    /// describe the moment the menu opens.
    var items: () -> [NativeMenuItem]
    var accessibilityLabel: String? = nil
    var rightClickOnly = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.items = items
        let view = TriggerView()
        view.coordinator = context.coordinator
        view.rightClickOnly = rightClickOnly
        if let accessibilityLabel {
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.popUpButton)
            view.setAccessibilityLabel(accessibilityLabel)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.items = items
        (nsView as? TriggerView)?.coordinator = context.coordinator
        (nsView as? TriggerView)?.rightClickOnly = rightClickOnly
        if let accessibilityLabel {
            nsView.setAccessibilityLabel(accessibilityLabel)
        }
    }

    /// Builds the menu and runs the chosen item.
    ///
    /// The target lives here rather than on the view because `NSMenuItem.target`
    /// is a **weak** reference: an owner AppKit does not retain can be gone by
    /// the time the menu closes, and then choosing an item does nothing at all.
    /// SwiftUI holds the coordinator for as long as the representable exists,
    /// which is exactly as long as the menu can be opened.
    final class Coordinator: NSObject {
        var items: (() -> [NativeMenuItem])?
        /// The set the open menu was built from. Items dispatch by index into
        /// this, so a closure never has to survive inside an AppKit object.
        private var current: [NativeMenuItem] = []

        func menu() -> NSMenu? {
            current = items?() ?? []
            guard !current.isEmpty else { return nil }

            let menu = NSMenu()
            // Our own enablement. Left on, AppKit asks a validator this app
            // does not have and greys every item out.
            menu.autoenablesItems = false
            for (index, entry) in current.enumerated() {
                switch entry.kind {
                case .separator:
                    menu.addItem(.separator())
                case .heading:
                    if #available(macOS 14.0, *) {
                        menu.addItem(NSMenuItem.sectionHeader(title: entry.title))
                    } else {
                        let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                        item.isEnabled = false; menu.addItem(item)
                    }
                case .action:
                    let item = NSMenuItem(
                        title: entry.title,
                        action: #selector(run(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.tag = index
                    item.isEnabled = entry.isEnabled
                    item.state = entry.isSelected ? .on : .off
                    if let symbol = entry.symbol {
                        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: entry.title)
                        item.image?.size = NSSize(width: 16, height: 16)
                        // macOS 27 hides menu images automatically. Older SDKs
                        // keep their existing image behavior.
                        #if compiler(>=6.4)
                        if #available(macOS 27.0, *) {
                            item.preferredImageVisibility = .visible
                        }
                        #endif
                    }
                    menu.addItem(item)
                }
            }
            return menu
        }

        @objc private func run(_ sender: NSMenuItem) {
            guard current.indices.contains(sender.tag) else { return }
            current[sender.tag].action()
        }
    }

    final class TriggerView: NSView {
        weak var coordinator: Coordinator?
        var rightClickOnly = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            if rightClickOnly && !SidebarContextClick.accepts(NSApp.currentEvent) { return nil }
            return super.hitTest(point)
        }

        /// Menus drop from the bottom of the row, which is where a pop-up
        /// button puts them, and flipped coordinates make that `maxY`.
        override var isFlipped: Bool { true }

        /// Open on the click that also brings the window forward. Without
        /// this, pressing the row in a background window only activates it and
        /// the press has to be repeated.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
            else { openMenu() }
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = coordinator?.menu() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        override func accessibilityPerformPress() -> Bool {
            openMenu()
            return true
        }

        private func openMenu() {
            guard let menu = coordinator?.menu() else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
        }
    }
}
#endif
