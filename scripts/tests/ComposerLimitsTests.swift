// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ComposerLimits.swift using swiftc -parse-as-library, then run.
import Foundation

@main
struct ComposerLimitsTests {
    struct Window: Equatable {
        var label: String
        var percent: Double
        var scope: String? = nil
    }

    struct Provider: Equatable {
        var source: String
        var windows: [Window]
    }

    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func canonical(_ id: String) -> String {
        if id == "claude" { return "claude_code" }
        return id
    }

    static func rows(_ windows: [Window]) -> [(display: String, window: Window)] {
        ComposerLimits.badgeRows(windows: windows, label: \.label, scope: \.scope)
    }

    static func headline(_ windows: [Window]) -> [(display: String, window: Window)] {
        ComposerLimits.codexHeadlineRows(windows: windows, label: \.label, scope: \.scope)
    }

    static func main() {
        require(ComposerLimits.tag(for: "5-hour") == "5h", "5-hour tags 5h")
        require(ComposerLimits.tag(for: "weekly") == "7d", "weekly tags 7d")
        require(ComposerLimits.tag(for: "monthly") == "30d", "monthly tags 30d")
        require(ComposerLimits.tag(for: "Weekly") == "7d", "tags ignore case")
        require(ComposerLimits.tag(for: " 5-hour ") == "5h", "tags ignore padding")
        require(ComposerLimits.tag(for: "Gemini models · 5-hour") == "5h", "qualified windows tag by suffix")
        require(ComposerLimits.tag(for: "Claude and GPT models · 5-hour") == "5h", "family tag ignores the head")
        require(ComposerLimits.tag(for: "Gemini models · weekly") == "7d", "qualified weekly tags 7d")
        require(ComposerLimits.tag(for: "billing cycle") == nil, "a billing cycle is not a 30-day window")
        require(ComposerLimits.tag(for: "daily") == nil, "unknown labels have no tag")
        require(ComposerLimits.tag(for: "") == nil, "empty label has no tag")

        let windows = [
            Window(label: "monthly", percent: 87),
            Window(label: "5-hour", percent: 26),
            Window(label: "weekly", percent: 41),
        ]
        let ordered = rows(windows)
        require(ordered.map(\.display) == ["5h", "7d", "30d"], "badge reads 5h, 7d, 30d in that order")
        require(ordered.map(\.window.percent) == [26, 41, 87], "rows stay attached to their own windows")

        let families = [
            Window(label: "Claude and GPT models · 5-hour", percent: 0),
            Window(label: "Gemini models · 5-hour", percent: 5),
        ]
        let sideBySide = rows(families)
        require(sideBySide.map(\.display) == ["5h", "5h"], "shared tags stay visible side by side")
        require(sideBySide.map(\.window.percent) == [0, 5], "each row keeps its own figure")

        let scoped = [
            Window(label: "5-hour", percent: 88, scope: "current model"),
            Window(label: "weekly", percent: 100, scope: "general"),
            Window(label: "weekly", percent: 84, scope: "current model"),
        ]
        let popover = rows(scoped)
        require(
            popover.map(\.display)
                == ["5-hour (secondary)", "weekly (general)", "weekly (secondary)"],
            "the popover names whose allowance is whose")
        require(
            rows([Window(label: "weekly", percent: 30, scope: "secondary")]).map(\.display)
                == ["all models 7d"],
            "a positional secondary keeps its all-models name")

        let composer = headline(scoped)
        require(composer.map(\.display) == ["7d"], "the composer shows general only")
        require(composer[0].window.percent == 100, "the account week is the headline")

        let modelOnly = [
            Window(label: "5-hour", percent: 12, scope: "primary"),
            Window(label: "weekly", percent: 30, scope: "secondary"),
        ]
        require(
            headline(modelOnly).map(\.display) == ["5h", "7d"],
            "a model-only reading still reads as one")

        let mixed = [Window(label: "billing cycle", percent: 93), Window(label: "5-hour", percent: 12)]
        let kept = rows(mixed)
        require(kept.map(\.display) == ["5h", "billing cycle"], "canonical first, named windows after")
        require(kept[1].window.percent == 93, "a named window keeps its own figure")

        let providers = [
            Provider(source: "cursor", windows: [Window(label: "monthly", percent: 10)]),
            Provider(source: "claude_code", windows: [Window(label: "5-hour", percent: 26)]),
            Provider(source: "grok", windows: []),
        ]
        func pick(_ backend: String) -> Provider? {
            ComposerLimits.pick(
                backend: backend, canonical: canonical, providers: providers,
                source: \.source, hasWindows: { !$0.windows.isEmpty })
        }
        require(pick("claude")?.source == "claude_code", "the chat's own vendor wins, through the canonical id")
        require(pick("codex") == nil, "no readings for this agent is nil, not another agent's numbers")
        require(pick("muse") == nil, "an agent nobody reports quota for gets no badge, not a borrowed one")
        require(pick("grok") == nil, "a vendor with no windows is not a reading")

        print("ComposerLimitsTests passed.")
    }
}
