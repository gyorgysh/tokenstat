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
/// The brand colours are the same two the CLI uses (`ui.rs` `ACCENT_RGB` and
/// `SECONDARY_RGB`). One product, one palette: a user running both should not
/// see two different purples. Change them in both places or in neither.
///
/// Surfaces are flat and explicit rather than translucent material. A window
/// full of dense numbers wants a steady background: vibrancy pulls whatever is
/// behind the window into the table, and columns of digits are hard enough to
/// read without the desktop showing through them.
enum Theme {
    static let accent = Color(red: 0xB2 / 255, green: 0x64 / 255, blue: 0xEB / 255)
    static let secondary = Color(red: 0x67 / 255, green: 0xE8 / 255, blue: 0xF9 / 255)

    /// Behind everything.
    static let background = Color.adaptive(light: hex(0xF7F7F8), dark: hex(0x0A0A0B))
    /// Sidebar, one step darker than the content beside it.
    static let sidebar = Color.adaptive(light: hex(0xF0F0F1), dark: hex(0x0D0D0F))
    /// Cards and panels.
    static let panel = Color.adaptive(light: .white, dark: hex(0x141416))
    /// Hairlines. These carry the structure that shadows used to.
    static let border = Color.adaptive(light: hex(0xE2E2E5), dark: hex(0x232326))
    /// A selected row.
    static let rowHighlight = Color.adaptive(light: hex(0xE4E4E8), dark: hex(0x1C1C1F))

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

    static let cardRadius: CGFloat = 8

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
    static let sectionHeader = Font.system(size: 10, weight: .semibold)
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
        .padding(Theme.Space.l)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .font(Theme.numeric(10))
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
                        Image(systemName: item.symbol)
                            .font(.system(size: 10))
                        Text(item.label)
                            .font(.system(size: 12, weight: active ? .medium : .regular))
                    }
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(maxHeight: .infinity)
                    .background(active ? Theme.panel : .clear)
                    .overlay(alignment: .top) {
                        // The active tab is marked along its top edge rather
                        // than underlined, so the strip reads as tabs attached
                        // to the pane below instead of as a toolbar.
                        Rectangle()
                            .fill(active ? Theme.accent : .clear)
                            .frame(height: 2)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(height: 32)
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
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
