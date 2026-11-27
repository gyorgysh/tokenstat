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
    static let openPageEvents = 3000
    #if os(iOS)
    static let pageEvents = hostHistoryPageEventsMax / 2
    #else
    static let pageEvents = hostHistoryPageEventsMax
    #endif
    static let previewPageEvents = openPageEvents
    static let hostPageEventsMax = 4000
    static let hostHistoryPageEventsMax = 8000

    static func hasEarlier(_ reported: Bool, cursor: String?, after previous: String? = nil) -> Bool {
        guard reported, let cursor, !cursor.isEmpty else { return false }
        return cursor != previous
    }
}
