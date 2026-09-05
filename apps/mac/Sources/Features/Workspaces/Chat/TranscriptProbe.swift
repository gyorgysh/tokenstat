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
/// Four hang reports in a row put the whole main thread inside SwiftUI's lazy
/// layout with nothing of ours anywhere on the stack. That says where the
/// time goes and nothing about what the transcript was holding at the time,
/// which is the one number every theory about this bug has turned on and none
/// of them could check. A stackshot cannot report it. This can.
///
/// A run loop turn that takes longer than a person would call instant gets a
/// line naming how many rows the transcript held, whether the window had been
/// trimmed, what the follow state believed, and how long ago something asked
/// it to scroll. Counters and flags only: no conversation text, no paths, no
/// identifiers.
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
    var pinned = true
    var scrolling = false

    /// The last programmatic scroll, and when. A hang that always follows one
    /// is a different bug from a hang that never does.
    private var lastScroll = "none"
    private var lastScrollAt: CFAbsoluteTime = 0

    /// Nanoseconds spent measuring each kind of row this turn, and how many
    /// times each was measured. A turn's cost divided by its rows says the
    /// cost is per row; this says which row.
    private var layoutNanos: [String: UInt64] = [:]
    private var layoutCounts: [String: Int] = [:]

    func addLayout(_ kind: String, _ nanos: UInt64) {
        layoutNanos[kind, default: 0] += nanos
        layoutCounts[kind, default: 0] += 1
    }

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
            layoutNanos.removeAll(keepingCapacity: true)
            layoutCounts.removeAll(keepingCapacity: true)
            return
        }
        guard turnStart > 0 else { return }
        let spent = CFAbsoluteTimeGetCurrent() - turnStart
        turnStart = 0
        guard spent >= Self.slowTurn else { return }
        let worst = layoutNanos
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { "\($0.key)=\($0.value / 1_000_000)ms/\(self.layoutCounts[$0.key] ?? 0)" }
            .joined(separator: " ")
        let sinceScroll = lastScrollAt > 0
            ? Int((CFAbsoluteTimeGetCurrent() - lastScrollAt) * 1000)
            : -1
        log.warning(
            """
            slow turn \(Int(spent * 1000), privacy: .public)ms \
            rows=\(self.rows, privacy: .public) \
            pinned=\(self.pinned, privacy: .public) \
            scrolling=\(self.scrolling, privacy: .public) \
            metrics=\(self.metricsThisTurn, privacy: .public) \
            lastScroll=\(self.lastScroll, privacy: .public) \
            +\(sinceScroll, privacy: .public)ms \
            \(worst, privacy: .public)
            """
        )
    }
}

/// Time one row's own measuring pass and attribute it to the kind of row.
///
/// A `Layout` rather than a modifier, because the cost that matters is not
/// building the row's body, which happens once per identity, but measuring
/// it, which happens on every pass the lazy stack makes over the list.
private struct ProbeTimedRow: Layout {
    let kind: String

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let start = DispatchTime.now().uptimeNanoseconds
        let size = subviews.first?.sizeThatFits(proposal) ?? .zero
        let spent = DispatchTime.now().uptimeNanoseconds - start
        MainActor.assumeIsolated { TranscriptProbe.shared.addLayout(kind, spent) }
        return size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(at: bounds.origin, proposal: proposal)
    }
}
#endif

import SwiftUI

extension View {
    /// Measure this row and record it under `kind`. Nothing outside a debug
    /// build, where it is not even a wrapper.
    func probeRow(_ kind: String) -> some View {
        #if DEBUG
        return ProbeTimedRow(kind: kind) { self }
        #else
        return self
        #endif
    }
}

#if DEBUG
extension ChatDisplayItem {
    /// What sort of row this is, for the probe. One word, no content.
    var probeKind: String {
        switch kind {
        case .user: "user"
        case .assistant: "assistant"
        case .turnSeparator: "sep"
        case .handoff: "handoff"
        case .thinking: "thinking"
        case .tool: "tool"
        case .edit: "edit"
        case .attachment: "attach"
        case .approval: "approval"
        case .usage: "usage"
        case .failed: "failed"
        }
    }
}
#endif
