// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// The client's type scale. Every size on a phone screen comes from here.
///
/// The first build picked a style per call site: `.title3` here, `.headline`
/// there, a 34 point symbol, a rounded `.title`. Read together they had no
/// hierarchy, only variation, and the screen looked big in one place and
/// cramped in the next. Seven roles is enough for an app that shows numbers and
/// labels, and a list this short is one somebody can hold in their head.
///
/// Every role is a Dynamic Type **text style**, never a fixed point size, so all
/// of it scales to the accessibility sizes. Fixed sizes are allowed for a symbol
/// inside a fixed frame, and nowhere else.
enum ClientType {
    /// The one number a screen is about.
    ///
    /// Monospaced digits, because a figure that changes on refresh must not
    /// make everything beside it jump. Same argument as `Theme.numeric` on the
    /// Mac, reached differently: a relative style so it scales, rather than a
    /// point size so it does not.
    static let figure = Font.system(.largeTitle, design: .rounded)
        .weight(.semibold)
        .monospacedDigit()

    /// A figure sharing a row with other figures.
    static let figureSmall = Font.system(.title2, design: .rounded)
        .weight(.semibold)
        .monospacedDigit()

    /// A sheet's own heading.
    static let screenTitle = Font.title3.weight(.semibold)

    /// A card's heading.
    static let sectionTitle = Font.headline

    /// Sentences.
    static let body = Font.body

    /// A figure's label, a row's name.
    static let label = Font.subheadline

    /// A date, a count, the quiet second line under a name.
    static let caption = Font.caption

    /// A number inside a row or a list, where it has to line up with the
    /// numbers above and below it.
    static let rowFigure = Font.callout.monospacedDigit()
}

#endif
