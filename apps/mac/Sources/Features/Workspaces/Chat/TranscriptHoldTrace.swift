// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if DEBUG
import Foundation
import os

/// Where a held row actually was on each frame that reached the screen.
///
/// A page or a slide that lands right on the second frame still looks like a
/// jump if the first frame drew the rows at the old offset. Row reports and
/// scroll callbacks happen during layout, so neither can say what was drawn.
/// A run loop observer after Core Animation's commit can: what the held row
/// last reported at that point is what the frame showed.
///
/// Debug builds only. Read it with:
/// `log stream --predicate 'subsystem == "ai.tokenstat.tokenstat" && category == "hold"' --level debug`
/// Main thread only, like `TranscriptWindow`, which is its only caller.
@MainActor
final class TranscriptHoldTrace {
    static let shared = TranscriptHoldTrace()

    private nonisolated static let log = Logger(subsystem: "ai.tokenstat.tokenstat", category: "hold")
    private var observer: CFRunLoopObserver?
    private var label = ""
    private var drift: CGFloat?
    private var frames: [String] = []
    private var started = Date.distantPast

    nonisolated static func note(_ message: String) {
        log.notice("\(message, privacy: .public)")
    }

    func armed(_ label: String, id: String, top: CGFloat, height: CGFloat) {
        finish()
        self.label = label
        drift = 0
        frames = []
        started = Date()
        let geometry = String(format: "top=%.0f height=%.0f", top, height)
        Self.log.notice("hold \(label, privacy: .public) id=\(id.prefix(24), privacy: .public) \(geometry, privacy: .public)")
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, Int.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// How far the held row is from where it has to be, nil when unbuilt.
    func reported(drift: CGFloat?) {
        guard observer != nil else { return }
        self.drift = drift
    }

    func corrected(_ how: String) {
        guard observer != nil else { return }
        frames.append(how)
    }

    func released() {
        guard observer != nil else { return }
        sample()
        corrected("released")
        finish()
    }

    /// Each distinct value once, with how many drawn turns it held for.
    private func sample() {
        let value = drift.map { String(format: "%.0f", $0) } ?? "gone"
        if let last = frames.last, last.hasPrefix(value + "x"),
           let count = Int(last.dropFirst(value.count + 1)) {
            frames[frames.count - 1] = "\(value)x\(count + 1)"
        } else {
            frames.append("\(value)x1")
        }
        if Date().timeIntervalSince(started) > 3.2 || frames.count > 40 { finish() }
    }

    func finish() {
        guard let observer else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = nil
        Self.log.notice("frames \(self.label, privacy: .public): \(self.frames.joined(separator: " "), privacy: .public)")
    }
}
#endif
