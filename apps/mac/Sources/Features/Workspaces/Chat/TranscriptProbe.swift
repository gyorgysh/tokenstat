// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build.

#if DEBUG
import Foundation
import os

/// Why a transcript stopped, written down while it is stopped.
///
/// Hang reports put the main thread inside SwiftUI's lazy layout. A stackshot
/// names `LazyStack.measureEstimates` and nothing about what the transcript
/// was holding. This logs that: how many rows were loaded, how many the
/// ForEach actually built, whether the window had been trimmed, what follow
/// believed, and how long ago something asked it to scroll.
///
/// It used to wrap every row in a `Layout` to time `sizeThatFits`. That
/// wrapper was itself the hang: a debug build spent thirty seconds in
/// `ProbeTimedRow.sizeThatFits` while the lazy stack measured every row
/// through an extra layout node with no cache. Counters and a run-loop
/// observer do not change what the stack measures.
///
/// Read it back with:
/// `log stream --predicate 'subsystem == "ai.tokenstat.tokenstat"' --level debug`
@MainActor
final class TranscriptProbe {
    static let shared = TranscriptProbe()

    private let log = Logger(subsystem: "ai.tokenstat.tokenstat", category: "transcript")
    private var observer: CFRunLoopObserver?
    private var turnStart: CFAbsoluteTime = 0
    private var metricsThisTurn = 0

    /// What the transcript is holding. Written on change, not per frame.
    var rows = 0
    /// Rows actually in the ForEach this turn, after the slice.
    var built = 0
    var pinned = true
    var scrolling = false

    /// The last programmatic scroll, and when. A hang that always follows one
    /// is a different bug from a hang that never does.
    private var lastScroll = "none"
    private var lastScrollAt: CFAbsoluteTime = 0

    /// A turn slower than this is worth a line. Well above a dropped frame,
    /// well below anything a person would sit through.
    private static let slowTurn: CFAbsoluteTime = 0.25

    func install() {
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue
        let created = CFRunLoopObserverCreateWithHandler(
            nil, activities, true, 0
        ) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.turn(activity) }
        }
        guard let created else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
        observer = created
    }

    func noteScroll(_ what: String) {
        lastScroll = what
        lastScrollAt = CFAbsoluteTimeGetCurrent()
    }

    /// One scroll-geometry callback. Counted per turn, because a turn holding
    /// dozens of them is a feedback loop and a turn holding one is not.
    func noteMetrics() {
        metricsThisTurn += 1
    }

    private func turn(_ activity: CFRunLoopActivity) {
        if activity.contains(.afterWaiting) {
            turnStart = CFAbsoluteTimeGetCurrent()
            metricsThisTurn = 0
            return
        }
        guard turnStart > 0 else { return }
        let spent = CFAbsoluteTimeGetCurrent() - turnStart
        turnStart = 0
        guard spent >= Self.slowTurn else { return }
        let sinceScroll = lastScrollAt > 0
            ? Int((CFAbsoluteTimeGetCurrent() - lastScrollAt) * 1000)
            : -1
        log.warning(
            """
            slow turn \(Int(spent * 1000), privacy: .public)ms \
            rows=\(self.rows, privacy: .public) \
            built=\(self.built, privacy: .public) \
            pinned=\(self.pinned, privacy: .public) \
            scrolling=\(self.scrolling, privacy: .public) \
            metrics=\(self.metricsThisTurn, privacy: .public) \
            lastScroll=\(self.lastScroll, privacy: .public) \
            +\(sinceScroll, privacy: .public)ms
            """
        )
    }
}
#endif
