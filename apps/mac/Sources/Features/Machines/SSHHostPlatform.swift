// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// Confirmed server metadata, local to this device. Never infer an OS from an address.
@MainActor @Observable
final class SSHHostPlatformCache {
    static let shared = SSHHostPlatformCache()
    private static let storageKey = "ssh.confirmedPlatforms.v1"
    struct Entry: Codable {
        let label: String
        /// The endpoint this label was confirmed for, so editing the address
        /// invalidates old metadata instead of showing Ubuntu for a new box.
        let hostname: String
        let port: Int
        /// The trusted identity at confirmation time. Empty where the check
        /// ran before the fingerprint was trusted (the setup wizard probes
        /// first), so a later trust must not orphan the label.
        let hostKeys: [String]
        let saved: Date
    }
    private var entries: [String: Entry]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // v1 stored bare labels keyed by a hash of id+endpoint+keys. Read it
        // once so an upgrade keeps what was confirmed, then write the new shape.
        if let data = defaults.data(forKey: Self.storageKey),
           let migrated = try? JSONDecoder().decode([String: Entry].self, from: data),
           !migrated.isEmpty
        {
            entries = migrated
        } else if let data = defaults.data(forKey: Self.storageKey),
                  let legacy = try? JSONDecoder().decode([String: LegacyEntry].self, from: data)
        {
            entries = Dictionary(uniqueKeysWithValues: legacy.compactMap { key, value in
                (key, Entry(label: value.label, hostname: "", port: 0, hostKeys: [], saved: value.saved))
            })
        } else {
            entries = [:]
        }
    }
    private struct LegacyEntry: Codable {
        let label: String
        let saved: Date
    }
    func label(for host: SSHHost, now: Date = Date()) -> String? {
        guard let entry = entries[host.id],
              now.timeIntervalSince(entry.saved) < 90 * 86400
        else { return nil }
        // An edited endpoint invalidates old metadata.
        if !entry.hostname.isEmpty,
           (entry.hostname != host.hostname.lowercased() || entry.port != host.port)
        { return nil }
        // A changed trusted identity invalidates it too, but only where the
        // label was confirmed against a known identity: a check that ran
        // before the first trust carries no keys and must survive it.
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
    /// Forget what was confirmed for a host, after its endpoint or identity
    /// was edited into something the label no longer describes.
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

/// Simple Icons slug for the distribution named in a platform label, or nil
/// when the label names nothing this build ships a mark for.
func distroBrandID(_ label: String?) -> String? {
    guard let label, !label.isEmpty else { return nil }
    let name = label.lowercased()
    if name.contains("ubuntu") { return "ubuntu" }
    if name.contains("debian") { return "debian" }
    if name.contains("fedora") { return "fedora" }
    if name.contains("alpine") { return "alpinelinux" }
    if name.contains("arch") { return "archlinux" }
    if name.contains("nixos") || name.contains("nix os") { return "nixos" }
    if name.contains("mint") { return "linuxmint" }
    if name.contains("gentoo") { return "gentoo" }
    if name.contains("rocky") { return "rockylinux" }
    if name.contains("alma") { return "almalinux" }
    if name.contains("centos") { return "centos" }
    if name.contains("red hat") || name.contains("rhel") { return "redhat" }
    if name.contains("opensuse") { return "opensuse" }
    if name.contains("suse") || name.contains("sles") { return "suse" }
    if name.contains("linux") { return "linux" }
    return nil
}
