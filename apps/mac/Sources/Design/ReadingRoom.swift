// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// How much of a desktop window a reading surface uses, and where it sits.
///
/// One rule for every detail screen that is mostly read rather than filled
/// in: chat, pull requests, and whatever comes next. Two measurements, and a
/// place to stand.
///
/// **The lane** is what structured content may use. Diffs, tables, tool rows,
/// checks and code carry information in their width, and squeezing them into
/// a prose measure loses that information.
///
/// **The prose measure** is narrower, because a line of text long enough to
/// fill a wide window is a line somebody loses their place in.
///
/// **Leading, not centred.** A screen that centres its lane puts the reader's
/// eye somewhere different at every window size, and leaves two gutters that
/// say nothing. The window's left edge is the one place a line reliably
/// starts, so that is where the reading starts.
enum ReadingRoom {
    #if os(macOS)
    /// Structured content: diffs, checks, tool detail, tables.
    static let laneWidth: CGFloat = 1040
    /// Running text.
    static let proseWidth: CGFloat = 820
    #else
    /// A phone has one measure, and an iPad reaches this and stops.
    static let laneWidth: CGFloat = 780
    static let proseWidth: CGFloat = 780
    #endif

    /// Where the lane sits inside the window it is given.
    static let alignment: Alignment = .topLeading
}
