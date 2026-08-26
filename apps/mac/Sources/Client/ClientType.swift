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
    /// Tabular figures, because a number that changes on refresh must not
    /// make everything beside it jump. Same argument as `Theme.numeric` on the
    /// Mac, reached differently: a size that scales with Dynamic Type rather
    /// than one that scales with the window.
    static let figure = Theme.font(34, weight: .semibold, relativeTo: .largeTitle)
        .monospacedDigit()

    /// A figure sharing a row with other figures.
    static let figureSmall = Theme.font(22, weight: .semibold, relativeTo: .title2)
        .monospacedDigit()

    /// A sheet's own heading.
    static let screenTitle = Theme.title3.weight(.semibold)

    /// A card's heading.
    static let sectionTitle = Theme.headline

    /// Sentences.
    static let body = Theme.body

    /// A figure's label, a row's name.
    static let label = Theme.subheadline

    /// A date, a count, the quiet second line under a name.
    static let caption = Theme.caption

    /// A number inside a row or a list, where it has to line up with the
    /// numbers above and below it.
    static let rowFigure = Theme.callout.monospacedDigit()

    /// Source code, and the gutter beside it.
    ///
    /// One role for both, because a diff's line numbers and its lines have to
    /// share metrics or the columns come apart. A text style rather than a
    /// point size, like everything else here, so code scales with Dynamic Type
    /// and stays aligned while it does.
    static let code = Theme.monoText(13, relativeTo: .footnote)
}

#endif
