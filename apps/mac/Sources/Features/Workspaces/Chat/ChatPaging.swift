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
/// The host answers at most `hostPageEventsMax` records, and stops a page
/// early once it weighs more than its byte bound (`PAGE_EVENTS_MAX` and
/// `PAGE_BYTES` in `tokenstat-host/src/chat.rs`). Every count here stays
/// under the record ceiling, so a short page is always the weight bound at
/// work, never a clamp: dense pages end early with more behind them, and an
/// older host with the smaller bound only ends them earlier.
enum ChatPaging {
    /// How many records a conversation opens on. One latest page on ordinary
    /// open; what comes before is fetched a page at a time as somebody
    /// scrolls back.
    static let openPageEvents = 1500
    /// How many records each older page carries. Nearly as large as the
    /// opening page, for the same reason: a backend that streams spends
    /// hundreds of records on a handful of paragraphs, and pulling a few
    /// dozen at a time meant a chat of any length was read back in dozens
    /// of insertions, each one a walk over the rows and a correction of
    /// the reader's place.
    static let pageEvents = 1200
    /// How many records a background preview fetch asks for. Warming keeps
    /// only the newest tail (at most 150 rows in `ChatRecentMessages`), so a
    /// preview needs no more than it always did, and asking for the full
    /// opening page on every folder open and chat switch would triple the
    /// background reads for rows nobody keeps.
    static let previewPageEvents = 500
    /// The most records the host hands back in one page. Mirrors
    /// `PAGE_EVENTS_MAX`; a request above this is clamped, not refused.
    static let hostPageEventsMax = 2000
}
