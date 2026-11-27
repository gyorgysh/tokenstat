// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

enum TranscriptFollow {
    static let spaceName = "chat-scroll"
    static let contentSpaceName = "chat-content"
    static let threshold: CGFloat = 56
    static let seatHeight: CGFloat = 34
    static let bottomID = "chat-bottom"
    static let structureDuration: Double = 0.14

    static func structureToken(
        items: [ChatDisplayItem],
        busy: Bool,
        runningTool: Bool,
        settle: PersonaMood?
    ) -> String {
        let last = items.last?.id ?? ""
        let mood = settle.map { String(describing: $0) } ?? (busy ? (runningTool ? "working" : "thinking") : "idle")
        return "\(items.count)-\(last)-\(mood)"
    }

    static func liveMood(
        items: [ChatDisplayItem],
        busy: Bool,
        runningTool: Bool,
        waiting: Bool,
        settle: PersonaMood?
    ) -> PersonaMood? {
        if let settle { return settle }
        if waiting { return .waiting }
        guard busy else { return nil }
        if runningTool { return .working }
        if case let .assistant(text, _) = items.last?.kind, !text.isEmpty { return .speaking }
        return .thinking
    }

    static func liveStep(_ items: [ChatDisplayItem]) -> String? {
        for item in items.reversed() {
            switch item.kind {
            case let .tool(state) where state.running:
                return SeatStep.phrase(verb: state.verb, target: state.target)
            case let .edit(state) where state.running:
                return SeatStep.phrase(verb: L10n.text("common.edit"), target: state.path)
            case let .group(group) where group.running && group.liveVerb != nil:
                return SeatStep.phrase(verb: group.liveVerb, target: group.liveTarget)
            default:
                continue
            }
        }
        return nil
    }

    /// The one row allowed an animated spinner, newest first.
    ///
    /// A running `ProgressView` on macOS is an `NSProgressIndicator` behind a
    /// platform view host, and an animating one invalidates layout on every
    /// frame. A transcript with one of those measures the slice once per
    /// frame, which the lazy stack can afford. A transcript with forty never
    /// finishes a transaction: a hang report caught the app spending ten
    /// minutes inside a single `flushTransactions`, in lazy stack placement,
    /// with the process at six gigabytes. That is what a chat looked like
    /// when the host left every Bash call marked running.
    ///
    /// So the spinner is a property of the transcript rather than of the row:
    /// whatever the timeline claims is running, one row turns. The rest keep
    /// their accent border and their "Running" label, which is what says so
    /// in words anyway.
    static func spinningRow(_ items: [ChatDisplayItem]) -> String? {
        items.last { item in
            switch item.kind {
            case let .tool(state): return state.running
            case let .edit(state): return state.running
            case let .group(group): return group.running && !group.open
            default: return false
            }
        }?.id
    }

    static func streamExtent(_ items: [ChatDisplayItem]) -> Int {
        guard let last = items.last else { return 0 }
        switch last.kind {
        case let .assistant(text, _), let .thinking(text):
            return text.count
        case let .tool(state):
            return state.detail?.count ?? 0
        default:
            return 0
        }
    }
}

/// How many rows a transcript ForEach may hold.
///
/// `LazyVStack.measureEstimates` walks every item it is given, and measuring
/// a markdown row is the hang: a debug build spent thirty seconds in that
/// walk with `ProbeTimedRow.sizeThatFits` on the stack. Growing the list
/// (the old "show earlier" control added 300 rows per tap) is how a
/// conversation of any size became a stopped application. The slice stays
/// this wide. Older built rows are reached by sliding it, not by widening it.
enum TranscriptSlice {
    static let length = 1500
    static let step = 600

    static func clampOffset(_ offset: Int, count: Int) -> Int {
        guard count > length else { return 0 }
        return min(max(0, offset), count - length)
    }

    static func range(count: Int, olderOffset: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        guard count > length else { return 0..<count }
        let end = count - clampOffset(olderOffset, count: count)
        return (end - length)..<end
    }

    static func items(_ items: [ChatDisplayItem], olderOffset: Int) -> [ChatDisplayItem] {
        let span = range(count: items.count, olderOffset: olderOffset)
        guard !span.isEmpty else { return [] }
        return Array(items[span])
    }

    /// How many of the newest built rows sit outside the lazy stack.
    ///
    /// A lazy stack estimates rows it has not measured, and the end the view
    /// pins to sits below the stack, so the end is only as true as those
    /// estimates. A few short rows and one reply tens of thousands of points
    /// tall put it in the middle of that reply, or past every row the stack
    /// built, which is a blank transcript. The newest rows are measured
    /// exactly instead: they are what a following reader is looking at.
    ///
    /// Capped at enough rows to cover the window, measured by `tailHeightFloor`.
    static let measuredTail = 40
    static let measuredMinimum = 2
    static let measuredCover = 2400.0
    /// A slice this short is measured whole while nothing streams. A few
    /// rows of long replies are tens of thousands of points the lazy stack
    /// would only estimate, and the reader's first scroll is what makes it
    /// measure them: the content above the viewport grows or shrinks by a
    /// screen and the text under their hand jumps. Measuring a handful of
    /// settled rows once costs less than that. A streaming turn keeps the
    /// usual tail: switching rebuilds the rows it moves, and a reader
    /// following a reply is not scrolling through estimates.
    static let measuredWhole = 64
    /// A longer slice is measured whole too when its rows are small. A chat
    /// of one-line tool steps between replies and pictures has many rows and
    /// little to measure, and the lazy stack estimated those steps far too
    /// tall: the reader's first scroll up built them and the content above
    /// shrank by hundreds of points at a time. What counts is how much there
    /// is to lay out, not how many rows hold it.
    static let measuredWholeMost = 256
    static let measuredWholeHeight = 40_000.0

    static func measuresWhole(_ rows: [ChatDisplayItem]) -> Bool {
        if rows.count <= measuredWhole { return true }
        guard rows.count <= measuredWholeMost else { return false }
        var height = 0.0
        for row in rows {
            height += row.tailHeightFloor
            if height > measuredWholeHeight { return false }
        }
        return true
    }

    static func measuredTailStart(_ rows: [ChatDisplayItem], whole: Bool = false) -> Int {
        if whole, measuresWhole(rows) { return 0 }
        var count = 0
        var covered = 0.0
        for row in rows.reversed() {
            count += 1
            covered += row.tailHeightFloor
            if count >= measuredTail || (count >= measuredMinimum && covered >= measuredCover) { break }
        }
        return rows.count - count
    }

    static func split(_ rows: [ChatDisplayItem], measuredFrom start: Int? = nil)
        -> (lazy: ArraySlice<ChatDisplayItem>, measured: ArraySlice<ChatDisplayItem>) {
        let cut = start ?? measuredTailStart(rows)
        return (rows[..<cut], rows[cut...])
    }

    static func hiddenAbove(count: Int, olderOffset: Int) -> Int {
        range(count: count, olderOffset: olderOffset).lowerBound
    }

    static func revealingEarlier(count: Int, olderOffset: Int, limit: Int = step) -> Int {
        clampOffset(olderOffset + min(step, limit), count: count)
    }

    static func revealingLater(count: Int, olderOffset: Int, limit: Int = step) -> Int {
        clampOffset(olderOffset - min(step, limit), count: count)
    }

    static func revealing(_ id: String, in items: [ChatDisplayItem]) -> Int {
        guard let at = items.firstIndex(where: { $0.id == id }) else { return 0 }
        return clampOffset(items.count - at - 1, count: items.count)
    }

    static func holding(_ ids: [String], in items: [ChatDisplayItem], current: Int) -> Int {
        for id in ids {
            if let index = items.firstIndex(where: { $0.id == id }) {
                return clampOffset(items.count - index - length, count: items.count)
            }
        }
        return clampOffset(current, count: items.count)
    }

}

struct TranscriptMetrics: Equatable {
    var distanceFromTop: CGFloat
    var distanceFromBottom: CGFloat
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
    var readerIsScrolling: Bool? = nil

    var viewportPastContent: Bool {
        #if os(macOS)
        viewportHeight > 0 && contentHeight > 0 && distanceFromTop >= contentHeight
        #else
        false
        #endif
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension TranscriptMetrics {
    init(_ geometry: ScrollGeometry) {
        let top = geometry.contentOffset.y + geometry.contentInsets.top
        let viewport = geometry.containerSize.height
        self.init(
            distanceFromTop: max(0, top),
            distanceFromBottom: max(0, geometry.contentSize.height - top - viewport),
            contentHeight: geometry.contentSize.height,
            viewportHeight: viewport
        )
    }
}

/// Whether the viewport is still following the bottom.
///
/// Content growth and a person scrolling up both increase the distance from
/// the bottom. Growth is ignored so a stream cannot unpin the view. A height
/// that did not change, with a larger gap, can also be a lazy stack adjusting
/// its anchors. Use the native scroll phase when available to distinguish it
/// from a person moving away.
///
/// A reference type, and `showJump`, `paused`, `arrived` and `scrolling` are
/// the only things on it Observation watches: all four change on
/// transitions, never per frame. Everything else here is written on every
/// frame of every scroll, and a transcript that redraws itself that often
/// is a transcript nobody can scroll. The redraw is owed to the button
/// appearing, not to the offset moving by a point.
@Observable
final class TranscriptFollowState {
    private(set) var showJump = false
    private(set) var paused = false
    private(set) var scrolling = false
    @ObservationIgnored var pinned = true
    @ObservationIgnored var sliceHidesNewest = false
    @ObservationIgnored var suppressed = false {
        didSet { if suppressed { set(jump: false) } }
    }
    @ObservationIgnored private var programmaticUntil: Date = .distantPast
    @ObservationIgnored private(set) var settling = false
    /// Whether the transcript has actually reached the latest turn.
    ///
    /// A lazy stack builds from the top and finds its real height as it goes,
    /// so an opening conversation is visibly assembled and then yanked to the
    /// end. The transcript stays behind its wireframe until this turns true,
    /// which is the difference between watching that happen and arriving
    /// where the reading is.
    private(set) var arrived = false
    @ObservationIgnored var repin: (() -> Bool)?
    @ObservationIgnored private let repinDelivery = TranscriptScrollDelivery()
    @ObservationIgnored private var lastContentHeight: CGFloat = 0
    @ObservationIgnored private var lastViewportHeight: CGFloat = 0
    @ObservationIgnored private var lastOffset: CGFloat = 0
    @ObservationIgnored private var lastDistanceFromBottom: CGFloat = 0
    @ObservationIgnored private var readerIsScrolling = false
    /// The next geometry sample belongs to a trackpad wheel that already
    /// let go of the end. Mac scroll phase stays idle for that wheel, and
    /// an idle sample past the end is otherwise read as layout drift and
    /// pinned back. That pin is a walk of the lazy stack, which is the
    /// hitch a person feels scrolling up from the latest line.
    @ObservationIgnored private var forcedWheel = false
    @ObservationIgnored private(set) var layoutRevision: UInt64 = 0
    @ObservationIgnored private var undrivenDrift: CGFloat = 0
    @ObservationIgnored private var farMovedFrames = 0
    @ObservationIgnored private var retreatingFrames = 0
    /// Repins spent since the end was last actually reached.
    ///
    /// The pin and the lazy stack can argue forever, and did. Asking a
    /// `ScrollView` for the end makes the stack resolve an estimate for every
    /// row between here and there, and resolving one means building it and
    /// measuring its text. Those real heights replace the estimates, so the
    /// content is a different height than it was a moment ago, which is a
    /// growth nobody scrolled for, which is another repin. On a conversation
    /// of any size that loop does not converge: the app is in
    /// `LazyStack.measureEstimates` and never comes back, which is the
    /// ninety-second hang.
    ///
    /// A repin that works costs one frame and resets this, so following a
    /// stream is unaffected. A repin that changes nothing spends one, and
    /// when they run out the transcript stops asking for walks while the
    /// pin itself stays: streaming still follows through the token pins,
    /// and a conversation the reader left still offers Jump to latest.
    /// A conversation the reader can leave is better than one
    /// nobody can use.
    @ObservationIgnored private var repinsSpent = 0
    @ObservationIgnored private var pastContentRecoveryAttempted = false
    @ObservationIgnored private var viewportPastContent = false
    @ObservationIgnored private var lastRepinAt = Date.distantPast
    private static let scrollQuiet: TimeInterval = 0.35

    @ObservationIgnored private var scrollReset: DispatchWorkItem?

    private func trackScrolling(moved: Bool) {
        guard moved else { return }
        setScrolling(true)
        scrollReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.setScrolling(false) }
        scrollReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollQuiet, execute: reset)
    }

    private func setScrolling(_ value: Bool) {
        guard scrolling != value else { return }
        scrolling = value
    }

    deinit {
        scrollReset?.cancel()
    }
    @ObservationIgnored var active = true

    /// Stop every scroll-driven walk while the pane is behind another screen.
    ///
    /// Root keeps Chat mounted at opacity zero so a return finds the same
    /// conversation. Opacity does not stop layout: parent route changes still
    /// move the hidden ScrollView's geometry, `note` treated that as a fling,
    /// Observation redrew the LazyVStack, and `OnScrollGeometryChange` fired
    /// again on the same frame. That loop is the multi-second main-thread
    /// freeze when clicking through the sidebar. Cancel work and ignore
    /// metrics until the pane is front again.
    func freeze() {
        active = false
        repinDelivery.cancel()
        scrollReset?.cancel()
        scrollReset = nil
        setScrolling(false)
        settling = false
        abandoned = false
        undrivenDrift = 0
        farMovedFrames = 0
        retreatingFrames = 0
    }
    /// Whether the last frame put the end under the viewport.
    ///
    /// Read by the loops that hold the end while a conversation opens. One
    /// scroll to the end of a lazy stack is a walk over every row in between,
    /// so spending forty of them on a transcript that is already there is
    /// most of what made opening a long chat a hang.
    @ObservationIgnored private(set) var atEnd = false
    var exactlyAtEnd: Bool { atEnd && lastViewportHeight > 0 && lastDistanceFromBottom <= 2 }
    @ObservationIgnored private(set) var abandoned = false

    /// Hold the end while the transcript settles, whatever the geometry of a
    /// half-measured lazy stack claims.
    ///
    /// Leaving the settle always reveals, whether the end was reached or the
    /// frames simply ran out. A wireframe that can outlast its content is
    /// worse than the build-up it hides.
    func settle(_ holding: Bool) {
        chase(holding)
        set(arrived: !holding)
    }

    func chase(_ active: Bool) {
        repinDelivery.cancel()
        settling = active
        steadyFrames = 0
        abandoned = false
        repinsSpent = 0
        lastRepinAt = .distantPast
        undrivenDrift = 0
        farMovedFrames = 0
        retreatingFrames = 0
        if active {
            paused = false
            pinned = true
            set(jump: false)
        } else if !pinned && !atEnd {
            set(jump: true)
        }
    }

    func markDriven(duration: TimeInterval = 0.4) {
        programmaticUntil = Date().addingTimeInterval(duration)
    }

    func markDrivenInstant() {
        markDriven(duration: 0.08)
    }

    /// Whether the end is under the viewport *and* the content has stopped
    /// changing size.
    ///
    /// Both halves matter. A half-measured lazy stack reports a content
    /// height it has estimated, so "distance from the bottom is zero" can be
    /// true of a transcript with most of its rows still unmeasured, and
    /// believing it is how the conversation was revealed in its middle.
    @ObservationIgnored private(set) var steadyFrames = 0

    func resetViewport() {
        repinDelivery.cancel()
        atEnd = false
        steadyFrames = 0
        lastContentHeight = 0
        lastViewportHeight = 0
        lastOffset = 0
        lastDistanceFromBottom = 0
        readerIsScrolling = false
        forcedWheel = false
        layoutRevision &+= 1
        programmaticUntil = .distantPast
        undrivenDrift = 0
        farMovedFrames = 0
        retreatingFrames = 0
        pastContentRecoveryAttempted = false
        viewportPastContent = false
    }

    func note(_ metrics: TranscriptMetrics) {
        guard active else { return }
        viewportPastContent = metrics.viewportPastContent
        if !viewportPastContent { pastContentRecoveryAttempted = false }
        let grew = metrics.contentHeight > lastContentHeight + 0.5
        let shrank = metrics.contentHeight < lastContentHeight - 0.5
        let moved = abs(metrics.distanceFromTop - lastOffset) > 0.5
        let resized = abs(metrics.viewportHeight - lastViewportHeight) > 0.5
        if grew || shrank || moved || resized { layoutRevision &+= 1 }
        let fromWheel = forcedWheel
        let wheelMoved = fromWheel
            && (moved || metrics.distanceFromBottom > lastDistanceFromBottom + 0.5)
        if wheelMoved { forcedWheel = false }
        readerIsScrolling = metrics.readerIsScrolling == true || fromWheel
        if readerIsScrolling { repinDelivery.cancel() }
        if wheelMoved { trackScrolling(moved: true) }
        let readerMoved = moved && (fromWheel || metrics.readerIsScrolling != false)
        trackScrolling(moved: readerMoved)
        if wheelMoved, !settling { set(jump: true) }

        let hadViewport = lastViewportHeight > 0
        lastViewportHeight = metrics.viewportHeight
        if (hadViewport && resized) || (grew && !moved), pinned, !settling, !readerIsScrolling,
           !readerMoved, !sliceHidesNewest, !metrics.viewportPastContent,
           metrics.distanceFromBottom > 2, metrics.distanceFromBottom <= TranscriptFollow.threshold {
            repinDelivery.submit(after: max(0, 0.15 - Date().timeIntervalSince(lastRepinAt))) { [weak self] in
                guard let self, self.active, self.pinned, !self.sliceHidesNewest, !self.suppressed,
                      !self.settling, !self.readerIsScrolling, !self.exactlyAtEnd else { return }
                self.lastRepinAt = Date()
                self.markDrivenInstant()
                _ = self.repin?()
            }
        }

        if sliceHidesNewest {
            atEnd = false
            lastContentHeight = metrics.contentHeight
            lastOffset = metrics.distanceFromTop
            lastDistanceFromBottom = metrics.distanceFromBottom
            if pinned { stopFollowing() }
            return
        }

        if settling {
            let retreat = lastOffset - metrics.distanceFromTop
            let retreated = readerMoved && (pinned || Date() >= programmaticUntil)
                && (readerIsScrolling
                    ? retreat > 2 && metrics.distanceFromBottom > lastDistanceFromBottom + 0.5
                    : !grew && !shrank && metrics.distanceFromBottom > lastDistanceFromBottom + 8)
            lastContentHeight = metrics.contentHeight
            lastOffset = metrics.distanceFromTop
            lastDistanceFromBottom = metrics.distanceFromBottom
            if retreated {
                abandoned = true
                pinned = false
                repinDelivery.cancel()
                set(jump: false)
                return
            }
            atEnd = metrics.contentHeight > 0 && !metrics.viewportPastContent
                && metrics.distanceFromBottom <= TranscriptFollow.threshold
            steadyFrames = (atEnd && !grew && !shrank) ? steadyFrames + 1 : 0
            if steadyFrames >= Self.steadyToArrive { set(arrived: true) }
            set(jump: false)
            return
        }
        let prevBottom = lastDistanceFromBottom
        let prevOffset = lastOffset
        let driven = Date() < programmaticUntil
        lastDistanceFromBottom = metrics.distanceFromBottom
        if suppressed {
            set(jump: false)
            return
        }
        atEnd = metrics.contentHeight > 0 && !metrics.viewportPastContent
            && metrics.distanceFromBottom <= TranscriptFollow.threshold
        guard metrics.viewportHeight > 0, metrics.contentHeight > 0 else { return }
        if metrics.distanceFromBottom > TranscriptFollow.threshold {
            if readerMoved { farMovedFrames += 1 } else { farMovedFrames = 0 }
            if metrics.distanceFromBottom > prevBottom + 2 {
                retreatingFrames += 1
            } else {
                retreatingFrames = 0
            }
        } else {
            farMovedFrames = 0
            retreatingFrames = 0
        }
        lastContentHeight = metrics.contentHeight
        lastOffset = metrics.distanceFromTop
        if metrics.viewportPastContent && (readerMoved || metrics.readerIsScrolling == true) {
            repinDelivery.cancel()
            return
        }
        if driven {
            let retreatingNow = metrics.distanceFromBottom > prevBottom + 2
            if readerMoved, retreatingNow {
                undrivenDrift += abs(metrics.distanceFromTop - prevOffset)
            } else {
                undrivenDrift = 0
            }
        } else if readerMoved {
            undrivenDrift += abs(metrics.distanceFromTop - prevOffset)
        }
        if pinned, readerIsScrolling, metrics.distanceFromTop < prevOffset - 0.5,
           metrics.distanceFromBottom > max(2, prevBottom + 0.5) {
            stopFollowing()
            return
        }
        let pastContent = metrics.viewportPastContent
        if metrics.distanceFromBottom > TranscriptFollow.threshold || pastContent,
           (grew && !moved) || (metrics.readerIsScrolling == false && !fromWheel) || pastContent {
            if pinned, metrics.distanceFromBottom > TranscriptFollow.threshold || pastContent {
                if pastContent {
                    guard !pastContentRecoveryAttempted else { return }
                } else {
                    guard repinsSpent < Self.repinBudget else { return }
                }
                let delay = max(0, 0.15 - Date().timeIntervalSince(lastRepinAt))
                repinDelivery.submit(after: delay) { [weak self] in
                    guard let self, self.active, self.pinned,
                          !self.atEnd, !self.sliceHidesNewest,
                          !self.suppressed, !self.settling, !self.readerIsScrolling else { return }
                    if pastContent {
                        guard self.viewportPastContent, !self.pastContentRecoveryAttempted else { return }
                        self.pastContentRecoveryAttempted = true
                    } else {
                        guard self.repinsSpent < Self.repinBudget else { return }
                    }
                    self.lastRepinAt = Date()
                    self.repinsSpent += 1
                    self.markDrivenInstant()
                    if self.repin?() == false { self.stopFollowing() }
                }
            } else if !pinned,
                metrics.distanceFromBottom > TranscriptFollow.threshold || pastContent
            {
                set(jump: true)
            }
            return
        }
        if metrics.distanceFromBottom > TranscriptFollow.threshold {
            // Far from the end. Unpinning takes a moved viewport: only the
            // reader's own scroll proves a hand leaving. Stationary far
            // frames must hold, because the lazy stack routinely parks here
            // on its own: a repin that landed on estimated heights, or a
            // streaming stall longer than the driven window, both sit far
            // with nobody touching anything. Unpinning those is what flipped
            // Following to Jump to latest mid-reply and then never came back,
            // since every later pin is guarded on the pin this cleared.
            // A wheel tick can leave in a single callback. When content is
            // stable and the offset moves up as the bottom recedes, release
            // immediately, including during a driven pin. Keep the sustained
            // motion filter for frames whose content height is changing.
            let stableRetreat = readerMoved && !grew && !shrank
                && metrics.distanceFromTop < prevOffset
                && metrics.distanceFromBottom > prevBottom + 2
            let userMoved = farMovedFrames >= 4 || (undrivenDrift > 24 && farMovedFrames >= 2)
            if stableRetreat || (userMoved && (!driven || retreatingFrames >= 4)) {
                stopFollowing()
            }
        } else if metrics.distanceFromBottom <= 10 {
            undrivenDrift = 0
            let returnedByScrolling = readerMoved
                && (metrics.distanceFromTop > prevOffset || (paused && metrics.distanceFromBottom <= 2))
            if returnedByScrolling {
                paused = false
            }
            if !paused, pinned || returnedByScrolling {
                pinned = true
                undrivenDrift = 0
                set(jump: false)
            }
        }
        if metrics.distanceFromBottom <= TranscriptFollow.threshold {
            repinsSpent = 0
        }
    }

    /// Let go of the latest line because a trackpad wheel moved upward.
    ///
    /// Called from the wheel event, before AppKit applies it. The scroll
    /// phase for that event often stays idle, so waiting for geometry
    /// schedules a pin back to the end on the same gesture. The scrollbar
    /// does not have this problem: dragging it reports a real scroll phase
    /// and the ordinary path lets go. `pinned` is not observed, so this
    /// does not redraw inside the event.
    func releaseForReaderWheel() {
        guard pinned || settling else { return }
        forcedWheel = true
        abandoned = true
        repinDelivery.cancel()
        pinned = false
        undrivenDrift = 0
        farMovedFrames = 0
        retreatingFrames = 0
    }

    func stopFollowing() {
        guard !settling else { return }
        repinDelivery.cancel()
        pinned = false
        undrivenDrift = 0
        farMovedFrames = 0
        retreatingFrames = 0
        set(jump: true)
    }

    func jump() {
        repinDelivery.cancel()
        paused = false
        pinned = true
        repinsSpent = 0
        lastRepinAt = .distantPast
        undrivenDrift = 0
        farMovedFrames = 0
        retreatingFrames = 0
        forcedWheel = false
        markDriven()
        set(jump: false)
    }

    func pause() {
        repinDelivery.cancel()
        paused = true
        pinned = false
        undrivenDrift = 0
        farMovedFrames = 0
        retreatingFrames = 0
    }

    private func set(jump value: Bool) {
        guard showJump != value else { return }
        showJump = value
    }

    private func set(arrived value: Bool) {
        guard arrived != value else { return }
        arrived = value
    }

    private static let repinBudget = 6

    private static let steadyToArrive = 3
}

struct ChatScrollContentKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

struct ChatScrollViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Which transcript rows a lazy stack holds right now, and where it put them.
///
/// A lazy stack can be left drawing nothing while its scroll view rests among
/// its rows: the end was pinned on estimated heights and the estimates
/// changed as a long reply was measured, or a fling crossed a reply too tall
/// to estimate. It drops the rows it built, or keeps them where it thought
/// they were, and nothing asks it again which rows are on screen. The
/// transcript is plain background until something scrolls it. No mounted
/// row inside the viewport while the conversation has rows is how both chat
/// screens see that and move the view to make the stack build again.
///
/// A plain class so rows coming and going never invalidate the transcript.
@MainActor
final class TranscriptRowMounts {
    final class Row {
        var frame: CGRect?
    }

    private var mounted: [ObjectIdentifier: Row] = [:]

    func appeared(_ row: Row) { mounted[ObjectIdentifier(row)] = row }
    func disappeared(_ row: Row) { mounted[ObjectIdentifier(row)] = nil }
    func contains(_ row: Row) -> Bool { mounted[ObjectIdentifier(row)] != nil }

    func showsRows(viewportHeight: CGFloat) -> Bool {
        mounted.values.contains { row in
            guard let frame = row.frame, viewportHeight > 0 else { return true }
            return frame.maxY > 0 && frame.minY < viewportHeight
        }
    }
}

extension View {
    func transcriptRowMount(in mounts: TranscriptRowMounts, id: String, window: TranscriptWindow) -> some View {
        modifier(TranscriptRowMount(mounts: mounts, id: id, window: window))
    }
}

private struct TranscriptRowMount: ViewModifier {
    let mounts: TranscriptRowMounts
    let id: String
    let window: TranscriptWindow
    @State private var row = TranscriptRowMounts.Row()

    func body(content: Content) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            content
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TranscriptFollow.contentSpaceName)).minY } action: { top in
                    window.noteContentTop(id, top)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TranscriptFollow.spaceName)) } action: { frame in
                    row.frame = frame
                    #if DEBUG
                    TranscriptProbe.shared.noteRow(id, height: frame.height)
                    TranscriptProbe.shared.noteTracked(id, top: frame.minY)
                    #endif
                    if mounts.contains(row) { window.report(id, mount: row, frame: frame) }
                }
                .onAppear {
                    mounts.appeared(row)
                    if let frame = row.frame { window.report(id, mount: row, frame: frame) }
                }
                .onDisappear {
                    mounts.disappeared(row)
                    window.report(id, mount: row, frame: nil)
                }
        } else {
            content
                .onAppear { mounts.appeared(row) }
                .onDisappear { mounts.disappeared(row) }
        }
    }
}

struct TranscriptBottomSentinel: View {
    var trailingPadding: CGFloat = 0

    var body: some View {
        Color.clear
            .frame(height: 1 + trailingPadding)
            .id(TranscriptFollow.bottomID)
    }
}

struct OpeningCover: ViewModifier {
    var isOpening: Bool
    var ready: Bool
    var conversationID: String?
    @Binding var opening: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { opening = isOpening }
            .onChange(of: isOpening) { _, value in
                if value { opening = true }
            }
            .onChange(of: ready) { _, value in
                if value { opening = false }
            }
            .onChange(of: conversationID) { _, _ in
                opening = isOpening
            }
    }
}

struct TranscriptSkeleton: View {
    private static let turns: [(mine: Bool, lines: Int)] = [
        (false, 3), (true, 1), (false, 5), (true, 2), (false, 2), (false, 4), (true, 1), (false, 3),
    ]
    private static let widths: [CGFloat] = [0.94, 0.86, 0.71, 0.9, 0.58, 0.8]
    private static let lineHeight: CGFloat = 9
    private static let lineGap: CGFloat = 9
    private static let turnGap: CGFloat = 22
    private static let bubblePadding: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let lane = max(0, geometry.size.width)
            VStack(alignment: .leading, spacing: Self.turnGap) {
                ForEach(Self.filling(geometry.size.height), id: \.self) { index in
                    turn(index, lane: lane)
                }
            }
            .frame(width: lane, height: geometry.size.height, alignment: .bottom)
            .opacity(0.7)
        }
        .clipped()
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.38)],
                           startPoint: .top, endPoint: .bottom)
        }
        .padding(.vertical, Theme.Space.l)
        .padding(.horizontal, Theme.Space.l)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("apple.transcriptfollow.loading_the_conversation.f32af8b0"))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func turn(_ index: Int, lane: CGFloat) -> some View {
        let shape = Self.turns[index % Self.turns.count]
        let lines = VStack(alignment: .leading, spacing: Self.lineGap) {
            ForEach(0..<shape.lines, id: \.self) { line in
                Skeleton.Bar(width: nil, height: Self.lineHeight,
                             phase: Double(index % Self.turns.count) * 0.11 + Double(line) * 0.05)
                    .frame(maxWidth: (shape.mine ? lane * 0.5 : lane) * Self.widths[(index * 2 + line) % Self.widths.count],
                           alignment: .leading)
            }
        }
        if shape.mine {
            HStack(spacing: 0) {
                Spacer(minLength: lane * 0.3)
                lines
                    .frame(width: lane * 0.5, alignment: .leading)
                    .padding(Self.bubblePadding)
                    .background(Theme.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            lines.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func filling(_ height: CGFloat) -> [Int] {
        var used: CGFloat = 0
        var count = 0
        while used < height, count < 40 {
            let shape = turns[count % turns.count]
            used += CGFloat(shape.lines) * (lineHeight + lineGap) - lineGap
                + (shape.mine ? bubblePadding * 2 : 0) + turnGap
            count += 1
        }
        return Array((0..<max(count, 1)).reversed())
    }
}

struct TranscriptFollowPill: View {
    var showJump: Bool
    var busy: Bool
    var paused: Bool
    var resume: () -> Void
    var pause: () -> Void

    var body: some View {
        Group {
            if showJump {
                Button(L10n.text("apple.transcriptfollow.jump_to_latest.86752458"), .latest, action: resume)
                    .buttonStyle(AccentButtonStyle(small: true, capsule: true))
            } else if busy, paused {
                Button(L10n.text("apple.transcriptfollow.follow.641d1ef6"), .latest, action: resume)
                    .buttonStyle(AccentButtonStyle(small: true, capsule: true))
                    .help(L10n.text("apple.transcriptfollow.follow_new_responses_as_they_arrive.bc0eb314"))
            } else if busy {
                Button(L10n.text("apple.transcriptfollow.following.344b4271"), .latest, action: pause)
                    .buttonStyle(AccentButtonStyle(small: true, capsule: true))
                    .help(L10n.text("apple.transcriptfollow.pause_auto_follow.554e9318"))
            }
        }
        .padding(.bottom, Theme.Space.s)
        .animation(.snappy(duration: 0.18), value: showJump)
    }
}

extension View {
    @ViewBuilder
    func transcriptFollowBar<Bar: View>(@ViewBuilder bar: () -> Bar) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: bar)
        }
        #else
        safeAreaInset(edge: .bottom, spacing: 0, content: bar)
        #endif
    }
}

final class TranscriptScrollDelivery {
    private var pending: DispatchWorkItem?
    private var latest: (() -> Void)?

    func submit(after delay: TimeInterval = 0, _ action: @escaping () -> Void) {
        latest = action
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let action = self.latest
            self.latest = nil
            self.pending = nil
            action?()
        }
        pending = work
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        latest = nil
    }

    deinit { pending?.cancel() }
}

/// Report where the transcript is scrolled, by whichever route this system
/// offers, and name the space its rows measure themselves in.
private struct TranscriptScrollMetrics: ViewModifier {
    @MainActor
    final class Interaction {
        var phaseScrolling = false
        var lastOffset: CGFloat = .nan
        var lastMovedAt = Date.distantPast
        var last: TranscriptMetrics?
        var rest: DispatchWorkItem?
        static let quiet: TimeInterval = 0.3

        var readerIsScrolling: Bool {
            phaseScrolling && Date().timeIntervalSince(lastMovedAt) < Self.quiet
        }

        func noted(_ metrics: TranscriptMetrics, note: @escaping (TranscriptMetrics) -> Void) {
            if !(abs(metrics.distanceFromTop - lastOffset) <= 0.5) {
                lastOffset = metrics.distanceFromTop
                lastMovedAt = Date()
                if phaseScrolling { scheduleRest(note) }
            }
            last = metrics
        }

        func scheduleRest(_ note: @escaping (TranscriptMetrics) -> Void) {
            rest?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.phaseScrolling, var metrics = self.last,
                      Date().timeIntervalSince(self.lastMovedAt) >= Self.quiet - 0.01 else { return }
                self.phaseScrolling = false
                metrics.readerIsScrolling = false
                note(metrics)
            }
            rest = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.quiet, execute: work)
        }
    }
    @State private var interaction = Interaction()
    let note: (TranscriptMetrics) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            content
                .coordinateSpace(name: TranscriptFollow.spaceName)
                .onScrollGeometryChange(for: TranscriptMetrics.self) { geometry in
                    TranscriptMetrics(geometry)
                } action: { _, metrics in
                    var metrics = metrics
                    interaction.noted(metrics, note: note)
                    metrics.readerIsScrolling = interaction.readerIsScrolling
                    note(metrics)
                }
                .onScrollPhaseChange { _, phase, context in
                    interaction.phaseScrolling = phase == .interacting || phase == .decelerating
                    var metrics = TranscriptMetrics(context.geometry)
                    interaction.noted(metrics, note: note)
                    if interaction.phaseScrolling {
                        interaction.lastMovedAt = Date()
                        interaction.scheduleRest(note)
                    }
                    metrics.readerIsScrolling = interaction.readerIsScrolling
                    note(metrics)
                }
        } else {
            content.modifier(LegacyTranscriptScrollMetrics(note: note))
        }
    }
}

private struct LegacyTranscriptScrollMetrics: ViewModifier {
    final class Held {
        var frame = CGRect.zero
        var viewport: CGFloat = 0
    }

    let note: (TranscriptMetrics) -> Void
    @State private var held = Held()

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ChatScrollViewportKey.self,
                        value: geo.size.height
                    )
                }
            }
            .coordinateSpace(name: TranscriptFollow.spaceName)
            .onPreferenceChange(ChatScrollContentKey.self) { frame in
                held.frame = frame
                emit()
            }
            .onPreferenceChange(ChatScrollViewportKey.self) { height in
                held.viewport = height
                emit()
            }
    }

    private func emit() {
        let frame = held.frame
        let viewport = held.viewport
        note(
            TranscriptMetrics(
                distanceFromTop: max(0, -frame.minY),
                distanceFromBottom: max(0, frame.height + frame.minY - viewport),
                contentHeight: frame.height,
                viewportHeight: viewport
            )
        )
    }
}

extension View {
    @ViewBuilder
    func chatScrollContent() -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            self
        } else {
            background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ChatScrollContentKey.self,
                        value: geo.frame(in: .named(TranscriptFollow.spaceName))
                    )
                }
            }
        }
    }

    @ViewBuilder
    func transcriptOpensAtEnd() -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            self
        }
    }

    @ViewBuilder
    func preserveStreamingScrollback(_ preserve: Bool, window: TranscriptWindow) -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            transaction { transaction in
                if preserve, !window.isRestoringPage {
                    transaction.scrollContentOffsetAdjustmentBehavior = .disabled
                }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }

    func chatScrollMetrics(_ note: @escaping (TranscriptMetrics) -> Void) -> some View {
        modifier(TranscriptScrollMetrics(note: note))
    }

}


final class TranscriptWindow {
    var active = true {
        didSet {
            if !active {
                restWork?.cancel()
                readerIsScrolling = false
                release()
            }
        }
    }
    var viewportHeight: CGFloat = 0
    private var readerIsScrolling = false
    var isRestoringPage: Bool { held != nil }
    var distanceFromTop: CGFloat = .greatestFiniteMagnitude
    var rowFrames: [String: CGRect] = [:] {
        didSet {
            #if DEBUG
            if let held {
                let drift = rowFrames[held.id].map { target(for: held).drift(to: $0) }
                MainActor.assumeIsolated { TranscriptHoldTrace.shared.reported(drift: drift) }
            }
            #endif
            correctFromReport()
        }
    }
    var fetching = false
    var mounts = 0
    var canAskEarlier = false
    var hasHiddenEarlierRows = false
    var hasHiddenLaterRows = false
    var revealEarlier: (() -> Void)?
    var revealLater: (() -> Void)?
    var holdSliceStart: ((Bool) -> Void)?
    private var distanceFromBottom: CGFloat = .greatestFiniteMagnitude
    var readingEarlier: Bool?
    private var slideQuietUntil: Date = .distantPast
    var followingEnd = false
    var releaseFollow: (() -> Void)?
    var requestEarlier: ((Bool) -> Void)?
    var restore: ((TranscriptAnchor) -> Void)?
    var restoreMeasured: ((CGFloat) -> Bool)?
    /// The row the reader is reading, and where it sits in the content.
    ///
    /// Rows the lazy stack has not built yet are sized by estimate, and a
    /// chat of one-line tool steps between long replies and pictures is
    /// estimated far too tall. Scrolling up builds them, the content above
    /// the reader shrinks by hundreds of points at a time, and AppKit keeps
    /// the offset from the top, so the text under the reader jumped. The
    /// row being read keeps its place on screen instead: when its place in
    /// the content changes, something above it changed size, and the offset
    /// moves by exactly as much in the same pass, before anything is drawn.
    private var readingRow: String?
    private var readingTop: CGFloat = 0
    private var contentTops: [String: CGFloat] = [:]

    var rowHeightNoted: ((String, CGFloat) -> Void)?
    var prepareScroll: ((String) -> Bool)?

    func rowsAboveResized(by delta: CGFloat) {
        guard readingRow != nil else { return }
        readingTop += delta
    }

    func noteContentTop(_ id: String, _ top: CGFloat) {
        contentTops[id] = top
        guard id == readingRow else { return }
        var shift = top - readingTop
        readingTop = top
        // Content that shrinks near the end is partly put right by AppKit
        // already: the offset cannot pass the new end, so it is pulled back
        // by whatever the shrink takes beyond the room that was below the
        // screen. Only the rest moved the reader. Correcting the whole of it
        // again threw the row a screen away on the first scroll up.
        if shift < 0 { shift = -min(-shift, distanceFromBottom) }
        let leavingEnd = readerIsScrolling && readingEarlier == true
        guard abs(shift) > 0.5, active, held == nil, !followingEnd || leavingEnd,
              readingRowOnScreen, let restoreMeasured else { return }
        _ = restoreMeasured(shift)
    }

    private var readingRowOnScreen: Bool {
        guard let readingRow, let frame = rowFrames[readingRow] else { return false }
        return frame.maxY > 0 && frame.minY < viewportHeight
    }

    private func pickReadingRow() {
        guard let id = anchor?.id, id != readingRow, let top = contentTops[id] else { return }
        readingRow = id
        readingTop = top
    }

    var cover: (() -> Void)?
    var uncover: (() -> Void)?
    private var covered = false
    private var coverExpiry: DispatchWorkItem?

    func coverPageLanding() {
        guard let cover, !covered else { return }
        covered = true
        #if DEBUG
        MainActor.assumeIsolated { TranscriptHoldTrace.shared.corrected("cover") }
        #endif
        cover()
        coverExpiry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.uncoverPage() }
        coverExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coverLimit, execute: work)
    }

    func uncoverPage() {
        coverExpiry?.cancel()
        coverExpiry = nil
        quietWork?.cancel()
        quietWork = nil
        guard covered else { return }
        covered = false
        #if DEBUG
        MainActor.assumeIsolated { TranscriptHoldTrace.shared.corrected("uncover") }
        #endif
        uncover?()
    }

    private static let coverLimit: TimeInterval = 0.9

    func uncoverWhenQuiet() {
        guard covered else { return }
        quietWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.uncoverPage() }
        quietWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coverQuiet, execute: work)
    }

    func coveredLayoutMoved() {
        guard covered, quietWork != nil else { return }
        uncoverWhenQuiet()
    }

    private var quietWork: DispatchWorkItem?
    private static let coverQuiet: TimeInterval = 0.15

    var canRestore: (() -> Bool)?
    var canPage: (() -> Bool)?
    private let restoreDelivery = TranscriptScrollDelivery()
    private var held: TranscriptAnchor?
    private var heldLanded = false {
        didSet { if heldLanded { uncoverWhenQuiet() } }
    }
    private var heldIsPage = false
    private var armedFrame: CGRect?
    private var heldBackup: TranscriptAnchor?
    private var correctedFrom: CGRect?
    private var heldUntil: Date = .distantPast
    private var holdExpiry: DispatchWorkItem?
    private var lastContentHeight: CGFloat = 0

    func hold(_ anchor: TranscriptAnchor, label: String = "page") {
        #if DEBUG
        MainActor.assumeIsolated {
            TranscriptHoldTrace.shared.armed(label, id: anchor.id, top: anchor.top, height: anchor.height)
        }
        #endif
        held = anchor
        armedFrame = rowFrames[anchor.id]
        heldHeight = rowFrames[anchor.id]?.height
        heldIsPage = label == "page"
        heldBackup = TranscriptAnchor.candidates(rowFrames, viewportHeight: viewportHeight)
            .first { $0.id != anchor.id }
        heldLanded = false
        correctedFrom = nil
        heldUntil = Date().addingTimeInterval(Self.holdSeconds)
        heldSince = Date()
        heldCorrections = 0
        scheduleExpiry()
    }

    func release() {
        #if DEBUG
        if held != nil { MainActor.assumeIsolated { TranscriptHoldTrace.shared.released() } }
        #endif
        restoreDelivery.cancel()
        holdExpiry?.cancel()
        holdExpiry = nil
        if readerIsScrolling { uncoverPage() } else { uncoverWhenQuiet() }
        held = nil
        heldUntil = .distantPast
    }

    private func scheduleExpiry() {
        holdExpiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.held != nil else { return }
            self.release()
            self.ask()
            self.askLater()
        }
        holdExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, heldUntil.timeIntervalSinceNow), execute: work)
    }

    private static let holdSlack: CGFloat = 0.5

    /// Allow the insertion and the lazy stack’s first estimates to settle.
    private static let holdSeconds: TimeInterval = 0.6

    private static let holdCeiling: TimeInterval = 3
    private static let correctionCeiling = 20
    private var heldSince = Date.distantPast
    private var heldCorrections = 0

    private func spendCorrection(resized: Bool) -> Bool {
        guard heldCorrections < Self.correctionCeiling,
              Date().timeIntervalSince(heldSince) < Self.holdCeiling else { return false }
        heldCorrections += 1
        if heldIsPage, resized {
            heldUntil = min(Date().addingTimeInterval(Self.holdSeconds),
                            heldSince.addingTimeInterval(Self.holdCeiling))
            scheduleExpiry()
        }
        return true
    }

    private func heldResized(_ frame: CGRect) -> Bool {
        defer { heldHeight = frame.height }
        guard let heldHeight else { return false }
        return abs(frame.height - heldHeight) > 0.5
    }
    private var heldHeight: CGFloat?

    /// How close to the top of what is loaded counts as approaching it.
    ///
    /// Three and a half screens on macOS where viewports are tall and flicks
    /// are fast, two and a half elsewhere. The anchor is whatever is on screen
    /// now, so how early this fires no longer decides whether the page can be
    /// absorbed, and the only thing left to trade is round trips against
    /// runway. A reader flicking back through a long history covers a screen
    /// in a few hundred milliseconds and should never meet the end of what is
    /// loaded.
    static let reach: CGFloat = 2.5

    static let measureFrom: CGFloat = 4
    static let measureUntil: CGFloat = 6

    private var lastAnchorCheck = Date.distantPast
    private var lastDistanceFromTopForAnchor: CGFloat = .greatestFiniteMagnitude

    private(set) var nearTop = false
    var nearTopChanged: ((Bool) -> Void)?

    #if os(macOS)
    func noteWheel(towardEarlier: Bool) {
        guard active else { return }
        readingEarlier = towardEarlier
        lastWheelAt = Date()
        lastMovedAt = lastWheelAt
        readerIsScrolling = true
        if held != nil, heldLanded || !covered { release() }
        if towardEarlier { releaseFollow?() }
        settleAfterQuiet()
    }
    #endif

    func note(_ metrics: TranscriptMetrics) {
        let now = Date()
        let wheelIsScrolling = now.timeIntervalSince(lastWheelAt) < Self.restAfter
        let offsetDelta = metrics.distanceFromTop - distanceFromTop
        if abs(offsetDelta) > 0.5 {
            lastMovedAt = now
            if wheelIsScrolling || metrics.readerIsScrolling == true { settleAfterQuiet() }
        }
        readerIsScrolling = wheelIsScrolling
            || (metrics.readerIsScrolling == true && now.timeIntervalSince(lastMovedAt) < Self.restAfter)
        viewportHeight = metrics.viewportHeight
        distanceFromTop = metrics.distanceFromTop
        distanceFromBottom = metrics.distanceFromBottom
        updateNearTop(metrics)
        let changed = abs(metrics.contentHeight - lastContentHeight) > 0.5
        lastContentHeight = metrics.contentHeight
        if held == nil, !wheelIsScrolling, readerIsScrolling, !changed, abs(offsetDelta) > 0.5 {
            readingEarlier = offsetDelta < 0
        }
        if !changed || !readingRowOnScreen { pickReadingRow() }
        if followingEnd {
            release()
            return
        }
        if held != nil, (readerIsScrolling && heldLanded) || Date() > heldUntil { release() }
        if let held, changed {
            scheduleRestore(held)
            return
        }
        let moved = abs(metrics.distanceFromTop - lastDistanceFromTopForAnchor) > 8
        let shouldEvaluate = moved || now.timeIntervalSince(lastAnchorCheck) > 0.032
        if shouldEvaluate {
            lastAnchorCheck = now
            lastDistanceFromTopForAnchor = metrics.distanceFromTop
            ask()
            askLater()
        }
    }

    private func settleAfterQuiet() {
        restWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active,
                  Date().timeIntervalSince(self.lastMovedAt) >= Self.restAfter - 0.01 else { return }
            if self.canPage?() == false {
                self.settleAfterQuiet()
                return
            }
            self.readerIsScrolling = false
            if let held = self.held {
                self.scheduleRestore(held)
            } else {
                self.ask()
                self.askLater()
            }
        }
        restWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restAfter, execute: work)
    }

    private var restWork: DispatchWorkItem?
    private var lastMovedAt = Date.distantPast
    private var lastWheelAt = Date.distantPast
    private static let restAfter: TimeInterval = 0.3

    private func correctFromReport() {
        guard let held, !followingEnd, !(readerIsScrolling && heldLanded),
              Date() <= heldUntil, canRestore?() != false,
              let frame = rowFrames[held.id], frame != correctedFrom else { return }
        guard frame != armedFrame || correctedFrom != nil else { return }
        let target = target(for: held)
        guard abs(target.drift(to: frame)) > Self.holdSlack else {
            heldLanded = true
            return
        }
        #if os(iOS)
        if restoreMeasured != nil {
            scheduleRestore(held)
            return
        }
        #endif
        guard spendCorrection(resized: heldResized(frame)) else { return }
        correctedFrom = frame
        restoreDelivery.cancel()
        #if DEBUG
        MainActor.assumeIsolated { TranscriptHoldTrace.shared.corrected("sync") }
        #endif
        coveredLayoutMoved()
        restore?(target)
        #if os(macOS)
        if restoreMeasured != nil { scheduleRestore(held, after: 0.05) }
        #endif
    }

    static var rowsReportThemselves: Bool {
        if #available(macOS 15.0, iOS 18.0, *) { return true }
        return false
    }

    var extendedAtStart: ((String) -> Bool)?
    var resolveRow: ((String) -> String?)?

    private func rehome() {
        guard let held, rowFrames[held.id] == nil, let resolveRow else { return }
        guard let other = resolveRow(held.id) else {
            if let backup = heldBackup, resolveRow(backup.id) == backup.id {
                #if DEBUG
                TranscriptHoldTrace.note("rehome \(held.id.prefix(20)) -> backup \(backup.id.prefix(20))")
                #endif
                self.held = backup
                resetPlacement()
                heldBackup = nil
            }
            return
        }
        guard other != held.id else { return }
        #if DEBUG
        TranscriptHoldTrace.note("rehome \(held.id.prefix(20)) -> \(other.prefix(20))")
        #endif
        self.held = TranscriptAnchor(id: other, top: held.top, height: rowFrames[other]?.height ?? held.height)
        resetPlacement()
    }

    private func resetPlacement() {
        armedFrame = nil
        correctedFrom = nil
        heldHeight = nil
        heldLanded = false
    }

    func target(for held: TranscriptAnchor) -> TranscriptAnchor {
        guard heldIsPage, extendedAtStart?(held.id) == true else { return held }
        guard let frame = rowFrames[held.id] else {
            return TranscriptAnchor(id: held.id, top: viewportHeight - held.height, height: held.height)
        }
        guard abs(frame.height - held.height) > 0.5 else { return held }
        return TranscriptAnchor(id: held.id, top: held.top + held.height - frame.height, height: frame.height)
    }

    private var rowMounts: [String: ObjectIdentifier] = [:]

    func clearRowFrames() {
        rowMounts.removeAll()
        rowFrames.removeAll()
        contentTops.removeAll()
        readingRow = nil
    }

    /// A row can move between the lazy stack and the measured tail. Keep
    /// the new mount when the old view's disappearance arrives afterwards.
    func report(_ id: String, mount: TranscriptRowMounts.Row, frame: CGRect?) {
        let owner = ObjectIdentifier(mount)
        if let frame {
            rowMounts[id] = owner
            rowHeightNoted?(id, frame.height)
            rowFrames[id] = frame
        } else if rowMounts[id] == owner {
            rowMounts[id] = nil
            rowFrames[id] = nil
            contentTops[id] = nil
            if readingRow == id { readingRow = nil }
            if let held, held.id == id {
                scheduleRestore(held)
            }
        }
    }

    func slideRoom(in rows: [String], later: Bool) -> Int {
        let visible = rowFrames.filter { $0.value.maxY > 0 && $0.value.minY < viewportHeight }.keys
        let indices = rows.enumerated().filter { visible.contains($0.element) }.map(\.offset)
        guard let first = indices.min(), let last = indices.max() else { return 0 }
        let margin = 4
        return max(0, later ? first - margin : rows.count - 1 - last - margin)
    }

    func holdPlace(_ label: String) {
        if let anchor {
            hold(anchor, label: label)
            scheduleRestore(anchor, after: 0.05)
        } else {
            #if DEBUG
            TranscriptHoldTrace.note("hold \(label) without an anchor")
            #endif
            release()
        }
    }

    private func askLater() {
        guard active, readingEarlier != true, hasHiddenLaterRows, !followingEnd, held == nil, !readerIsScrolling, viewportHeight > 0,
              distanceFromBottom < viewportHeight * Self.reach,
              Date() >= slideQuietUntil, anchor != nil, let revealLater else { return }
        guard canPage?() != false else {
            settleAfterQuiet()
            return
        }
        slideQuietUntil = Date().addingTimeInterval(Self.slideQuiet)
        revealLater()
    }

    func placeHeldPage() {
        guard active, heldIsPage, let held, !followingEnd, canRestore?() != false else { return }
        #if DEBUG
        MainActor.assumeIsolated { TranscriptHoldTrace.shared.corrected("place") }
        #endif
        restore?(target(for: held))
    }

    private func scheduleRestore(_ anchor: TranscriptAnchor, after delay: TimeInterval = 0) {
        restoreDelivery.submit(after: delay) { [weak self] in
            guard let self, !self.followingEnd, !(self.readerIsScrolling && self.heldLanded),
                  self.held?.id == anchor.id, Date() <= self.heldUntil else { return }
            guard self.canRestore?() != false else {
                self.scheduleRestore(anchor, after: 0.08)
                return
            }
            self.rehome()
            guard let anchor = self.held else { return }
            let target = self.target(for: anchor)
            if let frame = self.rowFrames[anchor.id], abs(target.drift(to: frame)) <= Self.holdSlack {
                if frame != self.armedFrame || self.correctedFrom != nil {
                    self.heldLanded = true
                }
                return
            }
            let frame = self.rowFrames[anchor.id]
            guard self.spendCorrection(resized: frame.map { self.heldResized($0) } ?? false) else { return }
            self.correctedFrom = frame
            #if DEBUG
            MainActor.assumeIsolated { TranscriptHoldTrace.shared.corrected("late") }
            #endif
            self.coveredLayoutMoved()
            if let frame, self.restoreMeasured?(target.drift(to: frame)) == true { return }
            self.restore?(target)
            if frame == nil {
                self.scheduleRestore(anchor, after: 0.08)
            }
        }
    }

    private func updateNearTop(_ metrics: TranscriptMetrics) {
        guard canAskEarlier || hasHiddenEarlierRows, metrics.viewportHeight > 0 else {
            setNearTop(false)
            return
        }
        if nearTop {
            setNearTop(metrics.distanceFromTop < metrics.viewportHeight * Self.measureUntil)
        } else {
            setNearTop(metrics.distanceFromTop < metrics.viewportHeight * Self.measureFrom)
        }
    }

    private func setNearTop(_ value: Bool) {
        guard nearTop != value else { return }
        nearTop = value
        if !value, !Self.rowsReportThemselves { rowFrames = [:] }
        nearTopChanged?(value)
    }

    var wantsEarlier: Bool {
        !followingEnd
            && viewportHeight > 0
            && distanceFromTop < viewportHeight * Self.reach
            && anchor != nil
    }

    func ask() {
        guard active, !fetching, readingEarlier != false, wantsEarlier,
              held == nil, !readerIsScrolling else { return }
        guard canPage?() != false else {
            settleAfterQuiet()
            return
        }
        if hasHiddenEarlierRows {
            guard Date() >= slideQuietUntil, let revealEarlier else { return }
            slideQuietUntil = Date().addingTimeInterval(Self.slideQuiet)
            revealEarlier()
            return
        }
        if canAskEarlier { requestArchivePage(manual: false) }
    }

    func requestArchivePage(manual: Bool = true) {
        guard active, !fetching, let requestEarlier else {
            #if DEBUG
            TranscriptHoldTrace.note("earlier blocked active=\(active) fetching=\(fetching) request=\(requestEarlier != nil) manual=\(manual)")
            #endif
            return
        }
        fetching = true
        requestEarlier(manual)
    }

    private static let slideQuiet: TimeInterval = 0.3

    var anchor: TranscriptAnchor? {
        TranscriptAnchor.pick(rowFrames, viewportHeight: viewportHeight)
    }
}

/// What the top of a transcript says about what is before it.
///
/// Three states and no spinner that never resolves: there is more and it can
/// be asked for, more is on its way, or this is where the conversation
/// begins. The last of those only appears once somebody has actually read
/// back to it, because announcing the start of a short chat is announcing
/// that it is short.
struct TranscriptEarlierHeader: View {
    let model: ChatModel
    let load: () -> Void

    private static let height: CGFloat = 30

    var body: some View {
        if model.hasEarlier {
            HStack(spacing: Theme.Space.s) {
                if model.loadingEarlier {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("apple.transcriptfollow.loading_earlier_messages.41311657"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(L10n.text("apple.transcriptfollow.earlier_messages.561a197a"), .history, action: load)
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            }
            .frame(minHeight: Self.height)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel(L10n.text("apple.transcriptfollow.load_earlier_messages.33fd46b9"))
        } else if model.reachedStart {
            HStack(spacing: Theme.Space.s) {
                ThemeRule()
                Text(model.historyTrimmed ? L10n.text("apple.transcriptfollow.earlier_messages_are_no_longer_available.aae6a081") : L10n.text("apple.transcriptfollow.start_of_chat.a7e744bb"))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                ThemeRule()
            }
            .frame(minHeight: Self.height)
        }
    }
}

struct TranscriptRowFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        let next = nextValue()
        if value.isEmpty {
            value = next
        } else {
            value.merge(next) { _, next in next }
        }
    }
}

extension View {
    /// Report where this row is, while the boundary is near enough that one
    /// of them may have to hold the reader's place.
    ///
    /// A lazy stack only builds what is near the screen, so this runs for
    /// what is visible rather than for the window, and `nearTop` keeps even
    /// that off for the rest of a long conversation.
    ///
    /// It has to be the visible rows. Restricting it to the first rows of the
    /// *window* looks cheaper and is how the app came to hang: those rows are
    /// screens above the viewport, so the anchor became a row far away, and
    /// `scrollTo` on a lazy stack costs a walk over every item in between.
    /// Ten corrections per page of that is a stopped application.
    func transcriptRowFrame(_ id: String, watched: Bool) -> some View {
        background {
            if watched {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TranscriptRowFrameKey.self,
                        value: [id: geo.frame(in: .named(TranscriptFollow.spaceName))]
                    )
                }
            }
        }
    }

    func transcriptEarlierPages(
        _ model: ChatModel,
        window: TranscriptWindow,
        proxy: ScrollViewProxy,
        isActive: Bool,
        hiddenEarlierRows: Int = 0,
        hiddenLaterRows: Int = 0,
        revealEarlier: (() -> Void)? = nil,
        revealLater: (() -> Void)? = nil,
        holdSliceStart: ((Bool) -> Void)? = nil
    ) -> some View {
        let request: (Bool) -> Void = { [weak window] manual in
            guard let window else { return }
            Task { await loadEarlier(model, window: window, manual: manual) }
        }
        let restore: (TranscriptAnchor) -> Void = { [weak window] anchor in
            guard let window else { return }
            #if DEBUG
            TranscriptProbe.shared.noteScroll("restore")
            #endif
            func scroll() {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(anchor.id, anchor: anchor.unitPoint(in: window.viewportHeight))
                }
            }
            if window.prepareScroll?(anchor.id) == false {
                DispatchQueue.main.async { scroll() }
            } else {
                scroll()
            }
        }
        let extendedAtStart: (String) -> Bool = { [weak model] id in model?.rowExtendedAtStart(id) == true }
        let resolveRow: (String) -> String? = { [weak model] id in model?.transcriptRow(holding: id) }
        if isActive {
            window.restore = restore
        }
        return onPreferenceChange(TranscriptRowFrameKey.self) { frames in
            guard !TranscriptWindow.rowsReportThemselves else { return }
            window.rowFrames = frames
        }
        .onAppear {
            window.mounts += 1
            window.active = isActive
            window.hasHiddenEarlierRows = hiddenEarlierRows > 0
            window.hasHiddenLaterRows = hiddenLaterRows > 0
            window.requestEarlier = request
            window.restore = restore
            window.revealEarlier = revealEarlier
            window.revealLater = revealLater
            window.holdSliceStart = holdSliceStart
            window.extendedAtStart = extendedAtStart
            window.resolveRow = resolveRow
        }
        .onChange(of: isActive) { _, active in
            window.active = active
        }
        .onDisappear {
            window.mounts -= 1
            guard window.mounts <= 0 else { return }
            window.mounts = 0
            window.active = false
            window.revealEarlier = nil
            window.revealLater = nil
            window.holdSliceStart = nil
        }
        .onChange(of: model.selectionGeneration) { _, _ in
            window.release()
            window.readingEarlier = nil
            window.fetching = false
            window.hasHiddenEarlierRows = hiddenEarlierRows > 0
            window.hasHiddenLaterRows = hiddenLaterRows > 0
            window.requestEarlier = request
            window.restore = restore
            window.revealEarlier = revealEarlier
            window.revealLater = revealLater
            window.holdSliceStart = holdSliceStart
        }
        .onChange(of: model.hasEarlier, initial: true) { _, more in
            window.canAskEarlier = more
            guard more else { return }
            window.ask()
        }
        .onChange(of: hiddenEarlierRows, initial: true) { _, count in
            window.hasHiddenEarlierRows = count > 0
        }
        .onChange(of: hiddenLaterRows, initial: true) { _, count in
            window.hasHiddenLaterRows = count > 0
        }
    }
}

@MainActor
func loadEarlier(_ model: ChatModel, window: TranscriptWindow, manual: Bool) async {
    let generation = model.selectionGeneration
    guard window.active, model.hasEarlier else {
        window.fetching = false
        return
    }
    let before = model.displayItems.count
    let waitToPrepend: (() async -> Bool)? = window.canPage.map { canPage in
        {
            while !Task.isCancelled, window.active, model.selectionGeneration == generation {
                if canPage() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
    }
    var published = false
    let advanced = await model.loadEarlier(waitToPrepend: waitToPrepend) {
        published = true
        if window.active, let anchor = window.anchor {
            window.hold(anchor)
            window.coverPageLanding()
        } else {
            window.release()
        }
        if window.active { window.holdSliceStart?(true) }
    } afterPrepend: {
        window.placeHeldPage()
    }
    guard model.selectionGeneration == generation else { return }
    if published { window.holdSliceStart?(false) }
    if model.displayItems.count > max(before, TranscriptSlice.length) {
        window.hasHiddenEarlierRows = true
    }
    window.fetching = false
    window.canAskEarlier = model.hasEarlier
    if advanced, !published {
        window.release()
        if manual, model.hasEarlier { window.requestArchivePage() } else { window.ask() }
    }
}
