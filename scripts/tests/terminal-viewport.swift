// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Runs on an iOS simulator with terminal-viewport.py, using the real SwiftTerm view.
import UIKit
import SwiftTerm

@main final class ViewportCheck: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        DispatchQueue.main.async { self.check(in: controller.view) }
        return true
    }

    func check(in parent: UIView) {
        var checks = [String]()
        func require(_ condition: Bool, _ name: String) {
            checks.append((condition ? "PASS " : "FAIL ") + name)
        }
        let view = ClientTerminalInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.getTerminal().changeHistorySize(4_000)
        parent.addSubview(view)
        view.layoutIfNeeded()
        view.feedOutput((0..<5_000).map { "history \($0)\r\n" }.joined())
        func bottom() -> CGFloat { max(0, view.contentSize.height - view.bounds.height) }
        require(bottom() > 40_000, "long history is present")
        require(abs(view.contentOffset.y - bottom()) < 1, "output follows latest")
        view.contentOffset = .zero
        require(abs(view.contentOffset.y - bottom()) < 1, "caret property cannot jump following viewport to history")
        view.setContentOffset(.zero, animated: true)
        require(abs(view.contentOffset.y - bottom()) < 1, "animated caret scroll cannot jump following viewport")
        view.scrollMode = true
        view.scrollViewWillBeginDragging(view)
        view.setContentOffset(CGPoint(x: 0, y: bottom() - 300), animated: false)
        view.scrollViewDidScroll(view)
        view.scrollViewDidEndDragging(view, willDecelerate: false)
        let held = view.contentOffset.y
        require(abs(held - (bottom() - 300)) < 1, "manual drag can read history")
        view.contentOffset = .zero
        require(abs(view.contentOffset.y - held) < 1, "caret property preserves held history")
        view.setContentOffset(.zero, animated: false)
        require(abs(view.contentOffset.y - held) < 1, "caret method preserves held history")
        for _ in 0..<40 {
            view.insertText("a")
            view.feedOutput("\u{1b}[2K\rtyping redraw")
        }
        require(abs(view.contentOffset.y - held) < 1, "typing and cursor-only redraw preserve held history")
        view.frame.size.height = 340
        view.setNeedsLayout(); view.layoutIfNeeded()
        require(abs(view.contentOffset.y - held) < 1, "keyboard resize preserves held history")
        view.followLatest()
        for _ in 0..<40 {
            view.insertText("b")
            view.setContentOffset(.zero, animated: false)
            view.feedOutput("\u{1b}[2K\rtyping redraw")
        }
        require(abs(view.contentOffset.y - bottom()) < 1, "typing follows latest without jumps after keyboard resize")
        view.scrollMode = false
        require(abs(view.contentOffset.y - bottom()) < 1, "scroll mode off follows latest")
        let text = checks.joined(separator: "\n") + "\n"
        print(text)
        try! text.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("viewport-results.txt"), atomically: true, encoding: .utf8)
    }
}
