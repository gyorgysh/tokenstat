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
    /// The quiet circular seat behind a small chrome glyph, such as a close
    /// button.
    ///
    /// Explicitly adaptive rather than `Color.primary` at low opacity: the
    /// hierarchical primary resolves against whatever material sits behind
    /// it, and on a floating panel at a scaled resolution that read as a
    /// wrong tint. An explicit light/dark pair cannot drift.
    static let controlSeat = Color.adaptive(
        light: Color.black.opacity(0.06),
        dark: Color.white.opacity(0.09)
    )
    /// A small chrome glyph, such as a close button's xmark.
    ///
    /// Explicitly adaptive rather than `.secondary` or `Color.primary`: the
    /// hierarchical styles resolve through whatever sits behind the glyph,
    /// and on a dark tab strip at a scaled resolution the xmark came out the
    /// wrong colour. A plain adaptive pair cannot pick up its background.
    static let controlGlyph = Color.adaptive(light: hex(0x6B6876), dark: hex(0xA8A5B5))

    /// The same glyph while the pointer is over it.
    static let controlGlyphHover = Color.adaptive(light: hex(0x2A2831), dark: hex(0xE9E7F0))
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
    //
    // Success is the accent, deliberately: a green "good" sat outside the
    // purple design everywhere it appeared (toasts, status pills, live dots),
    // so the app's own active colour is what "good" means now. Warning and
    // danger stay distinct, because amber and red carry meaning the accent
    // does not.
    static let success = accent
    static let warning = Color(red: 0xE0 / 255, green: 0xA9 / 255, blue: 0x3B / 255)
    static let danger = Color(red: 0xD6 / 255, green: 0x45 / 255, blue: 0x3F / 255)

    /// A session that is doing something right now.
    ///
    /// The accent, so "something is happening" is the app's own colour rather
    /// than a traffic light. Named separately from `success` because a run
    /// that is working has not succeeded at anything yet, and the two will
    /// want to diverge the first time a state screen shows both.
    static let stateWorking = accent
    /// A session that is alive and quiet. Grey, and quiet in the layout too:
    /// most rows are idle most of the time, so this must not draw the eye.
    static let stateIdle = Color.adaptive(light: hex(0x9A97A6), dark: hex(0x6E6A80))

    /// Lines added, and lines removed.
    ///
    /// Green and red because a diff is the one place those two colours are
    /// not a traffic light: they are what every tool that shows a diff uses,
    /// and a purple `+128` beside a purple `−41` says nothing. Muted against
    /// the plain `.green` and `.red`, which are loud enough to pull the eye
    /// off the name of the workspace they belong to.
    static let diffAdded = Color.adaptive(light: hex(0x2E8B57), dark: hex(0x5FBF8B))
    static let diffRemoved = Color.adaptive(light: hex(0xC2453F), dark: hex(0xE8827C))

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

    /// A drop shadow, weighted for the appearance it lands on.
    ///
    /// The same black at the same opacity is not the same shadow twice. On a
    /// dark window it barely reads and mostly gives an edge some depth; on a
    /// near-white one it is a grey smudge under every button and popover, and
    /// enough of them turn a flat, quiet layout into something that looks
    /// embossed. Light mode gets a little under half the weight, which is
    /// where the separation survives and the smudge does not.
    ///
    /// Pass the dark-mode opacity, which is the one these were tuned at.
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

    /// Spacing scale. Four points, so layouts stay on a rhythm instead of
    /// accumulating one-off paddings.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 20
        static let xl: CGFloat = 32
    }

    /// Button metrics.
    ///
    /// Padding alone does not make two buttons the same size: a button with a
    /// glyph is taller than one without, and a dense variant beside a regular
    /// one is short by the difference in vertical padding. Both of those were
    /// visible in the SSH library, where three sizes shared one row. Height is
    /// set, not derived, and paired actions share a minimum width so Cancel and
    /// Save are the same shape.
    enum Control {
        /// Sheets, detail footers, empty-state calls to action.
        static let height: CGFloat = 30
        /// Row accessories and card headers.
        static let heightSmall: CGFloat = 24
        /// Buttons that sit beside each other in a footer.
        static let pairedWidth: CGFloat = 88
        /// Row height for a list a person scans rather than reads.
        #if os(macOS)
        static let rowHeight: CGFloat = 32
        #else
        static let rowHeight: CGFloat = 44
        #endif
    }

    /// Anatomy of an app-owned task sheet.
    ///
    /// In-window chrome stays on `chromeBarMetrics()`, the 40pt metric for
    /// adjacent bars. A modal is a different object: a two-line heading, a
    /// close seat that must not crowd the window curve, and a footer that
    /// holds 30pt buttons with air above and below. Callers that need these
    /// numbers live in `ThemedSheet`.
    enum Modal {
        /// Minimum height of the header. A 40pt chrome bar cannot hold a
        /// title, a subtitle and a close control without clipping into the
        /// rounded top.
        static let headerMinHeight: CGFloat = 72
        /// Icon seat beside the title. Larger than a chrome glyph, smaller
        /// than the 48pt mark on a permission sheet.
        static let iconSeat: CGFloat = 36
        /// Footer that holds one row of 30pt actions, optically centred.
        static let footerHeight: CGFloat = 64
        /// Inset of the body from the window edges and the header/footer
        /// rules. Generous on purpose: a sheet that hugs its copy looks
        /// unfinished, and this is the one padding owner for that air.
        static let bodyPadding: CGFloat = 32
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

    // MARK: - Type
    //
    // Every font in the app comes from here, and the two families come from
    // `AppFonts`. The point sizes below are exactly what the system's own text
    // styles give on each platform, so adopting a typeface changed the shape
    // of the words and nothing about the size or position of anything. A Mac
    // is not a phone at 17 points, and the migration would have been a
    // relayout of every screen rather than a change of face.
    //
    // `scripts/check-fonts.sh` keeps it that way: a bare `.font(.caption)` or
    // `.system(size:)` in the app's own views is rejected, the way a bare
    // `Color.blue` is.

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
            // The face failed to load. Fall back to the system style rather
            // than to a frozen size: the point sizes here are the styles' own
            // defaults anyway, and text frozen at a fixed size is exactly
            // the unreadability `relativeTo` exists to prevent.
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

    /// Numbers that sit in columns must not jitter as they update, so anything
    /// numeric uses tabular figures.
    ///
    /// The interface face, not the terminal one. Manrope's tabular figures
    /// already hold a column still, which is the whole requirement, and a stat
    /// tile is a headline rather than a readout.
    static func numeric(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        fitted(size, weight: weight, mono: false).monospacedDigit()
    }

    /// Identifiers read character by character: model ids, machine ids, paths.
    /// Monospaced so strings that look alike do not read alike.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        fitted(size, weight: weight, mono: true)
    }

    /// Small uppercase label above a group.
    static var sectionHeader: Font {
        fitted(12, weight: .semibold, mono: false)
    }

    // The system's text styles, in the app's face and at the system's sizes.
    //
    // A Mac's body text is 13 points and a phone's is 17, and the rest of each
    // ladder follows from that. Both are spelled out rather than derived,
    // because the two ladders are not one ladder times a constant.
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
    /// Conversation prose is read for minutes at a time, not scanned as Mac
    /// chrome. Give it a calmer reading size without inflating every sidebar,
    /// table and utility label that correctly uses the 13-point body style.
    static var chatBody: Font { font(14, weight: .regular, relativeTo: .body) }
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
    /// Brand mark or other leading tile, same place the website and the
    /// phone put a vendor mark: left of the title, not in the trailing
    /// accessory.
    var leading: AnyView?
    /// Trailing accessory in the header, for a count or a control.
    var accessory: AnyView?
    /// Take all the height offered rather than only what the content needs.
    ///
    /// Off by default, because a card in a scrolling column should end where
    /// its content ends. On for a card sharing a row with others: the row is
    /// already sized to the tallest card, and a card that does not fill it
    /// leaves its border stopping short while its neighbour's carries on, which
    /// is what "the panels do not match" looks like. Filling has to happen
    /// *inside* the card, before the background is drawn, which is why this is
    /// a parameter here and not a `.frame` at the call site.
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

    /// Same card, with a product FeatureMark in the header leading slot.
    ///
    /// The website puts a mint chip next to every titled block. Cards that
    /// omit it look like a different product, so this is the usual call.
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

    /// Header only. A content `EmptyView` still occupies a VStack slot and
    /// leaves a gap under the title, so header-only cards use this instead.
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
            // Content sits at the top of a filled card, rather than being
            // spread down it. A quota bar belongs under its heading whatever
            // the neighbour's card happens to be doing.
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
                        // The note is a qualifier, not the data. When the pair
                        // is squeezed it gives way first, shrinking before it
                        // ever truncates, instead of pushing the value around.
                        .layoutPriority(-1)
                        .minimumScaleFactor(0.8)
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

/// Names the folder a scoped screen is showing.
///
/// Accent-soft rather than grey. It is not chrome, it is the answer to "whose
/// cards are these", and the same accent already marks the folder in the
/// sidebar, so the two read as the same fact stated twice rather than as two
/// facts.
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
        .help("Showing \(label)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Showing \(label)")
    }
}

/// Sidebar / inspector marks for the shared detail chrome bar.
///
/// Injected by `RootView` so every destination gets the same leading controls
/// without each screen re-wiring ⌘B / ⌥⌘B.
struct DetailChromeToggles {
    var leftSidebar: AnyView
    var rightInspector: AnyView?
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
    /// Extra leading items after the shared toggles (back, etc.).
    @ViewBuilder var leading: () -> Leading
    /// Something that belongs to the folder rather than to the screen, drawn
    /// immediately after its name. A branch is the example: it says which
    /// version of that folder is on screen, so it reads as part of the folder
    /// and not as one more control at the far end of the bar.
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var trailing: () -> Trailing
    /// Which folder this screen is showing, when it is showing one.
    ///
    /// Lives on the bar rather than on each screen so every scoped screen says
    /// so in the same place and the same way. With the sidebar collapsed it is
    /// the only thing on screen that names the folder.
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
        // Nested HStacks: a multi-child `@ViewBuilder` is a TupleView that
        // stacks vertically if dropped in raw. Leading/trailing must stay one
        // horizontal group each.
        HStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                // Back first. A back control is the one thing on a screen that
                // leaves it, and the top left corner is where a hand goes for
                // that without reading anything. The sidebar toggle is chrome
                // and can move over by one; on the screens with nothing to go
                // back from it is still the first control in the row.
                leading()
                toggles?.leftSidebar
                if let scope {
                    scope
                }
                accessory()
            }
            Spacer(minLength: 0)
            HStack(spacing: Theme.Space.s) {
                trailing()
                // Last, so it is the control nearest the edge it opens, and so
                // a destination's own actions keep their order regardless of
                // whether that destination has an inspector at all.
                if let right = toggles?.rightInspector {
                    right
                }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .chromeBarMetrics()
        .background(Theme.tabStrip)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    /// Tall enough for a 30pt circular mark with a little breathing room, and
    /// for a compact segmented period picker on Insights.
    static var height: CGFloat { DetailChromeBarHeight }
}

/// Shared height for `DetailChromeBar` and matching chrome rows.
let DetailChromeBarHeight: CGFloat = 40
let DetailChromeBottomSpacing: CGFloat = 3

/// The inside geometry every destination chrome row shares.
///
/// The bottom breathing room is intentionally part of the metric rather than
/// a local adjustment. A 40pt bar with 3pt of bottom inset centres its visible
/// content 1.5pt higher, which is what lets adjacent headers meet on the same
/// optical baseline.
private struct ChromeBarMetrics: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.bottom, DetailChromeBottomSpacing)
            .frame(maxWidth: .infinity)
            .frame(height: DetailChromeBarHeight)
    }
}

extension View {
    /// Apply the fixed height and baseline correction shared by app chrome.
    func chromeBarMetrics() -> some View {
        modifier(ChromeBarMetrics())
    }
}

/// A hairline drawn from tokenstat's palette, never the platform material.
///
/// `Divider` resolves through the surrounding system surface, which is why a
/// sheet or a dark panel could grow an unrelated grey line. Rules in ordinary
/// content are horizontal by default; the few split panes say `.vertical` so
/// their axis remains deliberate and readable in source.
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

/// A flat tab strip, in place of the reference layout's row of agent tabs.
///
/// Not a segmented `Picker`: those are capsule shaped and centred, and this has
/// to sit flush with the top of the pane and read as part of the chrome.
struct TabStrip<Tab: Hashable>: View {
    /// An empty `symbol` draws the label alone, for a strip narrow enough that
    /// icons would push the labels into truncation.
    var tabs: [(tab: Tab, label: String, symbol: String)]
    @Binding var selection: Tab
    /// When false, only the tab row is drawn (no full-width fill or bottom
    /// rule). The parent chrome row owns those (Insights: tabs + actions).
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
                    // The accent, not just a heavier weight. On a dark strip a
                    // selected tab drawn as a slightly different dark panel is
                    // the same colour as everything around it, and which tab
                    // was selected became a guess.
                    // Explicit chrome colour, not `.secondary`. Hierarchical
                    // styles resolve through the window (and through any
                    // material still sitting behind the strip), so inactive
                    // tabs went grey-unfocused on the inspector even when the
                    // window was key.
                    .foregroundStyle(active ? Theme.accent : Theme.controlGlyph)
                    .padding(.horizontal, Theme.Space.xs)
                    // Every tab takes an equal share of the strip's width.
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
        .background(showsChrome ? Theme.sidebar : Color.clear)
        .overlay(alignment: .bottom) {
            if showsChrome {
                Rectangle().fill(Theme.border).frame(height: 1)
            }
        }
    }

    /// A generic type cannot hold a static stored property, so this is a
    /// computed one.
    static var height: CGFloat { 28 }
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
    /// Somebody else's exact words, under the sentence that says what
    /// happened. Git's output is the case this exists for: it names the file,
    /// the hook or the remote, and rewording loses that, but on its own it is
    /// plumbing rather than an answer. Shown quieter and monospaced, because
    /// it is a quotation and not the message.
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Label(text, systemImage: symbol ?? severity.symbol)
                .font(.callout)
                .foregroundStyle(severity.tint)
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

/// What a screen shows before it has anything to show.
///
/// One component for the whole app, for the reason `Banner` is one component:
/// an empty Automations screen and an empty Insights screen are the same
/// situation and should not look like two different products.
///
/// The rule it encodes is that an empty screen explains itself. "No runs yet"
/// tells somebody what they can already see. The headline names what is
/// missing, the line under it says what the thing is *for*, and the button is
/// the one action that ends the empty state, so nobody has to go looking for
/// where to start.
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
                // Wide enough to read, narrow enough that the eye does not have
                // to travel back across a full-screen window to find the line.
                .frame(maxWidth: 420)
            action
                .padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
        // The message is capped at 420 points and nothing else held it off the
        // edges, so on a phone narrower than that cap the sentence ran into
        // both bezels with no margin at all.
        .padding(.horizontal, Theme.Space.l)
    }
}

/// Whether an editable field has something waiting to be written.
enum FieldSaveState: Equatable {
    case idle
    case dirty
    case saving
    case saved
    case failed
}

/// Unsaved / Saving / Saved next to Save and Cancel.
///
/// Implicit blur-save hid failures. A card that looks finished after a
/// keystroke, then reverts later, is worse than a button that says it wrote.
struct FieldSaveBar: View {
    var state: FieldSaveState
    var saveTitle: String = "Save"
    var canSave: Bool = true
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            status
            Spacer(minLength: 0)
            if state == .dirty || state == .failed {
                Button("Cancel", .dismiss, action: onCancel)
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
            Text("Unsaved")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.warning)
        case .saving:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Saving")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .saved:
            Label("Saved", systemImage: "checkmark")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.success)
        case .failed:
            Text("Not saved")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.danger)
        }
    }
}

/// A short-lived confirmation that does not push the content column down.
struct TransientToast: View {
    @Binding var message: String?
    var severity: Banner.Severity = .success
    /// Optional way to the thing the message is about.
    ///
    /// A toast that says where something landed has to be able to take you
    /// there, or it is a notification that the app knows something you do not.
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        if let message {
            HStack(spacing: Theme.Space.s) {
                Label(message, systemImage: severity.symbol)
                if let actionLabel, let action {
                    Button(actionLabel) {
                        action()
                        self.message = nil
                    }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.accent)
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

/// Circular icon mark for the window toolbar.
///
/// Sidebar toggle, refresh, scan and fetch all share this seat so neighbouring
/// marks use the same diameter and border rather than mixing a custom view
/// with the system's bordered toolbar style (those read as different radii).
struct ToolbarIconButton: View {
    /// Outer diameter of the circular seat. Fixed so every toolbar mark matches.
    /// 36pt is still under the 44pt HIG floor but matches dense chrome; the
    /// content shape is expanded where the control sits alone.
    static let diameter: CGFloat = 36

    let systemImage: String
    var help: String = ""
    /// Accent the glyph (open sidebar, selected state).
    var isAccent: Bool = false
    /// Replace the glyph with a small spinner.
    var isBusy: Bool = false
    /// Optional accent dot on a corner (closed-panel cue).
    var showsBadge: Bool = false
    var badgeAlignment: Alignment = .topLeading
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: badgeAlignment) {
                Group {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(glyphColor)
                    }
                }
                .frame(width: Self.diameter, height: Self.diameter)
                .background(
                    Circle().fill(isHovering ? Theme.rowHighlight : Theme.controlSeat)
                )
                .overlay(
                    Circle().strokeBorder(
                        Theme.border.opacity(isHovering ? 0.9 : 0.55),
                        lineWidth: 1
                    )
                )
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
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private var glyphColor: Color {
        if isAccent { return Theme.accent }
        return isHovering ? Theme.controlGlyphHover : Theme.controlGlyph
    }
}

/// Left or right chrome toggle for toolbars and in-content chips.
///
/// Built from the system `sidebar.left` / `sidebar.right` symbols so the mark
/// always paints in a macOS toolbar. Open = accent tint. Closed = quiet glyph
/// + accent dot (the "panel is hidden" cue). Same circular seat as refresh.
struct SidebarToggleButton: View {
    enum Edge {
        case leading
        case trailing
    }

    let edge: Edge
    /// Whether the pane this button controls is currently on screen.
    let isOpen: Bool
    let action: () -> Void
    /// Full help string, including the shortcut (e.g. "Hide Sidebar (⌘B)").
    var help: String = ""

    var body: some View {
        ToolbarIconButton(
            systemImage: edge == .leading ? "sidebar.left" : "sidebar.right",
            help: help,
            isAccent: isOpen,
            showsBadge: !isOpen,
            badgeAlignment: edge == .leading ? .topLeading : .topTrailing,
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
    @ViewBuilder var content: () -> Content
    @ViewBuilder var accessory: () -> Accessory

    init(
        onClose: @escaping () -> Void,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.onClose = onClose
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 0) {
            content()
            accessory()
            InspectorCloseButton(action: onClose)
                .padding(.trailing, Theme.Space.s)
        }
        // The same optical baseline as `DetailChromeBar`, immediately to its
        // left. The shared modifier owns the 40pt frame and its 3pt correction
        // so a later inspector cannot drift a point or two by accident.
        .chromeBarMetrics()
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
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
    init(onClose: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.init(onClose: onClose, accessory: { EmptyView() }, content: content)
    }
}

/// Closes the right pane, from inside the right pane.
///
/// The toolbar has a toggle, but a toolbar button on the far side of the window
/// is not where anyone looks to dismiss a panel: they look at the panel. Both
/// inspectors carry one so the two panes behave the same way.
struct InspectorCloseButton: View {
    let action: () -> Void
    /// Tooltip and VoiceOver label. Defaults to the inspector copy; a sheet
    /// passes its own so "Close" never announces as "close the inspector".
    var help: String = "Close the inspector"
    var label: String = "Close the inspector"

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovering ? Theme.controlGlyphHover : Theme.controlGlyph)
                .frame(width: 22, height: 22)
                // A bare grey glyph floats on the dark sidebar material and
                // reads as a smudge. A quiet circular seat makes it a control
                // on any background, and the hover fills it like the tab close
                // buttons already do.
                .background(
                    Circle().fill(isHovering ? Theme.rowHighlight : Theme.controlSeat)
                )
                .overlay(
                    Circle().strokeBorder(Theme.border.opacity(isHovering ? 0.9 : 0.55), lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Keep the close target reliable inside a ScrollView and a floating
        // inspector, where a bare glyph can otherwise lose its hit region.
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
        .zIndex(10)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

/// A capsule selector in the app's own language: equal segments inside a
/// bordered panel, the selected one filled with the accent's soft tint and
/// accent text, hover in the same grey the sidebar rows use.
///
/// Deliberately not the system's liquid glass styles: at this size the glass
/// capsules squeezed their labels and the segments sat almost touching, so
/// this is drawn from `Theme` instead.
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

/// Glyph then title, a fixed gap, slightly smaller than the label.
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

/// Soft accent capsule for a primary action in content. Toolbar items stay
/// system-styled.
struct AccentButtonStyle: ButtonStyle {
    /// Dense variant for rows and card accessories.
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ActionLabelStyle(small: small))
            .font(.system(size: small ? 12 : 13, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, small ? 10 : 14)
            .frame(height: small ? Theme.Control.heightSmall : Theme.Control.height)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        configuration.isPressed
                            ? Theme.accent.opacity(0.18)
                            : Theme.accentSoft
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
            )
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The action somebody may regret: delete, drop, revoke, forget.
///
/// A real style rather than `.borderless` plus a hand-set `foregroundStyle`,
/// which is how the SSH library ended up with three button sizes in one row and
/// a delete that read as a link. Same shape as the other two, danger colour,
/// so the eye sorts a row of actions by colour and not by guessing.
struct DestructiveButtonStyle: ButtonStyle {
    /// Dense variant for rows and card accessories.
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ActionLabelStyle(small: small))
            .font(.system(size: small ? 12 : 13, weight: .medium))
            .foregroundStyle(Theme.danger)
            .padding(.horizontal, small ? 10 : 14)
            .frame(height: small ? Theme.Control.heightSmall : Theme.Control.height)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Theme.danger.opacity(0.16) : Theme.danger.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.danger.opacity(0.35), lineWidth: 1)
            )
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The secondary action: the same capsule family as `AccentButtonStyle`, but
/// neutral — panel fill, hairline border, primary text. For revoke, forget and
/// every action that is a real operation but not the one being offered.
/// A system-bordered button next to an accent capsule reads as a different
/// design language on the same row, which is exactly how the Machines screen
/// looked with default Revoke/Forget buttons beside accent Approve/Connect.
struct SecondaryButtonStyle: ButtonStyle {
    /// Dense variant for rows and card accessories.
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ActionLabelStyle(small: small))
            .font(.system(size: small ? 12 : 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, small ? 10 : 14)
            .frame(height: small ? Theme.Control.heightSmall : Theme.Control.height)
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
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.85 : 1)
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
    /// Dense variant, for a field sharing a row with small buttons.
    var small = false
    /// A field that grows with what is typed into it.
    var multiline = false
    /// The face for the text. See `ThemedFieldBox.font`: chaining `.font`
    /// after the style does not reach the text.
    var font: Font?

    // The protocol's requirement is underscored. Nothing to be done about it.
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.themedFieldBox(small: small, multiline: multiline, font: font)
    }
}

extension TextFieldStyle where Self == ThemedFieldStyle {
    /// `TextField("Name", text: $name).textFieldStyle(.themed)`
    static var themed: ThemedFieldStyle { ThemedFieldStyle() }
    static var themedSmall: ThemedFieldStyle { ThemedFieldStyle(small: true) }
    /// For `TextField(..., axis: .vertical)`. The plain themed box pins a
    /// field to one row's height, which is right for a name and wrong for a
    /// paragraph: a field asked to hold three to eight lines still showed one.
    static var themedMultiline: ThemedFieldStyle { ThemedFieldStyle(multiline: true) }
    /// For a code or a fingerprint, where the character shapes matter.
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
    /// Whether the field is allowed to be taller than one row.
    var multiline = false
    /// The face for the text, where the default is wrong.
    ///
    /// A recovery code is the case this exists for. The box used to set its
    /// own font unconditionally, and a font set inside a style sits closer to
    /// the text than one the caller chains on afterwards, so every field that
    /// asked for `Theme.mono` silently got the proportional default back. The
    /// three that did are the vault's code fields, where O against 0 and I
    /// against 1 is the entire reason the host normalises those characters.
    var font: Font?

    /// The face when the caller has not named one.
    ///
    /// A fixed point size does not grow with Larger Text, and a fixed height
    /// could not hold it if it did. The Mac has one text size and wants the
    /// row heights the rest of its chrome uses; the phone has a setting people
    /// rely on, so it takes a scaling style and a floor rather than a ceiling.
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
            // A fixed height is what gives a row of single-line fields the
            // same rhythm as the buttons beside them. A field that grows needs
            // a floor instead, or it holds one line whatever it was asked for.
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
    /// `SecureField("Password", text: $password).themedFieldBox()`
    ///
    /// Pass `font` for a field whose face matters, such as a recovery code.
    /// Chaining `.font` after this does not work: the box sets the font
    /// nearer the text than the caller can.
    func themedFieldBox(
        small: Bool = false,
        multiline: Bool = false,
        font: Font? = nil
    ) -> some View {
        modifier(ThemedFieldBox(small: small, multiline: multiline, font: font))
    }
}

/// A multi-line editor on the app's own surface.
///
/// `TextEditor` paints the platform text view's background and ignores
/// everything around it. Drawing a `Theme.border` on top of that, which is
/// what the snippet editor did, themes the outline of a grey slab and leaves
/// the slab. Hiding the scroll content background is what actually lets a
/// colour through.
struct ThemedEditor: View {
    @Binding var text: String
    /// Monospaced by default: everything this is used for is a command.
    var font: Font = Theme.mono(12)
    var minHeight: CGFloat = 88
    /// Past this it scrolls inside itself rather than asking for more room.
    var maxHeight: CGFloat = 320

    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(font)
            .focused($focused)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, Theme.Space.xs)
            .padding(.vertical, Theme.Space.xs)
            // A floor and a ceiling. A `TextEditor` asked for its content's
            // height grows with whatever is typed into it, and a caller that
            // hands it an unbounded maximum is handing that growth straight to
            // whatever is holding it.
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
    /// Same treatment as `ThemedFieldBox.defaultFont`: the Mac has one text
    /// size and fixed rows, the phone takes a style that grows with Larger
    /// Text.
    static var labelFont: Font {
        #if os(macOS)
        Font.system(size: 13)
        #else
        Font.system(.subheadline)
        #endif
    }

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: Theme.Space.s) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isOn ? Theme.accent : Theme.panel)
                    .frame(width: 18, height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(configuration.isOn ? Theme.accent : Theme.border)
                    )
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                configuration.label
                    .font(Self.labelFont)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // A checkbox that does not say whether it is checked is a button.
        // The stock Toggle this replaces announced "switch, off"; without a
        // value here somebody using VoiceOver could only learn the state by
        // changing it. `BrandToggleChip` in this file already says it.
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

extension ToggleStyle where Self == BrandCheckboxStyle {
    /// `Toggle("Run on connect", isOn: $flag).toggleStyle(.brandCheckbox)`
    static var brandCheckbox: BrandCheckboxStyle { BrandCheckboxStyle() }
}

/// A row of mutually exclusive tabs, in the app's colours.
///
/// `.pickerStyle(.segmented)` is the platform's own control: a grey track with
/// a grey pill sliding along it, which on a dark themed screen is the one
/// piece of chrome wearing somebody else's palette. It carried the SSH
/// library's Hosts/Keys/Snippets, the client's insight breakdowns and the iPad
/// layout choice, so three of the most-looked-at rows in the phone app were
/// grey on purple.
///
/// The selected tab slides rather than cuts, because a segmented control that
/// teleports reads as two separate controls blinking.
struct SegmentedTabs<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    /// What to write on each tab.
    let title: (Value) -> String

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
                        // Same split as `ThemedFieldBox.defaultFont`: fixed on
                        // the Mac, growing with Larger Text on the phone.
                        #if os(macOS)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        #else
                        .font(.system(.subheadline, weight: isSelected ? .semibold : .regular))
                        #endif
                        .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Control.height)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Theme.accentSoft)
                                    .matchedGeometryEffect(id: "segment", in: slide)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        // The tabs are the elements, not the row. Without this a label on the
        // container can stand in for theirs and a screen reader announces one
        // control where there are three to choose between.
        .accessibilityElement(children: .contain)
        .padding(2)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

extension SegmentedTabs where Value: RawRepresentable, Value.RawValue == String {
    /// The common case: an enum whose raw value is already the label.
    init(options: [Value], selection: Binding<Value>) {
        self.init(options: options, selection: selection) { $0.rawValue }
    }
}

/// A two-state chip in the same capsule family as the action buttons.
///
/// A system switch next to `AccentButtonStyle` is a different language on the
/// same row. This is the on/off control for a single flag, so the row stays
/// in Theme.
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
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// One option in a mutually exclusive set, same capsule as `BrandToggleChip`.
///
/// Tapping a selected chip does not deselect it. Empty is a valid state, and
/// it comes from a value that matches none of the options, not from tapping
/// again.
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

/// Minutes as a choice, with the field kept for anything else.
///
/// A gauge on a linear scale crowds three of its four ticks into the first
/// fifth of the bar, and nobody can move it. These chips are the values a
/// person actually picks. A custom number in the field selects none of them.
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
            ChoiceChip(title: "No limit", isSelected: noLimit) {
                noLimit = true
                onChange()
            }
        }
    }

    private func isPreset(_ minutes: Int) -> Bool {
        !noLimit && (Int(minutesText) ?? 0) == minutes
    }
}

/// One segment of `SegmentedCapsulePicker`.
private struct SegmentButton: View {
    var label: String
    var symbol: String
    var isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                // Empty symbol is text-only (period chips: 7d / 30d / All).
                if !symbol.isEmpty {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
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
        .onHover { isHovering = $0 }
    }
}

/// A form field whose control is a menu in the app's own language: caption
/// above, a bordered panel below with the selected value and a chevron, the
/// same shapes the capsules and search box use.
///
/// Replaces the system grey pop-up menus so every selector in a form reads as
/// the same control family.
struct AppMenuPicker<Option: Hashable>: View {
    /// Caption above the control. Empty hides it, for a row that already
    /// names the pickers (Auto commit next to Agent / Model).
    var title: String = ""
    var options: [(value: Option, label: String)]
    @Binding var selection: Option
    /// Reload the options. Offered in the panel when the list is somebody
    /// else's answer that can go stale, and nil when it is a fixed set.
    var refresh: (() async -> Void)?
    /// Above this many options the control opens a searchable panel instead
    /// of a menu.
    ///
    /// A menu is the better control for a short list: it is one press, it
    /// needs no filter, and the platform draws it. It stops being the better
    /// control somewhere around a screenful, which is where reading every
    /// line to find one starts costing more than typing three letters.
    var searchThreshold: Int = 10

    @State private var isPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: title.isEmpty ? 0 : 3) {
            if !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        PickerPanel(title: title.isEmpty ? "Choose" : title, isPresented: $isPresented) {
            PickerOptionList(
                choices: options.map { PickerChoice(value: $0.value, label: $0.label) },
                isSelected: { $0 == selection },
                prompt: title.isEmpty ? "Filter" : "Filter \(title.lowercased())",
                emptyMessage: "Nothing to choose from",
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
                Divider()
                Button("Refresh list") {
                    Task { await refresh?() }
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
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The control itself. A menu and a panel open from the same field.
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
            // Stretched *before* it is measured, so what is read is the width
            // on offer rather than the width the content happens to want.
            //
            // Without this the reader measures its own child, and a child that
            // sizes to its content feeds its width back in as the width to lay
            // out for. In a scrolling list that is a loop with a lever on it:
            // a lazy row arriving with a wide table or a long code line grows
            // the content, which moves the measurement, which rewrites the
            // state, which rebuilds the entire subtree, on the frame the row
            // appeared. It can also sit either side of a breakpoint and
            // oscillate. Measuring the offer is stable because the offer does
            // not depend on the answer.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: WidthKey.self, value: proxy.size.width)
                }
            )
            // Quantised, and only written when it actually moved. A live drag
            // otherwise delivers a new sub-pixel width every frame and reshapes
            // the whole card grid for a change nobody can see.
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

/// Width at which a screen has room for two cards side by side.
///
/// One number, so the breakpoints across the app cannot drift apart.
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

    /// 950 rather than 1000 so the 1260-wide default window still gets the
    /// two-across layout: with the sidebar at its ideal width the detail keeps
    /// ~1030 points, and asking for 1000 put the overview one step further
    /// down than it needed to be.
    static var twoColumnWidth: CGFloat { DisplayFit.box(950) }

    /// Width at which three cards sit side by side in the Overview.
    ///
    /// The third card must not vanish below this; the overview reflows it
    /// underneath instead (see `InsightsView`).
    static var threeAcrossWidth: CGFloat { DisplayFit.box(1200) }

    /// Width at which a list row has room for its secondary detail.
    ///
    /// Below this a row keeps its name, its state and its buttons, and drops
    /// the things beside them: the folder it lives in, when it last ran, the
    /// history strip. Those are worth a glance on a wide window and worth
    /// nothing at all when they squeeze the name of the thing down to an
    /// ellipsis.
    static var rowDetailWidth: CGFloat { DisplayFit.box(720) }

    /// How wide a self-contained panel wants to be in a flowing grid.
    ///
    /// A quota panel is a title and a few bars, so it needs about this much to
    /// avoid wrapping its header and no more. The grid fits as many of these as
    /// the window allows, which is why the count of columns follows the window
    /// rather than a hard breakpoint.
    static var panelWidth: CGFloat { DisplayFit.box(330) }
}

/// The display the window opens on, in points.
enum DisplayFit {
    #if os(macOS)
    /// The screen the fit was last computed for, if any.
    private static var tracked: NSScreen?
    #else
    private static var trackedWidth: CGFloat?
    #endif

    /// The size the fixed layout was tuned against, in points.
    private static let referenceWidth: CGFloat = 1440
    private static let referenceHeight: CGFloat = 900

    /// The smallest the factor goes.
    ///
    /// Small enough that a 1024×640 scaled display (about 720 visible points
    /// wide) still fits the minimum content plus the inspector, and large
    /// enough that the layout never collapses into a phone UI.
    private static let floor: CGFloat = 0.6

    /// Recompute the fit for a screen.
    ///
    /// Called when the window is created and again when it moves to another
    /// display or the display's resolution changes. `nil` (no screen yet)
    /// leaves the last known fit alone rather than snapping the layout.
    #if os(macOS)
    @MainActor
    static func update(screen: NSScreen?) {
        guard let screen else { return }
        tracked = screen
    }
    #else
    static func update(width: CGFloat?) {
        trackedWidth = width
    }
    #endif

    /// Current screen size in points.
    #if os(macOS)
    private static var screenSize: CGSize {
        tracked?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size ?? CGSize(
            width: referenceWidth,
            height: referenceHeight
        )
    }
    #else
    private static var screenSize: CGSize {
        CGSize(width: trackedWidth ?? UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
    }
    #endif

    /// 1 on a full-size display, smaller on one that presents fewer points.
    ///
    /// Both dimensions count: a 16:9 panel scaled to 1280×720 gives the width
    /// of a desktop and the height of a laptop, and a layout sized to the
    /// width alone overflows the window's height.
    static var factor: CGFloat {
        let size = screenSize
        let byWidth = size.width / referenceWidth
        let byHeight = size.height / referenceHeight
        return min(max(min(byWidth, byHeight), floor), 1)
    }

    /// The smallest the *text* factor goes.
    ///
    /// Layout can shrink to 0.6 so the window always fits, but text that
    /// shrinks as far becomes unreadable. Fonts stop at this floor while the
    /// chrome around them keeps compressing, which is the difference between a
    /// small but legible window and a squashed one.
    private static let textFloor: CGFloat = 0.85

    /// Scale a fixed width by the display fit.
    static func scale(_ value: CGFloat) -> CGFloat {
        value * factor
    }

    /// Scale a fixed width that has to hold text.
    ///
    /// Fonts stop shrinking at `textFloor`, so a container that keeps shrinking
    /// past it is guaranteed to clip. Chrome with no text in it can still use
    /// `scale`.
    static func box(_ value: CGFloat) -> CGFloat {
        value * max(factor, textFloor)
    }

    /// Design points → points for text.
    ///
    /// Use for every fixed font size in UI chrome. Terminal and editor glyphs
    /// stay at 1:1. They are content, not chrome.
    static func dp(_ points: CGFloat) -> CGFloat {
        points * max(factor, textFloor)
    }
}
