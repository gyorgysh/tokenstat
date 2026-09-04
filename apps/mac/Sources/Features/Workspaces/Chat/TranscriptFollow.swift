// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// How a transcript stays with the latest turn without chasing every token.
///
/// Structural changes (a new row, thinking becoming working, the live seat
/// arriving or leaving) may ease the viewport to the bottom. Streamed text
/// grows in place and the pin is silent, because animating that pin is what
/// made the live character look like it was travelling.
enum TranscriptFollow {
    static let spaceName = "chat-scroll"
    /// How far from the bottom counts as "still with the conversation".
    static let threshold: CGFloat = 56
    /// The live Thinking/Working seat. Fixed so a mood change cannot shove
    /// the rest of the transcript.
    static let seatHeight: CGFloat = 34
    static let bottomID = "chat-bottom"
    static let structureDuration: Double = 0.14

    /// Identity of the rows, not the length of the text inside them.
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

    /// What the live seat's character is doing.
    ///
    /// One function for both transcripts, because a chat on the Mac and the
    /// same chat on a phone should not disagree about whether the agent is
    /// thinking or already answering. Streaming prose is `.speaking`, not
    /// `.thinking`: the difference is the whole reason the seat has a face on
    /// it rather than a spinner.
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

    /// Growing prose. Used to pin without animation.
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

/// Where a transcript is scrolled to, in the one shape everything that cares
/// about it reads.
///
/// Two routes produce it and they have to agree. `onScrollGeometryChange`
/// answers exactly, on every frame, without a view update. Older systems have
/// no such call and measure it with a geometry reader and a preference, which
/// is what this always did and what costs a view update per frame.
struct TranscriptMetrics: Equatable {
    /// How far the top of the loaded conversation is above the viewport.
    /// Large at the bottom of a long chat, zero at the very beginning.
    var distanceFromTop: CGFloat
    /// How far the end is below it. Zero means the reader is with the latest
    /// turn.
    var distanceFromBottom: CGFloat
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
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
/// that did not change, with a larger gap, is a person moving away.
///
/// A reference type, and `showJump`, `paused` and `arrived` are the only
/// things on it Observation watches: all three change on transitions, never
/// per frame. Everything else here is written on every frame of every scroll,
/// and a transcript that redraws itself that often is a transcript nobody can
/// scroll. The redraw is owed to the button appearing, not to the offset
/// moving by a point.
@Observable
final class TranscriptFollowState {
    private(set) var showJump = false
    /// Paused by hand from the Following pill. Unlike an unpin from a scroll,
    /// this survives arriving at the bottom on a streaming frame: only coming
    /// back to the latest turn with a scroll of one's own, or pressing Follow
    /// again, clears it. Observed (rare transitions only, never per-frame).
    private(set) var paused = false
    @ObservationIgnored var pinned = true
    @ObservationIgnored var suppressed = false {
        didSet { if suppressed { set(jump: false) } }
    }
    /// Our own scrolls are in flight until this date. An animated pin travels
    /// through frames that look exactly like a reader leaving (far from the
    /// end, offset moving), and without this the pin unpinned itself midway.
    /// Written on scroll calls only, read on every scroll callback: ignored.
    @ObservationIgnored private var programmaticUntil: Date = .distantPast
    /// A conversation that has just opened is still finding its real heights,
    /// and every one of those frames says the end is far below. Taking that
    /// as a reader who scrolled away is what left a long chat open in its
    /// middle: the first estimate unpinned the view, and the settle that was
    /// meant to correct it stopped because the view was no longer pinned.
    @ObservationIgnored private(set) var settling = false
    /// Whether the transcript has actually reached the latest turn.
    ///
    /// A lazy stack builds from the top and finds its real height as it goes,
    /// so an opening conversation is visibly assembled and then yanked to the
    /// end. The transcript stays behind its wireframe until this turns true,
    /// which is the difference between watching that happen and arriving
    /// where the reading is.
    private(set) var arrived = false
    /// Put the viewport back on the end. Installed by the transcript, which
    /// is the only thing holding a scroll proxy.
    ///
    /// Called from the scroll callback rather than from a view update,
    /// because the growth this answers is a lazy row finding its real height
    /// and no view update is owed for that. Without it the pin was only ever
    /// applied when a row arrived or a stream grew, and everything else that
    /// changes a transcript's height (rows measuring themselves, a page the
    /// opening backfill was still fetching, an image decoding) left the
    /// viewport wherever it happened to be.
    @ObservationIgnored var repin: (() -> Void)?
    @ObservationIgnored private var lastContentHeight: CGFloat = 0
    @ObservationIgnored private var lastOffset: CGFloat = 0
    @ObservationIgnored private var lastDistanceFromBottom: CGFloat = 0
    /// Offset drift outside our own scrolls, accumulated across frames. Scroll
    /// callbacks run per frame, so a slow reading scroll moves less than the
    /// per-frame `moved` epsilon every frame and would otherwise read as
    /// stationary forever. Our own pins reset this (they move the viewport a
    /// lot and must never count as the reader leaving).
    @ObservationIgnored private var undrivenDrift: CGFloat = 0
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
    /// Whether the last frame put the end under the viewport.
    ///
    /// Read by the loops that hold the end while a conversation opens. One
    /// scroll to the end of a lazy stack is a walk over every row in between,
    /// so spending forty of them on a transcript that is already there is
    /// most of what made opening a long chat a hang.
    @ObservationIgnored private(set) var atEnd = false
    /// Somebody scrolled away while the end was being chased. Read by the
    /// chase, which stops rather than argue.
    @ObservationIgnored private(set) var abandoned = false

    /// Hold the end while the transcript settles, whatever the geometry of a
    /// half-measured lazy stack claims.
    ///
    /// Leaving the settle always reveals, whether the end was reached or the
    /// frames simply ran out. A wireframe that can outlast its content is
    /// worse than the build-up it hides.
    func settle(_ active: Bool) {
        chase(active)
        set(arrived: !active)
    }

    /// Hold the end without hiding anything.
    ///
    /// What `settle` does minus the wireframe. An opening conversation has
    /// nothing worth looking at yet; a press of Jump to latest has the
    /// conversation on screen already and only needs the end to be reached.
    /// It needs the same insistence, though: one scroll to the end of a lazy
    /// stack from far above it lands on estimated heights, builds rows on the
    /// way that correct those estimates, and stops short. That is why the
    /// button took several presses.
    func chase(_ active: Bool) {
        settling = active
        steadyFrames = 0
        abandoned = false
        repinsSpent = 0
        undrivenDrift = 0
        if active {
            paused = false
            pinned = true
            set(jump: false)
        }
    }

    /// Mark that a scroll about to happen is ours, not the reader's.
    ///
    /// Called beside every programmatic `scrollTo` (pins, repins, jump
    /// chases, approval jumps). The animation lands within a few frames;
    /// anything inside the window that shrinks the gap to the end is the
    /// arrival, not a departure.
    func markDriven() {
        programmaticUntil = Date().addingTimeInterval(0.4)
    }

    /// Whether the end is under the viewport *and* the content has stopped
    /// changing size.
    ///
    /// Both halves matter. A half-measured lazy stack reports a content
    /// height it has estimated, so "distance from the bottom is zero" can be
    /// true of a transcript with most of its rows still unmeasured, and
    /// believing it is how the conversation was revealed in its middle.
    @ObservationIgnored private(set) var steadyFrames = 0

    func note(_ metrics: TranscriptMetrics) {
        let grew = metrics.contentHeight > lastContentHeight + 0.5
        let shrank = metrics.contentHeight < lastContentHeight - 0.5
        let moved = abs(metrics.distanceFromTop - lastOffset) > 0.5

        if settling {
            // Moving away from the end, on a frame where nothing grew, is a
            // hand on the trackpad. Nothing here may out-argue that: the
            // chase after Jump to latest would otherwise drag somebody back
            // for the length of its budget.
            let retreated = moved
                && !grew
                && !shrank
                && metrics.distanceFromBottom > lastDistanceFromBottom + 8
            lastContentHeight = metrics.contentHeight
            lastOffset = metrics.distanceFromTop
            lastDistanceFromBottom = metrics.distanceFromBottom
            if retreated {
                abandoned = true
                set(jump: false)
                return
            }
            atEnd = metrics.contentHeight > 0
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
        atEnd = metrics.contentHeight > 0
            && metrics.distanceFromBottom <= TranscriptFollow.threshold
        guard metrics.viewportHeight > 0, metrics.contentHeight > 0 else { return }
        // Content that grew where nobody scrolled is a turn arriving, and it
        // must not unpin the view. Content that grew while the offset also
        // moved is a lazy row finding its real height under a reader who is
        // scrolling, and that frame still says where they are.
        lastContentHeight = metrics.contentHeight
        lastOffset = metrics.distanceFromTop
        if driven {
            undrivenDrift = 0
        } else if moved {
            undrivenDrift += abs(metrics.distanceFromTop - prevOffset)
        }
        if grew, !moved {
            // Growth nobody scrolled for. It must not unpin the view, and if
            // the view was following the end it has to be put back on it:
            // the height changed under a viewport that did not move, so the
            // end is now further down than it was a frame ago.
            //
            // Auto-follow is the default: streaming grows this way for
            // hundreds of frames, and unpinning here is what stalled a reply
            // mid-screen. Only a person's own scroll below may unpin. The
            // budget only stops asking the lazy stack for another walk,
            // never the pin itself.
            if pinned, metrics.distanceFromBottom > TranscriptFollow.threshold {
                guard repinsSpent < Self.repinBudget else { return }
                repinsSpent += 1
                markDriven()
                repin?()
            } else if !pinned,
                metrics.distanceFromBottom > TranscriptFollow.threshold
            {
                // Drifted away while not following (paused, or a page that
                // landed above): offer the way back.
                set(jump: true)
            }
            return
        }
        let retreating = metrics.distanceFromBottom > prevBottom + 2
        if metrics.distanceFromBottom > TranscriptFollow.threshold {
            // Far from the end. Unpinning takes a moved viewport: only the
            // reader's own scroll proves a hand leaving. Stationary far
            // frames must hold, because the lazy stack routinely parks here
            // on its own: a repin that landed on estimated heights, or a
            // streaming stall longer than the driven window, both sit far
            // with nobody touching anything. Unpinning those is what flipped
            // Following to Jump to latest mid-reply and then never came back,
            // since every later pin is guarded on the pin this cleared.
            // (A pin arriving reads as moved + shrinking inside its own
            // window, so it still cannot unpin itself; a grab mid-flight
            // reads as retreating and still wins immediately. And because
            // callbacks run per frame, a slow scroll that never clears the
            // per-frame epsilon still counts once its drift adds up.)
            let userMoved = moved || undrivenDrift > 6
            if userMoved, !driven || retreating {
                pinned = false
                undrivenDrift = 0
                set(jump: true)
            }
        } else if metrics.distanceFromBottom <= 10 {
            // Back on the latest turn with a scroll of one's own: follow
            // again, clearing a manual pause. A stationary paused frame must
            // not resume itself, or pausing at the bottom could never stick.
            // Home also clears the drift tab: micro-scrolls from a while ago
            // must not unpin a far frame later.
            undrivenDrift = 0
            if moved {
                paused = false
            }
            if !paused {
                pinned = true
                undrivenDrift = 0
                set(jump: false)
            }
        }
        if metrics.distanceFromBottom <= TranscriptFollow.threshold {
            // The end is under the viewport, so whatever was spent getting
            // here worked. This is the only thing that refills the budget,
            // which is what tells a productive repin from a futile one.
            repinsSpent = 0
        }
    }

    func jump() {
        paused = false
        pinned = true
        repinsSpent = 0
        undrivenDrift = 0
        markDriven()
        set(jump: false)
    }

    /// Stop following by hand, from the Following pill.
    ///
    /// The button state is left alone: if the end drifts away the scroll
    /// callback offers Jump to latest on its own, and if the reader is
    /// already on it the pill flips to Follow so there is always a way back.
    func pause() {
        paused = true
        pinned = false
        undrivenDrift = 0
    }

    /// Observation does not compare before it notifies, so writing the same
    /// value back would invalidate the transcript on every frame of a scroll.
    private func set(jump value: Bool) {
        guard showJump != value else { return }
        showJump = value
    }

    private func set(arrived value: Bool) {
        guard arrived != value else { return }
        arrived = value
    }

    /// How many repins may go by without the end being reached.
    ///
    /// Enough that an insertion settling over three or four frames is
    /// followed properly, small enough that a stack which will not converge
    /// costs a handful of walks rather than a minute and a half.
    private static let repinBudget = 6

    /// Frames at the end, with the content size unchanged, before a
    /// transcript counts as arrived. Three at a sixtieth each is imperceptible
    /// and is the difference between an estimate and a measurement.
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

struct TranscriptBottomSentinel: View {
    var body: some View {
        Color.clear
            .frame(height: 1)
            .id(TranscriptFollow.bottomID)
    }
}

/// What a transcript shows while it is finding its end.
///
/// Shaped like a conversation rather than a spinner: turns alternating sides,
/// a couple of tool rows between them, weighted to the bottom because that is
/// where the reading starts. It is over in a few frames, and its job is that
/// those frames look like the thing that is about to appear.
struct TranscriptSkeleton: View {
    /// Roughly how tall each stand-in turn is, in bars.
    private static let turns: [(mine: Bool, lines: Int)] = [
        (false, 3), (true, 1), (false, 4), (true, 2), (false, 2),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Spacer(minLength: 0)
            ForEach(Array(Self.turns.enumerated()), id: \.offset) { index, turn in
                HStack(spacing: 0) {
                    if turn.mine { Spacer(minLength: 48) }
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(0..<turn.lines, id: \.self) { line in
                            Skeleton.Bar(
                                width: nil,
                                height: 10,
                                phase: Double(index) * 0.09 + Double(line) * 0.04
                            )
                            .frame(maxWidth: width(index: index, line: line), alignment: .leading)
                        }
                    }
                    .padding(Theme.Space.m)
                    .background(
                        turn.mine ? Theme.accentSoft : Theme.panel.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    if !turn.mine { Spacer(minLength: 48) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.vertical, Theme.Space.xl)
        .padding(.horizontal, Theme.Space.l)
        .accessibilityLabel("Loading the conversation")
        .allowsHitTesting(false)
    }

    /// Ragged, so it reads as prose rather than as a progress bar.
    private func width(index: Int, line: Int) -> CGFloat {
        let widths: [CGFloat] = [420, 360, 290, 240, 330]
        return widths[(index * 2 + line) % widths.count]
    }
}

/// The follow control at the bottom of a transcript: three states, one seat.
///
/// - Scrolled away: a solid **Jump to latest** that chases the end.
/// - Following a live turn: a quiet **Following** pill. It is the lock the
///   transcript was missing: pressing it pauses, pressing Follow resumes.
/// - Paused while live: an outlined **Follow** so there is always a way back
///   without scrolling.
/// - Idle and pinned: nothing. A control nobody needs is clutter, not state.
struct TranscriptFollowPill: View {
    var showJump: Bool
    var busy: Bool
    var paused: Bool
    var resume: () -> Void
    var pause: () -> Void

    var body: some View {
        Group {
            if showJump {
                Button("Jump to latest", .next, action: resume)
                    .buttonStyle(AccentButtonStyle(small: true))
            } else if busy, paused {
                Button(action: resume) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                        Text("Follow")
                    }
                    .font(Theme.caption.weight(.medium))
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .help("Follow new responses as they arrive")
            } else if busy {
                Button(action: pause) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Following")
                    }
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .help("Pause auto-follow")
            }
        }
        .padding(.bottom, Theme.Space.m)
        .animation(.easeOut(duration: 0.15), value: showJump)
    }
}

/// Report where the transcript is scrolled, by whichever route this system
/// offers, and name the space its rows measure themselves in.
private struct TranscriptScrollMetrics: ViewModifier {
    let note: (TranscriptMetrics) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            content
                .coordinateSpace(name: TranscriptFollow.spaceName)
                .onScrollGeometryChange(for: TranscriptMetrics.self) { geometry in
                    TranscriptMetrics(geometry)
                } action: { _, metrics in
                    note(metrics)
                }
        } else {
            content.modifier(LegacyTranscriptScrollMetrics(note: note))
        }
    }
}

/// The same answer on a system with no `onScrollGeometryChange`.
///
/// The two halves arrive as separate preferences and have to be held until
/// both are known. They are held in a plain object rather than in `@State`,
/// because a scroll offset is not something the transcript draws and writing
/// it into view state redraws the whole conversation once per frame.
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
    /// Measure the transcript content, for systems that need it measured.
    ///
    /// A geometry reader in the background of a scrolling stack runs on every
    /// frame, so on a system that can simply be asked where it is this adds
    /// nothing.
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

    /// Follow the transcript's scroll position.
    func chatScrollMetrics(_ note: @escaping (TranscriptMetrics) -> Void) -> some View {
        modifier(TranscriptScrollMetrics(note: note))
    }

}


/// How a transcript keeps the reader's place while older pages arrive above
/// them.
///
/// A conversation opens on its newest page, so everything before it is
/// fetched as the reader moves towards the top. Content added above the
/// viewport pushes what is on screen downwards, which is a jump on the one
/// gesture this feature exists to make smooth. The answer is to note where a
/// row near the top of the viewport is before the page arrives, and put it
/// back exactly there afterwards.
///
/// Nothing on this object is observed and nothing on it is drawn. It is
/// written on every frame of a scroll, and the decision it makes has to be
/// made from the scroll callback itself: a transcript that must redraw before
/// it can notice where it is will not notice in time, which is how the top of
/// a conversation used to arrive with nothing loading.
final class TranscriptWindow {
    var viewportHeight: CGFloat = 0
    /// How far the top of the loaded conversation is above the viewport.
    /// Large at the bottom of a long chat, zero at the very beginning.
    var distanceFromTop: CGFloat = .greatestFiniteMagnitude
    /// Where the rows are, in the viewport's own coordinates.
    ///
    /// Every row reports, and that is cheap for the reason the stack is lazy:
    /// a row that is not on screen has no body, so it has no geometry reader
    /// either. What arrives here is roughly what is visible, which is also
    /// exactly the set the anchor has to come from. Watching the first two
    /// dozen rows of the *window* instead looked cheaper and was worse: once
    /// the reader was a screen below them those rows were not being built, so
    /// this held whatever they last reported, and the anchor was computed
    /// from where rows used to be.
    var rowFrames: [String: CGRect] = [:] {
        didSet { rowFramesStamp &+= 1 }
    }
    /// Bumped every time the rows report. The drift check below is only
    /// honest once something has been reported since the hold was armed:
    /// `rowFrames` is filled by a view update, and the frame that inserts a
    /// page has not had one yet, so what it holds is where the row was
    /// *before* the insertion. Comparing the anchor against that reads the
    /// answer off the question, finds no drift, and skips the one correction
    /// the reader actually sees as a jump.
    private(set) var rowFramesStamp: UInt64 = 0
    /// A page has been asked for and the answer has not arrived. Claimed at
    /// the moment of asking rather than when the request starts, so a scroll
    /// across the boundary asks once instead of once per frame.
    var fetching = false
    /// Whether the conversation has anything before what is held. Kept in
    /// step with the model, so resting at the beginning of a chat does not
    /// start a request per frame only to have it answer that there is
    /// nothing to fetch.
    var canAskEarlier = false
    /// Whether the transcript is holding the latest turn: pinned to the end,
    /// or still settling onto it after opening.
    ///
    /// Nothing is fetched and nothing is restored in that state, and that is
    /// what stops a conversation opening in its middle. A half-measured lazy
    /// stack reports an estimated content height, which says the top of what
    /// is loaded is close, which is all `wantsEarlier` needs. The page then
    /// lands with an anchor to put back, and putting it back is a scroll away
    /// from the end, argued against by the settle scrolling towards it. The
    /// reader was shown the middle of the conversation with Jump to latest
    /// over it, and the window kept growing while the two sides argued, until
    /// a scroll to the end cost the stack a walk over thousands of rows and
    /// the application stopped.
    ///
    /// A reader at the end is not reading backwards, so there is nothing to
    /// prefetch for them either. It turns off as soon as they leave the end,
    /// which is screens before the boundary comes near.
    var followingEnd = false
    /// Fetch the page before the oldest row held. Installed by the transcript,
    /// which is the only thing that holds a scroll proxy.
    var requestEarlier: (() -> Void)?
    /// Put a row back where it was. Installed beside `requestEarlier`.
    var restore: ((TranscriptAnchor) -> Void)?
    /// The row holding the reader's place across an insertion, and how many
    /// more changes of content height it should survive.
    ///
    /// One correction is not enough. The rows a page brings are inserted with
    /// estimated heights and measured over the next few frames, so a single
    /// restore lands on the geometry of a stack that is still settling, and
    /// what the reader sees is the correction being wrong by a little and
    /// staying wrong. Each frame that changes the height re-applies it, which
    /// costs nothing when the height is already right because the scroll is
    /// then a no-op.
    private var held: TranscriptAnchor?
    /// What the rows had reported when the hold was armed.
    private var heldStamp: UInt64 = 0
    private var heldFrames = 0
    private var heldUntil: Date = .distantPast
    private var lastContentHeight: CGFloat = 0

    /// Hold this row's place across the insertion that is about to happen.
    ///
    /// Claimed **before** the page is asked for, not after it lands. The
    /// scroll callback is what applies it, and the first height change the
    /// insertion causes is the one that matters: arming afterwards meant the
    /// first frame of the new content was drawn at the old offset, which is
    /// the jump, and the correction chased it from there.
    func hold(_ anchor: TranscriptAnchor) {
        held = anchor
        heldStamp = rowFramesStamp
        heldFrames = Self.holdFrames
        heldUntil = Date().addingTimeInterval(Self.holdSeconds)
    }

    /// Stop holding, for a page that changed nothing.
    func release() {
        held = nil
        heldFrames = 0
        heldUntil = .distantPast
    }

    /// How many height changes a held place survives. Prepended rows are
    /// inserted at estimated heights and measured over the frames that
    /// follow, so the place has to be put back on more than one of them.
    ///
    /// Small, because each one that fires is a programmatic scroll, and a
    /// programmatic scroll during a flick stops the flick. The frames that
    /// find the row already where it belongs cost nothing, so the budget only
    /// has to cover the ones that do not.
    private static let holdFrames = 6

    /// How far the held row may have drifted before it is worth moving.
    ///
    /// Nothing here is free: `scrollTo` sets the offset, and setting the
    /// offset under somebody's finger ends their scroll. A page that landed
    /// two points off is not worth stopping a gesture for, and after the
    /// first correction most frames are already right.
    private static let holdSlack: CGFloat = 3

    /// And how long, whether or not those frames were spent.
    ///
    /// An insertion often settles in two or three height changes, which
    /// leaves the rest of the budget sitting there. Without a deadline the
    /// next thing to change the height, a streamed reply at the bottom an
    /// hour later, would be taken for part of that page and put the reader
    /// back where a row was during a load that finished long ago.
    private static let holdSeconds: TimeInterval = 0.6

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

    /// How far from the top rows start reporting where they are, as a
    /// multiple of the viewport. Ahead of `reach`, so a frame exists to
    /// anchor on by the time a page is asked for, and with hysteresis so a
    /// reader hovering at the boundary does not switch it on and off.
    static let measureFrom: CGFloat = 4
    static let measureUntil: CGFloat = 6

    /// Above this many rows, coming back to the latest turn reopens the
    /// conversation instead of scrolling to it.
    ///
    /// `scrollTo` on a lazy stack costs a walk over every item between here
    /// and the target: SwiftUI has to resolve estimates for all of them. On a
    /// window grown by paging back, one scroll to the end is seconds, and the
    /// loop that makes the press land would spend that several times over.
    static let reopenAbove = 250

    // Throttle anchor math: scroll callbacks fire every frame, and the anchor
    // filter+suffix runs over up to 20 reported frames each time.
    private var lastAnchorCheck = Date.distantPast
    private var lastDistanceFromTopForAnchor: CGFloat = .greatestFiniteMagnitude

    /// Whether rows should be reporting where they are.
    ///
    /// A geometry reader per visible row is not free, and for most of a long
    /// conversation nothing is going to be anchored, so they are only
    /// attached as the boundary comes near. Told to the transcript rather
    /// than read from it, because this is decided in the scroll callback and
    /// a view update is owed only when the answer changes.
    private(set) var nearTop = false
    var nearTopChanged: ((Bool) -> Void)?

    func note(_ metrics: TranscriptMetrics) {
        viewportHeight = metrics.viewportHeight
        distanceFromTop = metrics.distanceFromTop
        updateNearTop(metrics)
        let changed = abs(metrics.contentHeight - lastContentHeight) > 0.5
        lastContentHeight = metrics.contentHeight
        // The end owns the viewport while it is being followed. Anything held
        // from before is dropped rather than applied against it.
        if followingEnd {
            release()
            return
        }
        if held != nil, Date() > heldUntil { release() }
        if let held, changed {
            heldFrames -= 1
            if heldFrames <= 0 { release() }
            // Where the row actually is now, when the rows have said so since
            // the hold was armed. Already reported, because it is one of the
            // rows on screen, so this costs a dictionary lookup rather than
            // another measurement.
            let reported = rowFramesStamp != heldStamp
            if !reported {
                // Nothing has reported since the hold was armed, so what the
                // frames hold is pre-insertion geometry and the first height
                // change IS the page landing: correct blind, once.
                restore?(held)
                // A frame spent putting the reader back is not a frame to
                // judge the boundary from: the offset it reports is the one
                // being corrected.
                return
            }
            // A missing frame means the anchor row isn't built right now:
            // the reader scrolled away from it or the lazy stack dropped it.
            // Scrolling it back on a stale offset is the yank that made long
            // chats impossible to read back, so hands off until it reports.
            guard let frame = rowFrames[held.id] else { return }
            if abs(frame.minY - held.top) > Self.holdSlack {
                restore?(held)
                // A frame spent putting the reader back is not a frame to
                // judge the boundary from: the offset it reports is the one
                // being corrected.
                return
            }
        }
        // Anchor evaluation is the only O(n) work here. Throttle it to every
        // second frame or when the viewport actually moved.
        let moved = abs(metrics.distanceFromTop - lastDistanceFromTopForAnchor) > 8
        let now = Date()
        let shouldEvaluate = moved || now.timeIntervalSince(lastAnchorCheck) > 0.032
        if shouldEvaluate {
            lastAnchorCheck = now
            lastDistanceFromTopForAnchor = metrics.distanceFromTop
            ask(force: false)
        }
    }

    private func updateNearTop(_ metrics: TranscriptMetrics) {
        guard canAskEarlier, metrics.viewportHeight > 0 else {
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
        // The readers go away with it, so what they last said has to go too.
        // A stale frame is an anchor pointing at a row that has since moved.
        if !value { rowFrames = [:] }
        nearTopChanged?(value)
    }

    /// Whether the page before the oldest row held should be asked for now.
    ///
    /// Near the top *and* holding a row that can be put back. Fetching
    /// earlier than that buys lead time and spends it on a lurch, because the
    /// page lands with nothing on screen to measure the correction against.
    var wantsEarlier: Bool {
        !followingEnd
            && viewportHeight > 0
            && distanceFromTop < viewportHeight * Self.reach
            && anchor != nil
    }

    /// Ask for the page before the oldest row held.
    ///
    /// `force` is the button at the top of the transcript, which asks whatever
    /// the geometry says.
    func ask(force: Bool) {
        guard canAskEarlier, !fetching, force || wantsEarlier, let requestEarlier else { return }
        fetching = true
        requestEarlier()
    }

    /// The row to hold still: the first one at or below the viewport's top
    /// edge, and failing that the last one above it.
    /// Nil when no row is on screen at or below the top of the viewport.
    ///
    /// A row above the viewport cannot be put back where it was.
    /// `scrollTo(_:anchor:)` can only line a row's own point up with the
    /// container's, so the furthest it can go is the row's top at the
    /// viewport's top: offset zero. A row that was two hundred points above
    /// the viewport gets clamped there, and the conversation lurches by two
    /// hundred points in the middle of the gesture this feature exists to
    /// keep smooth. Refusing to answer is the honest result, and
    /// `wantsEarlier` uses it to fetch only when the page can be absorbed.
    var anchor: TranscriptAnchor? {
        let below = rowFrames.filter { $0.value.minY >= -1 }
        guard let picked = below.min(by: { $0.value.minY < $1.value.minY }) else { return nil }
        return TranscriptAnchor(
            id: picked.key,
            top: picked.value.minY,
            height: picked.value.height
        )
    }
}

/// A row and where it was, so it can be put back.
struct TranscriptAnchor {
    let id: String
    /// Its top edge, measured from the top of the viewport.
    let top: CGFloat
    let height: CGFloat

    /// The unit point that puts this row's top back at `top`.
    ///
    /// `scrollTo(_:anchor:)` lines the item's point at fraction `t` up with
    /// the container's point at the same fraction. With an item of height `h`
    /// in a viewport of height `v`, that leaves the item's top at
    /// `t * (v - h)`, so the fraction that restores an offset of `top` is
    /// `top / (v - h)`. Clamped, because a row taller than the viewport has
    /// no fraction that satisfies it and the nearest edge is the honest
    /// answer.
    func unitPoint(in viewportHeight: CGFloat) -> UnitPoint {
        let room = max(viewportHeight - height, 1)
        return UnitPoint(x: 0, y: min(max(top / room, 0), 1))
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

    /// One height for all three states. A row at the top of the transcript
    /// that changes size as a page arrives moves everything below it, which
    /// is the jump the whole paging path exists to avoid.
    ///
    /// A floor rather than a fixed size, because the button inside it grows
    /// with the reader's text size and a fixed frame would clip its own
    /// label. What matters is that the three states agree, not the number.
    private static let height: CGFloat = 30

    var body: some View {
        if model.hasEarlier {
            HStack(spacing: Theme.Space.s) {
                if model.loadingEarlier {
                    ProgressView().controlSize(.small)
                    Text("Loading earlier messages")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Earlier messages", .history, action: load)
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            }
            .frame(minHeight: Self.height)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel("Load earlier messages")
        } else if model.reachedStart {
            HStack(spacing: Theme.Space.s) {
                ThemeRule()
                Text("Start of chat")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                ThemeRule()
            }
            .frame(minHeight: Self.height)
        }
    }
}

struct TranscriptRowFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        // One dict per frame after batching in the view layer, so this is a
        // single merge rather than one per row. Keep last writer wins.
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

    /// Fetch the page before the oldest row held as the top comes near, and
    /// put the reader back where they were once it lands.
    ///
    /// Nothing here animates, whatever Reduce Motion says. Sliding rows in
    /// above the viewport is the movement this exists to remove, and the
    /// correction that follows has to be the same frame as the insertion or
    /// the reader watches the conversation slide and come back.
    func transcriptEarlierPages(
        _ model: ChatModel,
        window: TranscriptWindow,
        proxy: ScrollViewProxy
    ) -> some View {
        let request: () -> Void = {
            Task { await loadEarlier(model, window: window) }
        }
        let restore: (TranscriptAnchor) -> Void = { anchor in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(anchor.id, anchor: anchor.unitPoint(in: window.viewportHeight))
            }
        }
        return onPreferenceChange(TranscriptRowFrameKey.self) { frames in
            window.rowFrames = frames
        }
        // The proxy belongs to this reader, so the closures that use it are
        // installed here and renewed whenever the conversation changes.
        .onAppear {
            window.requestEarlier = request
            window.restore = restore
        }
        .onChange(of: model.selected?.id) { _, _ in
            window.fetching = false
            window.requestEarlier = request
            window.restore = restore
        }
        .onChange(of: model.hasEarlier, initial: true) { _, more in
            window.canAskEarlier = more
            guard more else { return }
            window.ask(force: false)
        }
    }
}

/// Pull one older page and hold the reader's place across it.
///
/// The claim on `window.fetching` is made by whoever asked, and released
/// here, so the two paths into this (the scroll and the button) cannot run
/// side by side and write a spent cursor back.
@MainActor
func loadEarlier(_ model: ChatModel, window: TranscriptWindow) async {
    guard model.hasEarlier else {
        window.fetching = false
        return
    }
    let before = model.displayItems.count
    // Armed before the request, so the reader's place is already claimed when
    // the rows land. The scroll callback corrects on every frame the
    // insertion changes the height, including the first one.
    //
    // The automatic path only asks when there is an anchor. The button at the
    // top of the transcript asks whatever the geometry says, and if it says
    // nothing is on screen to hold, the page still has to arrive: pressing it
    // is somebody looking at the boundary, so the rows landing under their
    // eyes is the answer they asked for.
    if let anchor = window.anchor { window.hold(anchor) } else { window.release() }
    await model.loadEarlier()
    window.fetching = false
    guard model.displayItems.count > before else {
        // A page of records that folded into no new rows changes nothing on
        // screen, so no scroll and no growth will ask again on its own. Keep
        // walking, and stop where the archive does.
        window.release()
        window.ask(force: false)
        return
    }
}
