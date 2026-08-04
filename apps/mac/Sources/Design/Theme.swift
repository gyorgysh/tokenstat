// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shared visual constants.
///
/// The brand colours follow tokenstat.ai's `sites/tokenstat` design tokens. The
/// Mac app and the public profile should read as one product in either theme.
///
/// The chrome is translucent and the content is not. A sidebar or an inspector
/// can sit on material and gain some depth from it, but a table of digits and a
/// terminal need a steady background: vibrancy pulls whatever is behind the
/// window into the text, and columns of numbers are hard enough to read
/// already. So `sidebarMaterial` for the edges, flat colours for the middle.
enum Theme {
    static let accent = Color.adaptive(light: hex(0x6A3DFF), dark: hex(0x8B5CF6))
    static let secondary = Color.adaptive(light: hex(0xC026D3), dark: hex(0xE879F9))

    /// Behind everything.
    static let background = Color.adaptive(light: hex(0xFBFBFD), dark: hex(0x08070D))
    /// Sidebar, one step darker than the content beside it.
    static let sidebar = Color.adaptive(light: hex(0xF3F2F8), dark: hex(0x12101D))
    /// Cards and panels.
    static let panel = Color.adaptive(light: .white, dark: hex(0x100E1A))
    /// Behind a tab strip.
    ///
    /// A step darker than the pane under it, so the strip reads as chrome
    /// rather than as the first row of the content. Only a step: in light mode
    /// this was a solid grey, which put a third tone between the toolbar above
    /// and the content below and made the strip look like a band stuck across
    /// the window. Dark mode can take the contrast, light mode cannot.
    static let tabStrip = Color.adaptive(light: hex(0xF3F2F8), dark: hex(0x08070D))
    /// Hairlines. These carry the structure that shadows used to.
    static let border = Color.adaptive(light: hex(0xE7E7EE), dark: hex(0x211D33))
    /// A row the pointer is over.
    static let rowHighlight = Color.adaptive(light: hex(0xF0ECFF), dark: hex(0x1B1430))
    /// The row that is actually selected.
    ///
    /// Tinted with the accent rather than being a lighter grey. With a hover
    /// highlight and a selection highlight both in grey, the two were the same
    /// thing at a glance and you could not tell which workspace you were in.
    static let rowSelected = accent.opacity(0.18)
    /// A selected row nested inside a selected one, such as the session showing
    /// inside the open workspace.
    ///
    /// Neutral, not tinted. It was the accent at half strength, which put two
    /// purple blocks one above the other and made the pair read as two
    /// competing selections rather than as "this folder, and this terminal
    /// within it". The folder carries the colour, this one just lifts off the
    /// background.
    static let rowSelectedNested = Color.adaptive(light: hex(0xE8E7F0), dark: hex(0x26213D))

    /// The accent at card strength, for a fill that has to read as tinted
    /// rather than as coloured.
    static let accentSoft = Color.adaptive(light: hex(0xF0ECFF), dark: hex(0x1B1430))

    // Semantic colours. Before these existed, a live session was `.green` and
    // an unsaved file was `.orange`, written at the call site, so the app had
    // no single answer to what "good" looks like.
    static let success = Color.adaptive(light: hex(0x2F7D4B), dark: hex(0x79D69C))
    static let warning = Color(red: 0xE0 / 255, green: 0xA9 / 255, blue: 0x3B / 255)
    static let danger = Color(red: 0xD6 / 255, green: 0x45 / 255, blue: 0x3F / 255)

    /// Five steps of activity, idle first.
    ///
    /// Exact `sites/tokenstat` ramp. Step 0 is neutral so a quiet day reads as
    /// "nothing here", while the upper levels run violet into fuchsia.
    static let heat: [Color] = [
        Color.adaptive(light: hex(0xECEAF2), dark: hex(0x191627)),
        Color.adaptive(light: hex(0xD6C9FF), dark: hex(0x3B2A6B)),
        Color.adaptive(light: hex(0xA98CFF), dark: hex(0x5F3FB8)),
        Color.adaptive(light: hex(0x7C4DFF), dark: hex(0x8B5CF6)),
        Color.adaptive(light: hex(0xC026D3), dark: hex(0xE879F9)),
    ]

    /// Colour for a syntax kind.
    ///
    /// The whole palette in one place, and the only place the app decides what
    /// a keyword looks like. `tokenstat-highlight` sends kinds and never
    /// colours, which is what lets this switch on appearance for free.
    static func syntax(_ kind: SyntaxKind) -> Color {
        switch kind {
        case .keyword:
            return accent
        case .string:
            return Color.adaptive(light: hex(0x8F5C1E), dark: hex(0xD8A657))
        case .number, .constant:
            return Color.adaptive(light: hex(0x1F6F5C), dark: hex(0x7FD1B9))
        case .comment:
            return Color.adaptive(light: hex(0x8A8A93), dark: hex(0x6B6B76))
        case .type:
            return secondary
        case .function:
            return Color.adaptive(light: hex(0x2D62C4), dark: hex(0x89B4FA))
        case .attribute:
            return Color.adaptive(light: hex(0x9A5CC4), dark: hex(0xC79BF0))
        case .property:
            return Color.adaptive(light: hex(0x1F5F8F), dark: hex(0x9CC5E0))
        case .markup:
            return Color.adaptive(light: hex(0x1F6F5C), dark: hex(0x8FD6BE))
        // Variables, operators and punctuation stay the text colour. Colouring
        // every token is how a file ends up unreadable: what stands out is what
        // is coloured, so most of it must not be.
        case .variable, .operator, .punctuation, .unknown:
            return .primary
        }
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Spacing scale. Four points, so layouts stay on a rhythm instead of
    /// accumulating one-off paddings.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 20
        static let xl: CGFloat = 32
    }

    /// Corner radius for cards and panels.
    ///
    /// Matched to the window's own corner rather than picked. A card sitting a
    /// few points inside a rounded window with a tighter radius reads as two
    /// unrelated shapes, and the eye catches the mismatch even where the two
    /// corners are nowhere near each other.
    static let cardRadius: CGFloat = 14

    /// Padding inside a card.
    ///
    /// One step below the old `Space.l`. On a screen that is mostly cards, 20
    /// points of inset on every one of them spends more of the window on
    /// margins than on content.
    static let cardPadding: CGFloat = 16

    /// Numbers that sit in columns must not jitter as they update, so anything
    /// numeric uses tabular figures with a monospaced digit face.
    static func numeric(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    /// Identifiers read character by character: model ids, machine ids, paths.
    /// Monospaced so strings that look alike do not read alike.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Small uppercase label above a group.
    static let sectionHeader = Font.system(size: 12, weight: .semibold)

    /// Material for the window's edges: the sidebar and the inspector.
    ///
    /// Not for the content column, and never behind the terminal. A terminal
    /// showing the desktop through it is unreadable, and it is the one surface
    /// in the app where every pixel is someone's output.
    static let sidebarMaterial: Material = .bar
}

extension Color {
    /// A colour that follows the system appearance.
    ///
    /// SwiftUI has no literal for this without an asset catalog, and the Xcode
    /// project is generated, so a catalog would be one more thing to keep in
    /// sync. Resolving through the platform colour type keeps light mode
    /// working rather than committing the app to dark only.
    static func adaptive(light: Color, dark: Color) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
        #else
        return Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}

/// A titled panel. Used for every block in the content column so they share one
/// corner radius and one border treatment.
struct Card<Content: View>: View {
    var title: String
    var subtitle: String?
    /// Trailing accessory in the header, for a count or a control.
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String? = nil,
        accessory: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let accessory {
                    accessory
                }
            }
            content
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

/// One headline number with its label.
struct Stat: View {
    var label: String
    var value: String
    /// Shown next to the value in a dimmer colour, for units or qualifiers.
    var note: String?
    var tint: Color = .primary
    var size: CGFloat = 22
    /// Take an equal share of the row. Off for a group that should stay
    /// together: three expanding stats in a full-screen window end up a third
    /// of a metre apart, and figures that far from each other stop being
    /// comparable, which is the only reason to put them in a row.
    var expands: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label.uppercased())
                .font(Theme.sectionHeader)
                .foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Text(value)
                    .font(Theme.numeric(size, weight: .medium))
                    .foregroundStyle(tint)
                    // A wrapped headline figure is unreadable, and a `+` or `~`
                    // qualifier landing alone on the next line looks like a
                    // rendering fault rather than a caveat.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
    }
}

/// Uppercase group label with an optional count, as in the sidebar.
struct SectionLabel: View {
    var text: String
    var count: Int?

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(Theme.sectionHeader)
                .foregroundStyle(.tertiary)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(Theme.numeric(11))
                    .foregroundStyle(.quaternary)
            }
        }
    }
}

/// A flat tab strip, in place of the reference layout's row of agent tabs.
///
/// Not a segmented `Picker`: those are capsule shaped and centred, and this has
/// to sit flush with the top of the pane and read as part of the chrome.
struct TabStrip<Tab: Hashable>: View {
    /// An empty `symbol` draws the label alone, for a strip narrow enough that
    /// icons would push the labels into truncation.
    var tabs: [(tab: Tab, label: String, symbol: String)]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.tab) { item in
                let active = selection == item.tab
                Button {
                    selection = item.tab
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        if !item.symbol.isEmpty {
                            Image(systemName: item.symbol)
                                .font(.system(size: 11))
                        }
                        Text(item.label)
                            .font(.system(size: 13, weight: active ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    // The accent, not just a heavier weight. On a dark strip a
                    // selected tab drawn as a slightly different dark panel is
                    // the same colour as everything around it, and which tab
                    // was selected became a guess.
                    .foregroundStyle(active ? Theme.accent : Color.secondary)
                    .padding(.horizontal, Theme.Space.xs)
                    // Every tab takes an equal share of the full width. Sized
                    // to their labels with a trailing spacer, two tabs left
                    // two thirds of the strip empty and the group floated in
                    // the corner instead of reading as a bar.
                    .frame(maxWidth: .infinity)
                    // An explicit height, not `maxHeight: .infinity`. The strip
                    // sits directly under the window's toolbar, and an
                    // unbounded height let the active tab's fill and its top
                    // rule expand up through the toolbar's safe area, so the
                    // marker was drawn a toolbar's height above the tab it
                    // belonged to.
                    .frame(height: TabStrip.height)
                    .background(active ? Theme.accentSoft : .clear)
                    .overlay(alignment: .top) {
                        // The active tab is marked along its top edge rather
                        // than underlined, so the strip reads as tabs attached
                        // to the pane below instead of as a toolbar.
                        //
                        // A capsule inset from the tab's edges, not a rule
                        // spanning it. The strip's first tab sits under the
                        // window's rounded corner, and a hard-cornered line
                        // running into that curve reads as a rendering fault
                        // rather than as a marker.
                        Capsule()
                            .fill(active ? Theme.accent : .clear)
                            .frame(height: 2.5)
                            .padding(.horizontal, Theme.Space.s)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        // Nothing in a tab strip may paint outside it.
        .clipped()
        // Darker than the pane below, so the strip reads as chrome the content
        // sits under rather than as the first row of that content.
        .background(Theme.tabStrip)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    /// A generic type cannot hold a static stored property, so this is a
    /// computed one.
    private static var height: CGFloat { 28 }
}

/// The account tier, as a small uppercase pill.
///
/// One component so the badge is the same object wherever it appears. Uppercase
/// and tracked out, because a tier is a label and not a word in a sentence:
/// "Patron" beside a name reads as part of the name, "PATRON" reads as a badge.
struct TierBadge: View {
    var tier: String
    var size: CGFloat = 10

    var body: some View {
        Text(tier.uppercased())
            .font(.system(size: size, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.accentSoft, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.28), lineWidth: 1))
            .fixedSize()
    }
}

/// A line of status across the top of a pane.
///
/// One banner for the whole app. There used to be three: a red-tinted bar in
/// the editor, this in Insights, and orange caption text in the sidebar footer,
/// so the same severity looked like three different things depending on which
/// screen you were on.
struct Banner: View {
    enum Severity {
        case info
        case success
        case warning
        case danger

        var tint: Color {
            switch self {
            case .info: return Theme.secondary
            case .success: return Theme.success
            case .warning: return Theme.warning
            case .danger: return Theme.danger
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "exclamationmark.octagon.fill"
            }
        }
    }

    var text: String
    var severity: Severity = .warning
    /// Overrides the severity's own symbol where a more specific one says more.
    var symbol: String?

    var body: some View {
        Label(text, systemImage: symbol ?? severity.symbol)
            .font(.callout)
            .foregroundStyle(severity.tint)
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                severity.tint.opacity(0.12),
                in: RoundedRectangle(cornerRadius: Theme.cardRadius)
            )
    }
}

/// A short-lived confirmation that does not push the content column down.
struct TransientToast: View {
    @Binding var message: String?
    var severity: Banner.Severity = .success

    var body: some View {
        if let message {
            Label(message, systemImage: severity.symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(severity.tint)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(severity.tint.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(.snappy(duration: 0.25), value: message)
        }
    }
}

/// Explains a surface that is planned but not built, without pretending to be
/// one. Showing invented workspaces here would make the app a demo rather than
/// a tool, and would be impossible to tell apart from a bug once real data
/// exists.
struct NotBuiltYet: View {
    var title: String
    var symbol: String
    var summary: String
    var milestone: String

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.65))
            Text(title)
                .font(.title3.weight(.medium))
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text(milestone)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
        .background(Theme.background)
    }
}

/// Hands its own width to its content, so a layout can change shape rather
/// than stretch.
///
/// macOS has no size classes, and `ViewThatFits` cannot help when every
/// candidate layout is willing to fill any width: it takes the first, always.
/// So the width is measured and the decision made explicitly.
struct WidthReader<Content: View>: View {
    @ViewBuilder var content: (CGFloat) -> Content

    @State private var width: CGFloat = 0

    var body: some View {
        content(width)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: WidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(WidthKey.self) { width = $0 }
    }
}

private struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Width at which a screen has room for two cards side by side.
///
/// One number, so the breakpoints across the app cannot drift apart.
extension CGFloat {
    static let twoColumnWidth: CGFloat = 1_000

    /// How wide a self-contained panel wants to be in a flowing grid.
    ///
    /// A quota panel is a title and a few bars, so it needs about this much to
    /// avoid wrapping its header and no more. The grid fits as many of these as
    /// the window allows, which is why the count of columns follows the window
    /// rather than a hard breakpoint.
    static let panelWidth: CGFloat = 330
}
