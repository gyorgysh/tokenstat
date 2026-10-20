// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Mirrors `tokenstat_highlight::Kind`. The Rust side never sends a colour, so
/// the mapping from a kind to a colour lives in `Theme` and switching to light
/// mode is not a round trip through a parser.
enum SyntaxKind: String, Codable, Sendable, Hashable {
    case keyword
    case string
    case number
    case comment
    case type
    case function
    case constant
    case attribute
    case property
    case variable
    case `operator`
    case punctuation
    case markup
    /// A kind this build does not know. Newer core, older app: colour it as
    /// plain text rather than refusing to decode the whole file.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SyntaxKind(rawValue: raw) ?? .unknown
    }
}
