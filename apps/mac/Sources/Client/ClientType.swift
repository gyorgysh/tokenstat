// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

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

    static let figureSmall = Theme.font(22, weight: .semibold, relativeTo: .title2)
        .monospacedDigit()

    static let screenTitle = Theme.title3.weight(.semibold)

    static let sectionTitle = Theme.headline

    static let body = Theme.body

    static let label = Theme.subheadline

    static let caption = Theme.caption

    static let rowFigure = Theme.callout.monospacedDigit()

    /// The +N and -N beside an edit.
    ///
    /// One role so a count sits with the path beside it, in the same face as
    /// `code`, and so two edits in one thread cannot disagree about the size
    /// of the same figure.
    static let diffFigure = Theme.monoText(13, relativeTo: .footnote).weight(.medium)

    /// Source code, and the gutter beside it.
    ///
    /// One role for both, because a diff's line numbers and its lines have to
    /// share metrics or the columns come apart. A text style rather than a
    /// point size, like everything else here, so code scales with Dynamic Type
    /// and stays aligned while it does.
    static let code = Theme.monoText(13, relativeTo: .footnote)
}

#endif
