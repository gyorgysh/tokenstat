// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import Foundation

/// JSON object encoding for a `remote.call` params bag.
enum ClientJSON {
    enum Error: Swift.Error {
        case notObject
    }

    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else { throw Error.notObject }
        return dict
    }
}

/// Confirm copy for starting or stopping work on another machine.
///
/// One helper so Workflows and Automations cannot word the same threat
/// differently. A phone or tablet in somebody else's hand is the model, and
/// peer approval is the only gate below this.
enum ClientJobCopy {
    static func run(_ name: String, folder: String, host: String) -> String {
        "Starts \(name) in \(folder) on \(host)."
    }

    static func stop(_ name: String, host: String) -> String {
        "Stops the run of \(name) on \(host)."
    }

    static func continueGate(_ name: String, host: String) -> String {
        "Lets \(name) continue on \(host)."
    }

    static func budget(_ seconds: UInt64) -> String {
        if seconds == 0 { return "No time limit" }
        let minutes = seconds / 60
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    @MainActor
    static func lastRunPhrase(_ date: Date?) -> String {
        guard let date else { return "Never run" }
        return "Last \(RelativeClock.phrase(for: date, style: .abbreviated))"
    }
}

private let transcriptDisplayCap = 256 * 1024

enum ClientTranscript {
    static func capped(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > transcriptDisplayCap else { return text }
        var start = bytes.count - transcriptDisplayCap
        while start < bytes.count && bytes[start] & 0b1100_0000 == 0b1000_0000 {
            start += 1
        }
        if let newline = bytes[start...].firstIndex(of: UInt8(ascii: "\n")) {
            start = newline + 1
        }
        return String(decoding: bytes[start...], as: UTF8.self)
    }
}

#endif
