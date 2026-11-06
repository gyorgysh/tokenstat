// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct StreamingWordAttribute: TextAttribute {
    let index: Int

    static func text(_ value: AttributedString, next: inout Int) -> Text {
        var result = Text("")
        let characters = value.characters
        var start = characters.startIndex
        while start < characters.endIndex {
            let whitespace = characters[start].isWhitespace
            var end = characters.index(after: start)
            while end < characters.endIndex, characters[end].isWhitespace == whitespace {
                end = characters.index(after: end)
            }
            let part = AttributedString(value[start..<end])
            let text = MarkdownLinks.text(part)
            let excluded = whitespace || part.runs.contains { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }
            if excluded {
                result = result + text
            } else {
                result = result + text.customAttribute(StreamingWordAttribute(index: next))
                next += 1
            }
            start = end
        }
        return result
    }
}

/// Opacity changes only in drawing: text, layout and stored messages stay intact.
struct StreamingText: View {
    let text: Text
    let live: Bool
    let arrivals: [Int: TimeInterval]
    let revision: Int
    @AppStorage("chat.smoothStreaming") private var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if #available(macOS 15, iOS 18, *), live && enabled && !reduceMotion {
            StreamingWordText(text: text, arrivals: arrivals, revision: revision)
        } else {
            text
        }
    }
}

@available(macOS 15, iOS 18, *)
private struct StreamingWordText: View {
    let text: Text
    let arrivals: [Int: TimeInterval]
    let revision: Int
    @State private var animating = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animating)) { _ in
            text.textRenderer(StreamingWordRenderer(arrivals: arrivals, now: ProcessInfo.processInfo.systemUptime))
        }
        .task(id: revision) {
            animating = !arrivals.isEmpty
            guard animating else { return }
            try? await Task.sleep(for: .seconds(StreamingWordArrivals.duration))
            guard !Task.isCancelled else { return }
            animating = false
        }
    }
}

@available(macOS 15, iOS 18, *)
private struct StreamingWordRenderer: TextRenderer {
    let arrivals: [Int: TimeInterval]
    let now: TimeInterval

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            let fading = line.contains { run in
                guard let word = run[StreamingWordAttribute.self], let born = arrivals[word.index] else { return false }
                return now - born < StreamingWordArrivals.duration
            }
            guard fading else { context.draw(line); continue }
            for run in line {
                var ink = context
                if let word = run[StreamingWordAttribute.self], let born = arrivals[word.index] {
                    let progress = min(1, max(0, (now - born) / StreamingWordArrivals.duration))
                    ink.opacity *= 0.2 + 0.8 * (1 - pow(1 - progress, 3))
                }
                ink.draw(run)
            }
        }
    }
}
