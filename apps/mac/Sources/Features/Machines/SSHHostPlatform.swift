// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation
import CryptoKit

/// Confirmed server metadata, local to this device. Never infer an OS from an address.
@MainActor @Observable
final class SSHHostPlatformCache {
    static let shared = SSHHostPlatformCache()
    private static let storageKey = "ssh.confirmedPlatforms.v1"
    struct Entry: Codable {
        let label: String
        let saved: Date
    }
    private var entries: [String: Entry]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }
    private func key(_ host: SSHHost) -> String {
        // Editing an endpoint or its trusted identity invalidates old metadata.
        let parts = [host.id, host.hostname.lowercased(), String(host.port)] + host.hostKeys.sorted()
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func label(for host: SSHHost, now: Date = Date()) -> String? {
        guard let entry = entries[key(host)], now.timeIntervalSince(entry.saved) < 90 * 86400 else { return nil }
        return entry.label
    }
    func remember(_ check: ServerCheck, for host: SSHHost, now: Date = Date()) {
        guard !host.hostKeys.isEmpty else { return }
        let label = (check.distro?.isEmpty == false ? check.distro : check.os) ?? ""
        let clean = String(label.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ").prefix(80))
        guard !clean.isEmpty else { return }
        entries[key(host)] = Entry(label: clean, saved: now)
        if entries.count > 128 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.saved > $1.value.saved }.prefix(128).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
