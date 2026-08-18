// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI
import UIKit

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
        /// Walk parents first, then the window's whole controller tree.
        ///
        /// SwiftUI does not promise where it hosts a background view, so the
        /// parent chain alone is not enough to find the bar.
        func findTabBarController() -> UITabBarController? {
            if let direct = tabBarController { return direct }
            var node: UIViewController? = self
            while let current = node {
                if let tabs = current as? UITabBarController { return tabs }
                node = current.parent
            }
            guard let root = view.window?.rootViewController else { return nil }
            return Self.search(root)
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
            guard let tabs = findTabBarController() else { return }
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
}

#endif
