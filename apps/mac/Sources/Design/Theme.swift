// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
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
    private struct PaletteColor {
        let key: KeyPath<AppearanceColors, String>
        let fallback: Color
        let blackInOLED: Bool

        init(_ key: KeyPath<AppearanceColors, String>, _ light: UInt32, _ dark: UInt32, blackInOLED: Bool = false) {
            self.key = key
            fallback = Color.adaptive(light: Theme.hex(light), dark: Theme.hex(dark))
            self.blackInOLED = blackInOLED
        }

        var color: Color {
            AppAppearance.shared.color(key, fallback: fallback, blackInOLED: blackInOLED)
        }
    }

    private static let accentColor = PaletteColor(\.accent, 0x6A3DFF, 0x8B5CF6)
    private static let secondaryColor = PaletteColor(\.secondary, 0xC026D3, 0xE879F9)
    private static let backgroundColor = PaletteColor(\.background, 0xFBFBFD, 0x08070D, blackInOLED: true)
    private static let sidebarColor = PaletteColor(\.sidebar, 0xF3F2F8, 0x12101D, blackInOLED: true)
    private static let panelColor = PaletteColor(\.panel, 0xFFFFFF, 0x100E1A, blackInOLED: true)
    private static let tabStripColor = PaletteColor(\.sidebar, 0xF3F2F8, 0x08070D, blackInOLED: true)
    private static let borderColor = PaletteColor(\.border, 0xE7E7EE, 0x211D33)
    private static let selectionColor = PaletteColor(\.selection, 0xF0ECFF, 0x1B1430)
    private static let nestedSelectionColor = PaletteColor(\.selection, 0xE8E7F0, 0x26213D)

    static var accent: Color { accentColor.color }
    static let brandAccent = Color.adaptive(light: hex(0x6A3DFF), dark: hex(0x8B5CF6))
    static var showsBrandColours: Bool { AppAppearance.shared.paletteID == "default" }
    static var secondary: Color { secondaryColor.color }
    static var background: Color { backgroundColor.color }
    static var sidebar: Color { sidebarColor.color }
    static var panel: Color {
        AppAppearance.shared.mode == .oled ? oledPanel : panelColor.color
    }
    private static let oledPanel = hex(0x0C0C0F)
    static var hairline: Color {
        AppAppearance.shared.mode == .oled ? Color.white.opacity(0.07) : border.opacity(0.7)
    }

    static var tabStrip: Color { tabStripColor.color }
    static var chatStartGround: Color {
        AppAppearance.shared.mode == .oled ? .black : chatStartGroundColor
    }
    private static let chatStartGroundColor = Color.adaptive(light: hex(0xF2F1F7), dark: hex(0x050409))
    static var border: Color {
        AppAppearance.shared.mode == .oled ? Color.white.opacity(0.06) : borderColor.color
    }
    static let contentRim = Color.adaptive(light: Color.black.opacity(0.09), dark: Color.white.opacity(0.085))
    static var rowHighlight: Color { accentSoft }
    static let controlSeat = Color.adaptive(
        light: Color.black.opacity(0.06),
        dark: Color.white.opacity(0.09)
    )
    static let controlGlyph = Color.adaptive(light: hex(0x6B6876), dark: hex(0xA8A5B5))

    static let controlGlyphHover = Color.adaptive(light: hex(0x2A2831), dark: hex(0xE9E7F0))
    static var rowSelected: Color { accent.opacity(0.18) }
    static var rowSelectedNested: Color { nestedSelectionColor.color }

    static var accentSoft: Color { selectionColor.color }

    static var success: Color { accent }
    static let warning = Color(red: 0xE0 / 255, green: 0xA9 / 255, blue: 0x3B / 255)
    static let danger = Color(red: 0xD6 / 255, green: 0x45 / 255, blue: 0x3F / 255)

    static var stateWorking: Color { accent }
    static let stateIdle = Color.adaptive(light: hex(0x9A97A6), dark: hex(0x6E6A80))

    static let diffAdded = Color.adaptive(light: hex(0x2E8B57), dark: hex(0x5FBF8B))
    static let diffRemoved = Color.adaptive(light: hex(0xC2453F), dark: hex(0xE8827C))

    static let pullOpen = Color.adaptive(light: hex(0x1A7F37), dark: hex(0x3FB950))
    static let pullMerged = Color.adaptive(light: hex(0x8250DF), dark: hex(0xA371F7))
    static let pullClosed = Color.adaptive(light: hex(0xCF222E), dark: hex(0xF85149))

    static var heat: [Color] {
        if AppAppearance.shared.paletteID != "default" || AppAppearance.shared.mode == .oled {
            return [border, accent.opacity(0.38), accent.opacity(0.7), accent, secondary]
        }
        return defaultHeat
    }

    private static let defaultHeat: [Color] = [
        Color.adaptive(light: hex(0xECEAF2), dark: hex(0x191627)),
        Color.adaptive(light: hex(0xD6C9FF), dark: hex(0x3B2A6B)),
        Color.adaptive(light: hex(0xA98CFF), dark: hex(0x5F3FB8)),
        Color.adaptive(light: hex(0x7C4DFF), dark: hex(0x8B5CF6)),
        Color.adaptive(light: hex(0xC026D3), dark: hex(0xE879F9)),
    ]

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
        case .variable, .operator, .punctuation, .unknown:
            return .primary
        }
    }

    static func shadow(_ opacity: Double) -> Color {
        Color.adaptive(
            light: Color.black.opacity(opacity * 0.35),
            dark: Color.black.opacity(opacity)
        )
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 20
        static let xl: CGFloat = 32
    }

    enum Control {
        static let height: CGFloat = 30
        static let heightSmall: CGFloat = 24
        static let heightComfortable: CGFloat = 44
        static let sidebarRow: CGFloat = 36
        static let sidebarIcon: CGFloat = 28
        static let pairedWidth: CGFloat = 88
        #if os(macOS)
        static let rowHeight: CGFloat = 32
        #else
        static let rowHeight: CGFloat = 44
        #endif
    }

    enum Modal {
        static let headerMinHeight: CGFloat = 72
        static let iconSeat: CGFloat = 36
        static let footerHeight: CGFloat = 64
        static let bodyPadding: CGFloat = 32
    }

    static let cardRadius: CGFloat = 14

    static let cardPadding: CGFloat = 16


    /// The interface face at a given size, with Dynamic Type.
    ///
    /// `relativeTo` is what makes the text grow with the reader's setting: a
    /// custom font without it is frozen at whatever size the developer typed,
    /// which is the usual way an app with a bundled typeface stops being
    /// readable for the people who most need it to be.
    static func font(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo style: Font.TextStyle = .body
    ) -> Font {
        guard AppFonts.registered else {
            return .system(style, weight: weight)
        }
        return .custom(AppFonts.interface, size: size, relativeTo: style).weight(weight)
    }

    /// The monospaced face at a given size, with Dynamic Type.
    ///
    /// For text read character by character: a command, a model id, a line of
    /// code. Not for a headline number. A figure a screen is about is
    /// language, and setting it in a terminal face makes a dashboard look like
    /// a log.
    static func monoText(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo style: Font.TextStyle = .footnote
    ) -> Font {
        guard AppFonts.registered else {
            return .system(style, design: .monospaced, weight: weight)
        }
        return .custom(AppFonts.mono, size: size, relativeTo: style).weight(weight)
    }

    /// A size that scales with the window rather than with Dynamic Type.
    ///
    /// The Mac's chrome, which is laid out against a reference window and
    /// shrinks with it. See `DisplayFit`.
    private static func fitted(_ size: CGFloat, weight: Font.Weight, mono: Bool) -> Font {
        let size = DisplayFit.dp(size)
        guard AppFonts.registered else {
            return .system(size: size, weight: weight, design: mono ? .monospaced : .default)
        }
        return .custom(mono ? AppFonts.mono : AppFonts.interface, fixedSize: size).weight(weight)
    }

    /// The interface face at a size that never scales.
    ///
    /// For glyphs drawn inside fixed containers — monograms, marks, the
    /// heatmap's labels — where the box is sized in points and cannot grow
    /// with the reader's setting. Dynamic Type here pushes the letter out of
    /// its box rather than making it readable; anything that reads as *text*
    /// still uses `font`.
    static func fixed(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard AppFonts.registered else {
            return .system(size: size, weight: weight)
        }
        return .custom(AppFonts.interface, fixedSize: size).weight(weight)
    }

    /// The interface face at a size that scales with the window.
    ///
    /// The Mac's own chrome: sidebar rows, list metadata, the marks beside
    /// them. Sized against a reference window rather than against the reader's
    /// Dynamic Type setting, because these sit in a fixed layout that has to
    /// keep working on a 1024-point display. Content uses `font` instead.
    static func fit(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        fitted(size, weight: weight, mono: false)
    }

    static func numeric(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        fitted(size, weight: weight, mono: false).monospacedDigit()
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        fitted(size, weight: weight, mono: true)
    }

    static var sectionHeader: Font {
        fitted(12, weight: .semibold, mono: false)
    }

    #if os(macOS)
    static var largeTitle: Font { font(26, weight: .regular, relativeTo: .largeTitle) }
    static var title: Font { font(22, weight: .regular, relativeTo: .title) }
    static var title2: Font { font(17, weight: .regular, relativeTo: .title2) }
    static var title3: Font { font(15, weight: .regular, relativeTo: .title3) }
    static var headline: Font { font(13, weight: .semibold, relativeTo: .headline) }
    static var body: Font { font(13, weight: .regular, relativeTo: .body) }
    static var callout: Font { font(12, weight: .regular, relativeTo: .callout) }
    static var subheadline: Font { font(11, weight: .regular, relativeTo: .subheadline) }
    static var footnote: Font { font(10, weight: .regular, relativeTo: .footnote) }
    static var caption: Font { font(10, weight: .regular, relativeTo: .caption) }
    static var caption2: Font { font(10, weight: .regular, relativeTo: .caption2) }
    static var chatBody: Font { body }
    static var chatCode: Font { monoText(12, relativeTo: .body) }
    #else
    static var largeTitle: Font { font(34, weight: .regular, relativeTo: .largeTitle) }
    static var title: Font { font(28, weight: .regular, relativeTo: .title) }
    static var title2: Font { font(22, weight: .regular, relativeTo: .title2) }
    static var title3: Font { font(20, weight: .regular, relativeTo: .title3) }
    static var headline: Font { font(17, weight: .semibold, relativeTo: .headline) }
    static var body: Font { font(17, weight: .regular, relativeTo: .body) }
    static var callout: Font { font(16, weight: .regular, relativeTo: .callout) }
    static var subheadline: Font { font(15, weight: .regular, relativeTo: .subheadline) }
    static var footnote: Font { font(13, weight: .regular, relativeTo: .footnote) }
    static var caption: Font { font(12, weight: .regular, relativeTo: .caption) }
    static var caption2: Font { font(11, weight: .regular, relativeTo: .caption2) }
    // iOS chat at 17 was too loose - the same hierarchy as the Mac
    // (body 17 -> chat 15) gives a calmer reading size without shrinking
    // supporting chrome. Thinking stays subheadline (15 -> 13) for the aside.
    static var chatBody: Font { font(15, weight: .regular, relativeTo: .body) }
    static var chatCode: Font { monoText(12, relativeTo: .body) }
    #endif

    static var chatHeading: Font { font(17, weight: .semibold, relativeTo: .body) }
    static var chatSubheading: Font { font(15, weight: .semibold, relativeTo: .body) }

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

struct ActivitySummaryTile: View {
    let title: String
    let value: Int
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(Theme.font(15, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text(value.formatted())
                .font(Theme.font(26, weight: .semibold)).monospacedDigit()
            Text(title).font(Theme.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }
}

struct Card<Content: View>: View {
    var title: String
    var subtitle: String?
    var leading: AnyView?
    var accessory: AnyView?
    var fillsHeight = false
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String? = nil,
        leading: AnyView? = nil,
        accessory: AnyView? = nil,
        fillsHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading
        self.accessory = accessory
        self.fillsHeight = fillsHeight
        self.content = content()
    }

    init(
        title: String,
        subtitle: String? = nil,
        mark: String,
        markTint: Color = Theme.accent,
        accessory: AnyView? = nil,
        fillsHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            leading: AnyView(FeatureMark(name: mark, tint: markTint, size: 22)),
            accessory: accessory,
            fillsHeight: fillsHeight,
            content: content
        )
    }

    init(
        title: String,
        subtitle: String? = nil,
        mark: String,
        markTint: Color = Theme.accent,
        accessory: AnyView? = nil,
        fillsHeight: Bool = false
    ) where Content == EmptyView {
        self.init(
            title: title,
            subtitle: subtitle,
            mark: mark,
            markTint: markTint,
            accessory: accessory,
            fillsHeight: fillsHeight
        ) {
            EmptyView()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: leading == nil ? .firstTextBaseline : .center) {
                if let leading {
                    leading
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: DisplayFit.dp(13), weight: .semibold))
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
            if Content.self != EmptyView.self {
                content
            }
            if fillsHeight {
                Spacer(minLength: 0)
            }
        }
        .padding(Theme.cardPadding)
        .frame(
            maxWidth: .infinity,
            maxHeight: fillsHeight ? .infinity : nil,
            alignment: .topLeading
        )
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

struct Stat: View {
    var label: String
    var value: String
    var note: String?
    var tint: Color = .primary
    var size: CGFloat = 22
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
    }
}

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

struct ScopeChip: View {
    let label: String
    var symbol: String = "folder.fill"

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 3)
        .background(Theme.accentSoft, in: Capsule())
        .help(L10n.text("apple.theme.showing_0.ee1f5b6a", "\(label)"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("apple.theme.showing_0.ee1f5b6a", "\(label)"))
    }
}

struct DetailChromeToggles {
    var leftSidebar: AnyView
    var rightInspector: AnyView?
    var search: AnyView? = nil
    var sectionTabs: AnyView? = nil
    var title: String? = nil
    var usesTitlebar = false
}

private struct DetailChromeTogglesKey: EnvironmentKey {
    static let defaultValue: DetailChromeToggles? = nil
}

extension EnvironmentValues {
    var detailChromeToggles: DetailChromeToggles? {
        get { self[DetailChromeTogglesKey.self] }
        set { self[DetailChromeTogglesKey.self] = newValue }
    }
}

/// Fixed action strip under the window titlebar.
///
/// One row on every destination:
/// - **Leading:** the screen's own navigation (e.g. Insights back), then the
///   sidebar toggle.
/// - **Trailing:** destination actions (refresh, period, scan, new, …), then
///   the inspector toggle at the far right when that screen has one.
///
/// **Each mark sits on the side of the window it acts on.** The inspector
/// toggle used to sit second from the left, beside the sidebar toggle, next to
/// a back button, pointing at a pane on the opposite edge. Two controls that
/// look alike and open opposite sides of the window, stacked together in one
/// corner, is a coin toss every time. Leading is the leading column and
/// whatever navigates within this screen; trailing is this screen's actions
/// and the trailing column.
///
/// Toggles no longer live in the system toolbar, so Home and Insights share
/// the same chrome shape and the window titlebar stays traffic lights only.
struct DetailChromeBar<Leading: View, Accessory: View, Trailing: View>: View {
    @Environment(\.detailChromeToggles) private var toggles
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var trailing: () -> Trailing
    var scope: ScopeChip?

    init(
        scope: ScopeChip? = nil,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.scope = scope
        self.leading = leading
        self.accessory = accessory
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                leading()
                toggles?.leftSidebar
                if let tabs = toggles?.sectionTabs {
                    tabs
                } else {
                    if let scope {
                        scope
                    } else if let title = toggles?.title {
                        Text(title)
                            .font(Theme.fit(14, weight: .semibold))
                            .lineLimit(1)
                            .padding(.leading, 2)
                    }
                    accessory()
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
                #if os(macOS)
                .frame(height: ToolbarIconButton.diameter)
                .overlay {
                    if toggles?.usesTitlebar == true {
                        TitlebarDragArea().accessibilityHidden(true)
                    }
                }
                #endif
            HStack(spacing: Theme.Space.xs) {
                trailing()
                toggles?.search
                if let right = toggles?.rightInspector {
                    right
                }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, Theme.Space.s)
        .chromeBarMetrics()
        #if os(macOS)
        .modifier(DesktopTitlebarPlate(fallback: Theme.tabStrip))
        #else
        .background(Theme.tabStrip)
        .overlay(alignment: .bottom) { ThemeRule() }
        #endif
    }

    static var height: CGFloat { DetailChromeBarHeight }
}

#if os(macOS)
let DetailChromeBarHeight: CGFloat = 40
let DetailChromeBottomSpacing: CGFloat = 2
#else
let DetailChromeBarHeight: CGFloat = 52
let DetailChromeBottomSpacing: CGFloat = 3
#endif

private struct ChromeBarMetrics: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.bottom, DetailChromeBottomSpacing)
            .frame(maxWidth: .infinity)
            .frame(height: DetailChromeBarHeight)
    }
}

extension View {
    func chromeBarMetrics() -> some View {
        modifier(ChromeBarMetrics())
    }
}

extension View {
    @ViewBuilder func desktopPaneBackground(_ color: Color = Theme.background) -> some View {
        #if os(macOS)
        modifier(DesktopPaneBackground(color: color))
        #else
        background(color)
        #endif
    }
}

struct ThemeRule: View {
    enum Axis {
        case horizontal
        case vertical
    }

    var axis: Axis = .horizontal

    static var vertical: ThemeRule { ThemeRule(axis: .vertical) }

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(
                maxWidth: axis == .horizontal ? .infinity : 1,
                maxHeight: axis == .vertical ? .infinity : 1
            )
            .accessibilityHidden(true)
    }
}

struct TabStrip<Tab: Hashable>: View {
    var tabs: [(tab: Tab, label: String, symbol: String)]
    @Binding var selection: Tab
    var showsChrome: Bool = true

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
                    .foregroundStyle(active ? Theme.accent : Theme.controlGlyph)
                    .padding(.horizontal, Theme.Space.xs)
                    .frame(maxWidth: .infinity)
                    .frame(height: TabStrip.height)
                    .background(active ? Theme.accentSoft : .clear)
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(active ? Theme.accent : .clear)
                            .frame(height: 2.5)
                            .padding(.horizontal, Theme.Space.s)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(CardButtonStyle())
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .clipped()
        .background(showsChrome ? Theme.sidebar : Color.clear)
        .overlay(alignment: .bottom) {
            if showsChrome {
                Rectangle().fill(Theme.border).frame(height: 1)
            }
        }
    }

    static var height: CGFloat { 28 }
}

struct TierBadge: View {
    var tier: String
    var size: CGFloat = 10

    var body: some View {
        Text(PlanName.title(tier).uppercased())
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

/// A spinner that stays a spinner.
///
/// Bare `ProgressView()` on macOS 14 becomes a linear indeterminate bar and
/// walks the width of whatever parent it sits in. Newer macOS draws a circular
/// control. This is the circular one, with a fixed size, on every version.
struct BusySpinner: View {
    var size: ControlSize = .regular

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(size)
            .frame(width: Self.side(size), height: Self.side(size))
            .accessibilityLabel(L10n.text("apple.theme.loading.dc380888"))
    }

    private static func side(_ size: ControlSize) -> CGFloat {
        switch size {
        case .mini: 12
        case .small: 16
        case .regular: 20
        case .large: 24
        case .extraLarge: 28
        @unknown default: 20
        }
    }
}

struct NoticeDismissButton: View {
    var action: () -> Void

    var body: some View {
        Button(L10n.text("apple.theme.dismiss_notification.b7bb3f34"), .dismiss, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(QuietLinkStyle())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .help(L10n.text("apple.theme.dismiss_notification.b7bb3f34"))
    }
}

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
    var symbol: String?
    var detail: String?
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Label(text, systemImage: symbol ?? severity.symbol)
                    .font(.callout)
                    .foregroundStyle(severity.tint)
                if let onDismiss {
                    Spacer(minLength: 0)
                    NoticeDismissButton(action: onDismiss)
                }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(Theme.mono(11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            severity.tint.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
    }
}

struct EmptyState<Action: View>: View {
    var symbol: String
    var title: String
    var message: String
    /// Product mark, preferred over the SF Symbol when the empty state is
    /// about a feature (the vault, a plan) rather than a list.
    var mark: String? = nil
    @ViewBuilder var action: Action

    init(
        symbol: String,
        title: String,
        message: String,
        mark: String? = nil,
        @ViewBuilder action: () -> Action = { EmptyView() }
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.mark = mark
        self.action = action()
    }

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            if let mark {
                FeatureMark(name: mark, tint: Theme.accent, size: 36)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.accent.opacity(0.7))
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            action
                .padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
        .padding(.horizontal, Theme.Space.l)
    }
}

enum FieldSaveState: Equatable {
    case idle
    case dirty
    case saving
    case saved
    case failed
}

struct FieldSaveBar: View {
    var state: FieldSaveState
    var saveTitle: String = L10n.text("common.save")
    var canSave: Bool = true
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            status
            Spacer(minLength: 0)
            if state == .dirty || state == .failed {
                Button(L10n.text("common.cancel"), .dismiss, action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
                Button(saveTitle, .save, action: onSave)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!canSave || state == .saving)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .idle:
            EmptyView()
        case .dirty:
            Text(L10n.text("apple.theme.unsaved.6250d572"))
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.warning)
        case .saving:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(L10n.text("apple.theme.saving.096b7362"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .saved:
            Label(L10n.text("apple.theme.saved.b5c120b3"), systemImage: "checkmark")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.success)
        case .failed:
            Text(L10n.text("apple.theme.not_saved.22b3467c"))
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.danger)
        }
    }
}

struct TransientToast: View {
    @Binding var message: String?
    var severity: Banner.Severity = .success
    var actionLabel: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        if let message {
            HStack(spacing: Theme.Space.s) {
                Label(message, systemImage: severity.symbol)
                if let actionLabel, let action {
                    Button(actionLabel) {
                        action()
                        self.message = nil
                    }
                    .buttonStyle(QuietLinkStyle())
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                }
                NoticeDismissButton {
                    self.message = nil
                    onDismiss?()
                }
            }
                .font(.callout.weight(.medium))
                .foregroundStyle(severity.tint)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(severity.tint.opacity(0.35), lineWidth: 1))
                .shadow(color: Theme.shadow(0.2), radius: 14, y: 6)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(.snappy(duration: 0.25), value: message)
                .task(id: [message, severity.symbol]) {
                    guard case .success = severity else { return }
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard !Task.isCancelled, self.message == message else { return }
                    self.message = nil
                    onDismiss?()
                }
        }
    }
}

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

/// Rounds a measured length before anything is derived from it.
///
/// Writing state from a `GeometryReader` or an `onPreferenceChange` is a cycle:
/// layout produces a number, the number changes state, the state changes the
/// layout. AppKit is unforgiving about that when the state changes a hosted
/// view's *minimum* size, because SwiftUI then calls `setNeedsUpdateConstraints`
/// while AppKit is still inside its constraints update pass. That throws, and
/// dragging a split divider was reliably hitting it.
///
/// Sub-pixel jitter from a live drag is not information: it is a stream of
/// values that differ in the third decimal and invalidates everything
/// downstream on every frame. Quantising turns most drag frames into no-ops,
/// which is most of the cycle gone.
func quantised(_ length: CGFloat, step: CGFloat = 1) -> CGFloat {
    (length / step).rounded() * step
}

struct ControlFeedbackStyle: ButtonStyle {
    var highlights = true
    var diameter: CGFloat?
    var pressScale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration, highlights: highlights, diameter: diameter, pressScale: pressScale)
    }

    private struct Feedback: View {
        let configuration: Configuration
        let highlights: Bool
        let diameter: CGFloat?
        let pressScale: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(width: diameter, height: diameter)
                .scaleEffect(isEnabled && configuration.isPressed && !reduceMotion ? pressScale : 1)
                .animation(Motion.unless(reduceMotion, Motion.press), value: configuration.isPressed)
                .background {
                    if highlights {
                        let seated = isEnabled && (hovering || configuration.isPressed)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.controlSeat)
                            .opacity(seated ? 1 : 0)
                            .scaleEffect(seated ? 1 : 0.82)
                            .padding(2)
                            .animation(Motion.unless(reduceMotion, Motion.morph), value: seated)
                    }
                }
                .contentShape(.rect)
                .onHover { if highlights { hovering = $0 } }
        }
    }
}

struct ToolbarIconButton: View {
    #if os(macOS)
    static let diameter: CGFloat = 32
    #else
    static let diameter: CGFloat = 44
    #endif

    let systemImage: String
    var help: String = ""
    var isAccent: Bool = false
    var isBusy: Bool = false
    var showsBadge: Bool = false
    var badgeAlignment: Alignment = .topLeading
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack(alignment: badgeAlignment) {
                Group {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(glyphColor)
                    }
                }
                .frame(width: min(Self.diameter - 4, 30), height: min(Self.diameter - 4, 30))
                .background {
                    ZStack {
                        if isAccent {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.accentSoft.opacity(0.8))
                        }
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.rowHighlight)
                            .opacity(isHovering && isEnabled ? 1 : 0)
                            .scaleEffect(isHovering && isEnabled ? 1 : 0.8)
                    }
                }
                if showsBadge {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .offset(
                            x: badgeAlignment == .topLeading || badgeAlignment == .bottomLeading ? 1 : -1,
                            y: badgeAlignment == .topLeading || badgeAlignment == .topTrailing ? 1 : -1
                        )
                }
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlFeedbackStyle(highlights: false))
        .disabled(!isEnabled || isBusy)
        .opacity(isEnabled || isBusy ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .animation(Motion.unless(reduceMotion, Motion.morph), value: isHovering)
        .help(help)
        .accessibilityLabel(help)
    }

    private var glyphColor: Color {
        if isAccent { return Theme.accent }
        return isHovering ? Theme.controlGlyphHover : Theme.controlGlyph
    }
}

struct ToolbarMenuButton<Content: View>: View {
    var systemImage: String = "ellipsis"
    var help: String = L10n.text("apple.theme.more.d47d7cb0")
    var diameter: CGFloat = ToolbarIconButton.diameter
    var glyphSize: CGFloat = 14
    @ViewBuilder var content: () -> Content

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: glyphSize, weight: .regular))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(isHovering ? Theme.controlGlyphHover : Theme.controlGlyph)
        .fixedSize()
        .frame(width: diameter, height: diameter)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.rowHighlight)
                .opacity(isHovering ? 1 : 0)
                .scaleEffect(isHovering ? 1 : 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(Motion.unless(reduceMotion, Motion.morph), value: isHovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Left or right chrome toggle for toolbars and in-content chips.
///
/// Built from the system `sidebar.left` / `sidebar.right` symbols so the mark
/// always paints in a macOS toolbar. Same quiet seat as refresh.
struct SidebarToggleButton: View {
    enum Edge {
        case leading
        case trailing
    }

    let edge: Edge
    let isOpen: Bool
    let action: () -> Void
    var help: String = ""

    var body: some View {
        ToolbarIconButton(
            systemImage: edge == .leading ? "sidebar.left" : "sidebar.right",
            help: help,
            action: action
        )
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}

/// Shared top row of every inspector: destination chrome, then the close mark.
///
/// One object so Workspaces (tabs) and Insights (empty leading side) paint the
/// same opaque sidebar colour. A SwiftUI `.inspector` on a transparent titlebar
/// otherwise lets liquid glass or the unfocused grey show through the strip.
struct InspectorChromeBar<Content: View, Accessory: View>: View {
    var onClose: () -> Void
    var closeLabel: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var accessory: () -> Accessory

    init(
        onClose: @escaping () -> Void,
        closeLabel: String = L10n.text("apple.theme.close_the_inspector.eddd7e3c"),
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.onClose = onClose
        self.closeLabel = closeLabel
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 0) {
            content()
            accessory()
            InspectorCloseButton(action: onClose, help: closeLabel, label: closeLabel)
                .padding(.trailing, Theme.Space.s)
        }
        .chromeBarMetrics()
        #if os(macOS)
        .modifier(DesktopTitlebarPlate(fallback: Theme.sidebar))
        #else
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { ThemeRule() }
        #endif
    }
}

/// Consistent destination label for inspector chrome. SF Symbols keep this
/// neutral (an inspector is a place, not an agent brand) while the 24pt seat
/// gives small glyphs enough air beside their title.
struct InspectorTitle: View {
    let title: String
    let symbol: String
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title)
                .font(Theme.font(13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, Theme.Space.m)
    }
}

extension InspectorChromeBar where Accessory == EmptyView {
    init(onClose: @escaping () -> Void, closeLabel: String = L10n.text("apple.theme.close_the_inspector.eddd7e3c"), @ViewBuilder content: @escaping () -> Content) {
        self.init(onClose: onClose, closeLabel: closeLabel, accessory: { EmptyView() }, content: content)
    }
}

struct InspectorCloseButton: View {
    let action: () -> Void
    /// Tooltip and VoiceOver label. Defaults to the inspector copy; a sheet
    /// passes its own so "Close" never announces as "close the inspector".
    var help: String = L10n.text("apple.theme.close_the_inspector.eddd7e3c")
    var label: String = L10n.text("apple.theme.close_the_inspector.eddd7e3c")

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovering ? Theme.controlGlyphHover : Theme.controlGlyph)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(isHovering ? Theme.rowHighlight : Theme.controlSeat)
                )
                .overlay(
                    Circle().strokeBorder(Theme.border.opacity(isHovering ? 0.9 : 0.55), lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
        .zIndex(10)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

struct SegmentedCapsulePicker<Option: Hashable>: View {
    var options: [(value: Option, label: String, symbol: String)]
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                SegmentButton(
                    label: option.label,
                    symbol: option.symbol,
                    isSelected: option.value == selection
                ) {
                    selection = option.value
                }
            }
        }
        .padding(3)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

struct ActionLabelStyle: LabelStyle {
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: small ? 5 : 6) {
            configuration.icon
                .font(.system(size: small ? 11 : 12, weight: .semibold))
            configuration.title
        }
    }
}

struct AccentButtonStyle: ButtonStyle {
    var small = false
    var comfortable = false
    var capsule = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let height: CGFloat = comfortable
            ? Theme.Control.heightComfortable
            : (small ? Theme.Control.heightSmall : Theme.Control.height)
        let fontSize: CGFloat = comfortable ? 15 : (small ? 12 : 13)
        let pad: CGFloat = comfortable ? 16 : (small ? 10 : 14)
        let radius: CGFloat = capsule ? height / 2 : (comfortable ? 12 : 8)
        configuration.label
            .labelStyle(ActionLabelStyle(small: small && !comfortable))
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, pad)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? Theme.accent.opacity(0.18)
                            : Theme.accentSoft
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
            )
            .modifier(CapsuleFeedback(isPressed: configuration.isPressed, radius: radius, tint: Theme.accent))
            .contentShape(.rect)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.42)
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    var small = false
    var comfortable = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ActionLabelStyle(small: small && !comfortable))
            .font(.system(size: comfortable ? 15 : (small ? 12 : 13), weight: .medium))
            .foregroundStyle(Theme.danger)
            .padding(.horizontal, comfortable ? 16 : (small ? 10 : 14))
            .frame(height: comfortable ? Theme.Control.heightComfortable : (small ? Theme.Control.heightSmall : Theme.Control.height))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Theme.danger.opacity(0.16) : Theme.danger.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.danger.opacity(0.35), lineWidth: 1)
            )
            .modifier(CapsuleFeedback(isPressed: configuration.isPressed, radius: 8, tint: Theme.danger))
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var small = false
    var comfortable = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ActionLabelStyle(small: small))
            .font(.system(size: comfortable ? 15 : (small ? 12 : 13), weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, small ? 10 : 14)
            .frame(height: comfortable ? Theme.Control.heightComfortable : (small ? Theme.Control.heightSmall : Theme.Control.height))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Theme.rowHighlight : Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        configuration.isPressed ? Theme.accent.opacity(0.35) : Theme.border,
                        lineWidth: 1
                    )
            )
            .modifier(CapsuleFeedback(isPressed: configuration.isPressed, radius: 8, tint: Theme.accent))
            .contentShape(.rect)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.42)
    }
}

/// A text field on the app's own surface.
///
/// `.roundedBorder` is AppKit's bezel and UIKit's, and neither of them has
/// heard of `Theme`: on a dark panel they resolve to a flat mid grey that
/// belongs to no part of this design. That is the same failure the editors
/// already avoided by refusing `Form`, then walked straight back into one
/// field at a time. `SearchField` and the Automations search box had each
/// hand-built this shape rather than share one, which is how a convention
/// turns into three slightly different boxes.
struct ThemedFieldStyle: TextFieldStyle {
    var small = false
    var multiline = false
    var font: Font?

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.themedFieldBox(small: small, multiline: multiline, font: font)
    }
}

extension TextFieldStyle where Self == ThemedFieldStyle {
    static var themed: ThemedFieldStyle { ThemedFieldStyle() }
    static var themedSmall: ThemedFieldStyle { ThemedFieldStyle(small: true) }
    static var themedMultiline: ThemedFieldStyle { ThemedFieldStyle(multiline: true) }
    static func themedMono(_ size: CGFloat) -> ThemedFieldStyle {
        ThemedFieldStyle(font: Theme.mono(size))
    }
}

/// The same box, as a modifier, for the fields a `TextFieldStyle` cannot
/// reach.
///
/// SwiftUI hands a custom `TextFieldStyle` a `TextField` and nothing else, so
/// a `SecureField` silently keeps the platform's own chrome and a password box
/// ends up as the one grey control on a themed form. Applied to the field
/// itself rather than around it, so `focused`, `shake` and `onSubmit` chained
/// after it still land on the field.
///
/// No focus ring here: the call sites that need one already own a
/// `FocusState`, and a second focus binding underneath theirs is a fight over
/// the same field rather than a feature.
struct ThemedFieldBox: ViewModifier {
    var small = false
    var multiline = false
    var font: Font?

    private var defaultFont: Font {
        #if os(macOS)
        Font.system(size: small ? 12 : 13)
        #else
        Font.system(small ? .footnote : .subheadline)
        #endif
    }

    func body(content: Content) -> some View {
        let field = content
            .textFieldStyle(.plain)
            .font(font ?? defaultFont)
            .padding(.horizontal, Theme.Space.s)
        return Group {
            #if os(macOS)
            if multiline {
                field
                    .padding(.vertical, small ? 5 : 7)
                    .frame(
                        minHeight: small ? Theme.Control.heightSmall : Theme.Control.height,
                        alignment: .topLeading
                    )
            } else {
                field.frame(height: small ? Theme.Control.heightSmall : Theme.Control.height)
            }
            #else
            field
                .padding(.vertical, small ? 5 : 7)
                .frame(
                    minHeight: small ? Theme.Control.heightSmall : Theme.Control.height,
                    alignment: multiline ? .topLeading : .leading
                )
            #endif
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

extension View {
    func themedFieldBox(
        small: Bool = false,
        multiline: Bool = false,
        font: Font? = nil
    ) -> some View {
        modifier(ThemedFieldBox(small: small, multiline: multiline, font: font))
    }
}

struct ThemedEditor: View {
    @Binding var text: String
    var font: Font = Theme.mono(12)
    var minHeight: CGFloat = 88
    var maxHeight: CGFloat = 320

    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(font)
            .focused($focused)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, Theme.Space.xs)
            .padding(.vertical, Theme.Space.xs)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        focused ? Theme.accent.opacity(0.7) : Theme.border,
                        lineWidth: focused ? 1.5 : 1
                    )
            )
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// A checkbox in the app's colours.
///
/// The stock macOS checkbox is a small grey circle on a dark panel and the
/// stock iOS switch is a green one, so a settings row was the only place in
/// these screens wearing somebody else's palette. A tick in an accent box says
/// the same thing and belongs to this app.
struct BrandCheckboxStyle: ToggleStyle {
    var iconOnly = false
    @Environment(\.isEnabled) private var isEnabled
    static var labelFont: Font {
        #if os(macOS)
        Font.system(size: 13)
        #else
        Font.system(.subheadline)
        #endif
    }

    static func minimumHeight(iconOnly: Bool) -> CGFloat? {
        #if os(macOS)
        iconOnly ? 44 : nil
        #else
        44
        #endif
    }

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: Theme.Space.s) {
                BrandCheckboxBox(isOn: configuration.isOn)
                if !iconOnly {
                    configuration.label
                        .font(Self.labelFont)
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }
            .frame(minWidth: iconOnly ? 44 : nil, minHeight: Self.minimumHeight(iconOnly: iconOnly))
            .contentShape(.rect)
        }
        .buttonStyle(RowFeedbackStyle(bleed: 6, radius: 8))
        // A checkbox that does not say whether it is checked is a button.
        // The stock Toggle this replaces announced "switch, off"; without a
        // value here somebody using VoiceOver could only learn the state by
        // changing it. `BrandToggleChip` in this file already says it.
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
        .accessibilityValue(configuration.isOn ? L10n.text("apple.theme.on.13001175") : L10n.text("apple.theme.off.ca7981b4"))
    }
}

private struct BrandCheckboxBox: View {
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(isOn ? Theme.accent : Theme.background)
            .frame(width: 18, height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isOn ? Theme.accent : Color.secondary.opacity(0.75), lineWidth: 1.5)
            )
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
    }
}

extension ToggleStyle where Self == BrandCheckboxStyle {
    static var brandCheckbox: BrandCheckboxStyle { BrandCheckboxStyle() }
}

struct SegmentedTabs<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var comfortable = false

    @Namespace private var slide

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    guard option != selection else { return }
                    withAnimation(.snappy(duration: 0.22)) { selection = option }
                } label: {
                    Text(title(option))
                        #if os(macOS)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        #else
                        .font(.system(.subheadline, weight: isSelected ? .semibold : .regular))
                        #endif
                        .foregroundStyle(isSelected ? Theme.accent : Theme.controlGlyph)
                        .frame(maxWidth: .infinity)
                        .frame(height: comfortable ? Theme.Control.heightComfortable : Theme.Control.height)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Theme.accentSoft)
                                    .matchedGeometryEffect(id: "segment", in: slide)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(RowFeedbackStyle(bleed: 6, radius: 8))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .padding(2)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

extension SegmentedTabs where Value: RawRepresentable, Value.RawValue == String {
    init(options: [Value], selection: Binding<Value>, comfortable: Bool = false) {
        self.init(options: options, selection: selection, title: { L10n.enumLabel($0) }, comfortable: comfortable)
    }
}

struct BrandToggleChip: View {
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        Group {
            if isOn {
                Button(title) { isOn.toggle() }
                    .buttonStyle(AccentButtonStyle(small: true))
            } else {
                Button(title) { isOn.toggle() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            }
        }
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityValue(isOn ? L10n.text("apple.theme.on.13001175") : L10n.text("apple.theme.off.ca7981b4"))
    }
}

struct ChoiceChip: View {
    var title: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Group {
            if isSelected {
                Button(title) { action() }
                    .buttonStyle(AccentButtonStyle(small: true))
            } else {
                Button(title) { action() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            }
        }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

struct TimeLimitChips: View {
    @Binding var minutesText: String
    @Binding var noLimit: Bool
    var onChange: () -> Void = {}

    private static let presets: [(minutes: Int, title: String)] = [
        (15, "15m"), (30, "30m"), (60, "1h"), (180, "3h"), (480, "8h"),
    ]

    var body: some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            ForEach(Self.presets, id: \.minutes) { preset in
                ChoiceChip(title: preset.title, isSelected: isPreset(preset.minutes)) {
                    noLimit = false
                    minutesText = String(preset.minutes)
                    onChange()
                }
            }
            ChoiceChip(title: L10n.text("apple.theme.no_limit.f7fcff0d"), isSelected: noLimit) {
                noLimit = true
                onChange()
            }
        }
    }

    private func isPreset(_ minutes: Int) -> Bool {
        !noLimit && (Int(minutesText) ?? 0) == minutes
    }
}

struct ConcurrentChips: View {
    @Binding var countText: String
    var onChange: () -> Void = {}

    private static let presets: [(count: UInt32, title: String)] = [
        (1, "1"), (2, "2"), (4, "4"), (8, "8"),
    ]

    var body: some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            ForEach(Self.presets, id: \.count) { preset in
                ChoiceChip(title: preset.title, isSelected: isPreset(preset.count)) {
                    countText = String(preset.count)
                    onChange()
                }
            }
            ChoiceChip(title: L10n.text("apple.theme.no_cap.59db2115"), isSelected: isUncapped) {
                countText = "0"
                onChange()
            }
        }
    }

    private var isUncapped: Bool {
        (UInt32(countText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1) == 0
    }

    private func isPreset(_ count: UInt32) -> Bool {
        !isUncapped && (UInt32(countText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) == count
    }
}

private struct SegmentButton: View {
    var label: String
    var symbol: String
    var isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if !symbol.isEmpty {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .foregroundStyle(isSelected ? Theme.accent : Theme.controlGlyph)
            .padding(.horizontal, symbol.isEmpty ? 10 : 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                            ? Theme.accentSoft
                            : (isHovering ? Theme.rowHighlight.opacity(0.7) : .clear)
                    )
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onHover { isHovering = $0 }
    }
}

struct AppMenuPicker<Option: Hashable>: View {
    var title: String = ""
    var options: [(value: Option, label: String)]
    @Binding var selection: Option
    var refresh: (() async -> Void)?
    var searchThreshold: Int = 10

    @State private var isPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: title.isEmpty ? 0 : 3) {
            if !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Theme.controlGlyph)
            }
            if usesPanel {
                panel
            } else {
                menu
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var usesPanel: Bool {
        options.count >= searchThreshold
    }

    private var panel: some View {
        PickerPanel(title: title.isEmpty ? L10n.text("apple.theme.choose.c7f93783") : title, isPresented: $isPresented) {
            PickerOptionList(
                choices: options.map { PickerChoice(value: $0.value, label: $0.label) },
                isSelected: { $0 == selection },
                prompt: title.isEmpty ? L10n.text("apple.theme.filter.638e249f") : L10n.text("apple.theme.filter_0.50ee55cd", "\(title.lowercased())"),
                emptyMessage: L10n.text("apple.theme.nothing_to_choose_from.8bc6d972"),
                monospaced: false,
                refresh: refresh,
                pick: { value in
                    selection = value
                    isPresented = false
                },
                accessory: nil
            )
        } label: {
            field
        }
    }

    private var menu: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button(option.label) {
                    selection = option.value
                }
            }
            if refresh != nil {
                Button {
                    Task { await refresh?() }
                } label: {
                    Label(L10n.text("apple.theme.refresh_list.3cf8d662"), systemImage: "arrow.clockwise")
                }
            }
        } label: {
            field
        }
        // AppKit menus keep their first item list. A new agent must
        // remount this control or the previous models stay on screen.
        .id(optionsIdentity)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(QuietLinkStyle())
        .fixedSize(horizontal: false, vertical: true)
    }

    private var field: some View {
        HStack(spacing: 6) {
            Text(selectedLabel)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .contentShape(.rect)
    }

    private var optionsIdentity: String {
        options.map { "\($0.value)\u{1e}\($0.label)" }.joined(separator: "\u{1f}")
    }

    private var selectedLabel: String {
        options.first { $0.value == selection }?.label ?? ""
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: WidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(WidthKey.self) { measured in
                // A zero is not a width, it is a view that has not been laid
                // out yet, and a lazy stack recycling its rows can produce one
                // mid-scroll. Answering it means picking the narrow layout for
                // a pane that is nothing of the sort, then picking the wide one
                // back a frame later: two full rebuilds of whatever is inside,
                // for a measurement that was never real.
                guard measured > 0 else { return }
                let next = quantised(measured, step: 4)
                if width != next { width = next }
            }
    }
}

private struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension CGFloat {
    /// Folds the display the window opens on into the fixed breakpoints.
    ///
    /// macOS lays out in points, and a scaled display hands the app fewer of
    /// them: a 13-inch MacBook at its default resolution presents about 1440
    /// points, and a display set to a lower effective resolution fewer still.
    /// The layout was tuned on a full-size desktop; on a small screen the
    /// fixed columns add up to more than the window can hold and the inspector
    /// runs past the edge. This factor shrinks those numbers with the screen,
    /// so the same window fits a 1080p panel and a compact laptop.

    static var twoColumnWidth: CGFloat { DisplayFit.box(950) }

    static var threeAcrossWidth: CGFloat { DisplayFit.box(1200) }

    static var rowDetailWidth: CGFloat { DisplayFit.box(720) }

    static var panelWidth: CGFloat { DisplayFit.box(330) }
}

enum DisplayFit {
    #if os(macOS)
    private static var tracked: NSScreen?
    #else
    @Observable
    fileprivate final class TrackedScreen {
        var size: CGSize?
    }

    fileprivate static let trackedScreen = TrackedScreen()
    #endif

    private static let referenceWidth: CGFloat = 1440
    private static let referenceHeight: CGFloat = 900

    private static let floor: CGFloat = 0.6

    #if os(macOS)
    @MainActor
    static func update(screen: NSScreen?) {
        guard let screen else { return }
        tracked = screen
        cachedFactor = nil
    }

    /// The factor for the tracked screen, worked out once. Every fitted font
    /// in every view body asks for it, and each ask read the screen's visible
    /// frame from AppKit. Cleared when the screen or its parameters change.
    private static var cachedFactor: CGFloat?
    private static var watchingScreens = false

    private static func watchScreenChanges() {
        guard !watchingScreens else { return }
        watchingScreens = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in cachedFactor = nil }
    }
    #else
    static func update(screenSize: CGSize) {
        guard trackedScreen.size != screenSize else { return }
        trackedScreen.size = screenSize
    }
    #endif

    #if os(macOS)
    private static var screenSize: CGSize {
        tracked?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size ?? CGSize(
            width: referenceWidth,
            height: referenceHeight
        )
    }
    #else
    private static var screenSize: CGSize {
        trackedScreen.size ?? .zero
    }
    #endif

    static var factor: CGFloat {
        #if os(macOS)
        if let cachedFactor { return cachedFactor }
        let value = measuredFactor
        cachedFactor = value
        watchScreenChanges()
        return value
        #else
        return measuredFactor
        #endif
    }

    private static var measuredFactor: CGFloat {
        let size = screenSize
        let byWidth = size.width / referenceWidth
        let byHeight = size.height / referenceHeight
        return min(max(min(byWidth, byHeight), floor), 1)
    }

    private static let textFloor: CGFloat = 0.85

    static func scale(_ value: CGFloat) -> CGFloat {
        value * factor
    }

    static func box(_ value: CGFloat) -> CGFloat {
        value * max(factor, textFloor)
    }

    static func dp(_ points: CGFloat) -> CGFloat {
        points * max(factor, textFloor)
    }
}
