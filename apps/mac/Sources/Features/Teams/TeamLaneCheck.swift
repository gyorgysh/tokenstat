// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum TeamLaneCheck {
    static func arguments(_ text: String, loaded: [String]) -> [String] {
        text == loaded.joined(separator: " ") ? loaded : text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
