// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Runs on an iOS simulator with terminal-viewport.py, using the real SwiftTerm view.
import UIKit
import SwiftTerm

@main final class ViewportCheck: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { true }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = ViewportScene.self
        return configuration
    }

    func check(in parent: UIView) async {
        let frames = ViewportFrames()
        TerminalView.onFramePresented = { frames.presented() }
        func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }
        var checks = [String]()
        func require(_ condition: Bool, _ name: String) {
            checks.append((condition ? "PASS " : "FAIL ") + name)
        }
        let view = ClientTerminalInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        var reading = false
        view.onReadingChanged = { reading = $0 }
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.changeScrollback(4_000)
        parent.addSubview(view)
        view.layoutIfNeeded()
        let started = Date()
        view.feedOutput((0..<5_000).map { "history \($0)\r\n" }.joined())
        await settle()
        print("5,000 history rows fed in \(Date().timeIntervalSince(started)) seconds")
        require(view.isUsingMetalRenderer, "Metal renderer initialized")
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
        await settle()
        view.frame.size.height = 340
        view.setNeedsLayout(); view.layoutIfNeeded()
        await settle()
        require(abs(view.contentOffset.y - held) < 1, "keyboard resize preserves held history")
        let heldBeforeTrim = view.contentOffset.y
        let cellHeight = view.getOptimalFrameSize().height / CGFloat(view.terminalDimensions.rows)
        view.feedOutput((0..<10).map { "new history \($0)\r\n" }.joined())
        await settle()
        require(abs(view.contentOffset.y - max(0, heldBeforeTrim - 10 * cellHeight)) < 1,
                "held content stays fixed as capped history drops rows")
        view.followLatest()
        for _ in 0..<40 {
            view.insertText("b")
            view.setContentOffset(.zero, animated: false)
            view.feedOutput("\u{1b}[2K\rtyping redraw")
        }
        require(abs(view.contentOffset.y - bottom()) < 1, "typing follows latest without jumps after keyboard resize")
        await settle()
        view.scrollMode = false
        require(abs(view.contentOffset.y - bottom()) < 1, "scroll mode off follows latest")
        view.feedOutput("\u{1b}[?1049halternate screen")
        await settle()
        require(view.terminalInputStateSnapshot()?.isAlternateBuffer == true, "alternate buffer activates")
        view.feedOutput("\u{1b}[?1049l")
        await settle()
        require(view.terminalInputStateSnapshot()?.isAlternateBuffer == false, "normal buffer returns")
        require(view.visibleRowsText(0..<view.terminalDimensions.rows).joined().contains("typing redraw"), "normal output survives alternate buffer")
        view.feedOutput("\u{1b}c")
        await settle()
        view.feedOutput((0..<100).map { "short history \($0)\r\n" }.joined())
        await settle()
        view.scrollMode = true
        view.scrollViewWillBeginDragging(view)
        view.setContentOffset(CGPoint(x: 0, y: bottom() - 100), animated: false)
        view.scrollViewDidScroll(view)
        view.scrollViewDidEndDragging(view, willDecelerate: false)
        let wasReading = reading
        view.feedOutput("\u{1b}c")
        await settle()
        require(wasReading && !reading && abs(view.contentOffset.y - bottom()) < 1,
                "terminal reset releases held short history")
        let longURL = "https://example.com/" + String(repeating: "abcdefghij", count: 12)
        view.feedOutput("\r\n" + longURL + "\r\n")
        await settle()
        require(view.visibleTextSnapshot().contains(longURL), "soft-wrapped links remain contiguous in copied screen text")
        require(frames.value > 0, "Metal frame presented on iOS")
        let text = checks.joined(separator: "\n") + "\n"
        print(text)
        try! text.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("viewport-results.txt"), atomically: true, encoding: .utf8)
    }
}

final class ViewportScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        Task { await (UIApplication.shared.delegate as! ViewportCheck).check(in: controller.view) }
    }
}

private final class ViewportFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func presented() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
