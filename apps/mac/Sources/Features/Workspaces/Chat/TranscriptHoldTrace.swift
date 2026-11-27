// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if DEBUG
import Foundation
import os

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
