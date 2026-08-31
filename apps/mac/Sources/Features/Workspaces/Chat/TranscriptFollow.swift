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

/// Whether the viewport is still following the bottom.
///
/// Content growth and a person scrolling up both increase the distance from
/// the bottom. Growth is ignored so a stream cannot unpin the view. A height
/// that did not change, with a larger gap, is a person moving away.
struct TranscriptFollowState {
    var pinned = true
    var showJump = false
    var suppressed = false
    private var lastContentHeight: CGFloat = 0
    private var contentFrame = CGRect.zero
    private var viewportHeight: CGFloat = 0

    mutating func noteContent(_ frame: CGRect) {
        contentFrame = frame
        recompute()
    }

    mutating func noteViewport(height: CGFloat) {
        viewportHeight = height
        recompute()
    }

    mutating func jump() {
        pinned = true
        showJump = false
    }

    private mutating func recompute() {
        if suppressed {
            showJump = false
            return
        }
        let height = contentFrame.height
        guard viewportHeight > 0, height > 0 else { return }
        let distance = max(0, height + contentFrame.minY - viewportHeight)
        let grew = height > lastContentHeight + 0.5
        lastContentHeight = height
        if grew {
            return
        }
        if distance > TranscriptFollow.threshold {
            pinned = false
            showJump = true
        } else if distance <= 10 {
            pinned = true
            showJump = false
        }
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

extension View {
    /// Measure the transcript content in the named scroll space.
    func chatScrollContent() -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: ChatScrollContentKey.self,
                    value: geo.frame(in: .named(TranscriptFollow.spaceName))
                )
            }
        }
    }

    /// Name the scroll space and report the visible height.
    func chatScrollViewport() -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: ChatScrollViewportKey.self,
                    value: geo.size.height
                )
            }
        }
        .coordinateSpace(name: TranscriptFollow.spaceName)
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
struct TranscriptWindowState {
    var viewportHeight: CGFloat = 0
    /// How far the top of the loaded conversation is above the viewport.
    /// Large at the bottom of a long chat, zero at the very beginning.
    var distanceFromTop: CGFloat = .greatestFiniteMagnitude
    /// Where the first few rows are, in the viewport's own coordinates. Only
    /// the rows near the beginning are watched: they are the only ones that
    /// can be the anchor, and measuring every row of a transcript on every
    /// frame would be paying for the whole list to save a scroll position.
    var rowFrames: [String: CGRect] = [:]
    /// A page is being fetched by this view, as opposed to by the model on
    /// somebody else's behalf.
    var fetching = false

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

    mutating func note(content frame: CGRect) {
        distanceFromTop = -frame.minY
    }

    mutating func note(viewport height: CGFloat) {
        viewportHeight = height
    }

    /// Whether the page before the oldest row held should be asked for now.
    var wantsEarlier: Bool {
        viewportHeight > 0 && distanceFromTop < viewportHeight * Self.reach
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
        window: Binding<TranscriptWindowState>,
        proxy: ScrollViewProxy
    ) -> some View {
        onPreferenceChange(TranscriptRowFrameKey.self) { frames in
            window.wrappedValue.rowFrames = frames
        }
        .onChange(of: window.wrappedValue.distanceFromTop) { _, _ in
            // Tested here rather than inside, because this fires on every
            // frame of a scroll and starting a task per frame to find out
            // there is nothing to do is the expensive way to do nothing.
            guard model.hasEarlier, !window.wrappedValue.fetching,
                window.wrappedValue.wantsEarlier
            else { return }
            Task { await loadEarlier(model, window: window, proxy: proxy, force: false) }
        }
        .onChange(of: model.hasEarlier) { _, more in
            guard more else { return }
            Task { await loadEarlier(model, window: window, proxy: proxy, force: false) }
        }
    }
}

/// Ask for one older page and hold the reader's place across it.
///
/// `force` is the button at the top of the transcript, which asks whatever
/// the geometry says.
@MainActor
func loadEarlier(
    _ model: ChatModel,
    window: Binding<TranscriptWindowState>,
    proxy: ScrollViewProxy,
    force: Bool
) async {
    guard model.hasEarlier, !window.wrappedValue.fetching else { return }
    guard force || window.wrappedValue.wantsEarlier else { return }
    window.wrappedValue.fetching = true
    defer { window.wrappedValue.fetching = false }
    let anchor = window.wrappedValue.anchor
    let before = model.displayItems.count
    await model.loadEarlier()
    guard model.displayItems.count > before, let anchor else { return }
    // A frame for the prepended rows to be laid out in. Scrolling to a row
    // SwiftUI has not measured yet lands on the geometry it had before the
    // page arrived, which is the jump this is here to prevent.
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(16))
    let height = window.wrappedValue.viewportHeight
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
        proxy.scrollTo(anchor.id, anchor: anchor.unitPoint(in: height))
    }
}
