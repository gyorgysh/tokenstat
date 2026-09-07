// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI
import UIKit

/// Reach the `UITabBarController` SwiftUI is hosting.
///
/// A zero-size background view is not a child of the tabs in any promised
/// way, so the parent chain is tried first and the window's controller tree
/// is the fallback. Nil means this is not a tab layout (the iPad sidebar)
/// or a future iOS hosts tabs differently. Callers fail soft.
enum ClientTabBarHost {
    static func controller(from start: UIViewController) -> UITabBarController? {
        if let direct = start.tabBarController { return direct }
        var node: UIViewController? = start
        while let current = node {
            if let tabs = current as? UITabBarController { return tabs }
            node = current.parent
        }
        guard let root = start.view.window?.rootViewController else { return nil }
        return search(root)
    }

    /// Hide every supported tab bar, including the iOS 26 floating one.
    ///
    /// `.toolbar(.hidden, for: .tabBar)` on iOS 26 shrinks that bar into a
    /// pill. Tapping the pill opens the full tab menu. This is the API that
    /// actually takes it off the screen.
    static func setHidden(_ hidden: Bool, from start: UIViewController, animated: Bool) {
        guard let tabs = controller(from: start) else { return }
        if #available(iOS 18, *) {
            if tabs.isTabBarHidden != hidden {
                tabs.setTabBarHidden(hidden, animated: animated)
            }
        }
        // iOS 26 can report the bar hidden while the minimised pill is still
        // on screen and tappable. Drive the view itself as well.
        if tabs.tabBar.isHidden != hidden {
            tabs.tabBar.isHidden = hidden
        }
        let alpha: CGFloat = hidden ? 0 : 1
        if tabs.tabBar.alpha != alpha {
            tabs.tabBar.alpha = alpha
        }
        if tabs.tabBar.isUserInteractionEnabled == hidden {
            tabs.tabBar.isUserInteractionEnabled = !hidden
        }
        // The iOS 26 floating pill lives on a container around the bar, not
        // on `UITabBar` itself. Only touch a container whose type is about
        // the bar. Hiding `tabs.view` would take the whole screen with it.
        if let platter = tabs.tabBar.superview, platter !== tabs.view, isTabBarChrome(platter) {
            if platter.isHidden != hidden {
                platter.isHidden = hidden
            }
            if platter.alpha != alpha {
                platter.alpha = alpha
            }
            if platter.isUserInteractionEnabled == hidden {
                platter.isUserInteractionEnabled = !hidden
            }
        }
    }

    fileprivate static func isTabBarChrome(_ view: UIView) -> Bool {
        let name = String(describing: type(of: view))
        return name.contains("TabBar") || name.contains("TabContainer") || name.contains("Platter")
    }

    private static func search(_ controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let found = search(child) { return found }
        }
        if let presented = controller.presentedViewController {
            return search(presented)
        }
        return nil
    }
}

/// Hide the system tab bar for real, not the iOS 26 minimise-to-pill.
///
/// SwiftUI's `.toolbar(.hidden, for: .tabBar)` is still applied so layout
/// drops the reserved inset. The representable is what removes the pill
/// that hide-as-minimise would leave behind, tappable into the full menu.
struct ClientHiddenTabBar: UIViewControllerRepresentable {
    var hidden: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        let prober = Prober()
        prober.hidden = hidden
        return prober
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let prober = controller as? Prober else { return }
        prober.hidden = hidden
        prober.apply(animated: true)
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: ()) {
        (controller as? Prober)?.restore()
    }

    /// A zero-size controller whose only job is to reach the tab bar.
    final class Prober: UIViewController {
        var hidden = false
        /// Restore only what this instance hid, so tearing down a visible
        /// screen cannot unhide a later one that still wants it gone.
        private var hidByUs = false

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply(animated: false)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply(animated: false)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            // SwiftUI's toolbar hide can put the bar back as a pill after
            // we have already removed it. Re-assert while we still want it
            // gone. Cheap when the state already matches.
            apply(animated: false)
        }

        func apply(animated: Bool) {
            guard let tabs = ClientTabBarHost.controller(from: self) else { return }
            let reportedHidden: Bool
            if #available(iOS 18, *) {
                reportedHidden = tabs.isTabBarHidden
            } else {
                reportedHidden = tabs.tabBar.isHidden
            }
            let barHidden = tabs.tabBar.isHidden && tabs.tabBar.alpha == 0
            let platterHidden: Bool
            if let platter = tabs.tabBar.superview, platter !== tabs.view,
               ClientTabBarHost.isTabBarChrome(platter)
            {
                platterHidden = platter.isHidden && platter.alpha == 0
            } else {
                platterHidden = true
            }
            let viewHidden = barHidden && platterHidden
            if reportedHidden == hidden && viewHidden == hidden {
                if hidden { hidByUs = true }
                return
            }
            ClientTabBarHost.setHidden(hidden, from: self, animated: animated)
            hidByUs = hidden
        }

        func restore() {
            guard hidByUs else { return }
            hidden = false
            hidByUs = false
            ClientTabBarHost.setHidden(false, from: self, animated: false)
        }
    }
}

/// Give the iPad the phone's tab bar.
///
/// iPadOS draws a `TabView` as a pill in the top bar: no icons, no minimise on
/// scroll, and nowhere near a thumb. The floating bar the phone gets is not a
/// separate control, it is the same one drawn for a compact width, so the way
/// to have it is to tell the tab bar controller it is compact.
///
/// **The override stops at the bar.** Compact cascades to children, and a
/// compact child is a phone: the folder split would collapse to a stack and the
/// iPad would become a large phone with a nice tab bar. Each tab's own
/// controller is put back to regular, which is the whole trick and the reason
/// this is a view rather than one modifier.
///
/// Fails soft. If a future iOS hosts tabs differently, `tabBarController` is
/// nil, nothing is overridden, and the iPad keeps the top bar it has today.
struct CompactTabBarOnPad: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        Prober()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        (controller as? Prober)?.apply()
    }

    /// A zero-size controller whose only job is to reach its ancestors.
    final class Prober: UIViewController {
        /// Set the override only when it is not already what we want.
        ///
        /// Reading `traitOverrides.horizontalSizeClass` when nothing has been
        /// overridden **throws**, so the presence check is not defensive
        /// tidiness, it is the difference between working and a crash on the
        /// first appearance.
        private static func override(
            _ controller: UIViewController,
            with value: UIUserInterfaceSizeClass
        ) {
            if controller.traitOverrides.contains(UITraitHorizontalSizeClass.self),
               controller.traitOverrides.horizontalSizeClass == value
            {
                return
            }
            controller.traitOverrides.horizontalSizeClass = value
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Tabs are built lazily: a tab visited later gets its navigation
            // controller after the first pass, so the walk runs again on every
            // appearance rather than once at install.
            apply()
        }

        func apply() {
            guard UIDevice.current.userInterfaceIdiom == .pad else { return }
            guard #available(iOS 18, *) else { return }
            guard let tabs = ClientTabBarHost.controller(from: self) else { return }
            Self.override(tabs, with: .compact)
            // Put every tab's content back to regular. Without this the split
            // views inside collapse and the iPad reads as a phone.
            for child in tabs.viewControllers ?? [] {
                Self.override(child, with: .regular)
            }
        }
    }
}

extension View {
    /// Draw the tab bar the way the phone draws it, on iPad.
    ///
    /// A no-op on iPhone, where it is already true, and on anything that does
    /// not host tabs in a `UITabBarController`.
    func clientCompactTabBarOnPad() -> some View {
        background(CompactTabBarOnPad().frame(width: 0, height: 0).allowsHitTesting(false))
    }

    /// Take the tab bar off the screen, including the iOS 26 floating pill.
    ///
    /// Use this on a pushed conversation, not on the folder list. The list
    /// keeps the bar the other sections keep. Back is still how you leave.
    func clientTabBarHidden(_ hidden: Bool) -> some View {
        toolbar(hidden ? .hidden : .automatic, for: .tabBar)
            .background(
                ClientHiddenTabBar(hidden: hidden)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            )
    }
}

#endif
