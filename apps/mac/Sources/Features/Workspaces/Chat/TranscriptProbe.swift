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
    private var recording = false
    private var recordedTurns: [Double] = []
    private var recordedOpens: [[String: Any]] = []
    private var recordingStarted: TimeInterval = 0
    private var resizeCount = 0

    /// Opt-in, bounded diagnostics. No conversation identifiers or text leave
    /// the model. Run-loop work is responsiveness evidence, not rendered FPS.
    func startRecording() {
        install()
        recordedTurns.removeAll(keepingCapacity: true)
        recordedOpens.removeAll(keepingCapacity: true)
        recordingStarted = ProcessInfo.processInfo.systemUptime
        resizeCount = 0
        recording = true
    }

    func noteResize() { if recording { resizeCount += 1 } }

    func noteOpen(milliseconds: Double, preview: Bool, phase: String) {
        guard recording, recordedOpens.count < 200 else { return }
        recordedOpens.append(["milliseconds": milliseconds, "preview": preview, "phase": phase])
    }

    func finishRecording() {
        guard recording else { return }
        let stopped = ProcessInfo.processInfo.systemUptime
        if recording, turnStart > 0, recordedTurns.count < 60_000 {
            recordedTurns.append(max(0, stopped - max(turnStart, recordingStarted)) * 1000)
        }
        recording = false
        let sorted = recordedTurns.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        let report: [String: Any] = [
            "measurement": "Main run-loop work duration; not rendered frame latency",
            "turns": sorted.count, "p50_ms": percentile(0.5),
            "elapsed_ms": (stopped - recordingStarted) * 1000,
            "total_work_ms": sorted.reduce(0, +), "resize_requests": resizeCount,
            "p95_ms": percentile(0.95), "p99_ms": percentile(0.99),
            "max_ms": sorted.last ?? 0,
            "over_16_7_ms": sorted.filter { $0 > 16.7 }.count,
            "over_33_3_ms": sorted.filter { $0 > 33.3 }.count,
            "over_100_ms": sorted.filter { $0 > 100 }.count,
            "chat_opens": recordedOpens,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-ui-performance.json"), options: .atomic)
        }
    }

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
        lastScrollAt = ProcessInfo.processInfo.systemUptime
    }

    /// One scroll-geometry callback. Counted per turn, because a turn holding
    /// dozens of them is a feedback loop and a turn holding one is not.
    func noteMetrics() {
        metricsThisTurn += 1
    }

    private func turn(_ activity: CFRunLoopActivity) {
        if activity.contains(.afterWaiting) {
            turnStart = ProcessInfo.processInfo.systemUptime
            metricsThisTurn = 0
            return
        }
        guard turnStart > 0 else { return }
        let ended = ProcessInfo.processInfo.systemUptime
        let spent = ended - turnStart
        if recording, recordedTurns.count < 60_000 {
            recordedTurns.append(max(0, ended - max(turnStart, recordingStarted)) * 1000)
        }
        turnStart = 0
        guard spent >= Self.slowTurn else { return }
        let sinceScroll = lastScrollAt > 0
            ? Int((ProcessInfo.processInfo.systemUptime - lastScrollAt) * 1000)
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
