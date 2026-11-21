// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

/// How much transcript one `chat.eventPage` answer carries.
///
/// Records, not rows: streamed text arrives in many pieces and becomes one
/// paragraph. The cost that hurts is not the number of rows, it is the number
/// of *insertions*: each one changes the content height, and a changed content
/// height makes the lazy stack resolve estimates for the rows in between,
/// which means building them and measuring their text. So a page that reads
/// three times as much history costs one of those walks where three small
/// pages cost three.
///
/// The host also caps page bytes, and older hosts cap record counts lower.
enum ChatPaging {
    /// How many records a conversation opens on. One latest page on ordinary
    /// open; what comes before is fetched a page at a time as somebody
    /// scrolls back.
    static let openPageEvents = 1500
    /// Older pages can use the full history capacity without enlarging the
    /// initial read or the live tail.
    static let pageEvents = hostHistoryPageEventsMax
    /// The same page a chat opens on, so a warmed preview shows the same rows.
    static let previewPageEvents = openPageEvents
    /// Host ceilings for the newest page and for an advancing history cursor.
    static let hostPageEventsMax = 2000
    static let hostHistoryPageEventsMax = 3600

    /// An earlier page has to give the reader a usable, unspent cursor.
    static func hasEarlier(_ reported: Bool, cursor: String?, after previous: String? = nil) -> Bool {
        guard reported, let cursor, !cursor.isEmpty else { return false }
        return cursor != previous
    }
}
