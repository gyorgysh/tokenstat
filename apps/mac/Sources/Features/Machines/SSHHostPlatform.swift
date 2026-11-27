// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

@MainActor @Observable
final class SSHHostPlatformCache {
    static let shared = SSHHostPlatformCache()
    private static let storageKey = "ssh.confirmedPlatforms.v1"
    struct Entry: Codable {
        let label: String
        let hostname: String
        let port: Int
        let hostKeys: [String]
        let saved: Date
    }
    private var entries: [String: Entry]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let migrated = try? JSONDecoder().decode([String: Entry].self, from: data),
           !migrated.isEmpty
        {
            entries = migrated
        } else {
            entries = [:]
        }
    }
    func label(for host: SSHHost, now: Date = Date()) -> String? {
        guard let entry = entries[host.id],
              now.timeIntervalSince(entry.saved) < 90 * 86400
        else { return nil }
        if !entry.hostname.isEmpty,
           (entry.hostname != host.hostname.lowercased() || entry.port != host.port)
        { return nil }
        if entry.hostKeys.isEmpty, !host.hostKeys.isEmpty {
            entries[host.id] = Entry(label: entry.label, hostname: entry.hostname, port: entry.port, hostKeys: host.hostKeys.sorted(), saved: entry.saved)
            if let data = try? JSONEncoder().encode(entries) {
                defaults.set(data, forKey: Self.storageKey)
            }
            return entry.label
        }
        if !entry.hostKeys.isEmpty, entry.hostKeys.sorted() != host.hostKeys.sorted() { return nil }
        return entry.label
    }
    func remember(_ check: ServerCheck, for host: SSHHost, now: Date = Date()) {
        let label = (check.distro?.isEmpty == false ? check.distro : check.os) ?? ""
        let clean = String(label.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ").prefix(80))
        guard !clean.isEmpty else { return }
        entries[host.id] = Entry(
            label: clean,
            hostname: host.hostname.lowercased(),
            port: host.port,
            hostKeys: host.hostKeys.sorted(),
            saved: now
        )
        if entries.count > 128 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.saved > $1.value.saved }.prefix(128).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
    func forget(hostID: String) {
        entries.removeValue(forKey: hostID)
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

/// Asset name for a Linux distribution's mark, or nil when none is bundled.
///
/// Vendor marks, not ours: see TRADEMARK.md. The SVGs are Simple Icons
/// renditions (CC0) of each distribution's own logo, used only to identify
/// the OS the host itself reported in `/etc/os-release`. A distribution with
/// no bundled mark falls back to the generic Linux mark, then to a neutral
/// server glyph: never an invented initial, and never another distro's logo.
func distroBrandAsset(_ label: String?) -> String? {
    guard let id = distroBrandID(label) else { return nil }
    return "brand_distro_\(id)"
}

func distroBrandID(_ label: String?) -> String? {
    guard let label, !label.isEmpty else { return nil }
    let name = label.lowercased()
    let tokens = Set(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    if name.contains("ubuntu") { return "ubuntu" }
    if name.contains("debian") { return "debian" }
    if name.contains("fedora") { return "fedora" }
    if name.contains("alpine") { return "alpinelinux" }
    if tokens.contains("arch") || name.contains("arch linux") { return "archlinux" }
    if name.contains("nixos") || name.contains("nix os") { return "nixos" }
    if tokens.contains("mint") || name.contains("linux mint") { return "linuxmint" }
    if name.contains("gentoo") { return "gentoo" }
    if name.contains("rocky") { return "rockylinux" }
    if tokens.contains("alma") || name.contains("almalinux") { return "almalinux" }
    if name.contains("centos") { return "centos" }
    if name.contains("red hat") || tokens.contains("rhel") { return "redhat" }
    if name.contains("opensuse") { return "opensuse" }
    if tokens.contains("suse") || tokens.contains("sles") { return "suse" }
    if tokens.contains("linux") { return "linux" }
    return nil
}
