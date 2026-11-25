// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// The part of a handle's rules that needs no server.
///
/// The account service decides. This only keeps a form from asking about a
/// name that cannot be one, and words the reasons it answers with.
enum HandleRules {
    static let minimum = 4
    static let maximum = 32

    /// What somebody types or pastes, as the handle they meant. A pasted
    /// profile address and a leading @ are both the name at the end of them.
    static func normalized(_ raw: String) -> String {
        var text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = text.range(of: "tokenstat.ai/") { text = String(text[slash.upperBound...]) }
        while text.hasPrefix("@") || text.hasPrefix("/") { text.removeFirst() }
        if let end = text.firstIndex(where: { "/?#".contains($0) }) { text = String(text[..<end]) }
        return String(text.split(whereSeparator: \.isWhitespace).joined(separator: "-").prefix(maximum))
    }

    /// The server's reason for a name it would refuse on sight, or nil when
    /// only the server can answer.
    static func localReason(_ handle: String) -> String? {
        if handle.count < minimum { return "too_short" }
        if handle.count > maximum { return "too_long" }
        let allowed = handle.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
        if !allowed || handle.hasPrefix("-") || handle.hasSuffix("-") { return "invalid_characters" }
        if handle.contains("--") { return "double_dash" }
        if handle.utf8.allSatisfy({ (0x30...0x39).contains($0) }) { return "numeric_only" }
        return nil
    }

    /// A reason in words. `fallback` is the server's own sentence, for a reason
    /// newer than this app and for the one that carries a number of days.
    static func message(_ reason: String?, fallback: String = "") -> String {
        switch reason {
        case "too_short", "reserved_premium": return L10n.text("common.handle.reason.too_short", "\(minimum)")
        case "too_long": return L10n.text("common.handle.reason.too_long", "\(maximum)")
        case "invalid_characters", "invalid": return L10n.text("common.handle.reason.characters")
        case "double_dash": return L10n.text("common.handle.reason.double_dash")
        case "numeric_only": return L10n.text("common.handle.reason.numeric")
        case "taken": return L10n.text("common.handle.reason.taken")
        case "reserved", "reserved_lookalike", "inappropriate": return L10n.text("common.handle.reason.unavailable")
        default: return fallback.isEmpty ? L10n.text("common.handle.reason.unavailable") : fallback
        }
    }

    /// `tokenstat.ai/name`, the way an address is written for a person.
    static func address(host: String, handle: String) -> String {
        "\(prefix(host: host))\(handle)"
    }

    static func prefix(host: String) -> String {
        var text = host
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        while text.hasSuffix("/") { text.removeLast() }
        return text + "/"
    }
}
