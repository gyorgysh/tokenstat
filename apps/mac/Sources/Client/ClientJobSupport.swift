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
        L10n.text("apple.clientjobsupport.starts_0_in_1_on_2.c720825d", "\(name)", "\(folder)", "\(host)")
    }

    static func stop(_ name: String, folder: String, host: String) -> String {
        L10n.text("apple.clientjobsupport.stops_the_run_of_0_in_1_on_2.4717028b", "\(name)", "\(folder)", "\(host)")
    }

    static func continueGate(_ name: String, folder: String, host: String) -> String {
        L10n.text("apple.clientjobsupport.lets_0_continue_in_1_on_2.4962fc94", "\(name)", "\(folder)", "\(host)")
    }

    static func budget(_ seconds: UInt64) -> String {
        if seconds == 0 { return L10n.text("apple.clientjobsupport.no_time_limit.436b4b94") }
        let minutes = seconds / 60
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return (hours == 1 ? L10n.text("apple.clientjobsupport.0_hour_1.0df4dd9a.one", "\(hours)") : L10n.text("apple.clientjobsupport.0_hour_1.0df4dd9a.other", "\(hours)"))
        }
        return (minutes == 1 ? L10n.text("apple.clientjobsupport.0_minute_1.ef3d336c.one", "\(minutes)") : L10n.text("apple.clientjobsupport.0_minute_1.ef3d336c.other", "\(minutes)"))
    }

    @MainActor
    static func lastRunPhrase(_ date: Date?) -> String {
        guard let date else { return L10n.text("apple.clientjobsupport.never_run.3d40a69d") }
        return L10n.text("apple.clientjobsupport.last_0.857c540b", "\(RelativeClock.phrase(for: date, style: .abbreviated))")
    }

    /// Fact-row value. The label is already "Last", so no prefix.
    @MainActor
    static func lastRunWhen(_ date: Date?) -> String {
        guard let date else { return L10n.text("apple.clientjobsupport.never_run.3d40a69d") }
        return RelativeClock.phrase(for: date, style: .abbreviated)
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
