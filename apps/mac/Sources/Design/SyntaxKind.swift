// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

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
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SyntaxKind(rawValue: raw) ?? .unknown
    }
}
