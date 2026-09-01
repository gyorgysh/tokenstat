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
/// A reference type, and `showJump` is the only thing on it Observation
/// watches. Everything here is written on every frame of every scroll, and a
/// transcript that redraws itself that often is a transcript nobody can
/// scroll. The redraw is owed to the button appearing, not to the offset
/// moving by a point.
@Observable
final class TranscriptFollowState {
    private(set) var showJump = false
    @ObservationIgnored var pinned = true
    @ObservationIgnored var suppressed = false {
        didSet { if suppressed { set(jump: false) } }
    }
    @ObservationIgnored private var lastContentHeight: CGFloat = 0
    @ObservationIgnored private var lastOffset: CGFloat = 0

    func note(_ metrics: TranscriptMetrics) {
        if suppressed {
            set(jump: false)
            return
        }
        guard metrics.viewportHeight > 0, metrics.contentHeight > 0 else { return }
        // Content that grew where nobody scrolled is a turn arriving, and it
        // must not unpin the view. Content that grew while the offset also
        // moved is a lazy row finding its real height under a reader who is
        // scrolling, and that frame still says where they are.
        let grew = metrics.contentHeight > lastContentHeight + 0.5
        let moved = abs(metrics.distanceFromTop - lastOffset) > 0.5
        lastContentHeight = metrics.contentHeight
        lastOffset = metrics.distanceFromTop
        if grew, !moved { return }
        if metrics.distanceFromBottom > TranscriptFollow.threshold {
            pinned = false
            set(jump: true)
        } else if metrics.distanceFromBottom <= 10 {
            pinned = true
            set(jump: false)
        }
    }

    func jump() {
        pinned = true
        set(jump: false)
    }

    /// Observation does not compare before it notifies, so writing the same
    /// value back would invalidate the transcript on every frame of a scroll.
    private func set(jump value: Bool) {
        guard showJump != value else { return }
        showJump = value
    }
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

struct JumpToLatestButton: View {
    var action: () -> Void

    var body: some View {
        Button("Jump to latest", .next, action: action)
            .buttonStyle(AccentButtonStyle(small: true))
            .padding(.bottom, Theme.Space.m)
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
    /// Where the first few rows are, in the viewport's own coordinates. Only
    /// the rows near the beginning are watched: they are the only ones that
    /// can be the anchor, and measuring every row of a transcript on every
    /// frame would be paying for the whole list to save a scroll position.
    var rowFrames: [String: CGRect] = [:]
    /// A page has been asked for and the answer has not arrived. Claimed at
    /// the moment of asking rather than when the request starts, so a scroll
    /// across the boundary asks once instead of once per frame.
    var fetching = false
    /// Whether the conversation has anything before what is held. Kept in
    /// step with the model, so resting at the beginning of a chat does not
    /// start a request per frame only to have it answer that there is
    /// nothing to fetch.
    var canAskEarlier = false
    /// Fetch the page before the oldest row held. Installed by the transcript,
    /// which is the only thing that holds a scroll proxy.
    var requestEarlier: (() -> Void)?

    /// How many rows at the beginning report where they are.
    ///
    /// Only these can be the anchor, and the anchor is only ever needed when
    /// the reader is near them. Measuring every row of a transcript on every
    /// frame would be paying for the whole list to save a scroll position.
    static let watched = 16

    /// How close to the top of what is loaded counts as approaching it.
    ///
    /// More than a screen, so the request usually finishes inside the scroll
    /// that asked for it and the reader never waits at a boundary.
    static let reach: CGFloat = 1.2

    func note(_ metrics: TranscriptMetrics) {
        viewportHeight = metrics.viewportHeight
        distanceFromTop = metrics.distanceFromTop
        ask(force: false)
    }

    /// Whether the page before the oldest row held should be asked for now.
    var wantsEarlier: Bool {
        viewportHeight > 0 && distanceFromTop < viewportHeight * Self.reach
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
    var anchor: TranscriptAnchor? {
        let below = rowFrames.filter { $0.value.minY >= -1 }
        let picked =
            below.min { $0.value.minY < $1.value.minY }
            ?? rowFrames.max { $0.value.minY < $1.value.minY }
        guard let picked else { return nil }
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
        }
    }
}

struct TranscriptRowFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}

extension View {
    /// Report where this row is, for the rows that could be the anchor.
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
            Task { await loadEarlier(model, window: window, proxy: proxy) }
        }
        return onPreferenceChange(TranscriptRowFrameKey.self) { frames in
            window.rowFrames = frames
        }
        // The proxy belongs to this reader, so the closure that uses it is
        // installed here and renewed whenever the conversation changes.
        .onAppear { window.requestEarlier = request }
        .onChange(of: model.selected?.id) { _, _ in
            window.fetching = false
            window.requestEarlier = request
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
func loadEarlier(_ model: ChatModel, window: TranscriptWindow, proxy: ScrollViewProxy) async {
    guard model.hasEarlier else {
        window.fetching = false
        return
    }
    let anchor = window.anchor
    let before = model.displayItems.count
    await model.loadEarlier()
    window.fetching = false
    guard model.displayItems.count > before, let anchor else {
        // A page of records that folded into no new rows changes nothing on
        // screen, so no scroll and no growth will ask again on its own. Keep
        // walking, and stop where the archive does.
        window.ask(force: false)
        return
    }
    // A frame for the prepended rows to be laid out in. Scrolling to a row
    // SwiftUI has not measured yet lands on the geometry it had before the
    // page arrived, which is the jump this is here to prevent.
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(16))
    let height = window.viewportHeight
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
        proxy.scrollTo(anchor.id, anchor: anchor.unitPoint(in: height))
    }
}
