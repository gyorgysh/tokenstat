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
