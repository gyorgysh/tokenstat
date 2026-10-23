// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum TeamLaneCheck {
    /// The editor presents a command as text, but the host stores an argv.
    /// Saving another field must preserve argument boundaries in an existing
    /// command, including spaces or empty arguments.
    static func arguments(_ text: String, loaded: [String]) -> [String] {
        text == loaded.joined(separator: " ") ? loaded : text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
